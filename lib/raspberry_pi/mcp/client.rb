# frozen_string_literal: true

module RaspberryPi
  module Mcp
    # The MCP JSON-RPC client (port of pi's packages/mcp/src/client.ts):
    # state machine (idle/connecting/connected/closed), initialize handshake,
    # tools/list with pagination, tools/call — each request deadline-bounded
    # by the 30 s default timeout.
    class Client
      LATEST_PROTOCOL_VERSION = "2025-11-25"
      # Versions the client accepts from a server (pi's SUPPORTED_PROTOCOL_VERSIONS).
      SUPPORTED_PROTOCOL_VERSIONS = [LATEST_PROTOCOL_VERSION, "2025-06-18", "2025-03-26", "2024-11-05"].freeze
      DEFAULT_REQUEST_TIMEOUT_MS = 30_000
      MAX_LIST_PAGES = 1_000

      attr_reader :protocol_version, :server_info, :server_capabilities, :instructions

      # @param name [String] client info name (pi's Implementation.name).
      # @param version [String] client info version.
      # @param request_timeout_ms [Integer] default per-request timeout.
      # @param on_error [Proc, nil] called with protocol/transport errors that
      #   pi reports to its error listeners (late responses, invalid messages).
      def initialize(name: "raspberry-pi", version: RaspberryPi::VERSION,
                     request_timeout_ms: DEFAULT_REQUEST_TIMEOUT_MS, on_error: nil)
        @name = name
        @version = version
        @request_timeout_ms = request_timeout_ms
        @on_error = on_error
        @state = "idle"
        @next_request_id = 1
        @pending = {}
        @pending_mutex = Mutex.new
      end

      def connection_state
        @state
      end

      # Runs the initialize handshake on +transport+, then announces
      # notifications/initialized.
      #
      # @raise [Mcp::Error] "Invalid MCP initialize result" when the server's
      #   result fails validation; "MCP server selected unsupported protocol
      #   version X" when it answers with a version the client doesn't speak.
      def connect(transport)
        raise "Cannot connect MCP client in #{@state} state" unless @state == "idle"

        @state = "connecting"
        @transport = transport
        @pending_transport = transport
        transport.on_message = ->(message) { handle_message(message) }
        transport.on_error = ->(error) { emit_error(error) }
        transport.on_close = -> { handle_transport_close }
        transport.start
        result = request("initialize", {
          "protocolVersion" => LATEST_PROTOCOL_VERSION,
          "capabilities" => {},
          "clientInfo" => {"name" => @name, "version" => @version}
        })
        validate_initialize_result(result)
        unless SUPPORTED_PROTOCOL_VERSIONS.include?(result["protocolVersion"])
          raise "MCP server selected unsupported protocol version #{result['protocolVersion']}"
        end

        @protocol_version = result["protocolVersion"]
        @server_info = result["serverInfo"]
        @server_capabilities = result["capabilities"]
        @instructions = result["instructions"]
        notify("notifications/initialized")
        @state = "connected"
        result
      rescue Exception
        @transport = nil
        begin
          transport.close
        rescue StandardError
          nil
        end
        @state = "closed"
        raise
      end

      def list_tools(timeout_ms: nil)
        items = []
        cursors = []
        cursor = nil
        MAX_LIST_PAGES.times do
          page = request("tools/list", cursor ? {"cursor" => cursor} : nil, timeout_ms:)
          items.concat(validate_list_page("tools/list", "tools", page) { |item| tool?(item) })
          next_cursor = page.is_a?(Hash) ? page["nextCursor"] : nil
          next_cursor = nil if next_cursor.nil? || next_cursor == ""
          unless next_cursor.nil?
            raise "MCP tools/list returned duplicate cursor: #{next_cursor}" if cursors.include?(next_cursor)

            cursors << next_cursor
          end
          return items if next_cursor.nil?

          cursor = next_cursor
        end
        raise "MCP tools/list exceeded #{MAX_LIST_PAGES} pages"
      end

      def call_tool(name, args = nil, timeout_ms: nil)
        params = {"name" => name}
        params["arguments"] = args if args
        result = request("tools/call", params, timeout_ms:)
        validate_call_tool_result(result)
      end

      def close
        return if @state == "closed"

        @state = "closed"
        transport, @transport = @transport, nil
        fail_pending(ConnectionClosedError.new)
        transport&.close
      end

      def closed?
        @state == "closed"
      end

      private

      # @raise [ConnectionClosedError] "MCP client is <state>" when no usable
      #   transport (pi's requireTransport).
      def require_transport
        transport = @transport
        return transport if transport && (@state == "connected" || @state == "connecting")

        raise ConnectionClosedError, "MCP client is #{@state}"
      end

      def request(method, params = nil, timeout_ms: nil)
        transport = require_transport
        id = @next_request_id
        @next_request_id += 1
        queue = Queue.new
        @pending_mutex.synchronize { @pending[id] = queue }
        message = {"jsonrpc" => "2.0", "id" => id, "method" => method}
        message["params"] = params if params
        timeout_ms ||= @request_timeout_ms
        begin
          transport.send(message)
        rescue StandardError => e
          @pending_mutex.synchronize { @pending.delete(id) }
          raise e
        end
        await_response(id, queue, timeout_ms)
      end

      def notify(method, params = nil)
        transport = require_transport
        message = {"jsonrpc" => "2.0", "method" => method}
        message["params"] = params if params
        transport.send(message)
      end

      def await_response(id, queue, timeout_ms)
        deadline = clock_ms + timeout_ms
        loop do
          remaining = (deadline - clock_ms) / 1000.0
          raise TimeoutError.new(timeout_ms) if remaining <= 0

          delivery = queue.pop(timeout: remaining)
          raise TimeoutError.new(timeout_ms) if delivery.nil?

          return delivery[:result] if delivery.key?(:result)
          raise delivery[:closed] if delivery.key?(:closed)

          error = delivery[:error]
          raise Mcp::Error.new(error["code"], error["message"], error["data"])
        end
      ensure
        @pending_mutex.synchronize { @pending.delete(id) }
      end

      # pi's handleMessage dispatch order: response, request, notification.
      def handle_message(message)
        return handle_response(message) if JsonRpc.response?(message)
        return handle_request(message) if JsonRpc.request?(message)
        return if JsonRpc.notification?(message) # progress et al.: out of scope

        emit_error(Mcp::Error.new(JsonRpc::ERROR_CODES[:invalid_request], "Received invalid JSON-RPC message"))
      end

      def handle_response(message)
        queue = @pending_mutex.synchronize { @pending[message["id"]] }
        unless queue
          emit_error(StandardError.new("Received response for unknown MCP request #{message['id'].inspect}"))
          return
        end

        queue << if message.key?("error")
          {error: message["error"]}
        else
          {result: message["result"]}
        end
      end

      # Server->client requests: ping answers {} (pi's built-in handler);
      # anything else is methodNotFound.
      def handle_request(message)
        result = {"jsonrpc" => "2.0", "id" => message["id"]}
        if message["method"] == "ping"
          result["result"] = {}
        else
          result["error"] = {"code" => JsonRpc::ERROR_CODES[:method_not_found],
                             "message" => "Method not found: #{message['method']}"}
        end
        require_transport.send(result)
      rescue StandardError => e
        emit_error(e)
      end

      def handle_transport_close
        return if @state == "closed"

        @state = "closed"
        @transport = nil
        fail_pending(ConnectionClosedError.new)
      end

      def fail_pending(error)
        @pending_mutex.synchronize do
          @pending.each_value { |queue| queue << {closed: error} }
          @pending.clear
        end
      end

      def validate_initialize_result(result)
        invalid = JsonRpc.object?(result) && JsonRpc.object?(result["serverInfo"]) &&
          result["serverInfo"]["name"].is_a?(String) && result["serverInfo"]["version"].is_a?(String) &&
          JsonRpc.object?(result["capabilities"]) && result["protocolVersion"].is_a?(String)
        return result if invalid

        raise Mcp::Error.new(JsonRpc::ERROR_CODES[:invalid_request], "Invalid MCP initialize result")
      end

      # @return [Array] the page's items under +key+, each checked by the
      #   block (pi's validateListPage).
      def validate_list_page(method, key, value)
        items = JsonRpc.object?(value) ? value[key] : nil
        raise Mcp::Error.new(JsonRpc::ERROR_CODES[:invalid_request], "Invalid MCP #{method} result") unless
          JsonRpc.object?(value) && items.is_a?(Array)

        items.each do |item|
          unless JsonRpc.object?(item) && yield(item)
            raise Mcp::Error.new(JsonRpc::ERROR_CODES[:invalid_request], "Invalid entry in MCP #{method} result")
          end
        end
        # Some servers end pagination with `null` or "" instead of omitting the cursor.
        next_cursor = value["nextCursor"]
        next_cursor = nil if next_cursor == ""
        if !next_cursor.nil? && !next_cursor.is_a?(String)
          raise Mcp::Error.new(JsonRpc::ERROR_CODES[:invalid_request], "Invalid MCP #{method} cursor")
        end
        items
      end

      def validate_call_tool_result(result)
        unless JsonRpc.object?(result) && (result["content"].nil? || result["content"].is_a?(Array))
          raise Mcp::Error.new(JsonRpc::ERROR_CODES[:invalid_request], "Invalid MCP tools/call result")
        end
        if result.key?("structuredContent") && !JsonRpc.object?(result["structuredContent"])
          raise Mcp::Error.new(JsonRpc::ERROR_CODES[:invalid_request], "Invalid MCP tools/call structured content")
        end

        result["content"] ||= []
        result
      end

      def tool?(tool)
        tool["name"].is_a?(String) && JsonRpc.object?(tool["inputSchema"])
      end

      def emit_error(error)
        @on_error&.call(error)
      end

      def clock_ms
        Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000
      end
    end
  end
end
