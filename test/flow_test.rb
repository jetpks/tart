# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/mock_llm_server"
require "tmpdir"
require "fileutils"
require "json"
require "digest"

module Tart
  # The I45 flow contract (the step boundary): the loop's step-boundary
  # rescue ladder (Async::Cancel, then CancelledError, then StandardError —
  # the de-bridged I50 shape; the ladder reproduces the Bridge-era terminal
  # classification exactly), the MCP client's call-surface
  # taxonomy, and the no-silent-swallow golden — a failure raised mid-tool
  # reaches every observable seam byte-identically (Grounds §2.3).
  class FlowTest < Test
    ECHO_SERVER = File.expand_path("support/mcp_echo_server.rb", __dir__)
    RUBY = RbConfig.ruby

    def setup
      @dir = Dir.mktmpdir("tart-flow-")
      @mcp_clients = []
      @server_to_stop = nil
    end

    def teardown
      (@mcp_clients || []).each(&:close)
      @server_to_stop&.stop
      FileUtils.rm_rf(@dir)
    end

    # -- the step-boundary classification table (public surface) -------------

    def test_worker_http_error_classifies_as_bad_request
      server = mock_server([{type: :error, status: 400, message: "Extra inputs are not permitted"}])
      agent, events = run_agent_on_kernel(server, "hi")

      assert_kind_of Fast::Completions::BadRequestError, agent.last_error
      end_event = events.find { |e| e[:type] == :agent_end }
      assert_kind_of Fast::Completions::BadRequestError, end_event[:error]
      # I60 D6 (the declared re-pin): the failure now leaves pi's trace —
      # the synthesized failure assistant rides new_messages beside the user.
      assert_equal %i[user assistant], agent.new_messages.map(&:role)
    end

    def test_context_length_error_classifies_with_compaction_disabled
      server = mock_server([{type: :error, status: 400,
                             message: "This model maximum context length is 8 tokens"}])
      agent, events = run_agent_on_kernel(server, "hi", compaction: {enabled: false})

      assert_kind_of Fast::Completions::ContextLengthExceededError, agent.last_error
      end_event = events.find { |e| e[:type] == :agent_end }
      assert_kind_of Fast::Completions::ContextLengthExceededError, end_event[:error]
    end

    def test_dead_endpoint_classifies_as_connection_failed
      chat = Agent::Chat.new(
        client: Fast::Completions::Client.new(base_url: "http://127.0.0.1:1/v1", api_key: "test", timeout: 2),
        model_id: "tart-test-model", provider_key: "openai")
      agent, events = run_agent_on_kernel_with_chat(chat)

      assert_kind_of Fast::Completions::ConnectionError, agent.last_error
      end_event = events.find { |e| e[:type] == :agent_end }
      assert_kind_of Fast::Completions::ConnectionError, end_event[:error]
    end

    # -- the MCP call-surface taxonomy (public API) ---------------------------

    def test_connect_returns_the_initialize_result_as_success
      with_echo do |client, transport|
        result = client.connect(transport)

        assert result.success?
        assert_equal "echo", result.value!["serverInfo"]["name"]
        assert_equal "connected", client.connection_state
      end
    end

    def test_timeout_row_is_a_timeout_error_failure
      with_echo(timeout_ms: 250) do |client, transport|
        client.connect(transport)
        result = client.call_tool("sleep", {"ms" => 5000})

        assert result.failure?
        assert_kind_of Mcp::TimeoutError, result.failure
        assert_equal "MCP request timed out after 250ms", result.failure.message
        assert_equal 250, result.failure.timeout_ms
      end
    end

    def test_invalid_initialize_row_is_an_mcp_error_failure
      with_echo({"MCP_ECHO_FAIL_INITIALIZE" => "1"}) do |client, transport|
        result = client.connect(transport)

        assert result.failure?
        assert_kind_of Mcp::Error, result.failure
        assert_equal "Invalid MCP initialize result", result.failure.message
        assert_equal "closed", client.connection_state
      end
    end

    def test_method_not_found_row_carries_the_json_rpc_code
      with_echo do |client, transport|
        client.connect(transport)
        result = client.send(:request, "resources/list", nil, timeout_ms: nil)

        assert result.failure?
        assert_kind_of Mcp::Error, result.failure
        assert_equal(-32_601, result.failure.code)
        assert_equal "Method not found: resources/list", result.failure.message
      end
    end

    def test_duplicate_cursor_row_through_the_echo_toggle
      with_echo({"MCP_ECHO_DUPLICATE_CURSOR" => "1"}) do |client, transport|
        client.connect(transport)
        result = client.list_tools

        assert result.failure?
        assert_instance_of RuntimeError, result.failure
        assert_equal "MCP tools/list returned duplicate cursor: page-2", result.failure.message
      end
    end

    def test_unsupported_protocol_version_row_through_the_echo_toggle
      with_echo({"MCP_ECHO_PROTOCOL_VERSION" => "1999-01-01"}) do |client, transport|
        result = client.connect(transport)

        assert result.failure?
        assert_instance_of RuntimeError, result.failure
        assert_equal "MCP server selected unsupported protocol version 1999-01-01",
          result.failure.message
      end
    end

    def test_closed_client_row_is_a_connection_closed_error_failure
      with_echo do |client, transport|
        client.connect(transport)
        client.close
        result = client.call_tool("echo", {"message" => "x"})

        assert result.failure?
        assert_kind_of Mcp::ConnectionClosedError, result.failure
        assert_equal "MCP client is closed", result.failure.message
      end
    end

    def test_connect_in_a_non_idle_state_is_a_runtime_error_failure
      with_echo do |client, transport|
        client.connect(transport)
        result = client.connect(transport)

        assert result.failure?
        assert_instance_of RuntimeError, result.failure
        assert_equal "Cannot connect MCP client in connected state", result.failure.message
      end
    end

    # The pages-cap row is unreachable through the echo fixture (a server
    # answering distinct cursors forever means 1000 real round trips); the
    # request stub pins the cap check at unit level (Grounds §5's
    # itemized-if-cut allowance, same as the send-failure family below).
    def test_list_tools_pages_cap_is_a_runtime_error_failure
      capped = Class.new(Mcp::Client) do
        def request(method, params = nil, timeout_ms: nil)
          @page ||= 0
          @page += 1
          Success({"tools" => [], "nextCursor" => "page-#{@page}"})
        end
      end
      result = capped.new.list_tools

      assert result.failure?
      assert_instance_of RuntimeError, result.failure
      assert_equal "MCP tools/list exceeded 1000 pages", result.failure.message
    end

    # The send-failure wall (today's `raise e` after pending cleanup): the
    # transport's exception instance arrives as the Failure payload.
    def test_transport_send_failure_is_the_failure_payload
      broken = Class.new(Mcp::Stdio) do
        def send(message)
          raise Errno::EPIPE, "Broken pipe"
        end
      end
      client = Mcp::Client.new
      result = client.connect(broken.new(command: RUBY, args: [ECHO_SERVER]))

      assert result.failure?
      assert_instance_of Errno::EPIPE, result.failure
      assert_equal "closed", client.connection_state
    end

    def test_tools_for_skips_a_failed_server_with_the_frozen_warn_bytes
      out, stderr = capture_io do
        tools = Mcp.tools_for("broken" => {command: RUBY, args: ["-e", "exit 1"]})
        assert_empty tools
      end

      assert_empty out
      assert_match(/\Atart: mcp server "broken" failed to connect: .+\n\z/, stderr)
    end

    # -- the no-silent-swallow golden (Grounds §2.3) ---------------------------

    # A scripted mid-tool failure propagates to every observable seam exactly
    # as before the Result rewire: the tool_execution_end result value, the
    # wire's next-request tool-message content, the recorded session
    # tool-entry content, the run's message roles, agent_end error nil, and
    # the normalized session digest — frozen literals.
    def test_mid_tool_failure_keeps_every_observable_byte
      dir = @dir
      server = MockLLMServer.new.start
      @server_to_stop = server
      server.script([
        {type: :stream, content: "",
         tool_calls: [{id: "call_1", name: "edit",
                       arguments: {path: "absent.txt", edits: [{old_text: "a", new_text: "b"}]}}]},
        {type: :message, content: "noted the failure"},
      ])
      recorder = Agent::Session::Recorder.new(cwd: dir, root: File.join(dir, "agent"))
      tools = Tools::Registry.build(selected: %w[edit], cwd: dir)
      events = []
      chat = TestChat.build(server, system_prompt: "test prompt")
      agent = Agent::Loop.new(chat:, tools:, recorder:, on_event: ->(e) { events << e })
      Core::Loop.new(session: ScriptedSession.new).run { agent.run("edit the file") }

      refute agent.last_error, "a tool failure never stops the run"
      want_result = "{error: \"Could not edit file: absent.txt. Error code: ENOENT.\"}"
      tool_event = events.find { |e| e[:type] == :tool_execution_end }
      assert_equal want_result, tool_event[:result].inspect
      wire = server.captured_requests.last["messages"].find { |m| m["role"] == "tool" }
      assert_equal '{"error":"Could not edit file: absent.txt. Error code: ENOENT."}', wire["content"]
      recorded = File.readlines(recorder.path).map { |l| JSON.parse(l) }
        .find { |e| e.dig("message", "role") == "tool" }
      assert_equal wire["content"], recorded.dig("message", "content")
      assert_equal %i[user assistant tool assistant], agent.new_messages.map(&:role)
      assert_nil events.find { |e| e[:type] == :agent_end }[:error]

      # The I44 VOLATILE-normalized session digest (id/parentId/timestamp/
      # parentSession/cwd/firstKeptEntryId + the tmpdir path).
      volatile = %w[id parentId timestamp parentSession cwd firstKeptEntryId]
      norm = lambda { |o|
        case o
        when Hash
          o.each_with_object({}) { |(k, v), h| h[k] = volatile.include?(k) && !v.nil? ? "<#{k}>" : norm.call(v) }
        when Array
          o.map { |v| norm.call(v) }
        else
          o.to_s.gsub(dir, "<DIR>")
        end
      }
      digest = Digest::SHA256.hexdigest(
        File.readlines(recorder.path).map { |l| JSON.generate(norm.call(JSON.parse(l))) }.join("\n")
      )
      assert_equal "0b220daa136898e8494bb446f29cd3a92a1f38ed9cc657cd1f7230683420ebef", digest
    end

    private

    def mock_server(script)
      server = MockLLMServer.new.start
      @server_to_stop = server
      server.script(script)
      server
    end

    def run_agent_on_kernel(server, prompt, **loop_kwargs)
      events = []
      events_mutex = Mutex.new
      sink = ->(event) { events_mutex.synchronize { events << event } }
      chat = TestChat.build(server, system_prompt: "test prompt")
      agent = Agent::Loop.new(chat:, tools: {}, on_event: sink, **loop_kwargs)
      Core::Loop.new(session: ScriptedSession.new).run { agent.run(prompt) }
      [agent, events]
    end

    def run_agent_on_kernel_with_chat(chat)
      events = []
      events_mutex = Mutex.new
      sink = ->(event) { events_mutex.synchronize { events << event } }
      agent = Agent::Loop.new(chat:, tools: {}, on_event: sink)
      Core::Loop.new(session: ScriptedSession.new).run { agent.run("hi") }
      [agent, events]
    end

    def with_echo(env = nil, timeout_ms: Mcp::Client::DEFAULT_REQUEST_TIMEOUT_MS)
      client = Mcp::Client.new(request_timeout_ms: timeout_ms)
      @mcp_clients << client
      transport = Mcp::Stdio.new(command: RUBY, args: [ECHO_SERVER], env: env)
      yield client, transport
    end
  end
end
