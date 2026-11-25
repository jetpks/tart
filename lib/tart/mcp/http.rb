# frozen_string_literal: true

require "async"
require "async/http"
require "json"
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
    # The wire is the app's async-http stack (the fast-llm gem's one
    # runtime; models/listing.rb is the in-repo house pattern): ONE one-off
    # `Async do … end.wait` reactor task per HTTP attempt — it nests as a
    # child task inside a reactor and builds a transient reactor off one —
    # ONE client per attempt (a per-POST connection; no persistent pooled
    # client), every POST/DELETE attempt WHOLE-bounded by `with_timeout`,
    # every body read inactivity-bounded per chunk, and the response body
    # ALWAYS released before `client.close` in the attempt's ensure (an
    # unread body leaves the connection a busy pool resource and close
    # blocks in the async-pool wait_until_free).
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
    # machinery, and the fetch injection (async-http is the one client).
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
        @endpoint = Async::HTTP::Endpoint.parse(url)
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

      # One POST per message (pi's send): the whole exchange — connect,
      # request, reply status, and body consumption — is one bounded
      # attempt (pi bounds the fetch by the request deadline), so a JSON
      # reply lands on on_message before send returns and an SSE reply
      # streams until this request's answer arrives.
      #
      # @raise [HttpError, AuthRequiredError, SessionExpiredError,
      #   ConnectionClosedError, StandardError] the POST/parse failures —
      #   the client's send-failure wall converts them to Failure values.
      def send(message)
        raise ConnectionClosedError if !@started || @closed

        headers = request_headers("accept" => "application/json, text/event-stream",
                                  "content-type" => "application/json")
        perform("POST", headers, JSON.generate(message), @request_timeout_s) do |response|
          handle_response(response, message)
        end
        nil
      end

      def close
        return if @closed

        @closed = true
        stop_tasks
        send_session_delete
        emit_close
      end

      private

      # -- the async-http wire (the app's stack) ----------------------------

      # One bounded HTTP attempt (the listing.rb house pattern): the whole
      # exchange runs in ONE one-off reactor task, on ONE client (a
      # per-attempt connection), bounded whole by +timeout_s+, with the
      # body ALWAYS released before client.close in the ensure — on every
      # path. No `return` inside the Async block: it runs on its own fiber
      # (the ruby-4.0 non-local return would unwind the method before the
      # request fires) — the block's value is the handler's.
      def perform(verb, headers, body, timeout_s, &handler)
        Async do |task|
          client = Async::HTTP::Client.new(@endpoint)
          response = nil
          begin
            task.with_timeout(timeout_s) do
              response = client.call(Protocol::HTTP::Request[verb, request_path,
                                                             headers: headers, body: body])
              handler.call(response)
            end
          ensure
            release(response)
            client.close
          end
        end.wait
      end

      # The pool law's release half: a fully-read body closed itself; a
      # partially-read or unread body closes here — the connection is
      # discarded, never reused — so client.close never blocks in the
      # pool's wait_until_free.
      def release(response)
        response&.body&.close
      rescue StandardError
        nil
      end

      # Every body read is inactivity-bounded per chunk by the request
      # timeout — a stalled peer never wedges a reader.
      def read_chunk(body)
        Async::Task.current.with_timeout(@request_timeout_s) { body.read }
      end

      # -- request + reply plumbing -----------------------------------------

      def request_path
        path = @uri.request_uri
        path.empty? ? "/" : path
      end

      # pi's buildHeaders: the configured headers + the per-request extras,
      # plus the session id and the negotiated protocol version once held.
      def request_headers(extra)
        headers = (@headers || {}).merge(extra)
        headers["Mcp-Session-Id"] = @session_id if @session_id
        headers["MCP-Protocol-Version"] = @protocol_version if @protocol_version
        headers
      end

      def capture_session(response)
        session = response.headers["mcp-session-id"]
        @session_id = session if session && !session.empty?
      end

      def content_type(response)
        response.headers["content-type"]&.split(";", 2)&.first&.strip&.downcase
      end

      # Reads the body as text, keeping at most +max_bytes+ (pi's
      # readBodyText — the rest is dropped and reported truncated).
      def read_body_text(body, max_bytes)
        text = +""
        truncated = false
        while (chunk = read_chunk(body))
          remaining = max_bytes - text.bytesize
          break if remaining <= 0

          piece = chunk.byteslice(0, remaining)
          text << piece
          truncated = piece.bytesize < chunk.bytesize
          break if truncated
        end
        [text, truncated]
      end

      def check_response(response)
        return if (200..299).cover?(response.status)

        text, = read_body_text(response.body, MAX_ERROR_BODY_BYTES)
        status = response.status
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
        text, truncated = read_body_text(response.body, @max_message_bytes)
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

      # -- reply dispatch ----------------------------------------------------

      # The POST reply taxonomy (pi's send body): the reply's STATUS is
      # checked inline and the session captured; a notification or
      # client-side response is acknowledged with no reply (the
      # server-to-client stream may only open once the session is
      # initialized — pi's gate); a request dispatches on the reply shape.
      def handle_response(response, message)
        check_response(response)
        capture_session(response)
        if JsonRpc.request?(message)
          dispatch_reply(response, message)
        elsif @open_get_stream && message["method"] == "notifications/initialized"
          start_get_stream
        end
      end

      # A request's reply: 202/204 = acknowledged with no answer (the named
      # rejection); then the content-type dispatch — a JSON body emits
      # directly, an SSE reply streams until this request's answer arrives.
      def dispatch_reply(response, message)
        status = response.status
        if [202, 204].include?(status)
          raise HttpError.new(status, "MCP server accepted request #{message['method']} without a response")
        end

        type = content_type(response)
        case type
        when "application/json" then emit_json_body(response)
        when "text/event-stream" then consume_response_stream(response, message["id"])
        else raise HttpError.new(status, "Unsupported MCP response content type: #{type || 'missing'}")
        end
      end

      # The request's SSE reply: every parsed message flows to on_message
      # until THIS request's answer arrives, then the read stops (the
      # connection closes behind it). A stream that ends first fails the
      # request with pi's exact message (pi's no-resumption branch — the
      # resumption machinery itself is the itemized cut).
      def consume_response_stream(response, request_id)
        answered = read_sse(response.body, request_id)
        return if answered || @closed

        raise StandardError, "MCP response stream failed: stream ended without a response"
      end

      # -- the GET stream ----------------------------------------------------

      # The server-to-client stream: opens ONCE after initialization; 405 =
      # the server offers none (quiet stop); consumed until the server
      # closes it; a drop is NOT reconnected (the itemized cut). Runs as a
      # transient task on the host reactor (the I107 T6/D2 law).
      def start_get_stream
        return if !@open_get_stream || @get_stream_started || @closed

        @get_stream_started = true
        @get_stream_task = @task.async(transient: true) { consume_get_stream }
      end

      # The GET attempt: the request leg is whole-bounded by the request
      # timeout; the stream drain is inactivity-bounded per chunk (a
      # long-lived healthy stream is bounded like any reader, not killed
      # whole); every failure flows to on_error — never out of the reader
      # task — unless the transport closed first.
      def consume_get_stream
        headers = request_headers("accept" => "text/event-stream")
        Async do |task|
          client = Async::HTTP::Client.new(@endpoint)
          response = nil
          begin
            task.with_timeout(@request_timeout_s) do
              response = client.get(request_path, headers: headers)
            end
            consume_get_reply(response)
          ensure
            release(response)
            client.close
          end
        end.wait
      rescue StandardError => e
        emit_error(e) unless @closed
      end

      # The GET reply taxonomy (pi's startGetStream body): 405 = the server
      # does not offer a GET stream (quiet stop); anything else is checked
      # like a POST reply, then consumed as SSE to stream end.
      def consume_get_reply(response)
        return if response.status == 405

        check_response(response)
        capture_session(response)
        type = content_type(response)
        unless type == "text/event-stream"
          raise HttpError.new(response.status, "Unsupported MCP GET response content type: #{type || 'missing'}")
        end

        read_sse(response.body, nil)
      end

      # -- SSE ---------------------------------------------------------------

      # The SSE framing driver (pi's consumeSseStream): feeds the parser
      # chunk by chunk, every read inactivity-bounded, until +request_id+'s
      # answer arrives (nil = consume to stream end); then the tail is
      # flushed. Returns whether the answer arrived.
      def read_sse(body, request_id)
        answered = false
        parser = SseParser.new(@max_message_bytes)
        parser.on_event = lambda do |data, event|
          answered = true if emit_sse_event(data, event, request_id)
        end
        while (chunk = read_chunk(body))
          parser.feed(chunk)
          break if request_id && answered
        end
        parser.finish
        answered
      end

      # One parsed SSE event (pi's filter): events without data prime
      # resumption; non-`message` event types are not JSON-RPC. The payload
      # is parsed and delivered; true when it was +request_id+'s answer.
      # The resumption itself is cut.
      def emit_sse_event(data, event, request_id)
        return false if data.strip.empty? || (!event.nil? && event != "message")

        message = begin
          JsonRpc.parse_message(JSON.parse(data))
        rescue JSON::ParserError, Mcp::Error => e
          emit_error(e)
          return false
        end
        answered = request_id && JsonRpc.response?(message) && message["id"] == request_id
        @on_message&.call(message)
        answered
      end

      # -- task + teardown ---------------------------------------------------

      # Best effort: the session expires on the server anyway (pi's
      # close()); the whole DELETE is bounded to 1 s (pi's
      # AbortSignal.timeout(1_000)) — teardown never blocks long.
      def send_session_delete
        return unless @started && @session_id

        perform("DELETE", request_headers({}), nil, CLOSE_DELETE_TIMEOUT_S) { |_response| nil }
      rescue StandardError
        nil
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

        # Line scanning over the buffer: CRLF, LF, or a lone CR each end a
        # line (pi's consumeSseStream split); a trailing lone CR defers its
        # LF to the next chunk (feed's skip_leading_lf hand-off).
        def consume_lines
          start = 0
          i = 0
          while i < @buffered.length
            if @buffered[i] == "\r" || @buffered[i] == "\n"
              i = consume_line_break(i, start)
              start = i + 1
            end
            i += 1
          end
          @buffered = @buffered[start..] || +""
        end

        # Consumes the line ending at +i+ (its first byte at +start+) and
        # returns the index of its LAST terminator byte (a CRLF pair
        # counts both).
        def consume_line_break(i, start)
          process_line(@buffered[start, i - start])
          if @buffered[i] == "\r"
            if i + 1 < @buffered.length
              i += 1 if @buffered[i + 1] == "\n"
            else
              @skip_leading_lf = true
            end
          end
          i
        end

        def process_line(line)
          return dispatch if line.empty?
          return if line.start_with?(":")

          colon = line.index(":")
          field = colon.nil? ? line : line[0, colon]
          value = colon.nil? ? "" : line[(colon + 1)..].delete_prefix(" ")
          apply_field(field, value)
        end

        # `data` accumulates the pending event (byte-capped); `event`
        # names it. `id`/`retry` serve resumption only — cut with the
        # reconnect machinery (the itemized deviation); data/event are all
        # the message path needs.
        def apply_field(field, value)
          if field == "data"
            append_data(value)
          elsif field == "event"
            @event_name = value
          end
        end

        def append_data(value)
          @data_bytes += value.bytesize + (@data_lines&.length&.positive? ? 1 : 0)
          if @data_bytes > @max_event_bytes
            raise StandardError, "MCP SSE event exceeds #{@max_event_bytes} bytes"
          end

          (@data_lines ||= []) << value
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
    end
  end
end
