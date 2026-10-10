# frozen_string_literal: true

require "json"

module RaspberryPi
  module Mcp
    # JSON-RPC 2.0 error vocabulary and message validation (port of pi's
    # packages/mcp/src/protocol/jsonrpc.ts).
    #
    # Every failure is an {Mcp::Error} carrying the JSON-RPC error code;
    # malformed inbound messages are reported, never crash the reader.
    class Error < StandardError
      attr_reader :code, :data

      def initialize(code, message, data = nil)
        super(message)
        @code = code
        @data = data
      end
    end

    # The MCP connection dropped (child exited, stdin/stdout closed).
    class ConnectionClosedError < StandardError
      def initialize(message = "MCP connection closed")
        super
      end
    end

    # A request outlived its timeout (pi's McpTimeoutError).
    class TimeoutError < StandardError
      attr_reader :timeout_ms

      def initialize(timeout_ms)
        super("MCP request timed out after #{timeout_ms}ms")
        @timeout_ms = timeout_ms
      end
    end

    # Message shapes and validation (pi's parseJsonRpcMessage and predicates).
    module JsonRpc
      ERROR_CODES = {
        parse_error: -32_700,
        invalid_request: -32_600,
        method_not_found: -32_601,
        invalid_params: -32_602,
        internal_error: -32_603
      }.freeze

      module_function

      def object?(value)
        value.is_a?(Hash)
      end

      # A JSON-RPC id is a string or a finite number.
      def id?(value)
        value.is_a?(String) || (value.is_a?(Numeric) && value.finite?)
      end

      def request?(message)
        object?(message) && message["jsonrpc"] == "2.0" && id?(message["id"]) &&
          message["method"].is_a?(String)
      end

      def notification?(message)
        object?(message) && message["jsonrpc"] == "2.0" && !message.key?("id") &&
          message["method"].is_a?(String)
      end

      def response?(message)
        return false unless object?(message) && message["jsonrpc"] == "2.0" && id?(message["id"])
        # result XOR error (pi: `if ("result" in message) return !("error" in message)`).
        return !message.key?("error") if message.key?("result")
        return false unless message.key?("error") && object?(message["error"])

        message["error"]["code"].is_a?(Numeric) && message["error"]["message"].is_a?(String)
      end

      # @return [Hash] the message, validated.
      # @raise [Mcp::Error] invalid_request "Invalid JSON-RPC message" otherwise.
      def parse_message(message)
        return message if request?(message) || notification?(message) || response?(message)

        raise Mcp::Error.new(ERROR_CODES[:invalid_request], "Invalid JSON-RPC message")
      end
    end
  end
end
