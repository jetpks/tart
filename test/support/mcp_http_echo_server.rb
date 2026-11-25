# frozen_string_literal: true

# A pure-Ruby fixture MCP server over Streamable HTTP (loopback only, no
# gems): spawned as a subprocess by the MCP tests, answering initialize,
# ping, tools/list and tools/call over HTTP POST with the reply as
# `application/json` (or `text/event-stream` on demand), the session id
# riding `Mcp-Session-Id`, `GET` answering 405 (or a server-to-client SSE
# stream on demand) and `DELETE` answering 204.
#
# Tools (the stdio fixture's pair):
# - echo {message}: text result "echo: <message>" (the round-trip proof).
# - sleep {ms}: sleeps ms milliseconds, then "slept <ms>ms".
#
# Environment toggles (failure injection + proof capture):
# - MCP_HTTP_ECHO_PORT=<port>   listen port (default: a free port, printed
#   as "PORT=<port>\nREADY\n" on stdout for the parent test).
# - MCP_HTTP_ECHO_LOG=<path>    append one JSON line per request:
#   {method, path, headers (selected), body} — the session/protocol-version/
#   header round-trip proofs read it.
# - MCP_HTTP_ECHO_SSE=1         tools/call answers over
#   `text/event-stream` (an unrelated notification event first, then the
#   response — the multi-event parse proof), other methods stay JSON.
# - MCP_HTTP_ECHO_GET_STREAM=1  GET opens a server-to-client SSE stream
#   and sends one `ping` REQUEST after the first POST is seen; the client's
#   built-in ping answer comes back as a POST the server records.
# - MCP_HTTP_ECHO_GET_STALL=1   GET opens a server-to-client SSE stream
#   and then sends NOTHING (the stalled-stream row: the reader must fail
#   within the request timeout, never hang).
# - MCP_HTTP_ECHO_SLOW_SSE=1    (with MCP_HTTP_ECHO_SSE) the SSE reply's
#   answer event arrives 2s after an immediate unrelated notification —
#   a reply no bounded client can wait out (the bounded-read row).
# - MCP_HTTP_ECHO_STATUS=<n>    answer HTTP <n> with a JSON error body on
#   every POST (the named-error taxonomy rows).
# - MCP_HTTP_ECHO_LATE_404=1    answer 404 on every POST after the first
#   (the session-expired row: only reachable holding a session id).
#
# Exits on SIGTERM/EOF of stdin.
require "json"
require "socket"

module HttpEchoServer
  PROTOCOL_VERSION = "2025-06-18"
  SERVER_INFO = {name: "http-echo", version: "1.0.0"}.freeze
  TOOLS = [
    {
      name: "echo",
      description: "Echo the message back",
      inputSchema: {type: "object", properties: {message: {type: "string", description: "the message"}},
                    required: ["message"]}
    },
    {
      name: "sleep",
      description: "Sleep for a while",
      inputSchema: {type: "object", properties: {ms: {type: "number", description: "milliseconds to sleep"}},
                    required: ["ms"]}
    }
  ].freeze

  module_function

  def handle(message)
    return nil unless message.key?("id")

    case message["method"]
    when "initialize"
      {result: {"protocolVersion" => ENV["MCP_HTTP_ECHO_PROTOCOL_VERSION"] || PROTOCOL_VERSION,
                "capabilities" => {}, "serverInfo" => stringified(SERVER_INFO)}}
    when "ping"
      {result: {}}
    when "tools/list"
      {result: {tools: stringified(TOOLS)}}
    when "tools/call"
      {result: call(message.dig("params", "name"), message.dig("params", "arguments") || {})}
    else
      {error: {code: -32_601, message: "Method not found: #{message['method']}"}}
    end
  end

  def call(name, arguments)
    case name
    when "echo"
      text("echo: #{arguments["message"]}")
    when "sleep"
      duration = arguments["ms"].to_f / 1000
      sleep(duration) if duration.positive?
      text("slept #{arguments["ms"]}ms")
    else
      {"content" => [], "isError" => true}
    end
  end

  def text(string)
    {"content" => [{"type" => "text", "text" => string}]}
  end

  def stringified(value)
    JSON.parse(JSON.generate(value))
  end
end

port = (ENV["MCP_HTTP_ECHO_PORT"] || 0).to_i
server = TCPServer.new("127.0.0.1", port)
port = server.addr[1]
log_path = ENV["MCP_HTTP_ECHO_LOG"]
$stdout.write("PORT=#{port}\nREADY\n")
$stdout.flush
$stdout.sync = true

session_id = "sess-#{Process.pid}"
post_count = 0

log_request = lambda do |method, path, headers, body|
  return unless log_path

  selected = headers.select { |name, _| name =~ /\A(mcp-session-id|mcp-protocol-version|authorization|x-token|content-type|accept)\z/i }
  File.open(log_path, "a") do |f|
    f.write(JSON.generate({method: method, path: path,
                           headers: selected.transform_keys(&:downcase), body: body}) + "\n")
  end
end

write_response = lambda do |conn, status, reason, headers, body|
  head = "HTTP/1.1 #{status} #{reason}\r\n"
  headers.each { |name, value| head += "#{name}: #{value}\r\n" }
  if body.nil?
    conn.write("#{head}Transfer-Encoding: chunked\r\n\r\n")
  else
    conn.write("#{head}Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
  end
  conn.flush
end

sse_chunk = lambda do |conn, string|
  conn.write("#{string.bytesize.to_s(16)}\r\n#{string}\r\n")
  conn.flush
end

serve_connection = lambda do |conn|
  request_line = conn.gets
  return unless request_line

  method, path, = request_line.split(" ")
  headers = {}
  while (line = conn.gets) && line.strip != ""
    name, value = line.split(":", 2)
    headers[name.strip.downcase] = value.strip if name && value
  end
  length = headers["content-length"].to_i
  body = length.positive? ? conn.read(length) : ""
  parsed_body = begin
    JSON.parse(body)
  rescue JSON::ParserError, TypeError
    nil
  end

  status_override = ENV["MCP_HTTP_ECHO_STATUS"]
  if status_override
    log_request.call(method, path, headers, body)
    payload = JSON.generate({jsonrpc: "2.0", id: parsed_body && parsed_body["id"],
                             error: {code: -32_600, message: "injected #{status_override}"}})
    write_response.call(conn, status_override.to_i, "Injected", {"Content-Type" => "application/json"}, payload)
    return
  end

  post_count += 1 if method == "POST"
  if method == "POST" && ENV["MCP_HTTP_ECHO_LATE_404"] && parsed_body &&
     parsed_body["method"].to_s.start_with?("tools/")
    log_request.call(method, path, headers, body)
    write_response.call(conn, 404, "Gone", {"Content-Type" => "application/json"},
                        JSON.generate({jsonrpc: "2.0", error: {code: -32_600, message: "session gone"}}))
    return
  end

  if method == "GET"
    log_request.call(method, path, headers, body)
    if ENV["MCP_HTTP_ECHO_GET_STREAM"]
      write_response.call(conn, 200, "OK", {"Content-Type" => "text/event-stream", "Cache-Control" => "no-store"}, nil)
      sleep 0.15
      ping = JSON.generate({jsonrpc: "2.0", id: "srv-1", method: "ping"})
      sse_chunk.call(conn, "event: message\r\ndata: #{ping}\r\n\r\n")
      conn.read(1) rescue nil # hold the stream open until the client closes
    elsif ENV["MCP_HTTP_ECHO_GET_STALL"]
      write_response.call(conn, 200, "OK", {"Content-Type" => "text/event-stream", "Cache-Control" => "no-store"}, nil)
      conn.read(1) rescue nil # headers only — the stream never sends a byte
    else
      write_response.call(conn, 405, "Method Not Allowed", {"Content-Type" => "application/json"}, "{}")
    end
    return
  end
  if method == "DELETE"
    log_request.call(method, path, headers, body)
    write_response.call(conn, 204, "No Content", {}, "")
    return
  end
  return unless method == "POST"

  message = parsed_body
  log_request.call(method, path, headers, body)

  if message.key?("id") && message["method"] == "tools/call" && ENV["MCP_HTTP_ECHO_SSE"]
    response = JSON.generate({jsonrpc: "2.0", id: message["id"],
                              result: HttpEchoServer.call(message.dig("params", "name"),
                                                          message.dig("params", "arguments") || {})})
    notification = JSON.generate({jsonrpc: "2.0", method: "notifications/message",
                                  params: {level: "info", data: "unrelated"}})
    write_response.call(conn, 200, "OK", {"Content-Type" => "text/event-stream",
                                          "Mcp-Session-Id" => session_id,
                                          "Cache-Control" => "no-store"}, nil)
    sse_chunk.call(conn, "event: message\r\ndata: #{notification}\r\n\r\n")
    sleep 2.0 if ENV["MCP_HTTP_ECHO_SLOW_SSE"] # later than any bounded read
    sse_chunk.call(conn, "event: message\r\ndata: #{response}\r\n\r\n")
    conn.write("0\r\n\r\n")
    conn.flush
    return
  end

  answer = HttpEchoServer.handle(message)
  if answer.nil?
    write_response.call(conn, 202, "Accepted", {"Mcp-Session-Id" => session_id}, "")
    return
  end

  payload = JSON.generate(answer.merge(id: message["id"], jsonrpc: "2.0"))
  write_response.call(conn, 200, "OK", {"Content-Type" => "application/json",
                                        "Mcp-Session-Id" => session_id}, payload)
rescue StandardError
  nil
end

threads = []
listener = Thread.new do
  loop do
    conn = server.accept
    threads << Thread.new(conn) { |c| serve_connection.call(c); c.close rescue nil }
  end
rescue StandardError
  nil
end

Signal.trap("TERM") { exit! 0 }
STDIN.read # the parent closes stdin (or TERMs us) to shut down
