# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/mock_llm_server"
require "stringio"
require "tmpdir"
require "fileutils"

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

    private

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
  end
end
