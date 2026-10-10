# frozen_string_literal: true

require "socket"
require "json"

module Tart
  class Test < Minitest::Test
    # A hermetic mock OpenAI-compatible endpoint over TCP (127.0.0.1, ephemeral
    # port): the real ruby_llm client (Faraday/net_http, custom-endpoint
    # registration via openai_api_base, protocol :chat_completions) talks to it.
    #
    # Wire details (verified against ruby_llm 2.1.0 gem source):
    # - POST {api_base}/chat/completions; `stream: true` +
    #   `stream_options: {include_usage: true}` when the caller streams.
    # - Streaming reply: HTTP 200, `Content-Type: text/event-stream`,
    #   chunked transfer; SSE `data: <json>\n\n` lines, each an OpenAI delta
    #   ({choices: [{delta: {...}, finish_reason?}]}) plus usage, terminated
    #   by `data: [DONE]`.
    # - Non-streaming reply: HTTP 200 JSON {choices: [{message: {...},
    #   finish_reason}], usage}.
    #
    # Scripting: pass a list of response specs, each either
    #   {type: :stream, content: "text", tool_calls: [{id:, name:, arguments: hash_or_string}]}
    #   {type: :stream, reasoning_content: "thinking"}  (a `reasoning_content` delta
    #     before the content deltas — thinking-model wire shape, ruby_llm
    #     protocols/chat_completions/streaming.rb build_chunk)
    #   {type: :stream, chunks: [delta_hashes...]}   (raw deltas, full control)
    #   {type: :message, content: "text"}            (non-streaming JSON)
    #   {type: :slow_stream, content:, chunk_every:} (streams slowly, for interrupts)
    #   {type: :error, status: 400, message: "..."}  (HTTP error the client raises
    #     on — transport/error_middleware.rb maps 400 to BadRequestError)
    # Every captured request body is pushed to +requests+ (a Queue) for
    # assertions (e.g. schema gating against the actual payload).
    class MockLLMServer
      attr_reader :port, :requests

      def initialize
        @server = TCPServer.new("127.0.0.1", 0)
        @port = @server.addr[1]
        @requests = Queue.new
        @script = []
        @accept_thread = nil
      end

      def script(response_specs)
        @script = response_specs.dup
        self
      end

      def start
        @accept_thread = Thread.new do
          loop do
            client = @server.accept
            Thread.new(client) { |io| serve(io) }
          end
        rescue StandardError
          nil # socket closed at teardown
        end
        self
      end

      def stop
        @server.close
        @accept_thread&.join(1)
      rescue IOError
        nil
      end

      def url
        "http://127.0.0.1:#{@port}/v1"
      end

      # Drains and returns all captured request bodies (parsed JSON).
      def captured_requests
        list = []
        list << @requests.pop(true) until @requests.empty?
        list
      end

      private

      def serve(io)
        request_line = io.gets
        headers = {}
        while (line = io.gets) && line != "\r\n"
          name, value = line.split(":", 2)
          headers[name.to_s.strip.downcase] = value.to_s.strip
        end
        body = io.read(headers["content-length"].to_i)
        @requests << JSON.parse(body) unless body.to_s.empty?
        _ = request_line

        spec = @script.shift || {type: :message, content: ""}
        if spec[:type] == :error
          respond_error(io, spec)
        elsif headers["accept"].to_s.include?("text/event-stream") || body.to_s.include?('"stream":true')
          respond_stream(io, spec)
        else
          respond_message(io, spec)
        end
      rescue Errno::EPIPE
        # The client was torn down mid-response (interrupt tests disconnect
        # mid-stream); a dead socket must not pollute suite stderr (I03
        # backlog carry-in).
        nil
      ensure
        io.close rescue nil
      end

      def respond_message(io, spec)
        payload = {
          choices: [{message: {role: "assistant", content: spec[:content]}, finish_reason: "stop"}],
          usage: {prompt_tokens: 10, completion_tokens: 5, total_tokens: 15},
        }
        out = JSON.generate(payload)
        io.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{out.bytesize}\r\n\r\n#{out}")
      end

      # The body openai-compatible endpoints return on a schema rejection;
      # ruby_llm's error middleware raises on the status before any stream
      # is read.
      def respond_error(io, spec)
        payload = {error: {message: spec[:message], type: "invalid_request_error"}}
        out = JSON.generate(payload)
        status = spec[:status] || 400
        io.write("HTTP/1.1 #{status} Bad Request\r\nContent-Type: application/json\r\nContent-Length: #{out.bytesize}\r\n\r\n#{out}")
      end

      def respond_stream(io, spec)
        deltas = spec[:type] == :slow_stream ? slow_deltas(spec) : deltas_for(spec)
        io.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n")
        deltas.each do |delta|
          write_sse(io, delta)
        end
        write_sse(io, {usage: {prompt_tokens: 10, completion_tokens: 5, total_tokens: 15}})
        done = "data: [DONE]\n\n"
        io.write(format("%x\r\n%s\r\n", done.bytesize, done))
        io.write("0\r\n\r\n")
      end

      def slow_deltas(spec)
        content = spec[:content]
        deltas = [{choices: [{delta: {role: "assistant"}}]}]
        content.chars.each do |char|
          deltas << {choices: [{delta: {content: char}}]}
          deltas << :pause
        end
        deltas
      end

      def deltas_for(spec)
        return spec[:chunks] if spec[:chunks]

        reasoning = [{choices: [{delta: {reasoning_content: spec[:reasoning_content]}}]}] if spec[:reasoning_content]
        deltas = [*reasoning, {choices: [{delta: {role: "assistant", content: spec[:content] || ""}}]}]
        Array(spec[:tool_calls]).each_with_index do |call, i|
          deltas << {choices: [{delta: {tool_calls: [{index: i, id: call[:id], type: "function",
                                                      function: {name: call[:name], arguments: ""}}]}}]}
          arguments = call[:arguments].is_a?(String) ? call[:arguments] : JSON.generate(call[:arguments])
          deltas << {choices: [{delta: {tool_calls: [{index: i, function: {arguments: arguments}}]}}]}
        end
        deltas << {choices: [{delta: {}, finish_reason: spec[:tool_calls] ? "tool_calls" : "stop"}]}
        deltas
      end

      def write_sse(io, delta)
        if delta == :pause
          sleep(spec_pause) # real inter-chunk delay: the interrupt test races this
          # The keepalive comment must carry proper chunked framing — bare
          # bytes into a chunked stream corrupt the chunk-size lines (raw
          # net/http repro: Net::HTTPBadResponse after the first pause).
          write_chunk(io, ": keepalive\n\n")
          return
        end

        write_chunk(io, "data: #{JSON.generate(delta)}\n\n")
      rescue Errno::EPIPE
        nil
      end

      def write_chunk(io, payload)
        # The client may be torn down mid-stream (interrupt tests disconnect
        # mid-response); writing to a dead socket must not pollute suite
        # stderr with EPIPE noise (I03 backlog carry-in).
        io.write(format("%x\r\n%s\r\n", payload.bytesize, payload))
        io.flush
      rescue Errno::EPIPE
        nil
      end

      def spec_pause
        0.1
      end
    end

    # A ruby_llm chat pointed at a MockLLMServer — the real client on the
    # custom-endpoint path, hermetically.
    class TestChat
      class << self
        def build(server, tools: [], system_prompt: nil, request_timeout: 10)
          context = RubyLLM.context do |config|
            config.openai_api_key = "test-key"
            config.openai_api_base = server.url
            config.request_timeout = request_timeout
            config.max_retries = 0
          end
          chat = context.chat(model: "tart-test-model", provider: "openai",
                              protocol: :chat_completions, assume_model_exists: true)
          chat.with_tools(*tools) unless tools.empty?
          chat.with_instructions(system_prompt) if system_prompt
          chat
        end
      end
    end
  end
end
