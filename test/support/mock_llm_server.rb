# frozen_string_literal: true

require "socket"
require "json"

# A hermetic mock OpenAI-compatible endpoint over TCP (127.0.0.1, ephemeral
# port): the real fast-completions client (fiber-native on the caller's
# registration via openai_api_base, protocol :chat_completions) talks to it.
#
# Defined at TOP LEVEL (not nested in Tart::Test) so non-minitest callers —
# the pty-tester parity rig (bin/pty-tester) — can load this file without
# minitest on the load path. The historical nesting is preserved as a
# constant alias below; existing suite callers are unaffected.
#
# Parity-rig extensions (I02), backward compatible:
# - +request_logs+ / +captured_request_logs+: per-request entries
#   {method:, path:, headers:, body:} (the rig evidences which URL path and
#   dialect each app POSTs with, not just the body).
# - +rearm!+: resets the shifting script queue to the template stored by the
#   last +script+ call, so ONE server instance can serve pi and tart in the
#   same run with byte-identical responses.
#
# Wire details (the chat-completions wire shape):
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
#     before the content deltas — thinking-model wire shape, the delta
#     protocols/chat_completions/streaming.rb build_chunk)
#   {type: :stream, chunks: [delta_hashes...]}   (raw deltas, full control)
#   {type: :message, content: "text"}            (non-streaming JSON)
#   {type: :slow_stream, content:, chunk_every:} (streams slowly, for interrupts)
#   {type: :error, status: 400, message: "..."}  (HTTP error the client raises
#     on — transport/error_middleware.rb maps 400 to BadRequestError)
#   {type: :models, ids: [...]}                  (I71: the /v1/models listing
#     shape — {"object":"list","data":[{id:, object:"model"}...]}; answers
#     ANY request (the listing GET included) with that JSON. Optional
#     overrides: status: (a non-200 listing reply) and raw: (a malformed
#     body served verbatim).)
# Every captured request body is pushed to +requests+ (a Queue) for
# assertions (e.g. schema gating against the actual payload); the full
# per-request wire entry (method, path, notable headers, body) goes to
# +request_logs+ for the parity rig.
class MockLLMServer
  attr_reader :port, :requests, :request_logs

  def initialize
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @requests = Queue.new
    @request_logs = Queue.new
    @script = []
    @template = []
    @accept_thread = nil
    @suppress_usage = false
  end

  # The Case-3 compaction instrument (I29): every response is served
  # WITHOUT the usage payload — non-streaming JSON carries no `usage` key,
  # the stream carries no trailing usage chunk — so both apps' compaction
  # triggers must fall back to the chars/4 estimate (pi Case 3's zero-usage
  # branch, agent-session.ts:3058-3083; tart Compaction.trigger_tokens).
  # Scenario-level: set before start, survives rearm!, applies to every
  # scripted response.
  def suppress_usage!
    @suppress_usage = true
    self
  end

  def script(response_specs)
    @template = response_specs.dup
    @script = response_specs.dup
    self
  end

  # Reset the shifting script queue to the template (fresh app, same bytes).
  def rearm!
    @script = @template.dup
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

  # The served-request count WITHOUT draining (the I54 rig knob's poll
  # seam — Runner#run_app's mid_run_keys waits on it): a peek at the log
  # depth; captured_request_logs semantics are untouched.
  def request_count
    @request_logs.size
  end

  # Drains and returns all captured request entries: full wire facts
  # (method, path, notable headers, parsed body) per request.
  def captured_request_logs
    list = []
    list << @request_logs.pop(true) until @request_logs.empty?
    list
  end

  private

  NOTABLE_HEADERS = %w[authorization content-type accept user-agent].freeze

  def serve(io)
    request_line = io.gets
    # A connection that sends no request line (empty TCP connect, prober,
    # port scan) consumes nothing: no script shift, no log entry, no response
    # — the next real request still gets the next spec (I17 rig defect:
    # method=None entries shifted every later response by one).
    return if request_line.nil? || request_line.strip.empty?

    headers = {}
    while (line = io.gets) && line != "\r\n"
      name, value = line.split(":", 2)
      headers[name.to_s.strip.downcase] = value.to_s.strip
    end
    body = io.read(headers["content-length"].to_i)
    parsed_body = body.to_s.empty? ? nil : JSON.parse(body)
    entry = {
      method: request_line.to_s.split(" ")[0],
      path: request_line.to_s.split(" ")[1],
      streaming: headers["accept"].to_s.include?("text/event-stream") || body.to_s.include?("\"stream\":true"),
      headers: headers.slice(*NOTABLE_HEADERS),
      body: parsed_body,
    }
    @request_logs << entry
    @requests << parsed_body unless parsed_body.nil?

    spec = @script.shift || {type: :message, content: ""}
    if spec[:type] == :models
      respond_models(io, spec)
    elsif spec[:type] == :error
      respond_error(io, spec)
    elsif entry[:streaming]
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
    }
    payload[:usage] = {prompt_tokens: 10, completion_tokens: 5, total_tokens: 15} unless @suppress_usage
    out = JSON.generate(payload)
    io.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n" \
      "Content-Length: #{out.bytesize}\r\n\r\n#{out}")
  end

  # The I71 listing reply: the OpenAI-compatible /v1/models shape, or the
  # spec's overrides (status:/raw:) — the models_listing pins speak it.
  def respond_models(io, spec)
    out = spec[:raw] || JSON.generate({object: "list",
      data: Array(spec[:ids]).map { |id| {id:, object: "model"} }})
    status = spec[:status] || 200
    io.write("HTTP/1.1 #{status} Status\r\nContent-Type: application/json\r\nConnection: close\r\n" \
      "Content-Length: #{out.bytesize}\r\n\r\n#{out}")
  end

  # The body openai-compatible endpoints return on a schema rejection;
  # the client maps the status to its error class before any stream
  # is read.
  def respond_error(io, spec)
    payload = {error: {message: spec[:message], type: "invalid_request_error"}}
    out = JSON.generate(payload)
    status = spec[:status] || 400
    io.write("HTTP/1.1 #{status} Bad Request\r\nContent-Type: application/json\r\nConnection: close\r\n" \
      "Content-Length: #{out.bytesize}\r\n\r\n#{out}")
  end

  def respond_stream(io, spec)
    deltas = spec[:type] == :slow_stream ? slow_deltas(spec) : deltas_for(spec)
    io.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n" \
      "Transfer-Encoding: chunked\r\n\r\n")
    deltas.each do |delta|
      write_sse(io, delta)
    end
    write_sse(io, {usage: {prompt_tokens: 10, completion_tokens: 5, total_tokens: 15}}) unless @suppress_usage
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

module Tart
  # The minitest-nested block only evaluates when minitest is loaded (the
  # suite): bin/pty-tester loads this file without minitest and uses the
  # top-level class directly.
  if defined?(Minitest::Test)
    class Test < Minitest::Test
      # Historical nesting (backward compatibility): suite callers use
      # Tart::Test::MockLLMServer; the class above is the one definition.
      MockLLMServer = ::MockLLMServer

      # The gem Client + the tart Chat pointed at a MockLLMServer — the
      # real client on the wire, hermetically.
      class TestChat
        class << self
          def build(server, tools: [], system_prompt: nil, request_timeout: 10)
            client = Fast::Completions::Client.new(base_url: server.url, api_key: "test-key",
                                                   timeout: request_timeout)
            chat = Agent::Chat.new(client:, model_id: "tart-test-model", provider_key: "mock")
            chat.with_tools(*tools) unless tools.empty?
            chat.with_instructions(system_prompt) if system_prompt
            chat
          end
        end
      end
    end
  end
end
