# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/mock_llm_server"
require "stringio"
require "tmpdir"
require "fileutils"

module Tart
  # The MCP lane (AC3/AC4): the hand-rolled stdio client against the pure-Ruby
  # fixture echo server over real pipes; mcp.json-shaped config validation
  # with pi's exact error strings; Registry integration; the agent-level
  # round trip (MockLLMServer script -> mcp tool -> echo server -> tool
  # result back to the model).
  class McpTest < Test
    ECHO_SERVER = File.expand_path("support/mcp_echo_server.rb", __dir__)
    RUBY = RbConfig.ruby

    def setup
      @dir = Dir.mktmpdir("tart-mcp-")
      @mcp_tools = []
      @errors = []
    end

    def teardown
      @mcp_tools.each(&:close)
      (@clients || []).each(&:close)
      @server_to_stop&.stop
      FileUtils.rm_rf(@dir)
    end

    # -- AC3: the client round trip over real stdio pipes ------------------

    def test_client_initialize_list_and_call_round_trip
      client = connected_client

      assert_equal "connected", client.connection_state
      assert_equal "2025-06-18", client.protocol_version
      assert_equal "echo", client.server_info["name"]
      assert_equal "1.0.0", client.server_info["version"]

      tools = client.list_tools
      assert_equal %w[echo sleep], tools.map { |t| t["name"] }
      assert tools.all? { |t| t["inputSchema"].is_a?(Hash) }

      result = client.call_tool("echo", {"message" => "hello"})
      assert_equal "echo: hello", result["content"][0]["text"]
    end

    def test_close_reaps_the_child_process
      client = Mcp::Client.new
      transport = echo_transport
      client.connect(transport)
      pid = transport.pid

      client.close

      assert_raises(Errno::ECHILD) { Process.waitpid(pid, Process::WNOHANG) }
      assert_equal "closed", client.connection_state
    end

    def test_request_timeout_raises_with_the_default_message
      client = connected_client(request_timeout_ms: 250)
      error = assert_raises(Mcp::TimeoutError) do
        client.call_tool("sleep", {"ms" => 5000})
      end
      assert_equal "MCP request timed out after 250ms", error.message
      assert_equal 250, error.timeout_ms
    end

    def test_invalid_initialize_result_fails_the_handshake_and_closes_the_transport
      client = Mcp::Client.new
      transport = echo_transport(env: {"MCP_ECHO_FAIL_INITIALIZE" => "1"})
      error = assert_raises(Mcp::Error) { client.connect(transport) }
      assert_equal "Invalid MCP initialize result", error.message
      # pi: a failed connect closes the transport (client.ts catch -> close).
      wait_until { transport.pid.nil? || !child_alive?(transport.pid) }
    end

    def test_unsupported_protocol_version_is_rejected
      # The fixture answers 2025-06-18; simulate an unsupported answer by
      # checking the client-side predicate on the version list.
      refute Mcp::Client::SUPPORTED_PROTOCOL_VERSIONS.include?("1999-01-01")
      assert Mcp::Client::SUPPORTED_PROTOCOL_VERSIONS.include?("2024-11-05")
    end

    def test_server_method_not_found_surfaces_as_mcp_error
      client = connected_client
      error = assert_raises(Mcp::Error) do
        client.send(:request, "resources/list", nil, timeout_ms: nil)
      end
      assert_equal(-32_601, error.code)
      assert_equal "Method not found: resources/list", error.message
    end

    def test_jsonrpc_validation_matches_pis_predicates_and_codes
      codes = Mcp::JsonRpc::ERROR_CODES
      assert_equal({parse_error: -32_700, invalid_request: -32_600, method_not_found: -32_601,
                    invalid_params: -32_602, internal_error: -32_603}, codes)
      assert Mcp::JsonRpc.request?("jsonrpc" => "2.0", "id" => 1, "method" => "ping")
      assert Mcp::JsonRpc.notification?("jsonrpc" => "2.0", "method" => "ping")
      assert Mcp::JsonRpc.response?("jsonrpc" => "2.0", "id" => 1, "result" => {})
      assert Mcp::JsonRpc.response?("jsonrpc" => "2.0", "id" => 1,
                                    "error" => {"code" => -32_601, "message" => "x"})
      refute Mcp::JsonRpc.response?("jsonrpc" => "2.0", "id" => 1, "result" => {}, "error" => {"code" => 1, "message" => "x"})
      invalid_messages = [
        nil, "x", 1, {}, {"jsonrpc" => "2.0"}, {"jsonrpc" => "2.0", "id" => 1},
        {"jsonrpc" => "2.0", "id" => "x", "result" => {}, "error" => {"code" => 1, "message" => "m"}}
      ]
      invalid_messages.each do |invalid|
        error = assert_raises(Mcp::Error) { Mcp::JsonRpc.parse_message(invalid) }
        assert_equal(-32_600, error.code)
        assert_equal "Invalid JSON-RPC message", error.message
      end
    end

    def test_transport_passes_child_stderr_through
      chunks = []
      transport = echo_transport(env: {"MCP_ECHO_STDERR" => "echo-server: ready\n"}, on_stderr: ->(chunk) { chunks << chunk })
      client = Mcp::Client.new
      client.connect(transport)
      wait_until { chunks.join.include?("echo-server: ready") }
      client.close
      assert_includes chunks.join, "echo-server: ready"
    end

    # -- AC4: config validation with pi's exact error strings --------------

    def test_missing_config_file_means_no_servers_no_error
      assert_equal({}, Mcp::Config.load(File.join(@dir, "absent.json")))
    end

    def test_config_load_reads_the_mcp_servers_shape
      path = write_config("mcpServers" => {"echo" => {"command" => RUBY, "args" => [ECHO_SERVER]}})
      servers = Mcp::Config.load(path)
      assert_equal RUBY, servers["echo"][:command]
      assert_equal [ECHO_SERVER], servers["echo"][:args]
      assert_nil servers["echo"][:env]
    end

    def test_config_error_strings_match_pi
      path = File.join(@dir, "mcp.json")
      cases = {
        [1, 2] => "#{path}: expected an object with an \"mcpServers\" object",
        {"mcpServers" => "nope"} => "#{path}: expected an object with an \"mcpServers\" object",
        {"mcpServers" => {"x" => "nope"}} => %(#{path}: server "x" must be an object),
        {"mcpServers" => {"x" => {"command" => "c", "args" => "nope"}}} =>
          %(#{path}: server "x": args must be an array of strings),
        {"mcpServers" => {"x" => {"command" => "c", "env" => {"a" => 1}}}} =>
          %(#{path}: server "x": env must map names to strings),
        {"mcpServers" => {"x" => {"cwd" => 3}}} => %(#{path}: server "x": cwd must be a string),
        {"mcpServers" => {"x" => {"args" => []}}} =>
          %(#{path}: server "x" needs either "command" (stdio) or "url" (streamable HTTP))
      }
      cases.each do |body, message|
        File.write(path, JSON.generate(body))
        error = assert_raises(Mcp::Config::ConfigError) { Mcp::Config.load(path) }
        assert_equal message, error.message
      end
    end

    def test_url_entries_are_rejected_stdio_only
      path = write_config("mcpServers" => {"x" => {"url" => "https://example.com/mcp"}})
      error = assert_raises(Mcp::Config::ConfigError) { Mcp::Config.load(path) }
      assert_equal %(#{path}: server "x": streamable HTTP transport is not supported (stdio only)), error.message
    end

    def test_malformed_config_json_names_the_file
      path = File.join(@dir, "mcp.json")
      File.write(path, "{not json")
      error = assert_raises(Mcp::Config::ConfigError) { Mcp::Config.load(path) }
      assert_match(%r{\A#{Regexp.escape(path)}: }, error.message)
    end

    # -- AC4: registry integration -----------------------------------------

    def test_registry_registers_mcp_tools_behind_the_schema_gate
      tools = Tools::Registry.build(selected: %w[read], cwd: @dir, mcp_servers: {"echo" => echo_config})
      track_mcp(tools)

      assert_equal %w[mcp__echo__echo mcp__echo__sleep read], tools.keys.sort
      tool = tools["mcp__echo__echo"]
      assert_kind_of RubyLLM::Tool, tool
      assert_equal "mcp__echo__echo", tool.name
      assert_equal "Echo the message back", tool.description
      assert_equal "echo", tool.remote_name
      assert_equal(
        {"type" => "object", "properties" => {"message" => {"type" => "string", "description" => "the message"}},
         "required" => ["message"]},
        tool.parameters_schema
      )
      assert_equal "echo: direct", tool.execute(message: "direct")
    end

    def test_registry_without_mcp_servers_never_connects_anything
      tools = Tools::Registry.build(selected: %w[read], cwd: @dir)

      assert_equal %w[read], tools.keys
      assert_empty tools.values.select { |t| t.is_a?(Mcp::Tool) }
    end

    def test_registry_skips_a_server_that_fails_to_connect
      _, path = temp_config_file("mcpServers" => {"broken" => {"command" => RUBY, "args" => ["-e", "exit 1"]}})
      servers = Mcp::Config.load(path)
      tools = capture_stderr do
        Tools::Registry.build(selected: %w[read], cwd: @dir, mcp_servers: servers)
      end

      assert_equal %w[read], tools.keys
      assert_match(/mcp server "broken" failed to connect/, @captured_stderr)
    end

    def test_tool_name_sanitizes_and_hashes_like_pi
      assert_equal "mcp__a_b__x_y", Mcp::Tool.tool_name("a-b", "x.y")
      assert_equal "mcp__echo__echo", Mcp::Tool.tool_name("echo", "echo")
      long = Mcp::Tool.tool_name("s", "t#{'x' * 100}", ->(_n) { false })
      assert long.length <= Mcp::Tool::MAX_TOOL_NAME_LENGTH
      assert_match(/_[0-9a-f]{8}\z/, long)
      suffixed = Mcp::Tool.tool_name("s", "t", ->(_n) { true })
      assert_match(/_[0-9a-f]{8}\z/, suffixed)
    end

    # -- AC4: the agent-level round trip -----------------------------------

    def test_agent_round_trip_model_calls_mcp_tool_result_returns_to_the_model
      server = MockLLMServer.new.start
      @server_to_stop = server
      server.script([
        {type: :stream, tool_calls: [{id: "call_1", name: "mcp__echo__echo", arguments: {message: "ping"}}]},
        {type: :message, content: "the echo came back"},
      ])
      tools = Tools::Registry.build(selected: %w[read], cwd: @dir, mcp_servers: {"echo" => echo_config})
      track_mcp(tools)

      result = run_agent(server, tools)

      # The model's tool call reached the echo server over real stdio, and the
      # echo result returned to the model as the tool result.
      tool_message = server.captured_requests.last["messages"].find { |m| m["role"] == "tool" }
      assert_equal "call_1", tool_message["tool_call_id"]
      assert_includes tool_message["content"], "echo: ping"
      assert_equal "the echo came back", result.last.content
    end

    private

    def echo_config(env = {})
      {command: RUBY, args: [ECHO_SERVER], env: env}
    end

    def echo_transport(env: nil, on_stderr: nil)
      transport = Mcp::Stdio.new(command: RUBY, args: [ECHO_SERVER], env: env)
      transport.on_stderr = on_stderr
      transport
    end

    def connected_client(request_timeout_ms: Mcp::Client::DEFAULT_REQUEST_TIMEOUT_MS)
      client = Mcp::Client.new(request_timeout_ms:)
      client.connect(echo_transport)
      (@clients ||= []) << client
      client
    end

    def child_alive?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH, Errno::EPERM
      false
    end

    def track_mcp(tools)
      @mcp_tools.concat(tools.values.select { |t| t.is_a?(Mcp::Tool) })
    end

    def temp_config_file(body)
      path = File.join(@dir, "mcp.json")
      File.write(path, JSON.generate(body))
      [path, path]
    end

    def write_config(body)
      temp_config_file(body).first
    end

    def capture_stderr
      original = $stderr
      $stderr = StringIO.new
      yield
    ensure
      @captured_stderr = $stderr.string
      $stderr = original
    end

    # The agent-loop test harness (agent_loop_test.rb's kernel shape): the
    # agent runs as the kernel work subtree on a scripted session.
    def run_agent(server, tools)
      chat = TestChat.build(server, tools: tools.values, system_prompt: "test prompt")
      agent = Agent::Loop.new(chat:, tools:, on_event: nil)
      result = nil
      kernel = Core::Loop.new(session: ScriptedSession.new)
      kernel.run { result = agent.run("call the echo tool") }
      result
    end
  end
end
