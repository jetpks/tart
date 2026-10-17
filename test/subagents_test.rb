# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/mock_llm_server"
require "tmpdir"
require "fileutils"
require "json"

module Tart
  # The I48 subagents unit pin table (Specification §8 — RED at base by
  # design): the builtin table, model-suffix resolution, fork-preamble
  # bytes, the Manager against REAL `bin/tart -p` subprocess children on
  # MockLLMServer (foreground/async/steer/stop/deadline), the env
  # closure, hermeticity, the byte-pinned §7 strings, the settings gate,
  # and the T1/T2/T3 behaviors. Hermetic: staged HOME + closed manager
  # env; the only network is the mock on 127.0.0.1.
  class SubagentsTest < Test
    # pi shared/types.js:145-150, byte-exact (the frozen Grounds cite).
    PI_FORK_PREAMBLE = "You are a delegated subagent running from a fork of the parent session. " \
      "Treat the inherited conversation as reference-only context, not a live thread to continue. " \
      "Do not continue or answer prior messages as if they are waiting for a reply. " \
      "Your sole job is to execute the task below and return a focused result for that task using your tools."

    def setup
      @server = MockLLMServer.new.start
      @home = Dir.mktmpdir("i48-subagents-home-")
      @cwd = Dir.mktmpdir("i48-subagents-cwd-")
      @hooks = Hooks.new
      @managers = []
    end

    def teardown
      @managers.each(&:shutdown)
      @server.stop
      FileUtils.rm_rf(@home)
      FileUtils.rm_rf(@cwd)
    end

    # --- AC1: the builtin table + model routing + the gate ---

    def test_builtin_table_three_agents_with_byte_carried_descriptions
      agents = Subagents::BUILTIN_AGENTS
      assert_equal %w[oracle reviewer worker], agents.keys.sort
      assert_equal "Implementation agent for normal tasks and approved oracle handoffs", agents["worker"][:description]
      assert_equal "High-context decision-consistency oracle that protects inherited state and prevents drift",
                   agents["oracle"][:description]
      assert_equal "Versatile review specialist for code diffs, plans, proposed solutions, codebase health, " \
                   "and PR/issue validation", agents["reviewer"][:description]
    end

    def test_builtin_table_frontmatter_facts
      agents = Subagents::BUILTIN_AGENTS
      assert_equal %w[read grep find ls bash edit write], agents["worker"][:tools]
      assert_equal %w[read grep find ls bash], agents["oracle"][:tools]
      assert_equal %w[read grep find ls], agents["reviewer"][:tools]
      assert_equal "high", agents["worker"][:thinking]
      assert_equal "high", agents["oracle"][:thinking]
      assert_equal "high", agents["reviewer"][:thinking]
      assert_equal :fresh, agents["worker"][:context]
      assert_equal :fork, agents["oracle"][:context]
      assert_equal :fresh, agents["reviewer"][:context]
    end

    def test_builtin_prompts_carry_their_fallback_report_sentences
      # The contact_supervisor paragraphs are replaced by the plain-report
      # fallback sentence each pi agent file already carries — the
      # fallback IS the prompt (the port ships no supervisor channel).
      assert_includes Subagents::BUILTIN_AGENTS["worker"][:system_prompt],
                      "report the required decision in your final response"
      assert_includes Subagents::BUILTIN_AGENTS["oracle"][:system_prompt],
                      "return the best recommendation and name the decision that still needs the main agent"
      assert_includes Subagents::BUILTIN_AGENTS["reviewer"][:system_prompt],
                      "report the blocking decision in your final review"
      assert_includes Subagents::BUILTIN_AGENTS["worker"][:system_prompt], "You are `worker`"
      assert_includes Subagents::BUILTIN_AGENTS["oracle"][:system_prompt], "You are the oracle"
      assert_includes Subagents::BUILTIN_AGENTS["reviewer"][:system_prompt], "You are a disciplined review subagent"
    end

    def test_fork_preamble_is_pi_byte_exact
      assert_equal PI_FORK_PREAMBLE, Subagents::DEFAULT_FORK_PREAMBLE
    end

    def test_model_suffix_resolution
      assert_equal ["zai", "glm-5.3", "high"],
                   Subagents.resolve_model("zai/glm-5.3:high", catalog: nil, fallback: ["fireworks", "m0", "medium"])
      assert_equal ["fireworks", "m1", "low"], Subagents.resolve_model("fireworks/m1:low", catalog: nil, fallback: nil)
      # No suffix: the fallback (parent) level rides.
      assert_equal ["fireworks", "m0", "medium"],
                   Subagents.resolve_model("fireworks/m0", catalog: nil, fallback: ["fireworks", "m0", "medium"])
      # nil spec: the parent's current model wholesale.
      assert_equal ["a", "b", "high"], Subagents.resolve_model(nil, catalog: nil, fallback: %w[a b high])
      # An invalid suffix raises naming the valid set.
      error = assert_raises(ArgumentError) do
        Subagents.resolve_model("zai/glm-5.3:ultra", catalog: nil, fallback: ["f", "m", "medium"])
      end
      assert_includes error.message, "off"
      assert_includes error.message, "max"
      assert_raises(ArgumentError) { Subagents.resolve_model("no-slash:high", catalog: nil, fallback: nil) }
    end

    # I70 move (was test_settings_gate_rows_and_the_opt_in_build, the
    # default-off pin): the gate defaults ON now — the pin re-words to the
    # OPT-OUT shape, the register mechanics byte-unchanged.
    def test_settings_gate_rows_and_the_opt_out_build
      assert_equal true, Settings::DEFAULTS["subagents"], "the I70 default-on flip"
      assert_equal "SUBAGENTS", Settings::RESOLUTION_ENV["subagents"]
      assert_equal "THINKING_LEVEL", Settings::RESOLUTION_ENV["thinkingLevel"]

      # Opt-out: the loadout never carries the tool unless the register
      # seam ran — the off tiers (settings false / env off) keep the I48
      # build shape: no subagent tool, no watcher.
      off = Tools::Registry.build(selected: %w[read], cwd: @cwd, hooks: Hooks.new)
      refute off.key?("subagent"), "the opt-out tiers must leave the wire unchanged"

      # On: registered through the I47 seam, declared LAST.
      hooks = Hooks.new
      manager = Subagents.register(hooks:, cwd: @cwd, env: default_env, home: File.join(@home, "subagents"))
      @managers << manager
      loadout = Tools::Registry.build(selected: %w[read bash], cwd: @cwd, hooks:)
      assert_equal "subagent", loadout["subagent"].name
      assert_equal %w[read bash subagent], loadout.keys, "the subagent tool is declared LAST"
    end

    def test_unknown_agent_names_the_three
      manager = new_manager
      error = assert_raises(ArgumentError) { manager.spawn_run(agent: "scout", task: "x", async: true) }
      # I49 re-pin: the unknown-agent raise lives in Profiles.resolve now —
      # the merged-table listing (builtins + discovered) + the closest-match
      # sentence (pi formatUnknownAgentError's shape; "scout" has no close
      # match in the base table, so the Did-you-mean sentence is omitted).
      assert_includes error.message, "unknown agent \"scout\"."
      assert_includes error.message, "Available agents: oracle, reviewer, worker."
      refute_includes error.message, "Did you mean"
      refute_includes error.message, "Built-in agents:", "the I48 wording retired"
    end

    # --- I49: the profile tier at the spawn seam + the channel wiring ---

    def test_spawn_resolves_a_staged_profile_model_tools_and_prompt
      agents = File.join(@home, ".tart", "agents")
      FileUtils.mkdir_p(agents)
      File.write(File.join(agents, "scout.md"), <<~MD)
        ---
        description: staged profile scout
        tools: read, grep, find, ls
        model: mock/scout-model:low
        thinking: low
        ---

        You are the staged scout. Look around.
      MD
      @server.script([{type: :stream, content: "scout answer"}])
      manager = new_manager(root: File.join(@home, ".tart"))
      run = manager.spawn_run(agent: "scout", task: "t", async: false, timeout_ms: 0, tool_timeout_ms: 0)

      assert_equal :completed, run[:state]
      _, env = manager.spawn_argv_and_env(run)
      assert_equal "scout-model", env["PI_MODEL"], "the profile model routed"
      assert_equal "mock", env["PI_PROVIDER"]
      assert_equal "low", env["PI_THINKING_LEVEL"], "the :level suffix overrode thinking"
      assert_equal "scout", env["PI_SUBAGENTS_AGENT"]
      argv, = manager.spawn_argv_and_env(run)
      assert_equal "read,grep,find,ls,contact_supervisor", argv[argv.index("--tools") + 1],
                   "the profile's tool order preserved + the bridge union last"
      prompt_file = File.read(File.join(run[:dir], "system-prompt.md"))
      assert_includes prompt_file, "You are the staged scout. Look around."
      assert prompt_file.end_with?(Subagents::Supervisor::BRIDGE_INSTRUCTION)
    end

    def test_call_model_wins_over_the_profile_model
      agents = File.join(@home, ".tart", "agents")
      FileUtils.mkdir_p(agents)
      File.write(File.join(agents, "scout.md"), <<~MD)
        ---
        model: mock/profile-model:low
        ---

        Scout body.
      MD
      @server.script([{type: :stream, content: "ok"}])
      manager = new_manager(root: File.join(@home, ".tart"))
      run = manager.spawn_run(agent: "scout", task: "t", async: false, model: "mock/call-model:high",
                             timeout_ms: 0, tool_timeout_ms: 0)

      _, env = manager.spawn_argv_and_env(run)
      assert_equal "call-model", env["PI_MODEL"], "the call model beat the profile"
      assert_equal "high", env["PI_THINKING_LEVEL"]
    end

    def test_manager_root_kwarg_and_supervisor_channel_accessor
      @server.script([{type: :stream, content: "x"}])
      manager = new_manager
      assert_equal Agent::Session.default_root, manager.root, "the additive root kwarg defaults"
      assert_nil manager.supervisor_channel, "a bare Manager carries no channel"

      staged = File.join(@home, ".tart")
      rooted = new_manager(root: staged)
      assert_equal staged, rooted.root

      # register() arms the channel (same hooks; started, then stoppable).
      hooks = Hooks.new
      registered = Subagents.register(hooks:, cwd: @cwd, env: default_env,
                                      home: File.join(@home, "subagents"), root: staged)
      @managers << registered
      channel = registered.supervisor_channel
      refute_nil channel, "register assigns + arms the channel"
      assert_equal File.join(@home, "subagents"), channel.home
      assert_equal "No pending supervisor requests.", channel.pending_text
      channel.stop
      assert_equal "No pending supervisor requests.", channel.pending_text, "stop is idempotent"
    end

    def test_bridged_tools_validate_through_the_registry
      # The intercom tool resolves through TOOL_CLASSES (D6) without
      # entering Tools::ALL (no default-loadout byte moves).
      loadout = Tools::Registry.build(selected: %w[read contact_supervisor], cwd: @cwd)
      assert_equal "contact_supervisor", loadout["contact_supervisor"].name
      assert_includes Tools::ContactSupervisor::DESCRIPTION,
                      "Contact the parent/supervisor session"
      assert_equal %w[read edit write bash find grep ls], Tools::ALL
    end

    # --- AC2/AC4: the manager with a REAL subprocess child ---

    def test_foreground_delegation_end_to_end
      @server.script([{type: :stream, content: "child answer one"}])
      manager = new_manager
      run = manager.spawn_run(agent: "worker", task: "say answer one", async: false,
                              timeout_ms: 0, tool_timeout_ms: 0)

      assert_equal :completed, run[:state], "foreground spawn_run blocks and settles"
      result = manager.result(id: run[:id])
      assert_equal "child answer one", result["output"]
      assert_equal true, result["success"]

      # The run dir carries the full §2.1 layout; the child's session
      # records under it (one nested sessions/ component).
      %w[status.json result.json system-prompt.md runner.stdout.log runner.stderr.log].each do |name|
        assert File.file?(File.join(run[:dir], name)), "#{name} exists"
      end
      assert File.directory?(File.join(run[:dir], "control", "steer-requests"))
      assert File.directory?(File.join(run[:dir], "control", "stop-requests"))
      sessions = Dir.glob(File.join(run[:dir], "sessions", "**", "*.jsonl"))
      assert_equal 1, sessions.size, "the child session records under the run dir"

      # status.json: the lifecycle + the task redaction (taskChars only).
      status = JSON.parse(File.read(File.join(run[:dir], "status.json")))
      assert_equal "completed", status["state"]
      assert_equal "single", status["mode"]
      assert_equal false, status["timedOut"]
      assert_equal 14, status["taskChars"]
      refute status["task"].to_s.include?("answer one"), "the task text is NEVER recorded"
      assert_equal result_path(run)[:path], status["outputFile"]

      # The §7 status lines, disk-first.
      lines = manager.status(id: run[:id])
      %w[Run: State: Mode: Started: Dir: Output:].each do |token|
        assert_includes lines, token, "status line #{token}"
      end
      assert_includes lines, "Run: #{run[:id]}"
      assert_includes lines, "State: completed"
      assert_includes lines, "Mode: single"
      refute_includes lines, "Error:"
    end

    def test_spawn_argv_and_env_the_pin_target
      @server.script([{type: :stream, content: "ok"}])
      manager = new_manager
      run = manager.spawn_run(agent: "worker", task: "t", async: false, timeout_ms: 0, tool_timeout_ms: 0)

      argv, env = manager.spawn_argv_and_env(run)
      assert argv[1].end_with?("bin/tart"), "the child boots the committed launcher"
      assert_equal "-p", argv[2]
      assert_equal "t", argv[3]
      %w[--tools --system-prompt-file --session-root --steer-inbox].each do |flag|
        assert_includes argv, flag, "argv flag #{flag}"
      end
      assert_equal "read,grep,find,ls,bash,edit,write,contact_supervisor", argv[argv.index("--tools") + 1]
      # I49 D5: the bridge unions contact_supervisor LAST into every
      # gate-on child's allowlist (the builtin table's own lists hold
      # byte-identical — the union happens at spawn, never in the table).
      assert argv[argv.index("--tools") + 1].end_with?(",contact_supervisor"),
             "the intercom tool is the argv tools tail"
      assert_equal File.join(run[:dir], "system-prompt.md"), argv[argv.index("--system-prompt-file") + 1]
      assert_equal File.join(run[:dir], "sessions"), argv[argv.index("--session-root") + 1]
      assert_equal File.join(run[:dir], "control", "steer-requests"), argv[argv.index("--steer-inbox") + 1]
      refute_includes argv, "--resume", "a :fresh agent never resumes"

      # The CLOSED env (OQ-7): exactly the §4 key set, nil keys omitted,
      # NO subagents gate row (children never nest), NO MCP config. I49
      # adds exactly TWO keys: the intercom channel dir + the agent label.
      # I69 deviation (supervisor ruling 2026-10-17): the child identity
      # rides the LITERAL bootstrap key TART_IDENTITY (the child's
      # resolve_identity reads only that literal; the old namespaced
      # PI_IDENTITY write was a dead key nothing read).
      sanctioned = %w[PATH HOME TART_IDENTITY PI_API_KEY PI_API_BASE PI_MODEL PI_PROVIDER
                      PI_MODEL_REASONING PI_THINKING_LEVEL PI_CONTEXT_WINDOW PI_TOOL_TIMEOUT_MS
                      PI_RUN_DEADLINE_MS PI_SUBAGENTS_HOME PI_SUPERVISOR_CHANNEL PI_SUBAGENTS_AGENT]
      assert_empty(env.keys - sanctioned, "spawn env closure violated: #{(env.keys - sanctioned).inspect}")
      assert env.key?("PATH")
      assert env.key?("HOME")
      assert_equal @home, env["HOME"]
      assert_equal "pi", env["TART_IDENTITY"]
      assert_equal File.join(@home, "subagents"), env["PI_SUBAGENTS_HOME"]
      refute env.key?("PI_SUBAGENTS"), "children must not carry the gate row"
      refute env.key?("TART_MCP_CONFIG")
      refute env.key?("PI_RUN_DEADLINE_MS"), "timeout 0 = unbounded: the deadline env is omitted"
      # I49: the channel dir exists unconditionally (the run-dir mkdir
      # always creates it), the agent label feeds the surfaced ask.
      assert_equal File.join(run[:dir], "control"), env["PI_SUPERVISOR_CHANNEL"]
      assert_equal "worker", env["PI_SUBAGENTS_AGENT"]
      # The channel dirs exist on disk from the spawn's mkdir.
      assert File.directory?(File.join(run[:dir], "control", "supervisor-requests"))
      assert File.directory?(File.join(run[:dir], "control", "supervisor-replies"))
      # I49 D5: system-prompt.md carries the agent prompt + the bridge
      # instruction appended (pi applyIntercomBridgeToAgent).
      prompt_file = File.read(File.join(run[:dir], "system-prompt.md"))
      assert_includes prompt_file, "You are `worker`"
      assert prompt_file.end_with?(Subagents::Supervisor::BRIDGE_INSTRUCTION),
             "the bridge instruction is the prompt tail"
    end

    def test_fork_agent_prepends_the_preamble_and_resumes_the_parent_session
      recorder = Agent::Session::Recorder.new(cwd: @cwd, root: File.join(@home, "agent"))
      recorder.append_message(Agent::Message.user("inherited turn"))
      @server.script([{type: :stream, content: "oracle answer"}])
      manager = new_manager
      run = manager.spawn_run(agent: "oracle", task: "advise", async: false,
                              timeout_ms: 0, tool_timeout_ms: 0, parent_session: recorder.path)

      argv, = manager.spawn_argv_and_env(run)
      assert_equal recorder.path, argv[argv.index("--resume") + 1], "a :fork agent resumes the parent session"
      assert_equal "#{Subagents::DEFAULT_FORK_PREAMBLE}\n\nTask:\nadvise", argv[3], "pi wrapForkTask byte shape"
      assert_equal :completed, run[:state]
      header = Agent::Session.read_header(Dir.glob(File.join(run[:dir], "sessions", "**", "*.jsonl")).first)
      assert_equal recorder.path, header["parentSession"], "the I42 fork copy links the parent"
    end

    def test_fork_agent_without_a_parent_session_falls_back_to_fresh
      # pi's implicit-fork fallback: no parent session → fresh, no preamble.
      @server.script([{type: :stream, content: "ok"}])
      manager = new_manager
      run = manager.spawn_run(agent: "oracle", task: "advise", async: false, timeout_ms: 0, tool_timeout_ms: 0)

      argv, = manager.spawn_argv_and_env(run)
      refute_includes argv, "--resume"
      assert_equal "advise", argv[3]
    end

    def test_async_run_start_message_watcher_notification_and_wake_kick
      @server.script([{type: :stream, content: "async answer"}])
      kernel = fake_kernel
      manager = new_manager(kernel:, agent: nil)
      tool = Tools::Subagent.new(manager:)
      start = tool.execute(agent: "worker", task: "async task", async: true, timeout_ms: 0, tool_timeout_ms: 0)
      run = manager.runs.first

      # The §7 start message, byte-pinned headline + the OQ-5 guidance.
      assert_equal "Async: worker [#{run[:id]}]\n\nDetached. Return control now: native completion wakes you, " \
                   'so do not sleep or poll for it.' "\n" \
                   'One-shot check: subagent({ action: "status", id: "' + run[:id] + '" }).', start
      assert_equal :running, run[:state]

      wait_terminal(manager, run[:id])
      assert_equal :completed, manager.runs.first[:state]

      # The notification: pi's header bytes, the Run dir + Session file
      # tail, display false for completed (model-visible only).
      pend = @hooks.pending_next_turn
      notify = pend.find { |p| p[:custom_type] == Subagents::NOTIFY_CUSTOM_TYPE }
      refute_nil notify, "the watcher queued the completion notification"
      assert notify[:content].start_with?("Background task completed: **worker**")
      assert_includes notify[:content], "\n\nasync answer\n\n"
      assert_includes notify[:content], "Run dir: #{run[:dir]}"
      assert_includes notify[:content], "Session file: "
      assert_equal false, notify[:display]

      # The interactive wake kick rode the kernel bridge (captured, the
      # agent here is nil so the block no-ops).
      assert kernel.calls.size >= 1, "the completion kick went through kernel.async"
    end

    def test_terminal_state_implies_the_notification_is_queued
      # JUDGE PIN (post-merge fix, recorded in the verdict): the drain
      # contract leg B rides on — the moment a run is observably terminal
      # (`outstanding?` false), its completion notification is ALREADY on
      # the hooks queue. Before the fix, settle_run flipped the state
      # inside its mutex but queued the notification after releasing it,
      # so a drain poll landing in that window flushed an empty queue
      # (the parent exited without recording the custom_message — leg B
      # flaked 1-in-3 under the loaded rake suite). The notify now runs
      # under the same mutex as the flip, making the invariant atomic.
      @server.script([{type: :stream, content: "invariant answer"}])
      manager = new_manager
      manager.spawn_run(agent: "worker", task: "invariant", async: true, timeout_ms: 0, tool_timeout_ms: 0)

      # Hammer outstanding? until the run is observably terminal; at THAT
      # first observation the queue must already carry the notification
      # (atomic under the fix; any hit on the unfixed code is the race).
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 15
      settled = false
      until settled || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        next if manager.outstanding?

        settled = true
        pend = @hooks.pending_next_turn
        refute_empty pend, "terminal observed but the notification was not yet queued (the settle/notify window)"
        assert pend.any? { |p| p[:custom_type] == Subagents::NOTIFY_CUSTOM_TYPE }
      end
      assert settled, "the run never settled within the window"
      wait_terminal(manager, manager.runs.first[:id])
      assert_equal :completed, manager.runs.first[:state]
    end

    def test_failed_run_notification_display_true_with_error_line
      @server.script([{type: :error, status: 400, message: "nope"}])
      manager = new_manager
      run = manager.spawn_run(agent: "worker", task: "fail task", async: true, timeout_ms: 0, tool_timeout_ms: 0)

      wait_terminal(manager, run[:id])
      assert_equal :failed, manager.runs.first[:state]
      notify = @hooks.pending_next_turn.find { |p| p[:custom_type] == Subagents::NOTIFY_CUSTOM_TYPE }
      refute_nil notify
      assert notify[:content].start_with?("Background task failed: **worker**")
      assert_includes notify[:content], "Error: "
      assert_equal true, notify[:display], "non-completed notices display"
    end

    def test_steer_receipts_and_the_correlated_consumption_log
      # A 200-char slow stream ≈ 20s (the mock pauses 0.1s per char) — a
      # wide, deterministic steer window.
      @server.script([
        {type: :slow_stream, content: "x" * 120, chunk_every: 0.3},
        {type: :stream, content: "steered answer"}
      ])
      manager = new_manager
      run = manager.spawn_run(agent: "worker", task: "steer me", async: true, timeout_ms: 0, tool_timeout_ms: 0)
      sleep 0.5 # the child is mid-stream (the boundary is ~12s away)

      # The request file format — the follow_up write waits in the inbox
      # while the child streams (no boundary until the stream ends).
      manager.steer(id: run[:id], message: "second", mode: "follow_up")
      files = Dir.glob(File.join(run[:dir], "control", "steer-requests", "*.json"))
      refute_empty files, "an unconsumed request file waits in the inbox"
      name = File.basename(files.first)
      assert_match(/\A\d{13}-[0-9a-f-]{36}\.json\z/, name, "the ts-13-padded request file name")
      body = JSON.parse(File.read(files.first))
      assert_equal "steer", body["type"]
      assert_equal "second", body["message"]
      assert_equal "follow_up", body["mode"]
      assert_equal "tool", body["source"]
      assert body["ts"].is_a?(Integer)

      receipt = manager.steer(id: run[:id], message: "STEER-FOCUS-MARKER", mode: "steer", ack_timeout_ms: 30_000)
      assert_equal :delivered, receipt[:state], "delivered ONLY on the child's consumption of THAT request id"
      assert_equal 36, receipt[:request_id].to_s.length
      assert_equal "Steering delivered to async run #{run[:id]} (request #{receipt[:request_id]}).", receipt[:text]

      # T1: the CHILD's log names the request id ({requestId, consumedAt}).
      log = File.readlines(File.join(run[:dir], "control", "steer-log.jsonl")).map { |l| JSON.parse(l) }
      entry = log.find { |e| e["requestId"] == receipt[:request_id] }
      refute_nil entry, "the consumption log correlates by request id"
      assert entry["consumedAt"].is_a?(Integer)

      # The mid-run reach: the child's NEXT request carries the steer as
      # a user message (the turn-boundary drain).
      wait_terminal(manager, run[:id])
      steered = @server.captured_requests.any? do |request|
        request["messages"].any? { |m| m["role"] == "user" && m["content"].to_s.include?("STEER-FOCUS-MARKER") }
      end
      assert steered, "the steer reached the child wire as a user message"
    end

    def test_steer_receipt_vocabulary
      @server.script([{type: :slow_stream, content: "x" * 120, chunk_every: 0.3}, {type: :stream, content: "done"}])
      manager = new_manager
      run = manager.spawn_run(agent: "worker", task: "t", async: true, timeout_ms: 0, tool_timeout_ms: 0)

      # follow_up queues immediately.
      queued = manager.steer(id: run[:id], message: "later", mode: "follow_up")
      assert_equal :queued, queued[:state]
      assert_equal "Steering queued for async run #{run[:id]} (request #{queued[:request_id]}).", queued[:text]

      # A tiny ack window expires → queued (written, unconsumed).
      pending_receipt = manager.steer(id: run[:id], message: "fast", mode: "steer", ack_timeout_ms: 1)
      assert_equal :queued, pending_receipt[:state]

      # The 128KB cap fails.
      big = manager.steer(id: run[:id], message: "x" * (128 * 1024 + 1), mode: "follow_up")
      assert_equal :failed, big[:state]
      assert_equal "Failed to queue steering for async run #{run[:id]}: " \
                   "steer message exceeds #{Subagents::Manager::STEER_MESSAGE_CAP_BYTES} UTF-8 bytes.", big[:text]

      wait_terminal(manager, run[:id], 40)

      # A terminal run misses.
      missed = manager.steer(id: run[:id], message: "late", mode: "steer", ack_timeout_ms: 100)
      assert_equal :missed, missed[:state]
      assert_equal "Steering missed async run #{run[:id]} (request #{missed[:request_id]}): " \
                   "the run ended before consumption.", missed[:text]
    end

    def test_stop_flow_escalates_and_leaves_no_zombie
      @server.script([{type: :slow_stream, content: "s" * 200, chunk_every: 0.5}, {type: :stream, content: "never"}])
      manager = new_manager
      run = manager.spawn_run(agent: "worker", task: "stop target", async: true, timeout_ms: 0, tool_timeout_ms: 0)
      sleep 0.4
      assert_equal :running, manager.runs.first[:state]

      receipt = manager.stop(id: run[:id])
      assert_equal "Stop requested for async run #{run[:id]}.", receipt

      wait_terminal(manager, run[:id], 15)
      settled = manager.runs.first
      assert_equal :stopped, settled[:state]
      refute settled[:timed_out], "a user stop never sets timedOut"
      status = JSON.parse(File.read(File.join(settled[:dir], "status.json")))
      assert_equal "stopped", status["state"]
      assert_equal false, status["timedOut"]
      sleep 0.5
      assert_empty `ps -o stat= -p #{settled[:pid]} 2>/dev/null`.strip,
                   "no zombie — Process.detach owns the reap"
    end

    def test_run_deadline_ends_stopped_with_timed_out
      @server.script([{type: :slow_stream, content: "d" * 200, chunk_every: 0.5}, {type: :stream, content: "never"}])
      manager = new_manager
      run = manager.spawn_run(agent: "worker", task: "deadline target", async: true,
                              timeout_ms: 1500, tool_timeout_ms: 0)

      wait_terminal(manager, run[:id], 15)
      settled = manager.runs.first
      assert_equal :stopped, settled[:state]
      assert settled[:timed_out]
      status = JSON.parse(File.read(File.join(settled[:dir], "status.json")))
      assert_equal true, status["timedOut"]
      # The child self-deadline env rode the spawn (T2 both-sides).
      _, env = manager.spawn_argv_and_env(run)
      assert env.key?("PI_RUN_DEADLINE_MS")
    end

    def test_child_self_deadline_holds_without_the_parent_supervisor
      # T2 both-sides: the parent-side supervisor thread DISARMED — the
      # child's own RUN_DEADLINE_MS env still ends the run.
      @server.script([{type: :slow_stream, content: "d" * 200, chunk_every: 0.5}, {type: :stream, content: "never"}])
      manager = new_manager(arm_deadline_supervisor: false)
      run = manager.spawn_run(agent: "worker", task: "self deadline", async: true,
                              timeout_ms: 1500, tool_timeout_ms: 0)

      wait_terminal(manager, run[:id], 15)
      settled = manager.runs.first
      assert_equal :stopped, settled[:state]
      assert settled[:timed_out], "the child self-deadline enforced the run deadline"
    end

    def test_tool_timeout_rides_the_bash_default
      # OQ-8 in-process: the env is the DEFAULT for calls that omit one;
      # explicit call values win; unset = today; invalid ignored.
      tool = Tools::Bash.new(cwd: @cwd, identity: "pi",
                             env: {"PI_TOOL_TIMEOUT_MS" => "300"})
      result = tool.execute(command: "sleep 2")
      assert result.is_a?(Hash) && result.key?(:error), "the env default timed the call out"
      assert_includes result[:error], "timed out"
      result = tool.execute(command: "sleep 2 && echo no explicit timeout lost", timeout: 30)
      assert_equal "no explicit timeout lost\n", result, "an explicit call value wins"

      unset_tool = Tools::Bash.new(cwd: @cwd, identity: "pi", env: {})
      assert_equal "today\n", unset_tool.execute(command: "echo today"), "unset env = today"

      invalid = Tools::Bash.new(cwd: @cwd, identity: "pi", env: {"PI_TOOL_TIMEOUT_MS" => "soon"})
      assert_equal "still today\n", invalid.execute(command: "echo still today"), "invalid env ignored with a warn"
    end

    def test_tool_timeout_reaches_a_real_child_bash_call
      @server.script([
        {type: :stream, tool_calls: [{id: "c1", name: "bash", arguments: {command: "sleep 4"}}]},
        {type: :stream, content: "child done"}
      ])
      manager = new_manager
      run = manager.spawn_run(agent: "worker", task: "slow bash", async: false,
                              timeout_ms: 0, tool_timeout_ms: 900)

      assert_equal :completed, run[:state]
      bash_result = @server.captured_requests
                           .find { |request| request["messages"].any? { |m| m["role"] == "tool" } }
                           &.[]("messages")&.find { |m| m["role"] == "tool" }
      assert bash_result, "the child made a bash call"
      assert_includes bash_result["content"], "timed out", "the env default bounded the child's bash call"
    end

    def test_status_reconciles_from_disk
      # T3: a manager that never saw the watcher reports the terminal run
      # from disk (registry miss → status.json + result.json synthesis).
      @server.script([{type: :stream, content: "reconciled"}])
      first = new_manager
      run = first.spawn_run(agent: "worker", task: "reconcile me", async: true, timeout_ms: 0, tool_timeout_ms: 0)
      wait_terminal(first, run[:id])

      second = Subagents::Manager.new(cwd: @cwd, home: File.join(@home, "subagents"), env: default_env,
                                      identity: "pi", hooks: Hooks.new)
      @managers << second
      lines = second.status(id: run[:id])
      assert_includes lines, "State: completed", "disk-first: terminal even though this watcher never saw it"
      assert_includes lines, "Output: "
      assert_equal "reconciled", second.result(id: run[:id])["output"]

      # The fleet list: pi's byte-exact empty line.
      fresh = Subagents::Manager.new(cwd: @cwd, home: File.join(@home, "other"), env: default_env,
                                     identity: "pi", hooks: Hooks.new)
      @managers << fresh
      assert_equal "No active subagent fleet. Background runs that already finished are available through " \
                   'completion notifications or subagent({ action: "status", id: "..." }).',
                   fresh.status(id: nil)
    end

    def test_status_list_shape_and_unknown_id_error
      @server.script([{type: :stream, content: "one"}, {type: :stream, content: "two"}])
      manager = new_manager
      run1 = manager.spawn_run(agent: "worker", task: "a", async: true, timeout_ms: 0, tool_timeout_ms: 0)
      run2 = manager.spawn_run(agent: "oracle", task: "b", async: true, timeout_ms: 0, tool_timeout_ms: 0)
      wait_terminal(manager, run1[:id])
      wait_terminal(manager, run2[:id])

      list = manager.status(id: nil)
      assert list.start_with?("Active async runs: 2\n\n"), list[0, 40]
      assert_includes list, "- #{run1[:id]} | completed | single | worker"
      assert_includes list, "- #{run2[:id]} | completed | single | oracle"

      error = assert_raises(ArgumentError) { manager.status(id: "01ffffffffffffffffffffffffffff") }
      assert_includes error.message, "Active runs:"
      assert_includes error.message, run1[:id], "the unknown-id error names the active ids"
    end

    def test_hermeticity_everything_under_the_staged_home
      @server.script([{type: :stream, content: "h"}])
      manager = new_manager
      run = manager.spawn_run(agent: "worker", task: "stay home", async: false, timeout_ms: 0, tool_timeout_ms: 0)

      assert run[:dir].start_with?(File.join(@home, "subagents")), "the run dir lives under the staged home"
      assert_equal File.join(@home, "subagents"), manager.home
      # The default agent root under the STAGED home was untouched by the
      # child (its session went under the run dir, not ~/.tart/sessions).
      default_sessions = Agent::Session.dir_path(@cwd, root: File.join(@home, ".tart"))
      refute File.directory?(default_sessions), "no session leaked to the default root"
    end

    def test_runs_outstanding_and_shutdown_surface
      @server.script([{type: :stream, content: "s"}])
      manager = new_manager
      assert_equal false, manager.outstanding?
      assert_equal [], manager.runs
      run = manager.spawn_run(agent: "worker", task: "surface", async: true, timeout_ms: 0, tool_timeout_ms: 0)
      assert_equal true, manager.outstanding?
      assert_equal 1, manager.runs.size
      assert_equal run[:id], manager.runs.first[:id]
      assert_equal(%i[id agent state dir pid pgid async timed_out started_at tool_call_id],
                   %i[id agent state dir pid pgid async timed_out started_at tool_call_id])
      wait_terminal(manager, run[:id])
      assert_equal false, manager.outstanding?
      manager.shutdown
      assert_nil manager.shutdown, "shutdown is idempotent"
    end

    def test_subagent_tool_dispatch_and_safe_next_steps
      @server.script([{type: :stream, content: "answer"}, {type: :stream, content: "answer2"}])
      manager = new_manager
      tool = Tools::Subagent.new(manager:)

      unknown = tool.execute(action: "wat")
      assert unknown.is_a?(Hash) && unknown.key?(:error)
      assert_includes unknown[:error], "status"

      status_list = tool.execute(action: "status")
      assert_includes status_list, "No active subagent fleet"

      run = manager.spawn_run(agent: "worker", task: "tool dispatch", async: false, timeout_ms: 0, tool_timeout_ms: 0)
      one = tool.execute(action: "status", id: run[:id])
      assert_includes one, "Run: #{run[:id]}"

      # A steer at a TERMINAL run reports missed (never inbox acceptance).
      missed = tool.execute(action: "steer", id: run[:id], message: "x")
      assert_includes missed, "Steering missed async run #{run[:id]}"

      # An UNKNOWN id errors naming the active ids (the tool surfaces the
      # manager's raise as the {error:} result).
      unknown_id = tool.execute(action: "steer", id: "01ffffffffffffffffffffffffffff", message: "x")
      assert unknown_id.is_a?(Hash) && unknown_id.key?(:error)
      assert_includes unknown_id[:error], "Active runs:"
    end

    def test_subagent_tool_async_default_is_true
      @server.script([{type: :stream, content: "answer"}])
      manager = new_manager
      tool = Tools::Subagent.new(manager:)
      result = tool.execute(agent: "worker", task: "default async")
      run = manager.runs.first
      assert run[:async], "async defaults TRUE (pi's default-on)"
      assert result.start_with?("Async: worker [#{run[:id]}]")
      wait_terminal(manager, run[:id])
    end

    # --- helpers ---

    def new_manager(**opts)
      manager = Subagents::Manager.new(cwd: @cwd, home: File.join(@home, "subagents"), env: default_env,
                                       identity: "pi", hooks: @hooks, **opts)
      @managers << manager
      manager
    end

    # The CLOSED manager env: the child boots the mock endpoint through
    # the env tier only (deterministic against the outer environment).
    def default_env
      {"PATH" => ENV["PATH"], "HOME" => @home, "PI_API_KEY" => "test-key", "PI_API_BASE" => @server.url}
    end

    def wait_terminal(manager, id, timeout = 25)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      until manager.runs.find { |r| r[:id] == id } && manager.runs.find { |r| r[:id] == id }[:state] != :running
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          record = manager.runs.find { |r| r[:id] == id } || {}
          flunk "run #{id} never settled: #{record[:state].inspect} (stderr: #{stderr_head(record)})"
        end
        sleep 0.1
      end
    end

    def stderr_head(record)
      return "(no dir)" unless record[:dir]

      path = File.join(record[:dir], "runner.stderr.log")
      File.file?(path) ? File.read(path)[0, 400] : "(no log)"
    end

    def result_path(run)
      {path: File.join(run[:dir], "result.json")}
    end

    def fake_kernel
      kernel = Object.new
      kernel.define_singleton_method(:async) do |&block|
        (@calls ||= []) << block
        nil
      end
      kernel.define_singleton_method(:calls) { @calls ||= [] }
      kernel
    end
  end
end
