# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/mock_llm_server"
require "json"

module Tart
  # The I98 executor never-rejects belt (jetpks/tart#21): every
  # executor-layer StandardError — a raise escaping the gate/dispatch from
  # a bare custom tool, a before-tool hook raise, the not-found arm —
  # lands a PERSISTED tool-result record carrying the true failure, fires
  # BOTH execution events, and lets the run continue (pi
  # agent-loop.ts:806-809), so fast-completions' "No result provided"
  # synthetic never papers over a tart orphan. Exactly the four
  # Specification pins; the harness is the I96 pin-7 loopback idiom (the
  # real client chat + the real Agent::Loop on the scripted MockLLMServer,
  # driven headlessly on the kernel) — no network, no sleeps, no skips.
  class ToolResultPersistenceTest < Test
    # The executor/gate-layer raise family: a bare custom tool in the
    # loadout has no ToolGate and no in-tool safe_execute belt — its raise
    # escapes the dispatch raw (the Grounds probe's BoomTool shape).
    class BoomTool < Fast::Completions::Tool
      description "Raises a RuntimeError from call"
      parameters({"type" => "object",
                  "properties" => {"label" => {"type" => "string"}},
                  "required" => ["label"]})
      def name = "boom"
      def call(tool_call: nil, **_arguments)
        raise RuntimeError, "the REAL failure: kaboom"
      end
    end

    # The green sibling the mixed batch rides: succeeds and returns the
    # text argument verbatim (a String — the result_content pass-through).
    class EchoTool < Fast::Completions::Tool
      description "Echoes the text argument back"
      parameters({"type" => "object",
                  "properties" => {"text" => {"type" => "string"}},
                  "required" => ["text"]})
      def name = "echo"
      def call(tool_call: nil, **_arguments)
        _arguments["text"]
      end
    end

    def setup
      @server = nil
      @chat = nil
      @events = []
    end

    def teardown
      @server&.stop
    end

    # Pin 1 — raise-persists (the probe-1 shape, cured): the raising call
    # completes the session with the REAL error persisted and on the wire;
    # the codec synthetic never appears.
    def test_raising_tool_call_persists_the_real_error_and_the_run_continues
      agent = belted_agent(tools: {"boom" => BoomTool.new}, system_prompt: "probe")
      @server.script([
        {type: :stream, content: "", tool_calls: [{id: "call_1", name: "boom", arguments: {"label" => "x"}}]},
        {type: :message, content: "second-round reply"},
      ])
      result = run_on_kernel(agent, "go")

      assert_equal %i[user assistant tool assistant], result.map(&:role)
      assert_nil agent.last_error, "a belted tool failure never stops the run"
      record = tool_messages.last
      assert_equal "call_1", record.tool_call_id
      decoded = JSON.parse(record.content)
      assert decoded["error"].start_with?("RuntimeError: the REAL failure: kaboom"),
        "the persisted record carries the true failure: #{decoded["error"].inspect}"
      assert_includes decoded["error"], " (at ", "the I94 site clause names WHERE"

      wire = @server.captured_requests.last["messages"].find { |message| message["role"] == "tool" }
      assert_equal "call_1", wire["tool_call_id"]
      refute_includes wire["content"], "No result provided", "the codec synthetic stays off the wire"
      assert_equal record.content, wire["content"]
    end

    # Pin 2 — hook-raise-persists: a before_tool_call hook raise becomes
    # the call's persisted record (class+message, the I94 vocabulary); the
    # batch completes and the second round replies.
    def test_before_hook_raise_persists_the_hook_error_and_the_run_continues
      agent = belted_agent(tools: {"echo" => EchoTool.new}, system_prompt: "probe")
      # Registered AFTER the loop's construction: the loop's own start
      # emitter is registered first (the production-only registrant), then
      # this hook kills the prepare.
      @chat.before_tool_call do |_tool_call|
        raise "hook pre-flight detonation"
      end
      @server.script([
        {type: :stream, content: "", tool_calls: [{id: "call_1", name: "echo", arguments: {"text" => "unused"}}]},
        {type: :message, content: "replied past the hook"},
      ])
      result = run_on_kernel(agent, "go")

      assert_equal %i[user assistant tool assistant], result.map(&:role)
      assert_nil agent.last_error
      decoded = JSON.parse(tool_messages.last.content)
      assert decoded["error"].start_with?("RuntimeError: hook pre-flight detonation"),
        "the record carries the hook error's class+message: #{decoded["error"].inspect}"
      assert_includes decoded["error"], " (at "
      assert_equal "replied past the hook", result.last.content, "the second round replies"
    end

    # Pin 3 — not-found-events (the probe-2 shape, cured): the not-found
    # arm fires BOTH execution events (0/0 at base) with duration 0.0, and
    # its persisted bytes stay exactly the probe-2 shape on and off the run.
    def test_not_found_call_fires_both_events_and_keeps_the_exact_bytes
      agent = belted_agent(tools: {"echo" => EchoTool.new}, system_prompt: "probe")
      @server.script([
        {type: :stream, content: "", tool_calls: [{id: "call_1", name: "missing_tool", arguments: {}}]},
        {type: :message, content: "second-round reply"},
      ])
      result = run_on_kernel(agent, "go")

      assert_equal %i[user assistant tool assistant], result.map(&:role)
      assert_equal 1, @events.count { |event| event[:type] == :tool_execution_start },
        "the not-found arm fires :tool_execution_start (0 at base)"
      end_event = @events.find { |event| event[:type] == :tool_execution_end }
      refute_nil end_event, "the not-found arm fires :tool_execution_end (0 at base)"
      assert_equal 0.0, end_event[:duration]
      assert_equal({error: "Tool not found: missing_tool"}, end_event[:result])
      record = tool_messages.last
      assert_equal '{"error":"Tool not found: missing_tool"}', record.content, "the exact probe-2 bytes"
      wire = @server.captured_requests.last["messages"].find { |message| message["role"] == "tool" }
      assert_equal record.content, wire["content"]
    end

    # Pin 4 — mixed-batch: one raising sibling + one succeeding sibling —
    # BOTH records land in CALL order, the frozen join never dies, and the
    # next request carries both real contents.
    def test_mixed_batch_persists_both_records_in_call_order_and_the_join_survives
      agent = belted_agent(tools: {"boom" => BoomTool.new, "echo" => EchoTool.new}, system_prompt: "probe")
      @server.script([
        {type: :stream, content: "", tool_calls: [
          {id: "call_1", name: "boom", arguments: {"label" => "x"}},
          {id: "call_2", name: "echo", arguments: {"text" => "echo-ok"}},
        ]},
        {type: :message, content: "both records noted"},
      ])
      result = run_on_kernel(agent, "go")

      assert_equal %i[user assistant tool tool assistant], result.map(&:role)
      assert_nil agent.last_error, "the join never dies on a tool failure"
      records = tool_messages
      assert_equal %w[call_1 call_2], records.map(&:tool_call_id), "records land in CALL order"
      assert JSON.parse(records[0].content)["error"].start_with?("RuntimeError: the REAL failure"),
        "the raising sibling's record carries the real error"
      assert_equal "echo-ok", records[1].content, "the green sibling's record is byte-unchanged"

      wire_tools = @server.captured_requests.last["messages"].select { |message| message["role"] == "tool" }
      assert_equal %w[call_1 call_2], wire_tools.map { |message| message["tool_call_id"] }
      assert JSON.parse(wire_tools[0]["content"])["error"].start_with?("RuntimeError: the REAL failure")
      assert_equal "echo-ok", wire_tools[1]["content"]
      refute wire_tools.any? { |message| message["content"].include?("No result provided") }
    end

    private

    # The I96 pin-7 loopback idiom: the real client chat on the mock, the
    # real Agent::Loop with an event-recording sink. The chat is kept on
    # the test (the loop takes it without a reader) — its transcript is the
    # persistence observable.
    def belted_agent(tools:, system_prompt:)
      @server = MockLLMServer.new.start
      @chat = TestChat.build(@server, tools: tools.values, system_prompt: system_prompt)
      Agent::Loop.new(chat: @chat, tools:, on_event: ->(event) { @events << event })
    end

    def tool_messages
      @chat.messages.select { |message| message.role == :tool }
    end

    # The documented kernel usage: the scripted session drives a headless
    # run on the reactor fiber (Core::Loop — the kernel, not a bare Async).
    def run_on_kernel(agent, prompt)
      result = nil
      Core::Loop.new(session: ScriptedSession.new).run { result = agent.run(prompt) }
      result
    end
  end
end
