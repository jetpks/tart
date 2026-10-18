# frozen_string_literal: true

require "socket"
require "json"

# The mock observation-deck ingest endpoint (I74 test support — NOT shipped
# code; the MockLLMServer pattern): a hermetic TCPServer on 127.0.0.1 with an
# ephemeral port that speaks just enough HTTP to receive the session-sink's
# POSTs and answer 202.
#
# Wire details:
# - POST <host>/conversations/ingest with Content-Type: application/x-ndjson;
#   success = HTTP 202 with an empty body (the deck action's own contract:
#   app/actions/conversations/ingest.rb render_json(..., status: 202)).
# - Per-connection handling (the sink opens a fresh connection per POST);
#   responses are Content-Length: 0 + Connection: close so the client never
#   waits.
#
# Scripting: +fail_with(statuses)+ installs a per-connection fail script —
# statuses consumed in order, one per connection; 202 when exhausted. The
# always-fail retry legs pass a script as long as the attempts they need to
# exhaust (the exhausted default 202 lets a following leg prove the engine
# keeps accepting).
#
# Observation surface (synchronized): +posts+ (one entry per received POST:
# {status:, headers:, body:, records:} — headers downcased, records the
# parsed NDJSON lines), +post_count+, +connections+, +max_concurrent+ (the
# ≤ 1 in-flight POST pin), +wait_posts(n, timeout)+, +url+, +stop+.
class MockIngestServer
  attr_reader :port

  def initialize
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @mutex = Mutex.new
    @posts = []
    @connections = 0
    @active = 0
    @max_active = 0
    @fail_script = []
    @delay = 0
    @accept_thread = nil
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

  # The per-connection response script (the retry legs): one status per
  # connection, 202 when exhausted.
  def fail_with(statuses)
    @mutex.synchronize { @fail_script = statuses.dup }
    self
  end

  # Per-connection response delay (the slow-mock FIFO/in-flight legs):
  # sleeps this long before answering every connection.
  def delay_with(seconds)
    @mutex.synchronize { @delay = seconds }
    self
  end

  def url
    "http://127.0.0.1:#{@port}"
  end

  def posts
    @mutex.synchronize { @posts.dup }
  end

  def post_count
    @mutex.synchronize { @posts.size }
  end

  def connections
    @mutex.synchronize { @connections }
  end

  def max_concurrent
    @mutex.synchronize { @max_active }
  end

  def wait_posts(n, timeout)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    while post_count < n
      return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.01
    end
    true
  end

  def stop
    @server.close
    @accept_thread&.join(1)
  rescue IOError
    nil
  end

  private

  def serve(io)
    request_line = io.gets
    # A connection that sends no request line consumes nothing (the
    # MockLLMServer's empty-connect discipline — probes never shift the
    # script or pollute the observation surface).
    return if request_line.nil? || request_line.strip.empty?

    headers = {}
    while (line = io.gets) && line != "\r\n"
      name, value = line.split(":", 2)
      headers[name.to_s.strip.downcase] = value.to_s.strip
    end
    body = io.read(headers["content-length"].to_i)
    records = body.to_s.split("\n").filter_map do |line|
      JSON.parse(line)
    rescue StandardError
      nil
    end
    status = nil
    @mutex.synchronize do
      @connections += 1
      @active += 1
      @max_active = [@max_active, @active].max
      status = @fail_script.shift || 202
    end
    sleep(@delay) if @delay.positive? && status
    io.write("HTTP/1.1 #{status} Mock\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
    io.flush
    @mutex.synchronize do
      @posts << {status: status, headers: headers, body: body, records: records}
    end
  rescue StandardError
    nil
  ensure
    @mutex.synchronize { @active -= 1 if @active.positive? }
    io.close rescue nil
  end
end
