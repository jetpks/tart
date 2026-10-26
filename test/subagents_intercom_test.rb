# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/mock_llm_server"
require "tmpdir"
require "fileutils"
require "json"
require "securerandom"

module Tart
  # The I49 intercom unit battery (Specification §8): the byte-pinned
  # constants, the bridge union, the child tool in-process (progress /
  # validation / 64KB / short ask timeout / inert / reply consumption),
  # the parent channel in-process (surface bytes + display + the wake
  # kick, surface-ONCE, progress-never-surfaces, the lifecycle sweep, T1
  # wrong-address routing, pending shapes), the ROUND TRIP in both forms —
  # a real print child unblocked by a channel reply, and a REAL in-process
  # Agent::Loop whose wake turn carries the ask on the wire — and the
  # workflow-template pins. Hermetic: staged HOME/cwd, MockLLMServer, real
  # bin/tart -p children.
  class SubagentsIntercomTest < Test
    # pi intercom-bridge.js:22-34 VERBATIM (transcribed from the installed
    # 0.77.0 source; the byte-pinned form of Supervisor::BRIDGE_INSTRUCTION
    # minus the marker line).
    PI_BRIDGE_TEMPLATE = <<~'TEMPLATE'.chomp
      The inherited thread is reference-only. Do not continue that conversation or send questions, status updates, or completion handoffs to the supervisor in normal assistant text.

      Use contact_supervisor first. It resolves the supervisor session and run metadata automatically.
      - Need a decision, blocked, approval, or product/API/scope ambiguity: contact_supervisor({ reason: "need_decision", message: "<question>" })
      - Need structured supervisor input rather than a freeform reply: contact_supervisor({ reason: "interview_request", message: "<what input is needed>", interview: { title: "...", questions: [] } })
      - After contact_supervisor with reason "need_decision" or "interview_request", stay alive and continue only after the reply arrives. Do not finish your final response with a choose-one question.
      - Do not ask for clarification when the only conflict is review-only/no-edit versus progress-writing or artifact-writing instructions. If an output path is configured but no write-capable tool is available, return the complete artifact in your final response; the runtime will persist it. Do not contact the supervisor merely because you cannot write that output path directly.
      - Meaningful progress or unexpected discoveries that change the plan: contact_supervisor({ reason: "progress_update", message: "UPDATE: <summary>" })

      Do not use contact_supervisor for routine completion handoffs. If no coordination is needed, return a focused task result.
    TEMPLATE

    def setup
      @server = MockLLMServer.new.start
      @home = Dir.mktmpdir("i49-intercom-home-")
      @cwd = Dir.mktmpdir("i49-intercom-cwd-")
      @hooks = Hooks.new
      @kernel = fake_kernel
      @managers = []
      @channels = []
    end

    def teardown
      @channels.each { |channel| channel.stop rescue nil }
      @managers.each(&:shutdown)
      @server.stop
      FileUtils.rm_rf(@home)
      FileUtils.rm_rf(@cwd)
    end

    # --- the byte-pinned constants (Spec §4.1) ---

    def test_bridge_instruction_is_pi_verbatim_under_the_marker
      assert_equal "Intercom orchestration channel:\n#{PI_BRIDGE_TEMPLATE}", Subagents::Supervisor::BRIDGE_INSTRUCTION
      assert_predicate Subagents::Supervisor::BRIDGE_INSTRUCTION, :frozen?
    end

    def test_protocol_constants_are_pi_byte_exact
      assert_equal "subagent_supervisor_request", Subagents::Supervisor::REQUEST_CUSTOM_TYPE
      assert_equal "subagent.supervisor.request", Subagents::Supervisor::REQUEST_TYPE
      assert_equal "subagent.supervisor.reply", Subagents::Supervisor::REPLY_TYPE
      assert_equal 65_536, Subagents::Supervisor::MAX_MESSAGE_BYTES
      assert_equal 600_000, Subagents::Supervisor::DEFAULT_ASK_TIMEOUT_MS
      assert_equal "Subagent needs a supervisor decision.",
                   Subagents::Supervisor.reason_heading("need_decision")
      assert_equal "Subagent requests a structured supervisor interview.",
                   Subagents::Supervisor.reason_heading("interview_request")
      assert_equal "Subagent progress update.",
                   Subagents::Supervisor.reason_heading("progress_update")
      assert_equal %w[need_decision interview_request progress_update], Subagents::Supervisor::REASONS
    end

    def test_ask_timeout_env_tiers
      assert_equal 600_000, Subagents::Supervisor.ask_timeout_ms(env: {})
      # I69 move: the PI_* tiers ride an EXPLICIT pi identity (the default
      # resolved tart — the tart tier leg below already passes it).
      assert_equal 250, Subagents::Supervisor.ask_timeout_ms(env: {Subagents::Supervisor::ASK_TIMEOUT_ENV_SUFFIX.gsub("INTERCOM", "PI_INTERCOM") => "250"}, identity: "pi")
      assert_equal 600_000, Subagents::Supervisor.ask_timeout_ms(env: {"PI_INTERCOM_ASK_TIMEOUT_MS" => "soon"}, identity: "pi")
      assert_equal 600_000, Subagents::Supervisor.ask_timeout_ms(env: {"PI_INTERCOM_ASK_TIMEOUT_MS" => "-5"}, identity: "pi")
      assert_equal 900, Subagents::Supervisor.ask_timeout_ms(
        env: {"TART_INTERCOM_ASK_TIMEOUT_MS" => "900"}, identity: "tart")
    end

    # --- the bridge (Spec §3c, D5) ---

    def test_apply_bridge_unions_the_tool_last_and_appends_the_instruction
      spec = {name: "scout", description: "d", tools: %w[read grep find ls bash], thinking: "high",
              context: :fresh, system_prompt: "Be the scout.", model: nil, source: :user}

      bridged = Subagents::Supervisor.apply_bridge(spec)

      assert_equal %w[read grep find ls bash contact_supervisor], bridged[:tools]
      assert_equal "Be the scout.\n\n#{Subagents::Supervisor::BRIDGE_INSTRUCTION}", bridged[:system_prompt]
      # Never mutates: the resolved spec (and the frozen builtin entries)
      # hold byte-identical.
      assert_equal %w[read grep find ls bash], spec[:tools]
      assert_equal "Be the scout.", spec[:system_prompt]
    end

    def test_apply_bridge_is_idempotent_on_the_marker_and_handles_empty_prompts
      once = Subagents::Supervisor.apply_bridge(name: "x", tools: %w[read], system_prompt: "P.")
      twice = Subagents::Supervisor.apply_bridge(once)
      assert_equal once, twice, "the marker short-circuits a second append"

      from_empty = Subagents::Supervisor.apply_bridge(name: "x", tools: [], system_prompt: "")
      assert_equal Subagents::Supervisor::BRIDGE_INSTRUCTION, from_empty[:system_prompt]
      assert_equal ["contact_supervisor"], from_empty[:tools]

      # A builtin-table entry survives application byte-identically below
      # the union (the I48 table pins hold).
      bridged_builtin = Subagents::Supervisor.apply_bridge(Subagents::BUILTIN_AGENTS["reviewer"].merge(source: :builtin, model: nil))
      assert_equal %w[read grep find ls contact_supervisor], bridged_builtin[:tools]
    end

    # --- the child tool in-process (Spec §5) ---

    def tool_for(ctrl, timeout_ms: nil, agent: "scout")
      env = {"PATH" => ENV["PATH"], "HOME" => @home,
             "PI_SUPERVISOR_CHANNEL" => ctrl, "PI_SUBAGENTS_AGENT" => agent}
      env["PI_INTERCOM_ASK_TIMEOUT_MS"] = timeout_ms if timeout_ms
      # I69 move: EXPLICIT pi identity — the tool's PI_* channel keys are
      # the pi-parity opt-in's namespace (the default resolved tart).
      Tools::ContactSupervisor.new(cwd: @cwd, env: env, identity: "pi")
    end

    def test_child_tool_progress_update_writes_and_returns_immediately
      ctrl = new_ctrl
      tool = tool_for(ctrl)

      result = tool.execute(reason: "progress_update", message: "half done")

      assert_equal "Supervisor progress update queued.", result
      request = read_single_request(ctrl)
      assert_equal Subagents::Supervisor::REQUEST_TYPE, request["type"]
      assert_equal "progress_update", request["reason"]
      assert_equal false, request["expectsReply"]
      assert_nil request["expiresAt"], "expiresAt is present IFF expectsReply"
      assert_equal "half done", request["message"]
      assert_equal File.basename(File.dirname(ctrl)), request["runId"], "runId = the channel path's run-dir component"
      assert_equal "scout", request["agent"]
      assert request["id"].is_a?(String) && request["id"].length == 36
      assert request["createdAt"].is_a?(Integer)
      assert_empty Dir.glob(File.join(ctrl, "supervisor-requests", "*.tmp")), "the write was atomic temp+rename"
    end

    def test_child_tool_validation_and_interview_free_object
      ctrl = new_ctrl
      blank = tool_for(ctrl).execute(reason: "need_decision", message: "  ")
      assert blank.is_a?(Hash) && blank[:error] == "message is required for supervisor decisions and progress updates."

      bad_reason = tool_for(ctrl).execute(reason: "gossip", message: "x")
      assert bad_reason.is_a?(Hash) && bad_reason[:error].include?("reason must be one of")

      # interview_request may carry a blank message (pi's rule); the
      # interview object passes through unrestricted. The ask blocks, so a
      # thread answers it once the file lands (and the round trip re-checks
      # the reply consumption).
      ctrl2 = new_ctrl
      seen = Queue.new
      answerer = Thread.new do
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
        while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
          files = Dir.glob(File.join(ctrl2, "supervisor-requests", "*.json"))
          if (file = files.first)
            begin
              payload = JSON.parse(File.read(file))
            rescue Errno::ENOENT
              next # the child unlinked its own request between the glob and the read — the poll loop's next tick retries
            end
            seen << payload
            Subagents::Supervisor.atomic_write_json(
              File.join(ctrl2, "supervisor-replies", "#{payload['id']}.json"),
              {type: Subagents::Supervisor::REPLY_TYPE, requestId: payload["id"],
               createdAt: Subagents::Supervisor.now_ms, message: "STRUCTURED ANSWER"})
            break
          end
          sleep 0.05
        end
      end
      result = tool_for(ctrl2, timeout_ms: "8000").execute(
        reason: "interview_request", interview: {title: "shape", questions: ["q1"]})

      assert_equal "**Reply from supervisor:**\nSTRUCTURED ANSWER", result
      assert_equal "Subagent requests a structured supervisor interview.",
                   Subagents::Supervisor.reason_heading("interview_request")
      request = seen.pop # the payload the answerer saw, before consumption unlinked it
      assert_equal "interview_request", request["reason"]
      assert_equal true, request["expectsReply"]
      assert_equal({title: "shape", questions: ["q1"]}.to_json, request["interview"].to_json)
      assert request["expiresAt"].is_a?(Integer)
    ensure
      answerer.kill if answerer
    end

    def test_child_tool_rejects_over_the_64kb_cap
      ctrl = new_ctrl
      result = tool_for(ctrl).execute(reason: "need_decision", message: "x" * 70_000)
      assert result.is_a?(Hash) && result[:error] == "Supervisor request is too large."
      assert_empty Dir.children(File.join(ctrl, "supervisor-requests"))
    end

    def test_child_tool_ask_timeout_honors_the_env_bound
      ctrl = new_ctrl
      tool = tool_for(ctrl, timeout_ms: "250")

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = tool.execute(reason: "need_decision", message: "anyone?")
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      assert result.is_a?(Hash) && result[:error] == "Timed out waiting for supervisor reply."
      assert elapsed < 10, "the env bound held (#{elapsed}s)"
      assert_empty Dir.children(File.join(ctrl, "supervisor-requests")), "the request unlinked on timeout"
    end

    def test_child_tool_consumes_the_reply_and_unlinks_the_request
      ctrl = new_ctrl
      tool = tool_for(ctrl)
      answerer = Thread.new do
        100.times do
          files = Dir.children(File.join(ctrl, "supervisor-requests")).reject { |f| f.start_with?(".") }
          if (file = files.first)
            begin
              id = JSON.parse(File.read(File.join(ctrl, "supervisor-requests", file)))["id"]
            rescue Errno::ENOENT
              next # the child unlinked its consumed request between the Dir.children snapshot and the read — the poll loop's next tick retries
            end
            sleep 0.1
            Subagents::Supervisor.atomic_write_json(
              File.join(ctrl, "supervisor-replies", "#{id}.json"),
              {type: Subagents::Supervisor::REPLY_TYPE, requestId: id,
               createdAt: Subagents::Supervisor.now_ms, message: "YES PROCEED"})
            next
          end
          sleep 0.05
        end
      end

      result = tool.execute(reason: "need_decision", message: "may I proceed?")

      assert_equal "**Reply from supervisor:**\nYES PROCEED", result
      assert_empty Dir.children(File.join(ctrl, "supervisor-requests")).reject { |f| f.start_with?(".") },
                   "the consumed request is unlinked"
    ensure
      answerer.kill if answerer
    end

    def test_child_tool_is_inert_without_a_channel
      result = Tools::ContactSupervisor.new(cwd: @cwd, env: {"PATH" => ENV["PATH"], "HOME" => @home})
                                       .execute(reason: "need_decision", message: "x")
      assert result.is_a?(Hash) && result[:error] == "No supervisor channel configured for this session."
    end

    # --- the channel in-process (Spec §4.3/§4.4) ---

    def test_channel_surfaces_the_ask_once_with_the_pinned_bytes_and_kicks
      run = fake_run("worker")
      channel = new_channel
      rid = stage_request(run, reason: "need_decision", message: "Should I proceed?")

      surfaced = wait_surfaced("Should I proceed?")
      refute_nil surfaced, "the synthetic ask surfaced"

      want = "Subagent needs a supervisor decision.\nRun: #{run[:id]}\nAgent: worker\n\n" \
             "Should I proceed?\n\n" \
             "Reply with: subagent({ action: \"reply\", reply_to: \"#{rid}\", message: \"...\" })\n\n" \
             "Live guidance: subagent({ action: \"steer\", id: \"#{run[:id]}\", message: \"...\" }) " \
             "(Reply to the pending request first.)"
      assert_equal want, surfaced[:content]
      assert_equal Subagents::Supervisor::REQUEST_CUSTOM_TYPE, surfaced[:custom_type]
      assert_equal true, surfaced[:display]
      refute_empty @kernel.calls, "the wake kick rode kernel.async"

      # pending_next_turn is a drain (the loop's source): after consuming
      # the first surface, three more ticks must NOT re-surface the ask
      # (pi's request notice is never re-sent — pending is the re-read).
      sleep Subagents::Supervisor::POLL_INTERVAL * 3
      assert_empty @hooks.pending_next_turn, "the ask surfaces ONCE"
      assert_equal 1, channel.pending.size, "pending survives for the re-read path"
      assert_equal "Should I proceed?", channel.pending.first[:message]
    end

    def test_channel_surfaces_interview_asks_with_the_structured_block
      run = fake_run("worker")
      channel = new_channel
      stage_request(run, reason: "interview_request", message: "Need structured input.",
                    interview: {title: "Decision", questions: ["Go?", "Scope?"]})

      surfaced = wait_surfaced("Need structured input.")
      refute_nil surfaced
      assert_includes surfaced[:content], "Subagent requests a structured supervisor interview."
      assert_includes surfaced[:content],
                      "Structured response requested. Reply with JSON, optionally fenced in ```json, " \
                      "matching the requested interview shape."
      assert_includes surfaced[:content], JSON.pretty_generate({title: "Decision", questions: ["Go?", "Scope?"]})
    end

    def test_progress_requests_never_surface_and_are_consumed
      run = fake_run("worker")
      channel = new_channel
      stage_request(run, reason: "progress_update", message: "PROGRESS-MARKER", expects_reply: false)

      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
      while File.exist?(request_path(run, "PROGRESS-MARKER")) && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        sleep 0.1
      end

      assert_empty channel.pending, "progress never registers pending"
      assert_empty @hooks.pending_next_turn.select { |p| p[:custom_type] == Subagents::Supervisor::REQUEST_CUSTOM_TYPE }
      assert_empty @kernel.calls, "progress never kicks the wake"
      refute File.exist?(request_path(run, "PROGRESS-MARKER")), "the progress request is consumed (unlinked)"
    end

    def test_lifecycle_sweep_reply_expiry_and_terminal_runs
      done = fake_run("worker", state: "completed")
      channel = new_channel

      # Terminal run (T3, pi's inactive): a stale ask for a settled run is
      # dropped + unlinked, never surfaced.
      stage_request(done, reason: "need_decision", message: "STALE-RUN-MARKER")
      # Expired: past expiresAt.
      rid_expired = stage_request(done, reason: "need_decision", message: "EXPIRED-MARKER",
                                  expires_in_ms: -1_000)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
      while (File.exist?(request_path(done, "STALE-RUN-MARKER")) ||
             File.exist?(request_path(done, "EXPIRED-MARKER"))) &&
            Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        sleep 0.1
      end

      refute File.exist?(request_path(done, "STALE-RUN-MARKER")), "the terminal-run ask is unlinked"
      refute File.exist?(File.join(done[:dir], "control", "supervisor-requests", "#{rid_expired}.json")),
             "the expired ask is unlinked"
      assert_empty channel.pending

      # Resolved: a reply file appearing under a pending ask resolves it.
      live = fake_run("worker")
      rid = stage_request(live, reason: "need_decision", message: "RESOLVE-MARKER")
      surfaced = wait_surfaced("RESOLVE-MARKER")
      refute_nil surfaced
      Subagents::Supervisor.atomic_write_json(
        File.join(live[:dir], "control", "supervisor-replies", "#{rid}.json"),
        {type: Subagents::Supervisor::REPLY_TYPE, requestId: rid,
         createdAt: Subagents::Supervisor.now_ms, message: "answered elsewhere"})
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
      while channel.pending.any? && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        sleep 0.1
      end
      assert_empty channel.pending, "the reply resolves the pending ask"
      refute File.exist?(request_path(live, "RESOLVE-MARKER")), "the resolved request is unlinked"
    end

    def test_t1_replies_address_request_ids_only
      run = fake_run("worker")
      channel = new_channel
      rid = stage_request(run, reason: "need_decision", message: "the leaf ask")
      wait_surfaced("the leaf ask")

      # NO fuzzy matching, NO run-id/agent-name addressing (T1/OQ-5) —
      # every wrong address fails with pi's byte-exact error and never
      # writes a reply file (the child stays blocked until its bound).
      [run[:id], "worker", "stale-id", rid[0, 8]].each do |bad|
        error = assert_raises(ArgumentError) { channel.reply(reply_to: bad, message: "x") }
        assert_equal "No pending supervisor request found for reply_to '#{bad}'.", error.message
      end
      blank = assert_raises(ArgumentError) { channel.reply(reply_to: rid, message: "   ") }
      assert_equal "message is required for supervisor replies.", blank.message

      replies = Dir.glob(File.join(run[:dir], "control", "supervisor-replies", "*"))
      assert_empty replies, "the wrong-address replies never wrote a file"
      assert File.exist?(request_path(run, "the leaf ask")), "the child's ask is untouched"

      # The correct address: receipt bytes, the reply file shape, the
      # request unlinked, the registry dropped.
      receipt = channel.reply(reply_to: rid, message: "GO AHEAD")
      assert_equal "Replied to supervisor request #{rid}.", receipt
      reply = JSON.parse(File.read(File.join(run[:dir], "control", "supervisor-replies", "#{rid}.json")))
      assert_equal Subagents::Supervisor::REPLY_TYPE, reply["type"]
      assert_equal rid, reply["requestId"]
      assert_equal "GO AHEAD", reply["message"]
      assert reply["createdAt"].is_a?(Integer)
      refute File.exist?(request_path(run, "the leaf ask"))
      assert_empty channel.pending
      assert_equal "No pending supervisor requests.", channel.pending_text
    end

    def test_pending_text_shapes
      run = fake_run("worker")
      channel = new_channel
      assert_equal "No pending supervisor requests.", channel.pending_text

      rid = stage_request(run, reason: "need_decision", message: "first line\nsecond line")
      wait_surfaced("first line")

      text = channel.pending_text
      assert_includes text, "- #{rid}: worker [#{run[:id]}] need_decision. " \
                            "Reply: subagent({ action: \"reply\", reply_to: \"#{rid}\", message: \"...\" })"
      assert_includes text, "\n  first line\n  second line", "the message indents two spaces, newlines folded"

      snapshot = channel.pending
      assert_equal rid, snapshot.first[:id]
      assert_equal run[:id], snapshot.first[:run_id]
      assert_equal "worker", snapshot.first[:agent]
      assert_equal true, snapshot.first[:expects_reply]
    end

    def test_channel_skips_poison_files_without_dying
      run = fake_run("worker")
      channel = new_channel
      File.write(File.join(run[:dir], "control", "supervisor-requests", "garbage.json"), "{not json")
      rid = stage_request(run, reason: "need_decision", message: "the healthy ask")

      refute_nil wait_surfaced("the healthy ask"), "the healthy ask still surfaces"
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
      while File.exist?(File.join(run[:dir], "control", "supervisor-requests", "garbage.json")) &&
            Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        sleep 0.1
      end
      refute File.exist?(File.join(run[:dir], "control", "supervisor-requests", "garbage.json")),
             "the poison file is unlinked"
      assert_equal rid, channel.pending.first[:id]
    end

    # --- THE ROUND TRIP, channel form: a real print child unblocks ---

    def test_round_trip_channel_form_real_child_asks_and_unblocks
      @server.script([
        {type: :stream, tool_calls: [{id: "ask1", name: "contact_supervisor",
                                      arguments: {reason: "need_decision", message: "ROUND-TRIP-QUESTION"}}]},
        {type: :stream, content: "CHILD DONE"}
      ])
      manager = new_manager
      run = manager.spawn_run(agent: "worker", task: "ask the supervisor", async: true, timeout_ms: 0, tool_timeout_ms: 0)
      channel = new_channel

      wait_for_request_file(run, "ROUND-TRIP-QUESTION")
      surfaced = wait_surfaced("ROUND-TRIP-QUESTION")
      refute_nil surfaced, "the child's own ask surfaces"
      child_rid = read_single_request(run)["id"]

      receipt = channel.reply(reply_to: child_rid, message: "THE ANSWER")
      assert_equal "Replied to supervisor request #{child_rid}.", receipt

      wait_terminal(manager, run[:id], 40)
      assert_equal :completed, manager.runs.first[:state]

      tool_results = @server.captured_requests.flat_map { |request| request["messages"] }
                            .select { |message| message["role"] == "tool" }
      assert tool_results.any? { |message| message["content"].to_s.include?("**Reply from supervisor:**\nTHE ANSWER") },
             "the child's NEXT request carries the supervisor answer as the tool result"
      refute File.exist?(File.join(run[:dir], "control", "supervisor-requests", "#{child_rid}.json"))
    ensure
      manager&.shutdown
    end

    # --- THE ROUND TRIP, parent-loop form: the ask reaches a MODEL turn ---

    def test_round_trip_parent_loop_form_the_wake_turn_carries_the_ask
      @server.script([
        # The parent's spawn call, then its (fast) final — the child boot
        # (~350ms) is the slow pole, so the parent's two requests consume
        # slots 0/1 first (the I48 order-bet discipline, ~100x margin).
        {type: :stream, tool_calls: [{id: "p1", name: "subagent",
                                      arguments: {agent: "worker", task: "ask and report", async: true}}]},
        {type: :stream, content: "SPAWN TURN DONE"},
        # The child asks, then finishes after the reply.
        {type: :stream, tool_calls: [{id: "c1", name: "contact_supervisor",
                                      arguments: {reason: "need_decision", message: "PARENT-LOOP-QUESTION"}}]},
        # The parent's WAKE turn (the ask drain).
        {type: :stream, content: "ASK RECEIVED"},
        {type: :stream, content: "CHILD DONE"}
      ])
      recorder = Agent::Session::Recorder.new(cwd: @cwd, root: File.join(@home, "agent"))
      # The Manager's wake target is the CALLABLE resolving the loop
      # (register's own shape — the /new-swap precedent): the tool needs
      # the manager, the loop needs the tool — the callable breaks the
      # construction cycle.
      loop = nil
      wake_target = -> { loop }
      manager = new_manager(agent: wake_target)
      manager.supervisor_channel = new_channel(agent: wake_target)
      tool = Tools::Subagent.new(manager:)
      loop = Agent::Loop.new(chat: Test::TestChat.build(@server, tools: [tool], system_prompt: "test prompt"),
                             tools: {"subagent" => tool}, hooks: @hooks, recorder:)

      run_in_background(loop, "kick off the asking child")
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 15
      until (parent_run = manager.runs.first)
        flunk "the parent never spawned the child" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep 0.05
      end
      wait_for_request_file(parent_run, "PARENT-LOOP-QUESTION")
      surfaced = wait_surfaced("PARENT-LOOP-QUESTION", requeue: true)
      refute_nil surfaced, "the channel surfaced the child's ask"
      refute_empty @kernel.calls, "the kick block was captured"
      child_run = parent_run

      # Run the kick on a reactor (the documented wake contract): the ask
      # must reach the parent's NEXT request as user-role wire text.
      @kernel.calls.dup.each do |block|
        Core::Loop.new(session: Test::ScriptedSession.new).run { block.call }
      end
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 15
      ask_request = nil
      while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline && ask_request.nil?
        ask_request = @server.captured_requests.find do |request|
          request["messages"].any? do |message|
            message["role"] == "user" && message["content"].to_s.include?("PARENT-LOOP-QUESTION")
          end
        end
        sleep 0.1
      end
      refute_nil ask_request, "the wake turn carried the ask to the model"
      # The wake request is the parent's NEXT turn (turn-1 history rides
      # it) and the ask rides as USER-role wire text — the reasonHeading +
      # the reply hint + the live-guidance tail.
      assert_includes JSON.generate(ask_request["messages"]), "SPAWN TURN DONE"
      ask_message = ask_request["messages"].find do |message|
        message["role"] == "user" && message["content"].to_s.include?("PARENT-LOOP-QUESTION")
      end
      refute_nil ask_message, "the ask rides as user-role text"
      assert_includes ask_message["content"], "Subagent needs a supervisor decision."
      assert_includes ask_message["content"], 'Reply with: subagent({ action: "reply", reply_to: "'
      assert_includes ask_message["content"], "(Reply to the pending request first.)"

      # Reply to the CHILD's request id (T1 leaf routing): the child
      # unblocks and completes.
      child_rid = read_single_request(child_run)["id"]
      assert_equal "Replied to supervisor request #{child_rid}.",
                   manager.supervisor_channel.reply(reply_to: child_rid, message: "GO")
      wait_terminal(manager, child_run[:id], 40)
      assert_equal :completed, manager.runs.find { |r| r[:id] == child_run[:id] }[:state]
      join_run
    ensure
      manager&.shutdown
    end

    # --- the parent tool's intercom actions (Spec §6) ---

    def test_parent_tool_reply_and_pending_actions
      manager = new_manager
      tool = Tools::Subagent.new(manager:)

      # A bare Manager carries no channel: the state texts name exactly
      # what is true — nothing is pending (the gate's driven shapes).
      assert_equal "No pending supervisor requests.", tool.execute(action: "pending")
      bad = tool.execute(action: "reply", reply_to: "nope", message: "x")
      assert bad.is_a?(Hash) && bad[:error] == "No pending supervisor request found for reply_to 'nope'."

      run = manager.spawn_run(agent: "worker", task: "action target", async: true, timeout_ms: 0, tool_timeout_ms: 0)
      channel = new_channel
      manager.supervisor_channel = channel
      rid = stage_request(run, reason: "need_decision", message: "THE ACTION ASK")
      wait_surfaced("THE ACTION ASK")

      text = tool.execute(action: "pending")
      assert_includes text, "- #{rid}: worker [#{run[:id]}] need_decision."

      receipt = tool.execute(action: "reply", reply_to: rid, message: "ANSWERED")
      assert_equal "Replied to supervisor request #{rid}.", receipt

      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
      while manager.supervisor_channel.pending.any? && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        sleep 0.1
      end
      assert_equal "No pending supervisor requests.", tool.execute(action: "pending")

      unknown = tool.execute(action: "wat")
      assert unknown.is_a?(Hash) && unknown[:error].include?("pending")
      assert unknown[:error].include?("reply")
    ensure
      manager&.shutdown
    end

    # --- the workflow templates (Spec §7) ---

    def test_workflow_template_frontmatter_bytes
      templates = Subagents::WORKFLOW_TEMPLATES
      assert_equal %w[council gather-context-and-clarify parallel-cleanup parallel-research parallel-review review-loop],
                   templates.map(&:name).sort
      descriptions = {
        "council" => "Run a bounded supervisor-mediated council of advisors and write a decision memo",
        "parallel-research" => "Parallel subagents research",
        "parallel-review" => "Parallel subagents review",
        "parallel-cleanup" => "Parallel cleanup review",
        "review-loop" => "Review/fix loop until clean",
        "gather-context-and-clarify" => "Use subagents to gather context, then ask clarifying questions"
      }
      templates.each do |template|
        assert_equal descriptions.fetch(template.name), template.description
        assert template.is_a?(Prompts::Template)
        assert template.file_path.nil?
        refute template.content.to_s.strip.empty?
      end
      council = templates.find { |t| t.name == "council" }
      assert_equal "<question> [--advisors name,name] [--max-passes 2|3] [--scope ...] [--non-goals ...]",
                   council.argument_hint
      templates.reject { |t| t.name == "council" }.each { |t| assert_nil t.argument_hint }
    end

    def test_workflow_template_contents_port_the_idioms
      forbidden = ["workflow:", "runs.all", "runs.run", "action:", '"guide"', "bg_wait"]
      Subagents::WORKFLOW_TEMPLATES.each do |template|
        forbidden.each do |token|
          refute template.content.include?(token),
                 "#{template.name} must not reference cut machinery (#{token.inspect})"
        end
      end

      council = Subagents::WORKFLOW_TEMPLATES.find { |t| t.name == "council" }
      assert_includes council.content, "council-"
      assert_includes council.content, "oracle"
      assert_includes council.content.downcase, "memo"
      assert_includes council.content, "never exceed 4 advisors"
      assert_includes council.content, 'subagent({ agent: "<advisor>", task: "<pass-1 report brief>", async: true })'
      assert_includes council.content.downcase, "never sleep and never poll"

      review = Subagents::WORKFLOW_TEMPLATES.find { |t| t.name == "parallel-review" }
      assert_includes review.content, "P0"
      assert_includes review.content, "P1"
      assert_includes review.content, "P2"
      assert_includes review.content, "Merge verdict: BLOCK"
      assert_includes review.content, "No issues found."
      assert_includes review.content, "`blockers only`"

      loop_template = Subagents::WORKFLOW_TEMPLATES.find { |t| t.name == "review-loop" }
      assert_includes loop_template.content, "maximum of 3 review rounds"
      assert_includes loop_template.content, "Merge verdict:"
      assert_includes loop_template.content, "async `worker`"

      gather = Subagents::WORKFLOW_TEMPLATES.find { |t| t.name == "gather-context-and-clarify" }
      assert gather.content.end_with?("$@\n"), "the $@ line ends the template like pi's"
      assert_includes gather.content, "~/.tart/agents"
      assert_includes gather.content, "native completion notifications wake you"

      research = Subagents::WORKFLOW_TEMPLATES.find { |t| t.name == "parallel-research" }
      assert_includes research.content, "fresh context, not forked context"
      assert research.content.end_with?("$@\n")
    end

    def test_merge_workflow_templates_builtin_lowest_user_wins
      user = Prompts::Template.new(name: "council", description: "user override", argument_hint: nil,
                                   content: "USER WINS", file_path: "/x/council.md")
      merged = Subagents.merge_workflow_templates([user])

      assert_equal 6, merged.size, "the same-name builtin is replaced, the other five kept"
      assert_equal "USER WINS", merged.find { |t| t.name == "council" }.content
      assert_equal %w[council gather-context-and-clarify parallel-cleanup parallel-research parallel-review review-loop],
                   merged.map(&:name), "the merged tier is name-sorted"

      # No user templates: the six builtins pass through unchanged.
      untouched = Subagents.merge_workflow_templates([])
      assert_equal Subagents::WORKFLOW_TEMPLATES.map(&:name), untouched.map(&:name)
    end

    # --- the TOCTOU pins (I88): the cured helpers tolerate a request file
    # vanishing between the glob and the read — deterministic staging (a
    # Dir.glob stub that unlinks the staged file before returning its
    # path), never a timing bet ---

    def test_toctou_request_path_tolerates_a_vanish_between_glob_and_read
      run = fake_run("worker")
      rid = stage_request(run, reason: "progress_update", message: "TOCTOU-VANISH", expects_reply: false)
      stub_glob_unlinking_first(File.join(requests_dir(run), "#{rid}.json"))

      assert_equal File.join(requests_dir(run), "missing.json"),
                   request_path(run, "TOCTOU-VANISH"),
                   "the vanished file is not the marker; the missing-marker fallback answers"
    ensure
      restore_glob
    end

    def test_toctou_read_single_request_flunks_honestly_on_a_vanish
      run = fake_run("worker")
      rid = stage_request(run, reason: "need_decision", message: "TOCTOU-GONE")
      stub_glob_unlinking_first(File.join(requests_dir(run), "#{rid}.json"))

      error = assert_raises(Minitest::Assertion) { read_single_request(run) }
      assert_includes error.message, "vanished between the glob and the read",
                      "the vanish fails as the honest named flunk, never a raw Errno::ENOENT escape"
    ensure
      restore_glob
    end

    def test_toctou_found_marker_is_still_found
      run = fake_run("worker")
      stage_request(run, reason: "need_decision", message: "TOCTOU-FIRST")
      rid = stage_request(run, reason: "need_decision", message: "TOCTOU-TARGET")
      stage_request(run, reason: "need_decision", message: "TOCTOU-LAST")

      want = File.join(requests_dir(run), "#{rid}.json")
      assert_equal want, request_path(run, "TOCTOU-TARGET")
      assert_equal want, request_file(run, "TOCTOU-TARGET")
    end

    def test_toctou_missing_marker_fallback_is_unchanged
      run = fake_run("worker")
      assert_equal File.join(requests_dir(run), "missing.json"), request_path(run, "TOCTOU-ABSENT")
      assert_nil request_file(run, "TOCTOU-ABSENT")

      stage_request(run, reason: "need_decision", message: "TOCTOU-OTHER")
      assert_equal File.join(requests_dir(run), "missing.json"), request_path(run, "TOCTOU-ABSENT")
      assert_nil request_file(run, "TOCTOU-ABSENT")
    end

    # Deterministic TOCTOU staging: the Dir.glob stub unlinks the staged
    # file BEFORE returning its path — the consumer's unlink lands exactly
    # inside the helper's glob->read window. Single-threaded in these pins
    # (no channel is started), so no other code globs under the stub; the
    # caller restores through +restore_glob+ in its ensure.
    def stub_glob_unlinking_first(path)
      Dir.singleton_class.send(:alias_method, :toctou_unstubbed_glob, :glob)
      Dir.singleton_class.send(:define_method, :glob) do |*_args|
        File.unlink(path) if File.exist?(path)
        [path]
      end
    end

    def restore_glob
      return unless Dir.singleton_class.method_defined?(:toctou_unstubbed_glob)

      Dir.singleton_class.send(:alias_method, :glob, :toctou_unstubbed_glob)
      Dir.singleton_class.send(:remove_method, :toctou_unstubbed_glob)
    end

    # --- helpers ---

    def new_manager(**opts)
      manager = Subagents::Manager.new(cwd: @cwd, home: File.join(@home, "subagents"), env: default_env,
                                       identity: "pi", hooks: @hooks, kernel: @kernel,
                                       root: File.join(@home, ".tart"), **opts)
      @managers << manager
      manager
    end

    def new_channel(agent: nil)
      channel = Subagents::SupervisorChannel.new(home: File.join(@home, "subagents"),
                                                 hooks: @hooks, kernel: @kernel, agent:)
      channel.start
      @channels << channel
      channel
    end

    # A synthetic disk-first run dir: the channel is home-scanned and reads
    # status.json for the terminal sweep — no child process needed for the
    # pure channel pins (the round-trip legs spawn real children).
    def fake_run(agent, state: "running")
      id = "01900000-0000-7000-8000-#{SecureRandom.hex(6)}"
      dir = File.join(@home, "subagents", id)
      FileUtils.mkdir_p([File.join(dir, "control", "supervisor-requests"),
                         File.join(dir, "control", "supervisor-replies")])
      Subagents::Supervisor.atomic_write_json(File.join(dir, "status.json"),
                                              {"id" => id, "agent" => agent, "state" => state})
      {id:, dir:, agent:, state: state.to_sym}
    end

    def new_ctrl
      run_dir = File.join(@home, "synthetic-#{SecureRandom.uuid}")
      ctrl = File.join(run_dir, "control")
      FileUtils.mkdir_p([File.join(ctrl, "supervisor-requests"), File.join(ctrl, "supervisor-replies")])
      ctrl
    end

    def stage_request(run, reason: "need_decision", message:, interview: nil, expects_reply: nil,
                      expires_in_ms: 60_000)
      ctrl = File.join(run[:dir], "control")
      id = SecureRandom.uuid
      payload = {
        type: Subagents::Supervisor::REQUEST_TYPE, id:, createdAt: Subagents::Supervisor.now_ms,
        reason:, message:, expectsReply: expects_reply.nil? ? reason != "progress_update" : expects_reply,
        runId: run[:id], agent: run[:agent]
      }
      payload[:expiresAt] = Subagents::Supervisor.now_ms + expires_in_ms if payload[:expectsReply]
      payload[:interview] = interview unless interview.nil?
      Subagents::Supervisor.atomic_write_json(File.join(ctrl, "supervisor-requests", "#{id}.json"), payload)
      id
    end

    def requests_dir(run)
      File.join(run[:dir], "control", "supervisor-requests")
    end

    def request_path(run, message)
      file = Dir.glob(File.join(requests_dir(run), "*.json")).find do |path|
        JSON.parse(File.read(path))["message"] == message
      rescue JSON::ParserError, Errno::ENOENT
        false # a vanished file is not the marker — gone IS the awaited consumed state
      end
      file || File.join(requests_dir(run), "missing.json")
    end

    def read_single_request(run_or_ctrl)
      dir = run_or_ctrl.is_a?(String) ? File.join(run_or_ctrl, "supervisor-requests") : requests_dir(run_or_ctrl)
      files = Dir.glob(File.join(dir, "*.json"))
      flunk "expected exactly one request file, got #{files.inspect}" if files.size != 1
      JSON.parse(File.read(files.first))
    rescue Errno::ENOENT
      flunk "the single request file vanished between the glob and the read (the channel consumed it mid-read): #{files.first.inspect}"
    end

    def wait_for_request_file(run, message)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 20
      until request_file(run, message)
        flunk "the child never wrote its ask (#{message})" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep 0.1
      end
    end

    def request_file(run, message)
      Dir.glob(File.join(requests_dir(run), "*.json")).find do |path|
        JSON.parse(File.read(path))["message"] == message
      rescue JSON::ParserError, Errno::ENOENT
        false # a vanished file is not the marker — the child may consume its own ask mid-poll
      end
    end

    # pending_next_turn is a DRAIN (the loop's source) — +requeue:+ puts
    # the drained entries back (FIFO) for tests where the wake must be the
    # consumer (the parent-loop round trip).
    def wait_surfaced(message, requeue: false)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
      drained = []
      hit = nil
      until hit || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        batch = @hooks.pending_next_turn
        hit = batch.find do |pending|
          pending[:custom_type] == Subagents::Supervisor::REQUEST_CUSTOM_TYPE &&
            pending[:content].to_s.include?(message)
        end
        drained.concat(batch)
        sleep 0.1 unless hit
      end
      drained.each { |entry| @hooks.send_next_turn(**entry) } if requeue
      hit
    end

    def wait_terminal(manager, id, timeout = 25)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      record = nil
      while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        record = manager.runs.find { |r| r[:id] == id }
        break if record && record[:state] != :running

        sleep 0.1
      end
      flunk "run #{id} never settled: #{record && record[:state]}" unless record && record[:state] != :running
      record[:state]
    end

    # The I48 agent-loop pattern: the run on a background-thread reactor
    # (the loop machinery needs a reactor fiber).
    def run_in_background(agent, prompt)
      @run_thread = Thread.new do
        Thread.current.report_on_exception = false
        begin
          Async do |root|
            root.async { agent.run(prompt) }.wait
          end
        rescue Async::Cancel
          nil
        end
      end
    end

    def join_run
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 15
      until !@run_thread.alive? || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep 0.02
      end
      flunk "the parent run never finished" if @run_thread.alive?
      @run_thread.join
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

    # The CLOSED manager env: the child boots the mock endpoint through
    # the env tier only.
    def default_env
      {"PATH" => ENV["PATH"], "HOME" => @home, "PI_API_KEY" => "test-key", "PI_API_BASE" => @server.url}
    end
  end
end
