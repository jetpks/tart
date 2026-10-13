# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/mock_llm_server"
require "stringio"
require "tmpdir"
require "fileutils"

module Tart
  # Print mode (AC5): headless single-shot — final response only on raw
  # stdout, pi's exit-code semantics, unconditional tool execution — no
  # terminal session anywhere on the path.
  class PrintTest < Test
    def setup
      @server = MockLLMServer.new.start
      @dir = Dir.mktmpdir("tart-print-")
      @stdout = StringIO.new
      @stderr = StringIO.new
    end

    def teardown
      @server.stop
      FileUtils.rm_rf(@dir)
    end

    def test_print_writes_the_final_response_only
      @server.script([{type: :stream, content: "the final answer"}])
      code = Print.run(prompt: "hello", chat: chat, tools: {},
                       stdout: @stdout, stderr: @stderr)

      assert_equal Print::EXIT_OK, code
      assert_equal "the final answer\n", @stdout.string
      assert_empty @stderr.string
    end

    def test_print_runs_a_tool_round_trip_headlessly
      File.write(File.join(@dir, "fixture.txt"), "x")
      @server.script([
        {type: :stream, content: "listing", tool_calls: [{id: "call_1", name: "ls", arguments: {path: "."}}]},
        {type: :message, content: "done listing"},
      ])
      tools = Tools::Registry.build(selected: %w[ls], cwd: @dir)
      code = Print.run(prompt: "list the files", chat: chat(tools), tools:,
                       stdout: @stdout, stderr: @stderr)

      assert_equal Print::EXIT_OK, code
      assert_equal "done listing\n", @stdout.string
      tool_message = @server.captured_requests.last["messages"].find { |m| m["role"] == "tool" }
      assert_includes tool_message["content"], "fixture.txt"
    end

    # pi -p executes bash with no decision point (agent-loop.ts:832
    # executes unconditionally); print mode mirrors that exactly.
    def test_print_executes_bash_headlessly_with_no_gate
      @server.script([
        {type: :stream, tool_calls: [{id: "call_1", name: "bash", arguments: {command: "echo print-bash"}}]},
        {type: :message, content: "ran it"},
      ])
      tools = Tools::Registry.build(selected: %w[bash], cwd: @dir)
      code = Print.run(prompt: "run it", chat: chat(tools), tools:,
                       stdout: @stdout, stderr: @stderr)

      assert_equal Print::EXIT_OK, code
      assert_equal "ran it\n", @stdout.string
      tool_message = @server.captured_requests.last["messages"].find { |m| m["role"] == "tool" }
      assert_includes tool_message["content"], "print-bash"
    end

    # I41 (AC4): the resolved identity forwards into the loop — witnessed
    # at construction (the loop's env tier then reads
    # <IDENTITY>_CONTEXT_WINDOW under the resolved face; the tier readback
    # itself is pinned in agent_loop_test). The loop stays real: the
    # witness only records the kwargs and delegates.
    def test_print_forwards_the_resolved_identity_to_the_loop
      original_new = Agent::Loop.method(:new)
      captured = nil
      Agent::Loop.define_singleton_method(:new) do |**kwargs|
        captured = kwargs
        original_new.call(**kwargs)
      end
      begin
        @server.script([{type: :stream, content: "the final answer"}])
        code = Print.run(prompt: "hello", chat: chat, tools: {}, identity: "foo",
                         stdout: @stdout, stderr: @stderr)

        assert_equal Print::EXIT_OK, code
        assert_equal "the final answer\n", @stdout.string, "the witnessed loop still runs the real turn"
        assert_equal "foo", captured.fetch(:identity), "the resolved face threads into the loop"
      ensure
        Agent::Loop.define_singleton_method(:new, original_new)
      end
    end

    # I41 (AC3/AC4, the white-label smoke): the print path's session env
    # rides the resolved identity — foo exposes FOO_-prefixed vars with
    # the launcher-composed values (the ephemeral print shape: id minted,
    # no session file).
    def test_print_path_session_env_rides_the_resolved_identity
      @server.script([
        {type: :stream, tool_calls: [{id: "call_1", name: "bash",
          arguments: {command: 'printf "id=%s file=[%s] model=%s" "$FOO_SESSION_ID" "$FOO_SESSION_FILE" "$FOO_MODEL"'}}]},
        {type: :message, content: "read"},
      ])
      session_id = Agent::Session.uuidv7
      tools = Tools::Registry.build(selected: %w[bash], cwd: @dir, identity: "foo",
        session_env: {"SESSION_ID" => -> { session_id }, "MODEL" => -> { "glm-5.3" }})
      code = Print.run(prompt: "read the env", chat: chat(tools), tools:, identity: "foo",
                       stdout: @stdout, stderr: @stderr)

      assert_equal Print::EXIT_OK, code
      tool_message = @server.captured_requests.last["messages"].find { |m| m["role"] == "tool" }
      assert_includes tool_message["content"], "id=#{session_id} file=[] model=glm-5.3"
    end

    def test_print_exit_code_1_on_agent_error
      @server.script([{type: :error, status: 400, message: "bad request"}])
      code = Print.run(prompt: "hi", chat: chat, tools: {},
                       stdout: @stdout, stderr: @stderr)

      assert_equal Print::EXIT_ERROR, code
      assert_empty @stdout.string
      assert_includes @stderr.string, "bad request"
    end

    private

    def chat(tools = {})
      TestChat.build(@server, tools: tools.values, system_prompt: "test prompt")
    end
  end
end
