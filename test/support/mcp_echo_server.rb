# frozen_string_literal: true

# A pure-Ruby fixture MCP server over stdio (no gems, no network): spawned
# as a subprocess by the MCP tests, answering initialize, ping, tools/list
# and tools/call with newline-delimited JSON-RPC on stdin/stdout.
#
# Tools:
# - echo {message}: text result "echo: <message>" (the round-trip proof).
# - sleep {ms}: sleeps ms milliseconds, then "slept <ms>ms" (request-timeout
#   tests pick a timeout shorter than the sleep).
#
# Environment toggles (for failure-injection tests):
# - MCP_ECHO_FAIL_INITIALIZE=1  initialize answers an invalid result.
# - MCP_ECHO_STDERR=<text>      writes <text> to stderr at boot.
#
# Exits cleanly when the client closes stdin.
require "json"

module EchoServer
  PROTOCOL_VERSION = "2025-06-18"
  SERVER_INFO = {name: "echo", version: "1.0.0"}.freeze
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
    return nil unless message.key?("id") # notification (e.g. notifications/initialized)

    case message["method"]
    when "initialize"
      result = if ENV["MCP_ECHO_FAIL_INITIALIZE"]
        {"protocolVersion" => PROTOCOL_VERSION, "capabilities" => {}}
      else
        {"protocolVersion" => PROTOCOL_VERSION, "capabilities" => {}, "serverInfo" => stringified(SERVER_INFO)}
      end
      {result:}
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
      text("echo: #{arguments['message']}")
    when "sleep"
      duration = arguments["ms"].to_f / 1000
      sleep(duration) if duration.positive?
      text("slept #{arguments['ms']}ms")
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

$stdout.sync = true
$stderr.write(ENV["MCP_ECHO_STDERR"]) if ENV["MCP_ECHO_STDERR"]

STDIN.each_line do |line|
  next if line.strip.empty?

  begin
    message = JSON.parse(line)
  rescue JSON::ParserError
    next
  end
  response = EchoServer.handle(message)
  next unless response

  $stdout.write("#{JSON.generate(response.merge(id: message['id'], jsonrpc: '2.0'))}\n")
end
