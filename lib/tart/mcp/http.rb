# frozen_string_literal: true

require "async"
require "json"
require "net/http"
require "uri"

require_relative "jsonrpc"

module Tart
  module Mcp
    # The Streamable HTTP transport (port of pi's
    # packages/mcp/src/transports/streamable-http.ts): JSON-RPC over HTTP
    # POST with the reply arriving as `application/json` or
    # `text/event-stream`, the session id riding the `Mcp-Session-Id`
    # header, and the negotiated protocol version riding
    # `MCP-Protocol-Version` on every request after initialize.
    #
    # - every request is one POST to the configured URL; notifications and
    #   client-side responses are acknowledged (2xx, body discarded) and
    #   carry no reply;
    # - a request answered on an SSE response stream is consumed UNTIL ITS
    #   ANSWER ARRIVES, then send returns (the connection closes behind
    #   it — pi consumes to stream end in a background task; the trailing
    #   events are the itemized cut). A stream that ends before the answer
    #   fails that request with pi's exact message, raised through the
    #   client's send-failure wall;
    # - after `notifications/initialized` the server-to-client GET stream
    #   opens ONCE as a reader task (405 = the server offers none, quiet
    #   stop) and its events flow to on_message; a dropped GET stream is
    #   NOT reconnected (pi's backoff + Last-Event-ID machinery is the
    #   itemized cut);
    # - close: stop the reader task, then a best-effort DELETE with the
    #   session header (the session expires server-side anyway).
    #
    # I107 (T6/D2 law): the GET-stream reader task is a HOST-REACTOR task
    # — start runs on a reactor seat exactly like Stdio (production: the
    # Sync-wrapped interactive boot / tool tasks; tests: Sync-wrapped
    # scenarios). Off-reactor callers get the named seat error and the
    # connect fails as a warn-and-skip (the mcp-print-reactor backlog
    # class).
    #
    # CUT from pi (itemized deviations, BRIEF §5): the OAuth auth provider
    # (tart speaks plain configured headers; a 401 is the named
    # AuthRequiredError), the reconnect/backoff/Last-Event-ID resumption
    # machinery, and the fetch injection (Net::HTTP is the one client).
    class Http
      DEFAULT_MAX_MESSAGE_BYTES = Stdio::DEFAULT_MAX_MESSAGE_BYTES
      # The error body excerpt kept for the failure message (pi's MAX_ERROR_BODY_BYTES).
      MAX_ERROR_BODY_BYTES = 8 * 1024
      # The snippet length inside the failure message (pi's ERROR_MESSAGE_BODY_CHARS).
      ERROR_MESSAGE_BODY_CHARS = 500
      # The close DELETE's bounded wait (pi's AbortSignal.timeout(1_000)).
      CLOSE_DELETE_TIMEOUT_S = 1

      # pi's McpHttpError: a non-2xx reply the transport could not turn
      # into a protocol result.
      class HttpError < StandardError
        attr_reader :status, :body

        def initialize(status, message, body = "")
          super(message)
          @status = status
          @body = body
        end
      end

      # pi's McpAuthRequiredError: a 401 (tart has no OAuth flow — the
      # configured headers are the credentials).
      class AuthRequiredError < HttpError
        def initialize(body = "")
          super(401, "MCP server requires authentication", body)
        end
      end

      # pi's McpSessionExpiredError: a 404 while holding a session id.
      class SessionExpiredError < HttpError
        def initialize(body = "")
          super(404, "MCP session expired", body)
        end
      end

      attr_reader :url, :session_id
      attr_accessor :on_message, :on_error, :on_close

      def initialize(url:, headers: nil,
                     max_message_bytes: DEFAULT_MAX_MESSAGE_BYTES,
                     request_timeout_ms: Client::DEFAULT_REQUEST_TIMEOUT_MS,
                     open_get_stream: true)
        @uri = URI.parse(url)
        @headers = headers
        @max_message_bytes = max_message_bytes
        @request_timeout_s = request_timeout_ms / 1000.0
        @open_get_stream = open_get_stream
        @on_message = @on_error = @on_close = nil
        @started = false
        @closed = false
        @session_id = nil
        @protocol_version = nil
        @get_stream_started = false
        @task = @get_stream_task = nil
      end

      def started?
        @started
      end

      def closed?
        @closed
      end

      # pi's setProtocolVersion: the client reports the negotiated version
      # after initialize and it rides the MCP-Protocol-Version header.
      def set_protocol_version(version)
        @protocol_version = version
      end

      # @raise [ArgumentError] off the host reactor (the Stdio seat law).
      def start
        raise "MCP Streamable HTTP transport already started" if @started
        raise ConnectionClosedError if @closed
        task = Async::Task.current? or raise ArgumentError,
          "MCP HTTP start runs on the host reactor (Sync-wrapped scenario or tool task)"

        @started = true
        @task = task
      end

      # One POST per message (pi's send). The reply's STATUS is checked
      # inline — a 401/404/5xx fails the request fast — and the body is
      # consumed inside the request (Net::HTTP's session model), so a
      # JSON reply lands on on_message before send returns and an SSE
      # reply streams until this request's answer arrives.
      #
      # @raise [HttpError, AuthRequiredError, SessionExpiredError,
      #   ConnectionClosedError, StandardError] the POST/parse failures —
      #   the client's send-failure wall converts them to Failure values.
      def send(message)
        raise ConnectionClosedError if !@started || @closed

        request = Net::HTTP::Post.new(request_path)
        apply_headers(request, "accept" => "application/json, text/event-stream",
                                "content-type" => "application/json")
        request.body = JSON.generate(message)
        perform(request, @request_timeout_s) do |response|
          check_response(response)
          capture_session(response)
          unless JsonRpc.request?(message)
            # Acknowledged (2xx), no reply; the server-to-client stream
            # may only open once the session is initialized (pi's gate).
            start_get_stream if @open_get_stream && message["method"] == "notifications/initialized"
            next
          end
          if [202, 204].include?(status_of(response))
            raise HttpError.new(status_of(response),
                                "MCP server accepted request #{message['method']} without a response")
          end

          type = content_type(response)
          if type == "application/json"
            emit_json_body(response)
          elsif type == "text/event-stream"
            consume_response_stream(response, message["id"])
          else
            raise HttpError.new(status_of(response),
                                "Unsupported MCP response content type: #{type || 'missing'}")
          end
        end
        nil
      end

      def close
        return if @closed

        @closed = true
        stop_tasks
        if @started && @session_id
          # Best effort: the session expires on the server anyway (pi's
          # close()); the bounded DELETE never blocks teardown long.
          request = Net::HTTP::Delete.new(request_path)
          apply_headers(request, {})
          begin
            perform(request, CLOSE_DELETE_TIMEOUT_S) { |_response| nil }
          rescue StandardError
            nil
          end
        end
        emit_close
      end

      private

      # -- HTTP plumbing ----------------------------------------------------

      def request_path
        path = @uri.request_uri
        path.empty? ? "/" : path
      end

      def perform(request, timeout_s, &block)
        http = Net::HTTP.new(@uri.host, @uri.port)
        http.use_ssl = @uri.scheme == "https"
        http.open_timeout = timeout_s
        http.read_timeout = timeout_s
        http.request(request, &block)
      end

      def apply_headers(request, extra)
        (@headers || {}).merge(extra).each { |name, value| request[name] = value }
        request["Mcp-Session-Id"] = @session_id if @session_id
        request["MCP-Protocol-Version"] = @protocol_version if @protocol_version
        request
      end

      def capture_session(response)
        session = response["mcp-session-id"]
        @session_id = session if session && !session.empty?
      end

      def status_of(response)
        response.code.to_i
      end

      def content_type(response)
        response["content-type"]&.split(";", 2)&.first&.strip&.downcase
      end

      # Reads the body as text, keeping at most +max_bytes+ (pi's
      # readBodyText — the rest is dropped and reported truncated).
      def read_body_text(response, max_bytes)
        text = +""
        truncated = false
        response.read_body do |chunk|
          remaining = max_bytes - text.bytesize
          break if remaining <= 0

          piece = chunk.byteslice(0, remaining)
          text << piece
          truncated = true if piece.bytesize < chunk.bytesize
          break if truncated
        end
        [text, truncated]
      end

      def check_response(response)
        return if (200..299).cover?(status_of(response))

        text, = read_body_text(response, MAX_ERROR_BODY_BYTES)
        status = status_of(response)
        raise AuthRequiredError.new(text) if status == 401
        raise SessionExpiredError.new(text) if status == 404 && @session_id
        raise HttpError.new(status, describe_http_failure(status, text), text)
      end

      # pi's describeHttpFailure: the excerpt keeps the first 500 chars.
      def describe_http_failure(status, body)
        text = body.strip
        snippet = text.length > ERROR_MESSAGE_BODY_CHARS ? "#{text[0, ERROR_MESSAGE_BODY_CHARS - 3]}..." : text
        "MCP HTTP request failed with status #{status}#{snippet.empty? ? '' : ": #{snippet}"}"
      end

      # -- message emission -------------------------------------------------

      def emit_json_body(response)
        text, truncated = read_body_text(response, @max_message_bytes)
        raise StandardError, "MCP JSON response exceeds #{@max_message_bytes} bytes" if truncated

        body = JSON.parse(text)
        items = body.is_a?(Array) ? body : [body]
        items.each { |item| emit_message(item) }
      end

      def emit_message(item)
        @on_message&.call(JsonRpc.parse_message(item))
      rescue JSON::ParserError, Mcp::Error => e
        emit_error(e)
      end

      def emit_error(error)
        @on_error&.call(error)
      end

      def emit_close
        return if @close_emitted

        @close_emitted = true
        @on_close&.call
      end

      # -- SSE ---------------------------------------------------------------

      # The request's SSE reply: every parsed message flows to on_message
      # until THIS request's answer arrives, then the read stops (the
      # connection closes behind it). A stream that ends first fails the
      # request with pi's exact message (pi's no-resumption branch — the
      # resumption machinery itself is the itemized cut).
      def consume_response_stream(response, request_id)
        answered = consume_sse(response, request_id)
        return if answered || @closed

        raise StandardError, "MCP response stream failed: stream ended without a response"
      end

      # The server-to-client stream: opens ONCE after initialization; 405
      # = the server offers none (quiet stop); consumed until the server
      # closes it; a drop is NOT reconnected (the itemized cut). Runs as
      # a transient task on the host reactor.
      def start_get_stream
        return if !@open_get_stream || @get_stream_started || @closed

        @get_stream_started = true
        @get_stream_task = @task.async(transient: true) do
          request = Net::HTTP::Get.new(request_path)
          apply_headers(request, "accept" => "text/event-stream")
          perform(request, @request_timeout_s) do |response|
            next if status_of(response) == 405 # the server does not offer a GET stream

            check_response(response)
            capture_session(response)
            type = content_type(response)
            unless type == "text/event-stream"
              raise HttpError.new(status_of(response),
                                  "Unsupported MCP GET response content type: #{type || 'missing'}")
            end

            consume_sse(response, nil)
          end
        rescue StandardError => e
          emit_error(e) unless @closed
        end
      end

      # The SSE framing parser (pi's consumeSseStream): lines end CRLF,
      # LF, or a lone CR; `:` comments; data/event fields; the pending
      # event's data capped at max_message_bytes. Emits every parsed
      # message; returns whether +request_id+'s answer arrived (nil
      # request_id = consume to stream end).
      def consume_sse(response, request_id)
        answered = false
        parser = SseParser.new(@max_message_bytes)
        parser.on_event = lambda do |data, event|
          # Events without data prime resumption; other event types are
          # not JSON-RPC (pi's filter). The resumption itself is cut.
          next if data.strip.empty? || (!event.nil? && event != "message")

          message = begin
            JsonRpc.parse_message(JSON.parse(data))
          rescue JSON::ParserError, Mcp::Error => e
            emit_error(e)
            next
          end
          answered = true if request_id && JsonRpc.response?(message) && message["id"] == request_id
          @on_message&.call(message)
        end
        response.read_body do |chunk|
          parser.feed(chunk)
          break if request_id && answered
        end
        parser.finish
        answered
      end

      # The incremental SSE line framer (pi's consumeSseStream inner
      # machinery, fed by response body chunks).
      class SseParser
        attr_accessor :on_event

        def initialize(max_event_bytes)
          @max_event_bytes = max_event_bytes
          @buffered = +""
          @skip_leading_lf = false
          @data_lines = nil
          @data_bytes = 0
          @event_name = nil
          @on_event = nil
        end

        def feed(chunk)
          text = chunk.to_s.dup
          if @skip_leading_lf && !text.empty?
            text = text.delete_prefix("\n")
            @skip_leading_lf = false
          end
          @buffered << text
          consume_lines
          if @buffered.bytesize > @max_event_bytes
            raise StandardError, "MCP SSE event exceeds #{@max_event_bytes} bytes"
          end
        end

        # The stream ended: a final unterminated line dispatches too (pi's
        # tail handling).
        def finish
          process_line(@buffered) unless @buffered.empty?
          @buffered.clear
          dispatch
        end

        private

        def consume_lines
          start = 0
          i = 0
          while i < @buffered.length
            char = @buffered[i]
            if char == "\r" || char == "\n"
              process_line(@buffered[start, i - start])
              if char == "\r"
                if i + 1 < @buffered.length
                  i += 1 if @buffered[i + 1] == "\n"
                else
                  @skip_leading_lf = true
                end
              end
              start = i + 1
            end
            i += 1
          end
          @buffered = @buffered[start..] || +""
        end

        def process_line(line)
          if line.empty?
            dispatch
            return
          end
          return if line.start_with?(":")

          colon = line.index(":")
          field = colon.nil? ? line : line[0, colon]
          value = colon.nil? ? "" : line[(colon + 1)..].delete_prefix(" ")
          if field == "data"
            @data_bytes += value.bytesize + (@data_lines&.length&.positive? ? 1 : 0)
            if @data_bytes > @max_event_bytes
              raise StandardError, "MCP SSE event exceeds #{@max_event_bytes} bytes"
            end

            (@data_lines ||= []) << value
          elsif field == "event"
            @event_name = value
          end
          # `id`/`retry` serve resumption only — cut with the reconnect
          # machinery (the itemized deviation); data/event are all the
          # message path needs.
        end

        def dispatch
          if @data_lines.nil? || @data_lines.empty?
            @event_name = nil
            return
          end

          data = @data_lines.join("\n")
          event = @event_name
          @event_name = nil
          @data_lines = nil
          @data_bytes = 0
          @on_event&.call(data, event)
        end
      end

      def stop_tasks
        task = @get_stream_task
        return unless task&.alive?

        task.stop
        begin
          task.wait
        rescue Async::Cancel, StandardError
          nil
        end
      end
    end
  end
end
