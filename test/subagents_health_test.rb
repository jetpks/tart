# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/mock_llm_server"
require "tmpdir"
require "fileutils"
require "json"

module Tart
  # The I78 subagent-runner-health pin battery (AC1/AC2/AC3/AC4): the
  # dead-run specimen convergence through the fleet read (the reaper —
  # pi stale-run-reconciler.js ported), the result-derive leg, the
  # live-pid honesty leg, the ownership flags, the kill -9 crash leg,
  # and the loud dispatch validation law. Hermetic: staged homes,
  # staged catalogs, reaped-real-pids for ESRCH — ZERO live API calls.
  class SubagentsHealthTest < Test
    # The byte-pinned pi repair base (stale-run-reconciler.js
    # buildFailedRepair — via reason-less writeFailedRepair).
    REPAIR_BASE = "exited or disappeared before writing a result. Marked run failed by stale-run reconciliation."

    # The raw-hash specimen status.json shape (the 01a14e3c proof class:
    # legacy nil fields ride along; the pid is the only liveness handle).
    def setup
      @server = MockLLMServer.new.start
      @home = Dir.mktmpdir("i78-health-home-")
      @cwd = Dir.mktmpdir("i78-health-cwd-")
      @hooks = Hooks.new
      @managers = []
      @spawns = []
    end

    def teardown
      @managers.each(&:shutdown)
      @server.stop
      @spawns.each do |pid|
        Process.kill("KILL", -pid)
      rescue StandardError
        nil
      end
      FileUtils.rm_rf(@home)
      FileUtils.rm_rf(@cwd)
    end

    # --- helpers (the subagents_test.rb discipline: new_manager + staged homes) ---

    def new_manager(**opts)
      manager = Subagents::Manager.new(cwd: @cwd, home: File.join(@home, "subagents"), env: default_env,
                                       identity: "pi", hooks: @hooks, **opts)
      @managers << manager
      manager
    end

    def default_env
      {"PATH" => ENV["PATH"], "HOME" => @home, "PI_API_KEY" => "test-key", "PI_API_BASE" => @server.url}
    end

    # A REAL reaped pid: spawn a short sleep, detach (the port's own reap
    # discipline — no waitpid), and wait until kill(0) raises ESRCH on
    # both the pid and its group — the exited? law's dead probe.
    def dead_pid
      pid = Process.spawn("sleep", "0.05")
      Process.detach(pid)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
      begin
        loop do
          Process.kill(0, pid)
          raise "reaped pid never died" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

          sleep 0.05
        end
      rescue Errno::ESRCH
        nil
      end
      pid
    end

    # A LIVE pid the test owns (killed in teardown): a pgroup leader like
    # the real runner (pgroup: true), long outliving every probe.
    def live_pid
      pid = Process.spawn("sleep", "60", pgroup: true)
      Process.detach(pid) # the port's own reap discipline — ESRCH must arrive on death
      @spawns << pid
      sleep 0.05 # let it exec
      pid
    end

    # Fabricates the dead-run specimen dir (the 01a14e3c shape): a stale
    # running status.json, legacy nil fields, no result.json.
    def fabricate_run(id:, state: "running", pid:, agent: "worker", stderr: nil, result: nil, status: {})
      dir = File.join(@home, "subagents", id)
      FileUtils.mkdir_p([dir, File.join(dir, "control", "steer-requests"),
                         File.join(dir, "control", "stop-requests"), File.join(dir, "sessions")])
      payload = {"id" => id, "agent" => agent, "task" => nil, "taskChars" => nil, "mode" => "single",
                 "state" => state, "pid" => pid, "cwd" => @home, "asyncDir" => dir,
                 "sessionRoot" => File.join(dir, "sessions"), "startedAt" => nil,
                 "lastUpdate" => nil, "toolCallId" => nil}.merge(status)
      File.write(File.join(dir, "status.json"), JSON.generate(payload))
      File.write(File.join(dir, "runner.stderr.log"), stderr) if stderr
      File.write(File.join(dir, "result.json"), JSON.generate(result)) if result
      dir
    end

    def run_dir(id)
      File.join(@home, "subagents", id)
    end

    # --- AC1: the dead run converges (the reaper, fleet-read path) ---

    def test_dead_run_specimen_converges_through_the_fleet_read
      id = "01deadbee-0000-7000-8000-000000000001"
      pid = dead_pid
      dir = fabricate_run(id:, pid:, stderr: "a ruby warning line\nsecond diagnostic line\n")

      list = new_manager.status(id: nil)

      # The fleet lists the converged run (fleet-line format byte-kept).
      assert_includes list, "- #{id} | failed | single | worker"
      # The atomic status flip: running → failed, pid kept verbatim,
      # legacy nil fields pass through untouched.
      status = JSON.parse(File.read(File.join(dir, "status.json")))
      assert_equal "failed", status["state"]
      assert_equal pid, status["pid"]
      assert_nil status["startedAt"]
      assert_nil status["taskChars"]
      # The fabricated result (the port's schema): failed, not timed out,
      # empty stdout, the BYTE-PINNED pi message + the stderr-tail
      # diagnostics.
      result = JSON.parse(File.read(File.join(dir, "result.json")))
      assert_equal false, result["success"]
      assert_equal false, result["timedOut"]
      assert_equal "", result["output"]
      want = "Async runner process #{pid} #{REPAIR_BASE}"
      assert_equal true, result["error"].start_with?(want), result["error"].inspect
      assert_includes result["error"], "\n\nRunner stderr tail:\n"
      assert_includes result["error"], "second diagnostic line"
      assert_equal true, status["error"].start_with?(want), status["error"].inspect
      # NO notification into the adopter's session; the drain is not gated.
      assert_empty @hooks.pending_next_turn
      assert_equal false, @managers.last.outstanding?
    end

    # --- AC1: the result-derive leg (the result file is authoritative) ---

    def test_result_derive_leg_writes_only_the_status_flip_and_never_rewrites_the_result
      legs = [[{"success" => true, "output" => "done"}, "completed", false, nil],
              [{"success" => false, "timedOut" => true, "output" => "", "error" => "deadline hit"}, "stopped", true, "deadline hit"],
              [{"success" => false, "output" => "partial text", "error" => "child boom"}, "failed", false, "child boom"]]
      manager = new_manager
      legs.each_with_index do |(result, want_state, want_timed_out, want_error), index|
        id = "01deadbee-0000-7000-8000-0000000001%02d" % index
        pid = dead_pid
        dir = fabricate_run(id:, pid:, result: result)
        result_before = File.read(File.join(dir, "result.json"))

        manager.status(id: nil)

        status = JSON.parse(File.read(File.join(dir, "status.json")))
        assert_equal want_state, status["state"], "derive from #{result.inspect}"
        assert_equal want_timed_out, status["timedOut"]
        assert_equal want_error, status["error"] if want_error
        assert status["lastUpdate"].is_a?(Integer), "the flip stamped lastUpdate"
        assert status["endedAt"], "the flip stamped endedAt"
        # The result file is AUTHORITATIVE — never rewritten on this leg.
        assert_equal result_before, File.read(File.join(dir, "result.json"))
      end
      assert_empty @hooks.pending_next_turn, "the derive leg never notifies"
    end

    # --- AC2: live-pid honesty (the reaper never lies about a live run) ---

    def test_live_pid_is_left_byte_identical_listed_running_and_never_wedges_drain
      id = "01deadbee-0000-7000-8000-000000000003"
      pid = live_pid
      dir = fabricate_run(id:, pid:)
      status_before = File.read(File.join(dir, "status.json"))

      manager = new_manager
      list = manager.status(id: nil)

      assert_includes list, "- #{id} | running | single | worker"
      assert_equal status_before, File.read(File.join(dir, "status.json")), "no file written for a live pid"
      refute File.file?(File.join(dir, "result.json"))
      # The adopted foreign run never gates the adopter's drain (Law 3).
      manager.drain
      assert_includes manager.status(id: nil), "- #{id} | running | single | worker"
    end

    # --- AC2: ownership flags across outstanding?/notify/shutdown ---

    def test_ownership_owned_runs_gate_drain_and_notify_adopted_runs_never_do
      @server.script([{type: :stream, content: "owned answer"}])
      manager = new_manager
      owned = manager.spawn_run(agent: "worker", task: "owned", async: true, timeout_ms: 0, tool_timeout_ms: 0)
      assert_equal true, manager.outstanding?, "the owned in-flight run gates outstanding?"

      # Adopt a foreign LIVE run through the fleet read.
      foreign_id = "01deadbee-0000-7000-8000-000000000004"
      foreign_pid = live_pid
      fabricate_run(id: foreign_id, pid: foreign_pid, agent: "oracle")
      manager.status(id: nil)

      # The foreign run settles terminal only through its own death; while
      # it lives, the drain returns once the OWNED run settles (no wedge).
      wait_owned_terminal(manager, owned[:id])
      assert_equal false, manager.outstanding?, "the live foreign run must not gate the drain"
      manager.drain

      # The foreign run's convergence queues NO notification: the adopter's
      # chat carries exactly the owned run's completion (the queue DRAINS
      # on read — capture once).
      pending = @hooks.pending_next_turn
      assert_equal 1, pending.size
      assert_includes pending.first[:content], "worker"

      # Killing the foreign pid and re-reading converges it disk-only.
      Process.kill("KILL", -foreign_pid)
      wait_pid_gone(foreign_pid)
      list = manager.status(id: nil)
      assert_includes list, "- #{foreign_id} | failed | single | oracle"
      assert_empty @hooks.pending_next_turn, "a foreign convergence never notifies"

      # shutdown's stop ladder spares the (now terminal) foreign record;
      # the LIVE-foreign-child case is the next pin.
      manager.shutdown
    end

    def test_shutdown_spares_a_live_foreign_child
      manager = new_manager
      foreign_id = "01deadbee-0000-7000-8000-000000000005"
      foreign_pid = live_pid
      fabricate_run(id: foreign_id, pid: foreign_pid, agent: "oracle")
      manager.status(id: nil) # adopt the live foreign run

      manager.shutdown

      # The foreign child was NOT signaled by the adopter's teardown.
      Process.kill(0, foreign_pid)
    ensure
      begin
        Process.kill("KILL", -foreign_pid)
      rescue StandardError
        nil
      end
    end

    # --- AC3: a hard-killed OWNED runner settles through the watcher sweep ---

    def test_kill_9_owned_child_settles_terminal_through_the_watcher_sweep
      @server.script([{type: :stream, content: "never read"}])
      manager = new_manager
      run = manager.spawn_run(agent: "worker", task: "crash", async: true, timeout_ms: 0, tool_timeout_ms: 0)
      assert_equal :running, run[:state]

      Process.kill("KILL", run[:pid])

      wait_owned_terminal(manager, run[:id])
      record = manager.runs.find { |r| r[:id] == run[:id] }
      assert_equal true, %i[failed stopped].include?(record[:state]), record[:state].inspect
      assert File.file?(File.join(record[:dir], "result.json")), "the crash evidence landed in result.json"
      # Owned async convergence still notifies (the frozen observable).
      wait_until { !@hooks.pending_next_turn.empty? }
      assert_equal false, manager.outstanding?
      manager.shutdown
    end

    # --- AC4: the loud dispatch validation law ---

    def test_resolve_model_validation_all_exemption_arms_and_the_pinned_message
      root = File.join(@home, ".tart")
      FileUtils.mkdir_p(root)
      File.write(File.join(root, "models.json"), JSON.generate(
        {"providers" => {"mock" => {"name" => "Mock", "baseUrl" => "http://127.0.0.1:9/v1", "apiKey" => "k",
                                    "api" => "openai-completions",
                                    "models" => [{"id" => "call-model", "name" => "M", "reasoning" => false,
                                                  "contextWindow" => 100_000, "maxTokens" => 8192}]}}}
      ))
      loaded = Models.load(root: root)
      empty = Models.load(root: File.join(@home, "no-such-root"))
      refute_empty loaded.model_entries
      assert_empty empty.model_entries

      spec = "mock/nosuch-model"
      # The unknown + loaded registry → the BYTE-PINNED pi message.
      error = assert_raises(ArgumentError) { Subagents.resolve_model(spec, catalog: loaded, fallback: nil) }
      assert_equal "Unknown subagent model '#{spec}' in the active Pi model registry.", error.message
      # The parent-pair exemption (level ignored).
      pair = Subagents.resolve_model(spec, catalog: loaded, fallback: ["mock", "nosuch-model", "high"])
      assert_equal ["mock", "nosuch-model", "high"], pair
      # The empty-registry arm never validates (the never-raise boot law).
      assert_equal ["mock", "nosuch-model", nil], Subagents.resolve_model(spec, catalog: empty, fallback: nil)
      # The nil-catalog arm stays parse-only (byte-identical callers).
      assert_equal ["mock", "nosuch-model", nil], Subagents.resolve_model(spec, catalog: nil, fallback: nil)
      # A registry-resolvable spec is valid (the I71 exact-match law —
      # case-INSENSITIVE resolution; the returned pair stays the raw
      # parse — validation is never canonicalization, the parse-only
      # law byte-kept). The :level suffix never blocks resolution.
      assert_equal ["mock", "call-model", nil], Subagents.resolve_model("mock/call-model", catalog: loaded, fallback: nil)
      assert_equal ["MOCK", "CALL-MODEL", "high"],
                   Subagents.resolve_model("MOCK/CALL-MODEL:high", catalog: loaded, fallback: nil)
      # An inherited (nil) spec never loads, never validates.
      assert_equal %w[p m low], Subagents.resolve_model(nil, catalog: loaded, fallback: %w[p m low])
    end

    def test_unknown_model_rejected_at_spawn_with_zero_side_effects_call_and_profile_arms
      root = File.join(@home, ".tart")
      FileUtils.mkdir_p([root, File.join(root, "agents")])
      File.write(File.join(root, "models.json"), JSON.generate(
        {"providers" => {"mock" => {"name" => "Mock", "baseUrl" => @server.url, "apiKey" => "k",
                                    "api" => "openai-completions",
                                    "models" => [{"id" => "call-model", "name" => "M", "reasoning" => false,
                                                  "contextWindow" => 100_000, "maxTokens" => 8192}]}}}
      ))
      spec = "mock/nosuch-model"

      # Arm 1: the call `model:` — raised BEFORE any side effect.
      manager = new_manager(root: root)
      error = assert_raises(ArgumentError) do
        manager.spawn_run(agent: "worker", task: "must not spawn", async: true, model: spec)
      end
      assert_equal "Unknown subagent model '#{spec}' in the active Pi model registry.", error.message
      assert_empty Dir.children(File.join(@home, "subagents")), "no run dir, no status.json, no child process"

      # Arm 2: the profile's `model:` — the same law, the same message.
      File.write(File.join(root, "agents", "scout.md"), <<~MD)
        ---
        description: staged scout
        model: #{spec}
        ---

        Scout body.
      MD
      error = assert_raises(ArgumentError) do
        manager.spawn_run(agent: "scout", task: "must not spawn", async: true)
      end
      assert_equal "Unknown subagent model '#{spec}' in the active Pi model registry.", error.message
      assert_empty Dir.children(File.join(@home, "subagents"))

      # The registry-resolvable explicit model still dispatches (valid
      # dispatch = the child env written exactly as today).
      @server.script([{type: :stream, content: "ok"}])
      run = manager.spawn_run(agent: "worker", task: "valid model", async: false, model: "mock/call-model",
                              timeout_ms: 0, tool_timeout_ms: 0)
      assert_equal :completed, run[:state]
      _, env = manager.spawn_argv_and_env(run)
      assert_equal "call-model", env["PI_MODEL"]
      assert_equal "mock", env["PI_PROVIDER"]
    end

    # --- AC1: legacy/null-field tolerance ---

    def test_legacy_and_null_status_fields_never_raise_and_nil_pid_reads_unknown
      id = "01deadbee-0000-7000-8000-000000000006"
      # A NIL pid is unrecoverably gone (the exited? law); the repair
      # message reads pi's interpolation fallback "unknown", and every
      # nil/legacy field (taskChars, startedAt, NO timeoutMs key) passes
      # through without raising.
      dir = fabricate_run(id:, pid: nil, agent: "worker")
      list = new_manager.status(id: nil)

      assert_includes list, "- #{id} | failed | single | worker"
      result = JSON.parse(File.read(File.join(dir, "result.json")))
      assert_equal "Async runner process unknown #{REPAIR_BASE}", result["error"]
      status = JSON.parse(File.read(File.join(dir, "status.json")))
      assert_equal "failed", status["state"]
      assert_nil status["taskChars"], "legacy null fields ride untouched"
      assert_nil status["startedAt"]
      refute status.key?("timeoutMs"), "no invented keys"
    end

    # --- AC1: the stderr-tail diagnostics discipline (pi byte-shape) ---

    def test_stderr_tail_is_last_30_lines_with_the_4k_truncation_marker
      manager = new_manager
      # Under the bound: 35 short lines → the LAST 30 exactly, no marker.
      id = "01deadbee-0000-7000-8000-000000000007"
      pid = dead_pid
      dir = fabricate_run(id:, pid:, stderr: (1..35).map { |n| "line #{n}" }.join("\n") + "\n")

      manager.status(id: nil)

      result = JSON.parse(File.read(File.join(dir, "result.json")))
      tail = result["error"].split("\n\nRunner stderr tail:\n", 2)[1]
      assert_equal 30, tail.lines.size, "the LAST 30 lines only"
      assert_includes tail, "line 35", "the tail end of the log"
      refute_includes tail, "line 1\n", "the head of the log is gone"
      refute_includes result["error"], "[stderr tail truncated]"

      # Over the bound: the last 4000 chars + the marker.
      id2 = "01deadbee-0000-7000-8000-000000000709"
      pid2 = dead_pid
      dir2 = fabricate_run(id: id2, pid: pid2, stderr: (1..40).map { |n| "line #{n} #{"x" * 200}" }.join("\n") + "\n")

      manager.status(id: nil)

      result2 = JSON.parse(File.read(File.join(dir2, "result.json")))
      tail2 = result2["error"].split("\n\nRunner stderr tail:\n", 2)[1]
      assert_includes tail2, "\n[stderr tail truncated]", "over 4000 chars → the marker"
      assert_operator tail2.length, :<=, 4000 + "\n[stderr tail truncated]".length
      assert_includes tail2, "line 40", "the truncation keeps the TAIL end"
    end

    # --- AC2: the targeted id read routes through the SAME seam ---

    def test_targeted_status_read_converges_the_dead_specimen_through_the_reaper
      id = "01deadbee-0000-7000-8000-000000000008"
      pid = dead_pid
      dir = fabricate_run(id:, pid:)
      manager = new_manager

      rendered = manager.status(id: id)

      assert_includes rendered, "State: failed"
      status = JSON.parse(File.read(File.join(dir, "status.json")))
      assert_equal "failed", status["state"]
      assert_empty @hooks.pending_next_turn, "the accidental 12:47-style read never notifies"
      assert_equal false, manager.outstanding?
    end

    # --- helpers (continuation) ---

    def wait_owned_terminal(manager, id, timeout = 25)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      until manager.runs.find { |r| r[:id] == id } && manager.runs.find { |r| r[:id] == id }[:state] != :running
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          flunk "owned run #{id} never settled"
        end
        sleep 0.1
      end
    end

    def wait_pid_gone(pid, timeout = 5)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      begin
        loop do
          Process.kill(0, pid)
          raise "pid never died" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

          sleep 0.05
        end
      rescue Errno::ESRCH
        nil
      end
    end
  end
end
