# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/mock_llm_server"
require "tmpdir"
require "fileutils"
require "json"
require "securerandom"

module Tart
  # The I94 wake-wiring pins (W1–W6, issue #14): the interactive wake
  # FIRES. The seam over the TUI session (W1), the boot wiring swap away
  # from the never-existed TUI.push_event class method (W2), a completion
  # notify AND a supervisor ask each opening a parent agent turn with
  # ZERO keypress through the REAL objects — Subagents.wake_bridge, the
  # ScriptedSession synthetic channel, a real Core::Loop on the frozen
  # on_event rail contract, Agent::Loop#wake (W3/W4) — surface's warn
  # parity with the Manager's kick (W5), and the by-design print-mode
  # nil-kernel arms (W6). Hermetic: staged HOME/cwd, MockLLMServer, the
  # intercom real-child idiom for the notify legs, ZERO native events
  # pushed in the wiring pins.
  class SubagentsWakeWiringTest < Test
    def setup
      @server = MockLLMServer.new.start
      @home = Dir.mktmpdir("i94-wake-home-")
      @cwd = Dir.mktmpdir("i94-wake-cwd-")
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

    # --- W1: the seam (the REAL ferry, no injected push) ---

    def test_the_wake_ferry_lands_blocks_in_the_session_synthetic_queue
      session = Test::ScriptedSession.new
      bridge = Subagents.wake_bridge(session)

      assert_instance_of Subagents::KernelBridge, bridge, "the seam returns the real ferry"
      block = -> {}
      bridge.async(&block)

      assert session.synthetic_pending?, "the kicked block rides the session's synthetic queue"
      landed = []
      session.drain_synthetic { |event| landed << event }
      assert_equal 1, landed.size, "exactly one queue item"
      assert_same block, landed.first, "the queue item IS the kicked block (a Proc), carried verbatim"
    end

    # --- W2: the boot wiring swap (the box test's Thread.new-grep idiom) ---

    def test_bin_tart_wires_the_session_ferry_not_the_missing_class_method
      source = File.read(File.expand_path("../bin/tart", __dir__))
      assert_match(/Subagents\.wake_bridge\(session\)/, source,
                   "bin/tart wires the seam over the in-scope session block param")
      refute_includes "TUI.push_event", source,
                      "the never-existed TUI.push_event class-method call is gone from bin/tart"
      Dir.glob(File.expand_path("../lib/**/*.rb", __dir__)).each do |path|
        refute File.read(path).include?("TUI.push_event"),
               "#{path} still references the missing TUI.push_event class method"
      end
    end

    # --- W3: a completion notify opens a parent turn, ZERO keypress ---

    def test_a_completion_notify_opens_a_parent_turn_with_zero_keypress
      @server.script([
        # The child's single turn, then the parent's wake turn — arrival
        # order is causal (the notify derives from the child's settle),
        # so the blind script shift is deterministic here.
        {type: :stream, content: "CHILD DONE"},
        {type: :stream, content: "WAKE ACK"}
      ])
      hooks = Hooks.new
      session = Test::ScriptedSession.new
      kernel, kernel_thread, rail_else = wake_kernel(session)
      parent = Agent::Loop.new(chat: Test::TestChat.build(@server, system_prompt: "test prompt"),
                               tools: {}, hooks:)
      manager = new_manager(hooks:, kernel: Subagents.wake_bridge(session), agent: -> { parent })

      run = manager.spawn_run(agent: "worker", task: "one quick turn for the wake pin",
                             async: true, timeout_ms: 0, tool_timeout_ms: 0)
      assert_equal :running, run[:state], "the child started detached"

      wait_terminal(manager, run[:id])
      assert_equal :completed, run[:state], "the child completed cleanly"

      # The watcher's settle queued the notify + kicked the wake; the
      # ferry pushed the kick onto the session's synthetic channel; the
      # running kernel drained it through the frozen rail onto the
      # parent's wake — a NEW model request, zero keypress.
      seen = []
      wake_request = nil
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 15
      while wake_request.nil? && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        seen.concat(@server.captured_requests)
        wake_request = seen.find do |request|
          request["messages"].any? do |message|
            message["role"] == "user" && message["content"].to_s.include?("Background task completed: **worker**")
          end
        end
        sleep 0.05 unless wake_request
      end

      refute_nil wake_request, "the completion notify never opened a parent turn"
      preview_rode = wake_request["messages"].any? do |message|
        message["role"] == "user" && message["content"].to_s.include?("CHILD DONE")
      end
      assert preview_rode, "the notify body (the child's output preview) rides the same user-role message"
      assert_empty session.events, "ZERO native events pushed — the kick rode the synthetic channel"
      refute session.synthetic_pending?, "the ferry's block was drained by the running kernel"
      assert_empty rail_else, "the rail's non-wake arm never fired"
    ensure
      stop_kernel(kernel, kernel_thread)
      manager&.shutdown
    end

    # --- W4: a supervisor ask opens a parent turn, ZERO keypress ---

    def test_a_supervisor_ask_opens_a_parent_turn_with_zero_keypress
      hooks = Hooks.new
      session = Test::ScriptedSession.new
      kernel, kernel_thread, rail_else = wake_kernel(session)
      parent = Agent::Loop.new(chat: Test::TestChat.build(@server, system_prompt: "test prompt"),
                               tools: {}, hooks:)
      bridge = Subagents.wake_bridge(session)
      channel = new_channel(home: File.join(@home, "subagents"), hooks:, kernel: bridge,
                            agent: -> { parent })
      run = fake_run("worker")
      message = "WIRE-PIN-ASK: proceed with the wake wiring?"
      rid = stage_request(run, reason: "need_decision", message:)

      # The channel's scan surfaces the staged ask; the wake opens the
      # parent turn carrying it as user-role wire text (the intercom
      # round-trip assertions shape).
      seen = []
      ask_request = nil
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 15
      while ask_request.nil? && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        seen.concat(@server.captured_requests)
        ask_request = seen.find do |request|
          request["messages"].any? { |m| m["role"] == "user" && m["content"].to_s.include?(message) }
        end
        sleep 0.05 unless ask_request
      end

      refute_nil ask_request, "the supervisor ask never opened a parent turn"
      ask_message = ask_request["messages"].find do |m|
        m["role"] == "user" && m["content"].to_s.include?(message)
      end
      refute_nil ask_message, "the ask rides as user-role wire text"
      assert_includes ask_message["content"], "Subagent needs a supervisor decision."
      assert_includes ask_message["content"], "Reply with: subagent({ action: \"reply\", reply_to: \""
      assert_includes ask_message["content"], "(Reply to the pending request first.)"
      assert_equal rid, channel.pending.first[:id], "the ask stays registered for the reply path"
      assert_empty session.events, "ZERO native events pushed"
      refute session.synthetic_pending?, "the ferry's block was drained by the running kernel"
      assert_empty rail_else, "the rail's non-wake arm never fired"
    ensure
      stop_kernel(kernel, kernel_thread)
    end

    # --- W5: the wake failure is loud; the ask survives (the ONE
    # sanctioned double: the rescue IS the unit under test) ---

    def test_surface_warns_on_wake_failure_and_keeps_the_ask
      hooks = Hooks.new
      kernel = Object.new
      kernel.define_singleton_method(:async) { |&block| raise RuntimeError, "boom" }
      channel = Subagents::SupervisorChannel.new(home: File.join(@home, "subagents"), hooks:,
                                                 kernel:, agent: nil)
      run = fake_run("worker")
      request = {
        id: SecureRandom.uuid, run_id: run[:id], agent: "worker", reason: "need_decision",
        message: "the ask that must survive the failed wake", expects_reply: true,
        created_at: Subagents::Supervisor.now_ms, expires_at: nil, interview: nil,
        channel_dir: File.join(run[:dir], "control"),
        path: File.join(run[:dir], "control", "supervisor-requests", "w5.json")
      }

      # Synchronous surface call (the poll thread's scan→surface legs are
      # W4's): the warn parity is exact and the ask — queued BEFORE the
      # wake attempt — is not lost.
      assert_output(nil, /subagents: supervisor wake failed: boom/) do
        channel.send(:surface, request)
      end

      drained = hooks.pending_next_turn
      assert_equal 1, drained.size, "the ask queued exactly once"
      assert_equal Subagents::Supervisor::REQUEST_CUSTOM_TYPE, drained.first[:custom_type]
      assert_equal true, drained.first[:display]
      assert_includes drained.first[:content], "the ask that must survive the failed wake"
    end

    # --- W6: print mode (kernel nil) never wakes and never warns — by
    # design; the ask/notify rides pending_next_turn only ---

    def test_print_mode_nil_kernel_never_wakes_and_never_warns
      @server.script([{type: :stream, content: "PRINT MODE CHILD DONE"}])
      hooks = Hooks.new
      manager = new_manager(hooks:, kernel: nil, agent: nil)
      channel = Subagents::SupervisorChannel.new(home: manager.home, hooks:, kernel: nil, agent: nil)
      @channels << channel
      channel.start
      run = fake_run("worker")
      stage_request(run, reason: "need_decision", message: "PRINT-MODE ASK")

      drained = []
      out = err = nil
      out, err = capture_io do
        child = manager.spawn_run(agent: "worker", task: "print mode wake pin", async: true,
                                  timeout_ms: 0, tool_timeout_ms: 0)
        wait_terminal(manager, child[:id])
        assert_equal :completed, child[:state]
        # Terminal ⇒ queued (the settle atomicity pin); accumulate BOTH
        # queue riders across the poll — pending_next_turn is a drain.
        wait_until { drained.concat(hooks.pending_next_turn); drained.size >= 2 }
        manager.send(:kick_wake) # the nil arm: silent return, no raise
      end

      assert_equal "", out, "print mode prints nothing on stdout"
      assert_equal "", err, "print mode warns nothing on stderr"
      types = drained.map { |p| p[:custom_type] }
      assert_includes types, Subagents::Supervisor::REQUEST_CUSTOM_TYPE, "the ask rode the queue"
      assert_includes types, Subagents::NOTIFY_CUSTOM_TYPE, "the notify rode the queue"
      ask = drained.find { |p| p[:custom_type] == Subagents::Supervisor::REQUEST_CUSTOM_TYPE }
      assert_includes ask[:content], "PRINT-MODE ASK"
      notify = drained.find { |p| p[:custom_type] == Subagents::NOTIFY_CUSTOM_TYPE }
      assert notify[:content].start_with?("Background task completed: **worker**")
    end

    # --- harness (self-contained; the intercom/box idioms restated) ---

    def new_manager(hooks:, kernel: nil, agent: nil)
      manager = Subagents::Manager.new(cwd: @cwd, home: File.join(@home, "subagents"),
                                       env: default_env, identity: "pi", hooks:, kernel:, agent:,
                                       root: File.join(@home, ".tart"))
      @managers << manager
      manager
    end

    def new_channel(home:, hooks:, kernel:, agent:)
      channel = Subagents::SupervisorChannel.new(home:, hooks:, kernel:, agent:)
      channel.start
      @channels << channel
      channel
    end

    # The CLOSED manager env: the child boots the mock endpoint through
    # the env tier only (the intercom idiom).
    def default_env
      {"PATH" => ENV["PATH"], "HOME" => @home, "PI_API_KEY" => "test-key", "PI_API_BASE" => @server.url}
    end

    # A synthetic disk-first run dir (the intercom idiom): the channel is
    # home-scanned and reads status.json for the terminal sweep — no
    # child process needed for the staging legs.
    def fake_run(agent, state: "running")
      id = "01900000-0000-7000-8000-#{SecureRandom.hex(6)}"
      dir = File.join(@home, "subagents", id)
      FileUtils.mkdir_p([File.join(dir, "control", "supervisor-requests"),
                         File.join(dir, "control", "supervisor-replies")])
      Subagents::Supervisor.atomic_write_json(File.join(dir, "status.json"),
                                              {"id" => id, "agent" => agent, "state" => state})
      {id:, dir:, agent:, state: state.to_sym}
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

    def wait_terminal(manager, id, timeout = 40)
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

    # The wiring harness (W3/W4): the REAL core loop in event-only mode
    # on a background thread, draining the session's synthetic channel
    # every frame. The rail transcribes bin/tart's frozen on_event
    # contract — the Proc + :synthetic arm asyncs onto the reactor (the
    # wake arm, byte-shape); the else arm RECORDS instead of calling a
    # surface (none exists headless) — the pins assert it stayed empty,
    # which is the zero-native-events proof at the rail itself.
    def wake_kernel(session)
      kernel = Core::Loop.new(session:)
      rail_else = []
      kernel.on_event = lambda do |event, source|
        if event.is_a?(Proc) && source == :synthetic
          kernel.async(&event)
        else
          rail_else << [event, source]
        end
      end
      thread = Thread.new do
        Thread.current.report_on_exception = false
        kernel.run
      end
      [kernel, thread, rail_else]
    end

    # The bounded teardown: a wedged kernel fails the pin instead of
    # hanging the suite.
    def stop_kernel(kernel, thread)
      return unless thread

      kernel&.stop!
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
      until !thread.alive? || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep 0.02
      end
      flunk "the wake kernel never stopped" if thread.alive?
      thread.join
    end
  end
end
