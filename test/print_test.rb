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
