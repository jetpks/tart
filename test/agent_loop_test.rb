# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/mock_llm_server"
require "stringio"
require "tmpdir"
require "fileutils"
require "json"

module Tart
  # The agent loop on the I02 kernel (AC1/AC3): multi-turn tool round-trip
  # against the real ruby_llm client over a local mock OpenAI-compatible
  # endpoint, kernel-interrupt cancellation, schema gating, unconditional
  # tool execution (pi's agent-loop.ts:832 — no permissions system).
  class AgentLoopTest < Test
    EVENTS = %i[agent_start turn_start message_start message_update message_end
                tool_execution_start tool_execution_end turn_end agent_end].freeze

    def setup
      @server = MockLLMServer.new.start
      @dir = Dir.mktmpdir("tart-agent-")
    end

    def teardown
      @server.stop
      FileUtils.rm_rf(@dir)
    end

    def test_multi_turn_tool_round_trip_on_the_kernel
      File.write(File.join(@dir, "fixture.txt"), "x")
      @server.script([
        {type: :stream, content: "listing", tool_calls: [{id: "call_1", name: "ls", arguments: {path: "."}}]},
        {type: :message, content: "the listing is above"},
      ])
      tools = Tools::Registry.build(selected: %w[ls], cwd: @dir)
      agent, events = agent_on_kernel(tools:)
      result = run_agent(agent, "list the files")

      # pi's loop shape: user message -> assistant (tool calls) -> tool
      # result -> assistant -> completion.
      assert_equal %i[user assistant tool assistant], result.map(&:role)
      assert_equal "the listing is above", result.last.content
      assert agent_newly_complete?(agent)

      # Tool results return into the context: the second request's messages
      # carry the ls output as a tool message joined to the call id.
      requests = @server.captured_requests
      assert_equal 2, requests.size
      tool_message = requests.last["messages"].find { |m| m["role"] == "tool" }
      assert_equal "call_1", tool_message["tool_call_id"]
      assert_includes tool_message["content"], "fixture.txt"

      # Event lifecycle: every phase present, in order.
      types = events.map { |e| e[:type] }
      %i[agent_start turn_start tool_execution_start tool_execution_end turn_end agent_end].each do |type|
        assert_includes types, type
      end
      assert types.index(:tool_execution_end) < types.rindex(:agent_end)
      deltas = events.select { |e| e[:type] == :message_update }
      assert deltas.any? { |e| e[:chunk].content == "listing" }, "streamed text deltas must flow"

      # I17 AC2: :tool_execution_end carries the execution's wall duration —
      # Float seconds off the monotonic clock, always present, 0.0 legitimate
      # (pi's durationMs; rendered as `Took 0.0s`). Session recording stays
      # untouched — the replay gap is itemized, not closed.
      durations = events.select { |e| e[:type] == :tool_execution_end }.map { |e| e[:duration] }
      assert_equal 1, durations.size
      assert durations.first.is_a?(Float) && durations.first >= 0.0,
        "duration must be non-negative Float seconds, got #{durations.first.inspect}"
    end

    def test_schema_gating_disabled_tools_never_reach_the_model
      @server.script([{type: :message, content: "ok"}])
      tools = Tools::Registry.build(selected: %w[read ls], cwd: @dir) # bash/edit/write/find/grep disabled
      agent, _events = agent_on_kernel(tools:, script_enabled: false)
      run_agent(agent, "hi")

      request = @server.captured_requests.first
      names = request["tools"].map { |t| t["function"]["name"] }
      assert_equal %w[ls read], names.sort,
        "a disabled tool must never appear in the tool declarations sent to the model"
      assert request["tools"].all? { |t| t["type"] == "function" }
      assert request["tools"].all? { |t| t["function"]["parameters"].is_a?(Hash) }
    end

    # The former destructive-tool gate is gone (owner ruling 2026-10-10,
    # reversing I03): bash runs through the loop with no decision point —
    # pi's shape, agent-loop.ts:832.
    def test_bash_runs_through_the_loop_with_no_decision_point
      @server.script([
        {type: :stream, tool_calls: [{id: "call_1", name: "bash", arguments: {command: "echo straight-through"}}]},
        {type: :message, content: "done"},
      ])
      agent, events = agent_on_kernel(tools: Tools::Registry.build(selected: %w[bash], cwd: @dir))
      run_agent(agent, "run it")

      requests = @server.captured_requests
      tool_message = requests.last["messages"].find { |m| m["role"] == "tool" }
      assert_includes tool_message["content"], "straight-through"
      types = events.map { |e| e[:type] }
      assert types.index(:tool_execution_start) < types.index(:tool_execution_end),
        "the call executes — no pause, no decision"
    end

    # I05 defect 1 (live repro tmp/repro_tool_hang.rb): a worker exception
    # (the mock's scripted 400 — the live shape was fireworks 400ing the
    # replayed reasoning field) must terminate the run through the existing
    # error path. The pre-fix bridge left the reactor blocked on queue.pop
    # forever after the dead worker pushed {type: :error} — this test's
    # bounded wait times out there (5 s) instead of hanging the suite.
    def test_worker_error_terminates_the_run_bounded
      @server.script([{type: :error, status: 400,
                       message: "Extra inputs are not permitted ('messages[1].reasoning')"}])
      agent, events = agent_on_kernel
      run_agent_bounded(agent, "hi")

      error_event = events.find { |e| e[:type] == :agent_end }
      assert error_event, "the run must reach agent_end"
      assert error_event[:error], "the worker's error must surface on agent_end"
      assert_kind_of RubyLLM::BadRequestError, agent.last_error
      assert_includes agent.last_error.message, "Extra inputs"
      assert_equal %i[user], agent.new_messages.map(&:role)
    end

    # I36 (the replay protocol — pi :1340-1352, the delta-carried field):
    # a thinking reply's assistant message KEEPS its thinking (the I05
    # strip_thinking_replay deviation is gone), and follow-up request
    # bodies replay it under `reasoning_content` — the field the provider's
    # deltas carried (live-verified for fireworks) — with ruby_llm's
    # duplicate `reasoning` field ABSENT (the request-seam normalization).
    # The tool-result continuation completes (the I05 400 class cannot
    # recur through the port's own payload shape).
    def test_followup_requests_replay_the_assistant_reasoning_content
      @server.script([
        {type: :stream, content: "listing", reasoning_content: "I should list the files",
         tool_calls: [{id: "call_1", name: "ls", arguments: {path: "."}}]},
        {type: :message, content: "done"},
      ])
      File.write(File.join(@dir, "fixture.txt"), "x")
      tools = Tools::Registry.build(selected: %w[ls], cwd: @dir)
      agent, events = agent_on_kernel(tools:)
      result = run_agent(agent, "list the files")

      requests = @server.captured_requests
      assert_equal 2, requests.size
      assistants = requests.last["messages"].select { |m| m["role"] == "assistant" }
      assert assistants.any?
      replayed = assistants.find { |message| message["reasoning_content"] }
      assert_equal "I should list the files", replayed["reasoning_content"],
        "the thinking replays under the delta-carried signature (pi's assistantMsg[signature])"
      assistants.each do |message|
        refute message.key?("reasoning"), "ruby_llm's duplicate `reasoning` field must be absent"
      end
      assert_equal "done", result.last.content
      types = events.map { |e| e[:type] }
      assert_includes types, :turn_end
      error_ends = events.select { |e| e[:type] == :agent_end && e[:error] }
      assert_empty error_ends, "the continuation must complete without an error"
    end

    # I36 AC1: the resolved level reaches the wire — reasoning_effort =
    # Models.resolve_reasoning_effort (the map's value for the clamped
    # level), read at request time so a mid-session set_thinking_level
    # changes the NEXT request with no gem state to reset.
    def test_reasoning_effort_rides_the_wire_and_follows_the_session_level
      @server.script([
        {type: :message, content: "one"},
        {type: :message, content: "two"},
      ])
      agent, _events = agent_on_kernel(
        model_reasoning: true,
        thinking_level_map: {off: "low", low: "low", medium: "medium", high: "high"}
      )
      run_agent(agent, "first")
      assert_equal "medium", @server.captured_requests.first["reasoning_effort"],
        "pi's DEFAULT_THINKING_LEVEL medium resolves through the map"

      agent.set_thinking_level("high")
      run_agent(agent, "second")
      assert_equal "high", @server.captured_requests.first["reasoning_effort"],
        "the mid-session level applies to the next request"
      assert_equal "high", agent.thinking_level
    end

    # The off-floor shapes: a null-off map clamps upward (off → low); an
    # owner-override String off value floors directly; a map-less off
    # sends NO reasoning_effort key.
    def test_reasoning_effort_off_floor_shapes
      @server.script([
        {type: :message, content: "a"},
        {type: :message, content: "b"},
      ])

      agent, _events = agent_on_kernel(
        thinking_level: "off", model_reasoning: true,
        thinking_level_map: {off: nil, minimal: nil, low: "low", medium: nil, high: "high", xhigh: nil, max: "max"}
      )
      run_agent(agent, "first")
      assert_equal "low", @server.captured_requests.first["reasoning_effort"],
        "the null-off floor clamps upward (the live-catalog shape)"

      agent2, _events2 = agent_on_kernel(
        thinking_level: "off", model_reasoning: true,
        thinking_level_map: {off: "low", low: "low", high: "high"}
      )
      run_agent(agent2, "second")
      assert_equal "low", @server.captured_requests.last["reasoning_effort"],
        "the owner-override String off value floors directly"

      agent3, _events3 = agent_on_kernel(thinking_level: "off", model_reasoning: true)
      run_agent(agent3, "third")
      refute @server.captured_requests.last.key?("reasoning_effort"),
        "map-less off sends nothing"
    end

    # A non-reasoning model never sends reasoning_effort, whatever the
    # level and map (pi: the generic branch gates on model.reasoning).
    def test_non_reasoning_model_never_sends_reasoning_effort
      @server.script([{type: :message, content: "ok"}])
      agent, _events = agent_on_kernel(thinking_level: "high", model_reasoning: false,
        thinking_level_map: {high: "high"})
      run_agent(agent, "hi")

      refute @server.captured_requests.first.key?("reasoning_effort")
    end

    # The switch seam re-resolves the reasoning facts alongside the window
    # (pi setModel swaps the Model object): the switched entry's flag/map
    # govern the following requests.
    def test_switch_model_re_resolves_the_reasoning_facts
      @server.script([
        {type: :message, content: "before"},
        {type: :message, content: "after"},
        {type: :message, content: "muted"},
      ])
      agent, _events = agent_on_kernel(thinking_level: "high", model_reasoning: false)
      run_agent(agent, "first")
      refute @server.captured_requests.first.key?("reasoning_effort"), "non-reasoning boot sends nothing"

      agent.switch_model("glm-5.3", provider: "openai", model_reasoning: true,
        thinking_level_map: {high: "high"})
      run_agent(agent, "second")
      assert_equal "high", @server.captured_requests.first["reasoning_effort"],
        "the switched entry's facts govern (the map's value for the level)"

      agent.switch_model("mock-2", provider: "openai", model_reasoning: true, thinking_level_map: nil)
      run_agent(agent, "third")
      assert_equal "high", @server.captured_requests.first["reasoning_effort"],
        "the map-less rule falls back to the level itself"
    end

    # The map re-resolve is TOTAL (pi setModel swaps the Model object — no
    # stale facts survive the switch): switching to a map-less entry DROPS
    # the previous map. A leaked map would keep flooring "off" to its
    # String value where the map-less rule sends nothing.
    def test_switch_to_a_mapless_entry_drops_the_previous_map
      @server.script([
        {type: :message, content: "one"},
        {type: :message, content: "two"},
      ])
      agent, _events = agent_on_kernel(thinking_level: "off", model_reasoning: true,
        thinking_level_map: {off: "low", high: "high"})
      run_agent(agent, "first")
      assert_equal "low", @server.captured_requests.first["reasoning_effort"],
        "the String off map value floors off"

      agent.switch_model("mock-2", provider: "openai", model_reasoning: true, thinking_level_map: nil)
      run_agent(agent, "second")
      refute @server.captured_requests.last.key?("reasoning_effort"),
        "the map-less entry re-resolves: off sends nothing (a stale map would still floor to low)"
    end

    # Print mode (AC1's third wire site): the launcher-threaded thinking
    # facts ride Print.run into the loop's request seam — reasoning_effort
    # on the wire when the model reasons, no key when it doesn't (the
    # defaults keep the legacy shape).
    def test_print_mode_wires_the_thinking_facts_into_the_request
      @server.script([
        {type: :message, content: "reasoned"},
        {type: :message, content: "plain"},
      ])
      stdout, stderr = StringIO.new, StringIO.new
      code = Print.run(prompt: "think", chat: TestChat.build(@server, tools: [], system_prompt: "test prompt"),
        tools: {}, stdout:, stderr:, thinking_level: "high", model_reasoning: true,
        thinking_level_map: {high: "high", off: "low"})

      assert_equal Print::EXIT_OK, code
      assert_equal "high", @server.captured_requests.first["reasoning_effort"]

      code = Print.run(prompt: "plain", chat: TestChat.build(@server, tools: [], system_prompt: "test prompt"),
        tools: {}, stdout:, stderr:)
      assert_equal Print::EXIT_OK, code
      refute @server.captured_requests.last.key?("reasoning_effort"),
        "the default facts (non-reasoning) send no reasoning_effort"
    end

    # --- I46: the zai dialect at the request seam (the ten-wire-pin table) ---

    # The owner's live thinkingLevelMap (Grounds §3): the supported ladder
    # is [low, high, max] — DEFAULT medium clamps FORWARD to high.
    OWNER_MAP = {off: nil, minimal: nil, low: "low", medium: nil,
                 high: "high", xhigh: nil, max: "max"}.freeze

    def zai_compat(overrides = {})
      Shapes::ModelCompat.new({thinking_format: "zai", max_tokens_field: "max_tokens",
                               supports_developer_role: false, supports_reasoning_effort: true,
                               zai_tool_stream: true}.merge(overrides))
    end

    # Pin 1 — the owner dialect: thinking object ALWAYS on a reasoning
    # zai model, reasoning_effort = the map's value for the CLAMPED level
    # (medium → high), tool_stream with the tools, and the instruction
    # role rewritten to system (supportsDeveloperRole false).
    def test_zai_owner_dialect_rides_the_wire
      @server.script([{type: :message, content: "ok"}])
      tools = Tools::Registry.build(selected: %w[ls], cwd: @dir)
      agent, _events = agent_on_kernel(tools:, thinking_level: "medium", model_reasoning: true,
        thinking_level_map: OWNER_MAP, compat: zai_compat)
      run_agent(agent, "hi")

      request = @server.captured_requests.first
      assert_equal({"type" => "enabled", "clear_thinking" => false}, request["thinking"],
        "the thinking object rides enabled with clear_thinking ONLY on enabled (pi :886-887)")
      assert_equal "high", request["reasoning_effort"],
        "medium clamps forward through the owner map (the catalog's null medium)"
      assert_equal true, request["tool_stream"], "zaiToolStream + request tools → tool_stream"
      assert_equal "system", request["messages"].first["role"],
        "the gem's developer instruction is rewritten to system"
    end

    # Pin 2 — the off-edge (OQ-5): a String off map value floors the I36
    # generic arm, but the zai arm keys on the CLAMPED level — a clamped
    # "off" is NO effort (pi :751), so disabled thinking and NO
    # reasoning_effort, whatever the map's off value.
    def test_zai_off_edge_sends_disabled_thinking_and_no_effort
      @server.script([{type: :message, content: "a"}])
      agent, _events = agent_on_kernel(thinking_level: "off", model_reasoning: true,
        thinking_level_map: {off: "low", low: "low", high: "high"}, compat: zai_compat)
      run_agent(agent, "hi")

      request = @server.captured_requests.first
      assert_equal({"type" => "disabled"}, request["thinking"],
        "a clamped off sends the disabled thinking object")
      refute request.key?("reasoning_effort"),
        "the String off floor does NOT apply on the zai arm (no reasoning_effort key)"
    end

    # Pin 3 — supportsReasoningEffort false/nil: the thinking object
    # still rides, the effort field does not (pi :888 gates the effort on
    # the compat flag; the owner's catalog overrides the detected false —
    # the flag is the model's say, not the dialect's).
    def test_zai_supports_reasoning_effort_false_keeps_thinking_drops_effort
      @server.script([{type: :message, content: "a"}, {type: :message, content: "b"}])
      agent, _events = agent_on_kernel(thinking_level: "high", model_reasoning: true,
        thinking_level_map: {high: "high"}, compat: zai_compat(supports_reasoning_effort: false))
      run_agent(agent, "first")

      request = @server.captured_requests.first
      assert_equal({"type" => "enabled", "clear_thinking" => false}, request["thinking"])
      refute request.key?("reasoning_effort"), "supportsReasoningEffort false drops the field"

      agent2, _events2 = agent_on_kernel(thinking_level: "high", model_reasoning: true,
        thinking_level_map: {high: "high"}, compat: zai_compat(supports_reasoning_effort: nil))
      run_agent(agent2, "second")
      request2 = @server.captured_requests.last
      assert_equal({"type" => "enabled", "clear_thinking" => false}, request2["thinking"])
      refute request2.key?("reasoning_effort"), "nil (pi's detected default for zai) drops it too"
    end

    # Pin 4 — tool_stream is gated on the REQUEST's tools (pi :855-863):
    # with tools the field rides; a tool-less session's request carries
    # no tool_stream.
    def test_zai_tool_stream_is_gated_on_request_tools
      @server.script([{type: :message, content: "a"}, {type: :message, content: "b"}])
      tools = Tools::Registry.build(selected: %w[ls], cwd: @dir)
      agent, _events = agent_on_kernel(tools:, thinking_level: "high", model_reasoning: true,
        thinking_level_map: {high: "high"}, compat: zai_compat)
      run_agent(agent, "first")
      assert_equal true, @server.captured_requests.first["tool_stream"]

      agent2, _events2 = agent_on_kernel(thinking_level: "high", model_reasoning: true,
        thinking_level_map: {high: "high"}, compat: zai_compat)
      run_agent(agent2, "second")
      refute @server.captured_requests.last.key?("tool_stream"),
        "no tools on the request, no tool_stream field"
    end

    # Pin 5 — the instruction role (pi :1233): developer only when the
    # model reasons AND the compat says so; the zai default (nil → the
    # detection stand-in false) rewrites the gem's developer to system.
    def test_zai_instruction_role_rewrite
      @server.script([{type: :message, content: "a"}, {type: :message, content: "b"}])
      agent, _events = agent_on_kernel(thinking_level: "high", model_reasoning: true,
        thinking_level_map: {high: "high"}, compat: zai_compat)
      run_agent(agent, "first")
      assert_equal "system", @server.captured_requests.first["messages"].first["role"],
        "nil supportsDeveloperRole on zai falls to the detection stand-in (false)"

      agent2, _events2 = agent_on_kernel(thinking_level: "high", model_reasoning: true,
        thinking_level_map: {high: "high"}, compat: zai_compat(supports_developer_role: true))
      run_agent(agent2, "second")
      assert_equal "developer", @server.captured_requests.last["messages"].first["role"],
        "explicit true keeps the gem's developer instruction"
    end

    # Pin 6 — the compaction summarization request rides the SAME dialect
    # (pi compaction.ts:605-607 carries the session level): the max-token
    # key renames to max_tokens (never max_completion_tokens), the
    # thinking object + mapped effort ride it, the role rewrites, and the
    # tool-less one-shot carries no tool_stream.
    def test_zai_summarization_request_carries_max_tokens_and_thinking
      @server.script([
        {type: :stream, content: "first answer"},
        {type: :message, content: "a summary of the first turn"},
        {type: :stream, content: "second answer"},
        {type: :message, content: "a summary of the second turn"},
      ])
      agent, _events = agent_on_kernel(
        compaction: {reserve_tokens: 1, keep_recent_tokens: 1}, context_window: 14,
        thinking_level: "medium", model_reasoning: true, thinking_level_map: OWNER_MAP,
        compat: zai_compat
      )
      agent.push_message("second question")
      run_agent(agent, "first question")

      requests = @server.captured_requests
      assert_equal 4, requests.size
      summary_request = requests[1]
      assert summary_request.key?("max_tokens"), "the rename lands on the one-shot"
      refute summary_request.key?("max_completion_tokens"), "never max_completion_tokens under the rename"
      assert_equal({"type" => "enabled", "clear_thinking" => false}, summary_request["thinking"],
        "the thinking object rides the summarization too")
      assert_equal "high", summary_request["reasoning_effort"],
        "the session level (medium, clamped forward) rides the one-shot"
      assert_equal "system", summary_request["messages"].first["role"],
        "the summarization instruction rewrites to system as well"
      refute summary_request.key?("tool_stream"), "the one-shot carries no tools, no tool_stream"
    end

    # Pin 7 — a NON-reasoning zai model: no thinking object, no
    # reasoning_effort (pi :880 gates the arm on model.reasoning), and
    # the role still rewrites (the effective role is system regardless).
    def test_zai_non_reasoning_sends_no_thinking_and_no_effort
      @server.script([{type: :message, content: "ok"}])
      agent, _events = agent_on_kernel(thinking_level: "high", model_reasoning: false,
        thinking_level_map: {high: "high"}, compat: zai_compat)
      run_agent(agent, "hi")

      request = @server.captured_requests.first
      refute request.key?("thinking")
      refute request.key?("reasoning_effort")
      assert_equal "system", request["messages"].first["role"]
    end

    # Pin 8 — compat nil zero-change, the loop path (the wire-bodies
    # digests pin the rig path): no thinking, no tool_stream, developer
    # role, and the summarization one-shot keeps TODAY'S exact shapes —
    # max_completion_tokens, no reasoning_effort (the gem's per-chat
    # callbacks mean the construction hook never ran there; the I36 arm
    # stays off it).
    def test_compat_nil_summarization_request_keeps_todays_shapes
      @server.script([
        {type: :stream, content: "first answer"},
        {type: :message, content: "a summary of the first turn"},
        {type: :stream, content: "second answer"},
        {type: :message, content: "a summary of the second turn"},
      ])
      agent, _events = agent_on_kernel(
        compaction: {reserve_tokens: 1, keep_recent_tokens: 1}, context_window: 14,
        thinking_level: "medium", model_reasoning: true,
        thinking_level_map: {off: "low", low: "low", medium: "medium", high: "high"}
      )
      agent.push_message("second question")
      run_agent(agent, "first question")

      requests = @server.captured_requests
      assert_equal 4, requests.size
      main_request, summary_request = requests[0], requests[1]
      refute main_request.key?("thinking")
      refute main_request.key?("tool_stream")
      assert_equal "developer", main_request["messages"].first["role"]
      refute summary_request.key?("thinking"), "no thinking object on the one-shot"
      refute summary_request.key?("tool_stream")
      assert_equal "developer", summary_request["messages"].first["role"]
      assert summary_request.key?("max_completion_tokens"), "today's max-token key unchanged"
      refute summary_request.key?("max_tokens")
      refute summary_request.key?("reasoning_effort"),
        "today's one-shot carries no reasoning_effort (no hook there)"
    end

    # Pin 9 — the switch seam: switch_model(compat:) swaps the dialect
    # mid-session and compat: nil restores the default arm (the wholesale
    # re-resolve idiom — nil IS "the switched model declares none").
    def test_switch_model_swaps_the_compat_dialect_and_restores
      @server.script([
        {type: :message, content: "one"},
        {type: :message, content: "two"},
        {type: :message, content: "three"},
      ])
      agent, _events = agent_on_kernel(thinking_level: "high", model_reasoning: true,
        thinking_level_map: {high: "high"})
      run_agent(agent, "first")

      agent.switch_model("glm-5.3", provider: "openai", model_reasoning: true,
        thinking_level_map: OWNER_MAP, compat: zai_compat)
      run_agent(agent, "second")

      agent.switch_model("mock-2", provider: "openai", model_reasoning: true,
        thinking_level_map: nil, compat: nil)
      run_agent(agent, "third")

      first, second, third = @server.captured_requests
      refute first.key?("thinking"), "compat-nil boot: today's arm"
      assert_equal "developer", first["messages"].first["role"]

      assert_equal({"type" => "enabled", "clear_thinking" => false}, second["thinking"],
        "the swapped dialect governs the next request")
      assert_equal "high", second["reasoning_effort"]
      assert_equal "system", second["messages"].first["role"]

      refute third.key?("thinking"), "compat nil restores the default arm"
      assert_equal "developer", third["messages"].first["role"]
      assert_equal "high", third["reasoning_effort"], "the I36 effort wiring re-resolves wholesale"
    end

    # Pin 10 — print-mode threading (the I36 third-wire-site idiom): the
    # launcher-threaded compat rides Print.run into the request seam.
    def test_print_mode_threads_the_compat_into_the_request
      @server.script([{type: :message, content: "reasoned"}])
      stdout, stderr = StringIO.new, StringIO.new
      code = Print.run(prompt: "think", chat: TestChat.build(@server, tools: [], system_prompt: "test prompt"),
        tools: {}, stdout:, stderr:, thinking_level: "high", model_reasoning: true,
        thinking_level_map: {high: "high", off: "low"}, compat: zai_compat)

      assert_equal Print::EXIT_OK, code
      request = @server.captured_requests.first
      assert_equal({"type" => "enabled", "clear_thinking" => false}, request["thinking"])
      assert_equal "high", request["reasoning_effort"]
      assert_equal "system", request["messages"].first["role"]
    end

    # The session file (pi's persistence): a thinking reply's recorded
    # entry carries the thinking text — resume replay regains it (the
    # transcript's replay_assistant renders message["thinking"]).
    def test_thinking_reply_persists_to_the_session_file
      @server.script([
        {type: :stream, content: "the answer", reasoning_content: "pondering hard"},
      ])
      recorder = Agent::Session::Recorder.new(cwd: @dir, root: File.join(@dir, "root"))
      agent, _events = agent_on_kernel(recorder:)
      run_agent(agent, "question")

      entries = Agent::Session.load_entries(recorder.path)
      assistant = entries.find { |entry| entry.dig("message", "role") == "assistant" }
      assert_equal "pondering hard", assistant.dig("message", "thinking"),
        "no strip: the recorded entry keeps the thinking"
    end

    def test_queued_message_continues_the_outer_loop
      @server.script([
        {type: :message, content: "first answer"},
        {type: :message, content: "second answer"},
      ])
      agent, _events = agent_on_kernel
      agent.push_message("second")
      result = run_agent(agent, "first")

      assert_equal "second answer", result.last.content
      requests = @server.captured_requests
      assert_equal 2, requests.size
      assert_equal "second", requests.last["messages"].select { |m| m["role"] == "user" }.last["content"]
    end

    # The kernel-level interrupt (the trap-net sentinel — the non-raw
    # SIGINT path): the in-flight turn cancels through Task#stop and
    # surfaces through the agent_end event. (Backlog C: the EDITOR-side
    # interrupt is escape — the surface's interrupt_work! call, pinned in
    # loop_test; ctrl+c is app.clear. The kernel's trap net keeps the
    # interrupted?-or-stop contract for real signals.)
    def test_kernel_interrupt_cancels_in_flight_turn
      @server.script([{type: :slow_stream, content: "x" * 40}])
      agent, events = agent_on_kernel

      kernel = Core::Loop.new(session: ScriptedSession.new)
      th = Thread.new do
        sleep 0.3 # the turn is streaming (40 chars × 0.1 s pauses)
        Process.kill("INT", Process.pid)
      end
      kernel.run { agent.run("long stream") }
      th.join

      assert kernel.interrupted?
      types = events.map { |e| e[:type] }
      assert_includes types, :agent_end
      assert events.find { |e| e[:type] == :agent_end }[:interrupted],
        "interrupt must be observable through the agent_end event"
      assert agent.interrupted?
      refute kernel.poller&.thread&.alive?, "no orphan poller after interrupt"
    end

    # ---- the de-bridge pins (I50 — the gate's -n anchors; names EXACT) -----

    # AC3: with :fibers tool concurrency (armed at Loop#initialize), two
    # 0.5 s sleep tools in ONE scripted batch OVERLAP on the reactor: the
    # batch's wall span (first start → last end) is < 0.9 s — the Bridge-era
    # base ran tools sequentially, span ≈ 1.0 s (this pin is the designed
    # RED at base), and both :tool messages land.
    def test_fibers_tool_concurrency_overlaps_two_interleaved_tools
      @server.script(BATCH_SCRIPT.map(&:dup))
      agent, stamped = stamped_agent_on_kernel(tools: {"sleep" => SleepTool.new})
      run_agent(agent, "sleep twice")

      starts = stamped_events(stamped, :tool_execution_start)
      ends = stamped_events(stamped, :tool_execution_end)
      assert_equal 2, starts.size, "both calls started"
      assert_equal 2, ends.size, "both calls ended"
      span = ends.map { |e| e[:_at] }.max - starts.map { |e| e[:_at] }.min
      assert_operator span, :<, 0.9,
        "the two tool executions must OVERLAP on the reactor (sequential span ≈ 1.0 s); got #{span.round(2)}s"
      assert_equal 2, agent.new_messages.count { |m| m.role == :tool }, "two :tool messages land"
    end

    # AC3 (attribution — Grounds §3 probe4 ARM B): each :tool_execution_end
    # pairs its OWN call by tool_call id (distinct ids, one start per id)
    # and its duration is that tool's OWN runtime (0.4–0.75 s) — the
    # Thread.current keying is fiber-local, so interleaved fibers do not
    # cross-attribute.
    def test_tool_event_attribution_under_interleaved_fibers_tools
      @server.script(BATCH_SCRIPT.map(&:dup))
      agent, stamped = stamped_agent_on_kernel(tools: {"sleep" => SleepTool.new})
      run_agent(agent, "sleep twice")

      starts = stamped_events(stamped, :tool_execution_start)
      ends = stamped_events(stamped, :tool_execution_end)
      start_ids = starts.map { |e| e[:tool_call].id }
      assert_equal 2, start_ids.uniq.size, "distinct tool_call ids"
      assert_equal start_ids.sort, ends.map { |e| e[:tool_call].id }.sort,
        "every end pairs a start by tool_call id — no cross-attribution"
      ends.each do |event|
        assert_instance_of Float, event[:duration]
        assert event[:duration].between?(0.4, 0.75),
          "each duration is its OWN tool's 0.5 s runtime, got #{event[:duration].round(2)}s"
      end
    end

    # AC2 (the interrupt gate): an interrupt during a live stream ABORTS the
    # in-flight request (the Async::Cancel lands in the streaming HTTP read
    # — probe3 ARM1; the full scripted stream would run ≈ 4 s) and emits NO
    # error terminal: interrupted? true, last_error nil, agent_end carries
    # interrupted: true and no :error key, no message_end with error: true.
    def test_interrupt_mid_stream_aborts_request_no_error_terminal
      @server.script([{type: :slow_stream, content: "x" * 40}])
      agent, events = agent_on_kernel

      wall = nil
      Async do |root|
        turn = root.async do
          t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          begin
            agent.run("long stream")
          ensure
            wall = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
          end
        end
        root.async do
          sleep 0.3 # mid-stream (40 chars × 0.1 s pauses)
          turn.stop
        end
        begin
          turn.wait
        rescue Async::Cancel
          nil # run() re-raises the Cancel after the interrupted bookkeeping
        end
      end

      assert_operator wall, :<, 2.0, "the request ABORTED (the full stream runs ≈ 4 s); wall=#{wall.round(2)}s"
      assert agent.interrupted?
      assert_nil agent.last_error
      end_event = events.find { |e| e[:type] == :agent_end }
      assert end_event, "the run reached agent_end"
      assert end_event[:interrupted], "the agent_end carries interrupted: true"
      refute end_event.key?(:error), "NO error key on the interrupted agent_end"
      refute events.any? { |e| e[:type] == :message_end && e[:error] == true },
        "no message_end with error: true — the cancelled shape"
    end

    # AC2 (the belt's residue contract — Grounds §6 OQ-3): the interrupt's
    # chat.cancel flag must not outlive the interrupt. At base the Bridge
    # worker's stream consumed the flag at its next chunk boundary (probe3
    # ARM2); de-bridged, the unwind consumes it (the Cancel arm) — the NEXT
    # run on the same chat makes a FRESH request and completes.
    def test_run_after_an_interrupt_makes_a_fresh_request
      @server.script([{type: :slow_stream, content: "x" * 40}])
      agent, = agent_on_kernel

      Async do |root|
        turn = root.async do
          begin
            agent.run("long stream")
          rescue Async::Cancel
            nil # run() re-raises after the interrupted bookkeeping
          end
        end
        root.async do
          sleep 0.3 # mid-stream
          turn.stop
        end
        begin
          turn.wait
        rescue Async::Cancel
          nil
        end
      end

      assert agent.interrupted?
      assert_nil agent.last_error

      @server.script([{type: :message, content: "fresh answer"}])
      result = run_agent(agent, "still there")

      assert_equal "fresh answer", result.last.content, "the next run completed"
      assert_equal 2, @server.captured_requests.size,
        "the post-interrupt run made a FRESH request (the cancel flag did not survive)"
      assert_nil agent.last_error
    end

    def agent_on_kernel(session: ScriptedSession.new, tools: empty_tools,
                        on_event: nil, script_enabled: true, **loop_kwargs)
      events = []
      events_mutex = Mutex.new
      sink = lambda do |event|
        events_mutex.synchronize { events << event }
      end
      chat = TestChat.build(@server, tools: tools.values, system_prompt: "test prompt")
      [Agent::Loop.new(chat:, tools:, on_event: on_event || sink, **loop_kwargs), events]
    end

    # Runs the agent on a BACKGROUND-thread reactor (the I48 inbox tests
    # write files mid-run; the run must proceed while the test thread
    # works). A bare Async reactor — Core::Loop's trap net is main-thread-
    # only; the loop machinery needs a reactor fiber, not the kernel.
    def run_in_background(agent, prompt)
      Thread.new do
        Thread.current.report_on_exception = false
        begin
          Async do |root|
            root.async { agent.run(prompt) }.wait
          end
        rescue Async::Cancel
          nil # the stop-file path: run() re-raises after the interrupted agent_end
        end
      end
    end

    # The bounded join: a wedged run fails the test instead of hanging it.
    def join_run(thread)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 15
      until !thread.alive? || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep 0.02
      end
      flunk "the run never finished" if thread.alive?
      thread.join
    end

    # Runs #wake on the kernel (the reactor fiber — the documented
    # contract for run-shaped calls). Returns wake's return value.
    def run_wake(agent)
      result = nil
      kernel = Core::Loop.new(session: ScriptedSession.new)
      kernel.run { result = agent.wake }
      result
    end

    def empty_tools
      {}
    end

    # Runs the agent as the kernel work subtree (the documented usage).
    def run_agent(agent, prompt)
      result = nil
      kernel = Core::Loop.new(session: ScriptedSession.new)
      kernel.run { result = agent.run(prompt) }
      yield if block_given?
      result
    end

    def agent_newly_complete?(agent)
      agent.new_messages.last.role == :assistant
    end

    # The model-switch seam (I27 AC3): the same chat object re-resolves
    # model + provider in place (ruby_llm Chat#with_model — live-verified
    # chat.rb:609), and the context window re-resolves (the compaction
    # threshold's denominator follows the switched model).
    def test_switch_model_swaps_the_runtime_chat_and_re_resolves_the_window
      chat = TestChat.build(@server, system_prompt: "test prompt")
      agent = Agent::Loop.new(chat:, tools: empty_tools, context_window: 1000)

      assert_equal "tart-test-model", chat.model.id
      assert_equal 1000, agent.context_window

      agent.switch_model("glm-5.3", provider: "openai", context_window: 200_000)

      assert_equal "glm-5.3", chat.model.id, "the runtime chat model swapped in place"
      assert_equal 200_000, agent.context_window, "the window re-resolved for the compaction math"

      # I29 (the I27 residual): a catalog entry that declares NO window —
      # the kwarg is nil and the loop re-resolves from the switched chat's
      # model instead of keeping the stale 200_000. Under the boot path's
      # assume_model_exists the mock lands on Model.default (no
      # context_window) — nil = threshold disabled, pi's `contextWindow ??
      # 0` (agent-session.ts:2965; pi itself has no cached window:
      # setModel swaps the Model object, :2484).
      agent.switch_model("mock-2", provider: "openai")
      assert_equal "mock-2", chat.model.id
      assert_nil agent.context_window, "no stale window after a no-window switch"
      assert_nil chat.model.context_window, "the re-resolve reads the chat's model"

      # I30 (the I29 residual): a known-models-table entry with no declared
      # window resolves the table's window (Settings::MODEL_CONTEXT_WINDOWS
      # — the boot chain's known-models tier) — the compaction denominator
      # refreshes instead of nil-disabling the threshold trigger.
      agent.switch_model("accounts/fireworks/models/glm-5p3-flash", provider: "openai")
      assert_equal "accounts/fireworks/models/glm-5p3-flash", chat.model.id
      assert_equal Settings::MODEL_CONTEXT_WINDOWS.fetch(chat.model.id), agent.context_window,
        "the table window resolved; the footer denominator readback refreshes"

      # The switched chat still talks to the endpoint (the seam does not
      # strand the connection) — a real request round-trips.
      @server.script([{type: :message, content: "switched"}])
      result = nil
      kernel = Core::Loop.new(session: ScriptedSession.new)
      kernel.run { result = agent.run("hi") }
      assert_equal "switched", result.last.content
    end

    # I41 (AC4, the tier readback): the loop's env tier speaks the
    # identity's namespace — the resolved face decides which CONTEXT_WINDOW
    # var the compaction denominator reads (tart → TART_, default pi →
    # PI_). Direct readback on the private resolver (the mcp_test send
    # precedent); the print path's forwarding is pinned in print_test.
    def test_env_tier_reads_the_identity_namespaced_context_window
      chat = TestChat.build(@server, system_prompt: "test prompt")
      tart_agent = Agent::Loop.new(chat:, tools: empty_tools, identity: "tart")
      pi_agent = Agent::Loop.new(chat:, tools: empty_tools)
      saved_tart = ENV["TART_CONTEXT_WINDOW"]
      saved_pi = ENV["PI_CONTEXT_WINDOW"]
      begin
        ENV["TART_CONTEXT_WINDOW"] = "4242"
        ENV.delete("PI_CONTEXT_WINDOW")
        assert_equal 4242, tart_agent.send(:resolved_context_window),
          "the tart face reads TART_CONTEXT_WINDOW"
        assert_nil pi_agent.send(:resolved_context_window),
          "the pi face ignores TART_CONTEXT_WINDOW (namespace isolation)"

        ENV["PI_CONTEXT_WINDOW"] = "77"
        assert_equal 77, pi_agent.send(:resolved_context_window), "the pi face reads PI_CONTEXT_WINDOW"
      ensure
        saved_tart ? ENV["TART_CONTEXT_WINDOW"] = saved_tart : ENV.delete("TART_CONTEXT_WINDOW")
        saved_pi ? ENV["PI_CONTEXT_WINDOW"] = saved_pi : ENV.delete("PI_CONTEXT_WINDOW")
      end
    end

    # I41 (spec item 5): the recorder reader — the launcher's session-env
    # readers expose the current session's id + file through it (a /new or
    # resume swap re-points surface.agent; the reader re-resolves at every
    # spawn).
    def test_recorder_reader_exposes_the_session_recorder
      chat = TestChat.build(@server, system_prompt: "test prompt")
      assert_nil Agent::Loop.new(chat:, tools: empty_tools).recorder, "no recorder wired, nil"

      recorder = Agent::Session::Recorder.new(cwd: @dir, root: File.join(@dir, "root"))
      agent = Agent::Loop.new(chat:, tools: empty_tools, recorder:)
      assert_same recorder, agent.recorder
      assert recorder.id, "the SESSION_ID reader's source is present"
      assert recorder.path, "the SESSION_FILE reader's source is present"
    end

    # AC2: threshold compaction after a completed turn — usage (the mock
    # reports 10+5 tokens) over context_window - reserve compacts; the next
    # request carries [summary message, kept tail, queued message] and none
    # of the summarized-away messages.
    def test_threshold_compaction_replaces_history_after_a_completed_turn
      # The mock's usage is fixed (10+5 every response), so the estimate
      # stays over this small threshold after every turn — pi re-checks per
      # turn (agent-session.ts:1884), hence the second summary.
      @server.script([
        {type: :stream, content: "first answer"},
        {type: :message, content: "a summary of the first turn"},
        {type: :stream, content: "second answer"},
        {type: :message, content: "a summary of the second turn"},
      ])
      agent, events = agent_on_kernel(
        compaction: {reserve_tokens: 1, keep_recent_tokens: 1}, context_window: 14
      )
      agent.push_message("second question")
      run_agent(agent, "first question")

      requests = @server.captured_requests
      assert_equal 4, requests.size

      # The summarization one-shot: system prompt + one user message with
      # the serialized conversation; only the summarized turn is in it.
      summary_request = requests[1]
      assert_equal "You are a context summarization assistant",
        summary_request["messages"].first["content"][0, 41]
      conversation = summary_request["messages"].last["content"]
      assert_includes conversation, "[User]: first question"
      refute_includes conversation, "second question"

      # The next request: [summary message, kept tail, queued message].
      payload = requests[2]["messages"].reject { |m| %w[system developer].include?(m["role"]) }
      assert_equal %w[user assistant user], payload.map { |m| m["role"] }
      assert_includes payload[0]["content"], "a summary of the first turn"
      assert_equal "first answer", payload[1]["content"]
      assert_equal "second question", payload[2]["content"]

      assert_includes events.map { |e| e[:type] }, :compaction
      compaction = events.find { |e| e[:type] == :compaction }
      assert_equal :threshold, compaction[:reason]
    end

    # AC3 (I30, the frozen payload): the :compaction event carries exactly
    # reason/tokens_before/summary/entries — entries the kept
    # post-compaction replay entries, chronological, no system/summary
    # message, the same as-loaded shape load_entries reads back (pi's
    # rebuild source, interactive-mode.ts:3698-3705 — buildContextEntries
    # + renderSessionEntries(entries.slice(1))). The summarization call's
    # usage (the mock's fixed 10+5) persists on the compaction entry in
    # pi's Usage shape; estimated_tokens_after does not.
    def test_compaction_event_carries_the_kept_replay_entries
      @server.script([
        {type: :stream, content: "first answer"},
        {type: :error, status: 400, message: "This model's maximum context length is 8 tokens"},
        {type: :message, content: "a summary of the first turn"},
        {type: :stream, content: "recovered"},
      ])
      recorder = Agent::Session::Recorder.new(cwd: @dir, root: File.join(@dir, "root"))
      agent, events = agent_on_kernel(compaction: {keep_recent_tokens: 5}, recorder:)
      agent.push_message("second question")
      run_agent(agent, "first question")

      # Turn 1, the overflowing turn-2 step, the summarization one-shot,
      # the retry.
      assert_equal 4, @server.captured_requests.size

      compaction = events.find { |e| e[:type] == :compaction }
      assert_equal %i[type reason tokens_before summary entries], compaction.keys
      assert_equal :overflow, compaction[:reason]
      assert_includes compaction[:summary], "a summary of the first turn"

      # The kept tail [first answer, second question] — chronological,
      # no summarized-away turn, no summary message, the recorded
      # (as-loaded) entry hashes exactly.
      entries = compaction[:entries]
      assert_equal %w[assistant user], entries.map { |e| e["message"]["role"] }
      assert_equal ["first answer", "second question"], entries.map { |e| e["message"]["content"] }
      recorded = Agent::Session.load_entries(recorder.path)
      assert_equal recorded[2, 2], entries, "the payload IS the recorded kept slice"

      persisted = recorded.find { |e| e["type"] == "compaction" }
      # The gem's chat_completions mapping reports an unexplained cache
      # write as 0 (protocols/chat_completions/chat.rb:191-195) — the
      # reader's value persists as-is.
      assert_equal({"input" => 10, "output" => 5, "cacheWrite" => 0, "totalTokens" => 15},
        persisted["usage"])
      refute persisted.key?("estimatedTokensAfter")
    end

    # AC1 (I29): the zero-usage fallback — the knob strips the usage
    # payload, so the just-completed message's direct usage is 0 and the
    # trigger fires on the estimate over the messages (pi Case 3,
    # agent-session.ts:3058-3083).
    def test_threshold_compaction_fires_on_the_estimate_under_zero_usage
      @server.suppress_usage!
      @server.script([
        {type: :stream, content: "first answer"},
        {type: :message, content: "a summary of the first turn"},
      ])
      agent, events = agent_on_kernel(
        compaction: {reserve_tokens: 1, keep_recent_tokens: 1}, context_window: 9
      )
      run_agent(agent, "first question")

      # Turn + summarization: the second request IS the compaction proof.
      requests = @server.captured_requests
      assert_equal 2, requests.size
      assert_includes requests[1]["messages"].last["content"], "[User]: first question"
      compaction = events.find { |e| e[:type] == :compaction }
      assert_equal :threshold, compaction[:reason]
    end

    # AC2 (I31): the zero-usage estimate covers the WIRE context — the
    # message text AND the registered tool schemas (pi's system.toolsAdded
    # arm, compaction.ts:302-311), counted once. The window sits between
    # the text-only estimate (10) and the tools-inclusive estimate
    # (10 + the ls definition component): without the threading the
    # trigger never fires and the run stops at 1 request.
    def test_zero_usage_threshold_estimate_covers_the_wire_tools
      @server.suppress_usage!
      @server.script([
        {type: :stream, content: "first answer"},
        {type: :message, content: "a summary of the first turn"},
      ])
      tools = Tools::Registry.build(selected: %w[ls], cwd: @dir)
      agent, events = agent_on_kernel(
        tools:, compaction: {reserve_tokens: 1, keep_recent_tokens: 1}, context_window: 50
      )
      run_agent(agent, "first question")

      # Turn + summarization: the second request proves the tools component
      # pushed the estimate over the window.
      assert_equal 2, @server.captured_requests.size
      compaction = events.find { |e| e[:type] == :compaction }
      assert_equal :threshold, compaction[:reason]
      assert_operator compaction[:tokens_before], :>, 49
    end

    # AC3 (I12): compaction_start fires once per started compaction, with
    # the reason, BEFORE the completed-compaction event (pi
    # agent-session.ts:3119 — after prepare, before the summary call).
    def test_compaction_start_precedes_compaction_on_threshold
      @server.script([
        {type: :stream, content: "first answer"},
        {type: :message, content: "a summary of the first turn"},
        {type: :stream, content: "second answer"},
      ])
      agent, events = agent_on_kernel(
        compaction: {reserve_tokens: 1, keep_recent_tokens: 1}, context_window: 14
      )
      run_agent(agent, "first question")

      starts = events.each_index.select { |i| events[i][:type] == :compaction_start }
      dones = events.each_index.select { |i| events[i][:type] == :compaction }
      assert_equal 1, starts.size
      assert_equal 1, dones.size
      assert_operator starts.first, :<, dones.first, "compaction_start before compaction"
      assert_equal :threshold, events[starts.first][:reason]
      assert_equal :threshold, events[dones.first][:reason]
    end

    # The start event marks the ATTEMPT: a failed summarization call never
    # emits the completed-compaction event — pinning the emission point
    # before the summarize call (pi: the status indicator is cleared by
    # compaction_end/error, agent-session.ts:3119's placement).
    def test_compaction_start_without_completion_when_the_summary_call_fails
      @server.script([
        {type: :stream, content: "first answer"},
        {type: :error, status: 500, message: "summary endpoint down"},
        {type: :stream, content: "second answer"},
      ])
      agent, events = agent_on_kernel(
        compaction: {reserve_tokens: 1, keep_recent_tokens: 1}, context_window: 14
      )
      run_agent(agent, "first question")

      starts = events.select { |e| e[:type] == :compaction_start }
      assert_equal 1, starts.size
      assert_equal :threshold, starts.first[:reason]
      assert_empty events.select { |e| e[:type] == :compaction }
      refute agent.last_error, "a failed compaction never stops the run"
    end

    # Nothing to compact (prepare returns nil — the keep-recent tail is the
    # whole history): no start event, no compaction (pi: no compaction_start
    # when prepareCompaction returns falsy, agent-session.ts:3113-3116).
    def test_no_compaction_start_when_nothing_to_compact
      @server.script([
        {type: :stream, content: "first answer"},
        {type: :stream, content: "second answer"},
      ])
      agent, events = agent_on_kernel(
        compaction: {reserve_tokens: 1, keep_recent_tokens: 10_000}, context_window: 14
      )
      agent.push_message("second question")
      run_agent(agent, "first question")

      assert_equal 2, @server.captured_requests.size, "no summarization call"
      assert_empty events.select { |e| e[:type] == :compaction_start }
      assert_empty events.select { |e| e[:type] == :compaction }
    end

    def test_compaction_disabled_performs_no_compaction
      @server.script([
        {type: :stream, content: "first answer"},
        {type: :stream, content: "second answer"},
      ])
      agent, events = agent_on_kernel(
        compaction: {enabled: false, reserve_tokens: 1, keep_recent_tokens: 1}, context_window: 14
      )
      agent.push_message("second question")
      run_agent(agent, "first question")

      assert_equal 2, @server.captured_requests.size, "no summarization call"
      assert_empty events.select { |e| e[:type] == :compaction }
      assert_empty events.select { |e| e[:type] == :compaction_start }
    end

    # AC3: a context-overflow step failure compacts and retries the turn
    # once; the overflowing attempt is not in the summarized or kept
    # history (the gem never appends the failed response).
    def test_overflow_compacts_and_retries_the_turn_once
      @server.script([
        {type: :error, status: 400, message: "This model's maximum context length is 8 tokens"},
        {type: :message, content: "a summary of the prior turns"},
        {type: :stream, content: "recovered"},
      ])
      agent, events = agent_on_kernel_with_seeds
      result = run_agent(agent, "new question")

      assert_equal "recovered", result.last.content
      refute agent.last_error

      starts = events.each_index.select { |i| events[i][:type] == :compaction_start }
      dones = events.each_index.select { |i| events[i][:type] == :compaction }
      assert_equal 1, starts.size
      assert_equal 1, dones.size
      assert_operator starts.first, :<, dones.first
      assert_equal :overflow, events[starts.first][:reason]

      requests = @server.captured_requests
      assert_equal 3, requests.size
      summary_conversation = requests[1]["messages"].last["content"]
      assert_includes summary_conversation, "[User]: old question"
      refute_includes summary_conversation, "new question"
      retry_payload = requests[2]["messages"].reject { |m| %w[system developer].include?(m["role"]) }
      assert_equal %w[user user], retry_payload.map { |m| m["role"] }
      assert_includes retry_payload[0]["content"], "a summary of the prior turns"
      assert_equal "new question", retry_payload[1]["content"]
    end

    # AC3: the overflow-recovery latch — a second consecutive overflow
    # after compaction does not retry again; the error surfaces.
    def test_second_consecutive_overflow_after_compaction_does_not_retry_again
      @server.script([
        {type: :error, status: 400, message: "This model's maximum context length is 8 tokens"},
        {type: :message, content: "a summary of the prior turns"},
        {type: :error, status: 400, message: "This model's maximum context length is 8 tokens"},
      ])
      agent, events = agent_on_kernel_with_seeds
      run_agent(agent, "new question")

      assert_equal 3, @server.captured_requests.size, "no third LLM call for the same turn"
      assert_kind_of RubyLLM::ContextLengthExceededError, agent.last_error
      error_end = events.find { |e| e[:type] == :agent_end }
      assert error_end[:error], "the second overflow must surface on agent_end"
    end

    # A clean assistant response after an overflow recovery resets the
    # latch (pi agent-session.ts:1168-1171): a later turn's overflow gets
    # its own compact-and-retry.
    def test_overflow_recovery_latch_resets_on_a_clean_response
      @server.script([
        {type: :error, status: 400, message: "This model's maximum context length is 8 tokens"},
        {type: :message, content: "a summary of the prior turns"},
        {type: :stream, content: "recovered"},
        {type: :error, status: 400, message: "This model's maximum context length is 8 tokens"},
        {type: :message, content: "another summary"},
        {type: :stream, content: "recovered again"},
      ])
      agent, _events = agent_on_kernel_with_seeds
      agent.push_message("second question") # drives the second overflow cycle
      run_agent(agent, "new question")

      requests = @server.captured_requests
      assert_equal 6, requests.size
      assert_equal "recovered again", agent.new_messages.last.content
    end

    # -- I45 step-boundary classification (additive): the Bridge terminal is
    # a Failure typed by the payload class; the three worker-error families
    # surface today's classes through the public readbacks (agent_end[:error]
    # + last_error) unchanged.

    def test_worker_http_error_classifies_as_bad_request
      @server.script([{type: :error, status: 400, message: "Extra inputs are not permitted"}])
      agent, events = agent_on_kernel
      run_agent(agent, "hi")

      assert_kind_of RubyLLM::BadRequestError, agent.last_error
      end_event = events.find { |e| e[:type] == :agent_end }
      assert_kind_of RubyLLM::BadRequestError, end_event[:error]
    end

    def test_context_length_error_classifies_with_compaction_disabled
      @server.script([{type: :error, status: 400,
                       message: "This model maximum context length is 8 tokens"}])
      agent, events = agent_on_kernel(compaction: {enabled: false})
      run_agent(agent, "hi")

      assert_kind_of RubyLLM::ContextLengthExceededError, agent.last_error
      end_event = events.find { |e| e[:type] == :agent_end }
      assert_kind_of RubyLLM::ContextLengthExceededError, end_event[:error]
    end

    def test_dead_endpoint_classifies_as_connection_failed
      chat = RubyLLM.context do |config|
        config.openai_api_key = "test"
        config.openai_api_base = "http://127.0.0.1:1/v1"
        config.request_timeout = 2
        config.max_retries = 0
      end.chat(model: "tart-test-model", provider: "openai",
              protocol: :chat_completions, assume_model_exists: true)
      agent, events = agent_on_kernel_with_chat(chat)
      run_agent(agent, "hi")

      assert_kind_of Faraday::ConnectionFailed, agent.last_error
      end_event = events.find { |e| e[:type] == :agent_end }
      assert_kind_of Faraday::ConnectionFailed, end_event[:error]
    end

    # --- I47 seam pins (the hooks-semantics gate drives the same surface) ---

    # The nextTurn drain: the pending queue injects AFTER the user message
    # — wire order [user, custom-as-user], the :message_start/:message_end
    # events carry the Hooks::CustomMessage, and the session records the
    # custom_message entry between them (pi _handleUserPrompt :2086-2095 +
    # messages.ts:161-170).
    def test_next_turn_drain_injects_after_the_user_message
      recorder_root = File.join(@dir, "agent")
      recorder = Agent::Session::Recorder.new(cwd: @dir, root: recorder_root)
      # The production shape: Hooks HOLDS the surface sink (the loop's emit
      # routes through the seam, which forwards to the base sink).
      events = []
      events_mutex = Mutex.new
      sink = ->(event) { events_mutex.synchronize { events << event } }
      hooks = Hooks.new(on_event: sink)
      hooks.send_next_turn(custom_type: "memory-recall", content: "RECALL-TEXT", display: true)
      @server.script([{type: :message, content: "ok"}])

      agent = Agent::Loop.new(chat: TestChat.build(@server, system_prompt: "test prompt"), tools: empty_tools,
        hooks:, recorder:)
      result = run_agent(agent, "hi")

      request = @server.captured_requests.last
      assert_equal %w[user user], request["messages"].map { |m| m["role"] }.last(2),
        "the recall rides the wire as a user-role message after the prompt"
      assert_includes request["messages"].last["content"], "RECALL-TEXT"
      assert_equal %i[user user assistant], result.map(&:role)

      custom_events = events.select { |event| event[:message].respond_to?(:role) && event[:message].role == :custom }
      assert_equal %i[message_start message_end], custom_events.map { |event| event[:type] }.uniq
      custom = custom_events.first[:message]
      assert_equal :custom, custom.role
      assert_equal "memory-recall", custom.custom_type
      assert_equal "RECALL-TEXT", custom.content
      assert_equal true, custom.display

      entries = File.readlines(recorder.path).map { |line| JSON.parse(line) }
      assert_equal ["session", "user", "custom_message", "assistant"],
        entries.map { |entry| entry["type"] == "message" ? entry.dig("message", "role") : entry["type"] }
      assert_equal({"type" => "custom_message", "customType" => "memory-recall", "content" => "RECALL-TEXT",
                    "display" => true}, entries[2].slice("type", "customType", "content", "display"))
    end

    # The terminate consult: a batch whose every tool call was a
    # terminate-marked block stops the INNER loop — one request total (pi
    # shouldTerminateToolBatch, agent-loop.ts:690-691).
    def test_all_terminate_batch_breaks_the_inner_loop
      File.write(File.join(@dir, "fixture.txt"), "x")
      hooks = Hooks.new
      hooks.on_tool_call { |_event, _ctx| {block: true, reason: "t", terminate: true} }
      @server.script([
        {type: :stream, content: "working", tool_calls: [
          {id: "call_1", name: "ls", arguments: {path: "."}},
          {id: "call_2", name: "read", arguments: {path: "fixture.txt"}}
        ]},
        {type: :message, content: "unreachable"},
      ])

      tools = Tools::Registry.build(selected: %w[ls read], cwd: @dir, hooks: hooks)
      agent, = agent_on_kernel(tools:, hooks:)
      result = run_agent(agent, "go")

      assert_equal 1, @server.captured_requests.size, "the terminated batch never reaches a second request"
      assert_equal %i[user assistant tool tool], result.map(&:role),
        "one blocked tool result per call, then the inner loop breaks"
      assert_equal "t", result.last.content, "the blocked result is the plain reason string"
    end

    # A partial terminate (some call unblocked) keeps the loop running —
    # the model answers on the next step.
    def test_partial_terminate_batch_continues_the_loop
      File.write(File.join(@dir, "fixture.txt"), "x")
      hooks = Hooks.new
      hooks.on_tool_call do |event, _ctx|
        {block: true, reason: "t", terminate: true} if event["tool_call_id"] == "call_1"
      end
      @server.script([
        {type: :stream, content: "working", tool_calls: [
          {id: "call_1", name: "ls", arguments: {path: "."}},
          {id: "call_2", name: "read", arguments: {path: "fixture.txt"}}
        ]},
        {type: :message, content: "the reply after the batch"},
      ])

      tools = Tools::Registry.build(selected: %w[ls read], cwd: @dir, hooks: hooks)
      agent, = agent_on_kernel(tools:, hooks:)
      result = run_agent(agent, "go")

      assert_equal 2, @server.captured_requests.size, "the loop continues after a non-all-terminate batch"
      assert_equal "the reply after the batch", result.last.content
    end

    # hooks: nil = today's path, byte-identical: events flow through
    # on_event and no pending queue drains.
    def test_hooks_nil_keeps_the_on_event_path
      @server.script([{type: :message, content: "ok"}])
      agent, events = agent_on_kernel
      result = run_agent(agent, "hi")

      assert_equal "ok", result.last.content
      assert events.any? { |event| event[:type] == :agent_start }, "the direct sink still receives events"
      assert_nil agent.instance_variable_get(:@hooks), "no hooks object is constructed"
    end

    # --- I48 steering-inbox pins (the async child's file inbox, §5.1) ---

    # A steer request file written mid-stream is consumed at the turn
    # boundary: the message joins the queue (the child's next request
    # carries it as a user message), the consumption log names the
    # requestId, and the file is unlinked (at-least-once).
    def test_steer_inbox_file_is_consumed_at_the_turn_boundary
      inbox = File.join(@dir, "control", "steer-requests")
      FileUtils.mkdir_p(inbox)
      @server.script([
        {type: :slow_stream, content: "x" * 80, chunk_every: 0.1},
        {type: :message, content: "steered reply"},
      ])
      agent, = agent_on_kernel(steer_inbox: inbox)
      thread = run_in_background(agent, "start the work")

      # Mid-stream: the request file lands while the turn runs.
      sleep 0.4
      request_id = "req-#{object_id}"
      File.write(File.join(inbox, "0001700000000000-#{request_id}.json"),
                 JSON.generate({"type" => "steer", "id" => request_id, "ts" => 1_700_000_000_000,
                                "message" => "STEER-INBOX-MARKER", "mode" => "steer", "source" => "tool"}))
      join_run(thread)
      request = @server.captured_requests.last
      users = request["messages"].select { |m| m["role"] == "user" }
      assert users.any? { |m| m["content"].to_s.include?("STEER-INBOX-MARKER") },
             "the steer rides the child's next request as a user message"
      log = File.join(File.dirname(inbox), "steer-log.jsonl")
      entries = File.readlines(log).map { |line| JSON.parse(line) }
      entry = entries.find { |e| e["requestId"] == request_id }
      refute_nil entry, "the consumption log correlates by requestId"
      assert entry["consumedAt"].is_a?(Integer)
      assert_empty Dir.glob(File.join(inbox, "*.json")), "the consumed file is unlinked"
    end

    # A stop request file interrupts the run exactly like a kernel
    # interrupt: Async::Cancel through run() → the interrupted agent_end,
    # the child exits non-zero with the abort message (print's error_exit).
    def test_stop_file_interrupts_the_run_at_the_boundary
      stop_dir = File.join(@dir, "control", "stop-requests")
      FileUtils.mkdir_p(stop_dir)
      @server.script([{type: :slow_stream, content: "x" * 80, chunk_every: 0.1}])
      agent, events = agent_on_kernel(steer_inbox: File.join(@dir, "control", "steer-requests"))
      thread = run_in_background(agent, "long stream")

      sleep 0.4
      File.write(File.join(stop_dir, "0001700000000000-stop.json"),
                 JSON.generate({"type" => "stop", "ts" => 1_700_000_000_000}))
      join_run(thread)
      assert agent.interrupted?, "the stop file interrupted the run"
      agent_end = events.find { |event| event[:type] == :agent_end }
      assert agent_end[:interrupted], "the interrupted flag rides agent_end"
      assert_empty Dir.glob(File.join(stop_dir, "*.json")), "the consumed stop file is unlinked"
    end

    # A file that fails JSON parse is unlinked and skipped (poison-pill
    # safety) — a valid steer beside it still delivers.
    def test_poison_inbox_file_is_skipped
      inbox = File.join(@dir, "control", "steer-requests")
      FileUtils.mkdir_p(inbox)
      @server.script([
        {type: :slow_stream, content: "x" * 80, chunk_every: 0.1},
        {type: :message, content: "steered reply"},
      ])
      agent, = agent_on_kernel(steer_inbox: inbox)
      thread = run_in_background(agent, "start the work")

      sleep 0.4
      File.write(File.join(inbox, "0001700000000001-garbage.json"), "{not json")
      File.write(File.join(inbox, "0001700000000002-ok.json"),
                 JSON.generate({"type" => "steer", "id" => "req-ok", "ts" => 1_700_000_000_002,
                                "message" => "POISON-NEIGHBOR-MARKER", "mode" => "steer"}))
      join_run(thread)
      request = @server.captured_requests.last
      assert request["messages"].any? { |m| m["role"] == "user" && m["content"].to_s.include?("POISON-NEIGHBOR-MARKER") }
      assert_empty Dir.glob(File.join(inbox, "*.json")), "the poison file is unlinked too"
    end

    # --- I48 wake pins (§5.3 — pi triggerTurn on the port's seams) ---

    # The wake drains the hooks' pending queue AS the run's opening
    # messages: wire [custom-as-user] first (the §I47 drain path), the
    # CustomMessage events, and the session custom_message entry.
    def test_wake_drains_the_pending_notification_as_the_opening_turn
      recorder_root = File.join(@dir, "agent")
      recorder = Agent::Session::Recorder.new(cwd: @dir, root: recorder_root)
      events = []
      events_mutex = Mutex.new
      sink = ->(event) { events_mutex.synchronize { events << event } }
      hooks = Hooks.new(on_event: sink)
      hooks.send_next_turn(custom_type: "subagent-notify", content: "Background task completed: **worker**", display: false)
      @server.script([{type: :message, content: "post-notify reply"}])

      agent = Agent::Loop.new(chat: TestChat.build(@server, system_prompt: "test prompt"), tools: {},
                              hooks:, recorder:)
      refute agent.running?
      assert run_wake(agent), "the wake ran a turn"

      request = @server.captured_requests.last
      non_system = request["messages"].reject { |m| %w[system developer].include?(m["role"]) }
      assert_equal %w[user], non_system.map { |m| m["role"] }
      assert_includes non_system.first["content"], "Background task completed: **worker**"

      custom_events = events.select { |event| event[:message].respond_to?(:role) && event[:message].role == :custom }
      assert_equal %i[message_start message_end], custom_events.map { |event| event[:type] }.uniq
      entries = File.readlines(recorder.path).map { |line| JSON.parse(line) }
      assert_equal ["session", "custom_message", "message"], entries.map { |entry| entry["type"] }
      assert_equal "subagent-notify", entries[1]["customType"]
      assert_equal "post-notify reply", agent.new_messages.last.content
    end

    # Empty queue + empty steering → NO model call, nothing recorded.
    def test_wake_with_nothing_pending_makes_no_request
      hooks = Hooks.new
      agent = Agent::Loop.new(chat: TestChat.build(@server), tools: {}, hooks:)
      assert_equal false, run_wake(agent), "the empty wake is a no-op"
      assert_empty @server.captured_requests, "no model call"
    end

    # A wake landing mid-run no-ops (race-safe: one Loop one fiber).
    def test_wake_noops_while_a_run_is_in_flight
      @server.script([{type: :slow_stream, content: "x" * 40, chunk_every: 0.1}])
      agent, = agent_on_kernel
      thread = run_in_background(agent, "long stream")
      sleep 0.3
      assert agent.running?, "the run is in flight"

      result = nil
      kernel = Core::Loop.new(session: ScriptedSession.new)
      kernel.run { result = agent.wake }
      assert_equal false, result, "the mid-run wake is a no-op"
      join_run(thread)
    end

    private

    # The two-interleaved-tools batch (the de-bridge pins drive it): one
    # streamed response carrying TWO tool calls, then the completion.
    BATCH_SCRIPT = [
      {type: :stream, tool_calls: [
        {id: "call_a", name: "sleep", arguments: {label: "a"}},
        {id: "call_b", name: "sleep", arguments: {label: "b"}}
      ]},
      {type: :message, content: "done"}
    ].freeze

    # agent_on_kernel with a monotonic stamp per event (the overlap/attribution
    # pins' clock — the event hashes themselves stay unmodified).
    def stamped_agent_on_kernel(tools:)
      stamped = []
      stamped_mutex = Mutex.new
      sink = lambda do |event|
        stamped_mutex.synchronize do
          stamped << event.merge(_at: Process.clock_gettime(Process::CLOCK_MONOTONIC))
        end
      end
      chat = TestChat.build(@server, tools: tools.values, system_prompt: "test prompt")
      agent = Agent::Loop.new(chat:, tools:, on_event: sink)
      [agent, stamped]
    end

    def stamped_events(stamped, type)
      stamped.select { |e| e[:type] == type }
    end

    # Overflow scripts need more than one summary-able message in the
    # history: the seed turns stand in for prior context (the overflowing
    # attempt itself is never appended by the gem).
    def agent_on_kernel_with_seeds(compaction: {keep_recent_tokens: 1})
      events = []
      events_mutex = Mutex.new
      sink = ->(event) { events_mutex.synchronize { events << event } }
      chat = TestChat.build(@server, system_prompt: "test prompt")
      agent = Agent::Loop.new(chat:, tools: {}, on_event: sink, compaction:,
                              seed_messages: [
                                RubyLLM::Message.new(role: :user, content: "old question"),
                                RubyLLM::Message.new(role: :assistant, content: "old answer"),
                              ])
      [agent, events]
    end

    # Runs the agent on the kernel in a side thread with the house 5 s
    # deadline: an unbounded run (the pre-fix error-path hang) fails the
    # test instead of wedging the suite.
    def run_agent_bounded(agent, prompt)
      thread = Thread.new do
        Thread.current.report_on_exception = false
        Core::Loop.new(session: ScriptedSession.new).run { agent.run(prompt) }
      end
      wait_until { !thread.alive? }
      thread.join
    end

    # I45: the same kernel harness over a caller-built chat (the
    # dead-endpoint classification pins a transport the mock server can't
    # serve).
    def agent_on_kernel_with_chat(chat)
      events = []
      events_mutex = Mutex.new
      sink = ->(event) { events_mutex.synchronize { events << event } }
      [Agent::Loop.new(chat:, tools: {}, on_event: sink), events]
    end
  end
end

# The de-bridge pins' load (top-level: the gem derives the wire tool name
# from the class name — a namespace-less name stays "sleep"; a nested class
# would carry a tart-- prefix the mock script would have to match).
class SleepTool < RubyLLM::Tool
  description "Sleeps half a second"
  parameter :label, type: "string", description: "the label"

  def execute(label:)
    sleep 0.5
    "slept #{label}"
  end
end
