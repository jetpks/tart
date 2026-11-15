# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/mock_llm_server"
require "tmpdir"
require "fileutils"
require "json"

module Tart
  # The I99 session-ownership pin battery: the spawn stamp (S1), the
  # session owner id (S2), scoped discovery (S3), scoped admission +
  # control (S4), the scoped supervisor channel (S5), the owned
  # complementary arm (S6 — the I78 legs preserved, now stamped-ours
  # only), and the owned umbrella. Hermetic: staged homes, real
  # `bin/tart -p` children on MockLLMServer, reaped-real-pids for ESRCH —
  # ZERO live API calls.
  class SubagentsSessionOwnershipTest < Test
    FOREIGN_STAMP = "01fff000-0000-7000-8000-00000000000f"

    # The byte-pinned pi repair base (stale-run-reconciler.js — the I78
    # legs' message, restated for the owned-arm pin).
    REPAIR_BASE = "exited or disappeared before writing a result. Marked run failed by stale-run reconciliation."

    def setup
      @server = MockLLMServer.new.start
      @home = Dir.mktmpdir("i99-ownership-home-")
      @cwd = Dir.mktmpdir("i99-ownership-cwd-")
      @hooks = Hooks.new
      @managers = []
      @channels = []
      @spawns = []
    end

    def teardown
      @managers.each(&:shutdown)
      @channels.each(&:stop)
      @server.stop
      @spawns.each do |pid|
        Process.kill("KILL", -pid)
      rescue StandardError
        nil
      end
      FileUtils.rm_rf(@home)
      FileUtils.rm_rf(@cwd)
    end

    # --- pin 1 (S1): the spawn stamp ---

    def test_spawn_stamps_session_id_last_and_the_stamp_survives_the_terminal_flip
      @server.script([{type: :stream, content: "async stamped"},
                      {type: :stream, content: "foreground stamped"}])
      manager = new_manager

      # The ASYNC arm: the spawn-time status.json carries the stamp as the
      # LAST key over the exact base key set.
      run = manager.spawn_run(agent: "worker", task: "stamp me", async: true, timeout_ms: 0, tool_timeout_ms: 0)
      initial = JSON.parse(File.read(File.join(run[:dir], "status.json")))
      assert_equal "running", initial["state"], "the spawn-time bytes (the child has not settled)"
      assert_equal manager.session_owner_id, initial["sessionId"]
      assert_equal %w[id agent task taskChars mode state pid cwd asyncDir sessionRoot startedAt
                      lastUpdate toolCallId context sessionId], initial.keys,
                   "the base keys, order byte-kept, sessionId appended LAST"

      wait_owned_terminal(manager, run[:id])
      settled = JSON.parse(File.read(File.join(run[:dir], "status.json")))
      assert_equal "completed", settled["state"]
      assert_equal manager.session_owner_id, settled["sessionId"], "the async flip preserves the stamp"

      # The FOREGROUND arm: the settle flip's final status.json still
      # carries it.
      fg = manager.spawn_run(agent: "worker", task: "stamp me too", async: false,
                             timeout_ms: 0, tool_timeout_ms: 0)
      final = JSON.parse(File.read(File.join(fg[:dir], "status.json")))
      assert_equal :completed, fg[:state]
      assert_equal manager.session_owner_id, final["sessionId"], "the foreground settle preserves the stamp"
    end

    # --- pin 2 (S2): the session owner id ---

    def test_session_owner_id_freezes_on_the_first_live_recorder_and_is_stable_without_an_agent
      recorder = Struct.new(:id, :path)
      loop1 = Struct.new(:recorder).new(recorder.new("01aaa111-0000-7000-8000-00000000aaaa", "/x/one.jsonl"))
      loop2 = Struct.new(:recorder).new(recorder.new("01bbb222-0000-7000-8000-00000000bbbb", "/x/two.jsonl"))
      current = [loop1]
      manager = new_manager(agent: -> { current.first })

      assert_equal "01aaa111-0000-7000-8000-00000000aaaa", manager.session_owner_id
      # A later swap keeps the first id — ONE identity per Manager life.
      current[0] = loop2
      assert_equal "01aaa111-0000-7000-8000-00000000aaaa", manager.session_owner_id,
                   "the FIRST resolution is memoized for the Manager's life"
      # And the stamp rides it.
      @server.script([{type: :stream, content: "stamped by the recorder id"}])
      run = manager.spawn_run(agent: "worker", task: "t", async: false, timeout_ms: 0, tool_timeout_ms: 0)
      assert_equal "01aaa111-0000-7000-8000-00000000aaaa",
                   JSON.parse(File.read(File.join(run[:dir], "status.json")))["sessionId"]

      # No agent threaded (print boots, bare test Managers): a stable
      # non-nil String — the per-boot mint, never memoized, per-boot
      # distinct.
      bare1 = new_manager
      boot1 = bare1.session_owner_id
      assert_instance_of String, boot1
      refute_empty boot1
      assert_equal boot1, bare1.session_owner_id, "stable within one Manager's life"
      bare2 = new_manager
      refute_equal boot1, bare2.session_owner_id, "owner ids are unique per process"
      refute_equal boot1, "01aaa111-0000-7000-8000-00000000aaaa", "the boot mint is not a recorder id"
    end

    # --- pin 3 (S3/AC2/AC3): scoped discovery ---

    def test_fresh_manager_over_foreign_and_unstamped_dirs_is_fully_isolated
      fdir = stage_run("01aaa111-0000-7000-8000-000000000001", pid: live_pid,
                       session_id: FOREIGN_STAMP)
      udir = stage_run("01bbb222-0000-7000-8000-000000000002", pid: live_pid)
      fbytes = File.read(File.join(fdir, "status.json"))
      ubytes = File.read(File.join(udir, "status.json"))

      manager = new_manager
      assert_equal Subagents::Manager::FLEET_EMPTY_LINE, manager.status(id: nil), "the fleet is byte-exact empty"
      assert_empty manager.box_snapshot.fetch(:rows), "the box renders nothing foreign"
      assert_empty manager.runs, "no record, no adoption"

      # No disk write, ever: status bytes, control dirs, no result.json.
      assert_equal fbytes, File.read(File.join(fdir, "status.json"))
      assert_equal ubytes, File.read(File.join(udir, "status.json"))
      [fdir, udir].each do |dir|
        assert_empty Dir.children(File.join(dir, "control", "steer-requests")), dir
        assert_empty Dir.children(File.join(dir, "control", "stop-requests")), dir
        assert_empty Dir.children(File.join(dir, "control", "supervisor-requests")), dir
        refute File.file?(File.join(dir, "result.json")), dir
      end
    end

    # --- pin 4 (S4/AC4): scoped control ---

    def test_targeted_control_on_a_foreign_id_takes_the_unknown_id_path_and_the_child_survives
      fdir = stage_run("01aaa111-0000-7000-8000-000000000001", pid: live_pid,
                       session_id: FOREIGN_STAMP)
      udir = stage_run("01bbb222-0000-7000-8000-000000000002", pid: live_pid)
      fbytes = File.read(File.join(fdir, "status.json"))
      ubytes = File.read(File.join(udir, "status.json"))
      sleeper = read_pid(fdir)
      manager = new_manager

      # The pinned unknown-id bytes, for BOTH the foreign and the
      # unstamped id (D4 — one vocabulary, before any write or signal).
      %w[01aaa111-0000-7000-8000-000000000001
         01bbb222-0000-7000-8000-000000000002].each do |id|
        error = assert_raises(ArgumentError) { manager.status(id: id) }
        assert_equal "unknown subagent run \"#{id}\". Active runs: (none).", error.message
        error = assert_raises(ArgumentError) { manager.steer(id: id, message: "foreign steer", ack_timeout_ms: 100) }
        assert_equal "unknown subagent run \"#{id}\". Active runs: (none).", error.message
        error = assert_raises(ArgumentError) { manager.stop(id: id) }
        assert_equal "unknown subagent run \"#{id}\". Active runs: (none).", error.message
        assert_nil manager.result(id: id)
      end
      assert_empty manager.runs, "the refused ids never entered the registry"

      # No file written into the dirs; the live foreign child SURVIVES the
      # stop attempt.
      assert_equal fbytes, File.read(File.join(fdir, "status.json"))
      assert_equal ubytes, File.read(File.join(udir, "status.json"))
      assert_empty Dir.children(File.join(fdir, "control", "steer-requests"))
      assert_empty Dir.children(File.join(fdir, "control", "stop-requests"))
      refute File.file?(File.join(fdir, "result.json"))
      Process.kill(0, sleeper) # raises ESRCH if the stop attempt killed it
    end

    # --- pin 5 (AC6): two live managers, one home ---

    def test_two_live_managers_sharing_one_home_cannot_see_or_control_each_others_runs
      @server.script([{type: :stream, content: "A's answer"}])
      manager_a = new_manager
      run = manager_a.spawn_run(agent: "worker", task: "A's run", async: true, timeout_ms: 0, tool_timeout_ms: 0)
      manager_b = new_manager

      # B is blind: fleet, box, registry.
      assert_equal Subagents::Manager::FLEET_EMPTY_LINE, manager_b.status(id: nil)
      assert_empty manager_b.box_snapshot.fetch(:rows)
      assert_empty manager_b.runs
      # B cannot control A's run — the unknown-id path, no steer file.
      assert_raises(ArgumentError) { manager_b.status(id: run[:id]) }
      assert_raises(ArgumentError) { manager_b.steer(id: run[:id], message: "B steers", ack_timeout_ms: 50) }
      assert_raises(ArgumentError) { manager_b.stop(id: run[:id]) }
      assert_nil manager_b.result(id: run[:id])
      assert_empty Dir.children(File.join(run[:dir], "control", "steer-requests")),
                   "B's refused steer wrote nothing into A's dir"

      # A sees and controls its own run normally.
      assert_includes manager_a.status(id: nil), "- #{run[:id]} | running | single | worker"
      receipt = manager_a.steer(id: run[:id], message: "A steers", ack_timeout_ms: 300)
      assert_includes %i[delivered queued], receipt[:state]
      assert_equal "Stop requested for async run #{run[:id]}.", manager_a.stop(id: run[:id])
      wait_owned_terminal(manager_a, run[:id])
      settled = JSON.parse(File.read(File.join(run[:dir], "status.json")))
      assert_equal "stopped", settled["state"]
      assert_equal manager_a.session_owner_id, settled["sessionId"], "the stop settle preserves the stamp"
      # B stays blind after the terminal flip (terminal dirs are never adopted).
      assert_equal Subagents::Manager::FLEET_EMPTY_LINE, manager_b.status(id: nil)
    end

    # --- pin 6 (S6/AC5): the owned complementary arm (the I78 legs) ---

    def test_owned_stamped_dirs_adopt_and_converge_through_the_fleet_read
      manager = new_manager
      # Dead pid, stamped-ours: adopts + converges (the reaper's dead-pid
      # repair), the stamp PRESERVED by the flip.
      id1 = "01ccc333-0000-7000-8000-000000000003"
      pid1 = dead_pid
      dir1 = stage_run(id1, pid: pid1, session_id: manager.session_owner_id, stderr: "boom line\n")
      list = manager.status(id: nil)
      assert_includes list, "- #{id1} | failed | single | worker"
      status = JSON.parse(File.read(File.join(dir1, "status.json")))
      assert_equal "failed", status["state"]
      assert_equal manager.session_owner_id, status["sessionId"], "the repair preserves the stamp"
      result = JSON.parse(File.read(File.join(dir1, "result.json")))
      assert_equal false, result["success"]
      want = "Async runner process #{pid1} #{REPAIR_BASE}"
      assert_equal true, result["error"].start_with?(want), result["error"].inspect
      assert_includes result["error"], "\n\nRunner stderr tail:\n"

      # Live pid, stamped-ours: lists running, byte-identical, never converged.
      id2 = "01ccc333-0000-7000-8000-000000000004"
      pid2 = live_pid
      dir2 = stage_run(id2, pid: pid2, session_id: manager.session_owner_id)
      bytes2 = File.read(File.join(dir2, "status.json"))
      assert_includes manager.status(id: nil), "- #{id2} | running | single | worker"
      assert_equal bytes2, File.read(File.join(dir2, "status.json"))
      refute File.file?(File.join(dir2, "result.json"))
    end

    # --- pin 7 (S5/AC4): the scoped supervisor channel ---

    def test_channel_owner_resolver_registers_and_surfaces_only_owned_asks
      owned_rid = "11111111-1111-4111-8111-111111111111"
      foreign_rid = "22222222-2222-4222-8222-222222222222"
      owner_id = "01owne000-0000-7000-8000-0000000000ff"
      odir = stage_run("01ccc333-0000-7000-8000-000000000005", pid: live_pid, session_id: owner_id)
      fdir = stage_run("01ccc333-0000-7000-8000-000000000006", pid: live_pid, session_id: FOREIGN_STAMP)
      stage_ask(odir, owned_rid, run_id: "01ccc333-0000-7000-8000-000000000005")
      stage_ask(fdir, foreign_rid, run_id: "01ccc333-0000-7000-8000-000000000006")
      foreign_path = File.join(fdir, "control", "supervisor-requests", "#{foreign_rid}.json")

      channel = Subagents::SupervisorChannel.new(home: File.join(@home, "subagents"), hooks: @hooks,
                                                 kernel: nil, agent: nil, owner_id: -> { owner_id })
      @channels << channel
      channel.start
      wait_until { !channel.pending.empty? }

      # The owned ask registered + surfaced, EXACTLY once; the foreign ask
      # never.
      assert_equal [owned_rid], channel.pending.map { |request| request[:id] }
      drained = @hooks.pending_next_turn
      assert_equal 1, drained.size
      assert_equal Subagents::Supervisor::REQUEST_CUSTOM_TYPE, drained.first[:custom_type]
      assert_equal true, drained.first[:display]
      assert_includes drained.first[:content], owned_rid

      # The foreign file is still on disk (never registered, surfaced, or
      # unlinked) and the reply fallback refuses its id.
      assert File.file?(foreign_path), "the foreign ask was never unlinked"
      error = assert_raises(ArgumentError) { channel.reply(reply_to: foreign_rid, message: "hello") }
      assert_includes error.message, "No pending supervisor request found for reply_to '#{foreign_rid}'"
      assert File.file?(foreign_path), "the refused reply never removed the foreign file"

      # The owned ask is fully serviceable: reply lands, the file unlinks.
      assert_equal "Replied to supervisor request #{owned_rid}.",
                   channel.reply(reply_to: owned_rid, message: "owned answer")
      refute File.file?(File.join(odir, "control", "supervisor-requests", "#{owned_rid}.json"))
      assert File.file?(File.join(odir, "control", "supervisor-replies", "#{owned_rid}.json"))
    end

    # --- pin 8 (S6): the owned umbrella ---

    def test_owned_async_run_end_to_end_umbrella_is_byte_identical_to_base
      @server.script([{type: :stream, content: "umbrella answer"}])
      manager = new_manager
      run = manager.spawn_run(agent: "worker", task: "umbrella", async: true, timeout_ms: 0, tool_timeout_ms: 0)

      assert_equal true, manager.outstanding?, "the owned in-flight run gates outstanding?"
      row = manager.box_snapshot.fetch(:rows).find { |candidate| candidate[:id] == run[:id] }
      assert row, "the box carries the owned run"
      assert_equal "running", row[:state]

      wait_owned_terminal(manager, run[:id])
      assert_includes manager.status(id: nil), "- #{run[:id]} | completed | single | worker"
      pending = @hooks.pending_next_turn
      assert_equal 1, pending.size, "exactly one completion notification"
      assert_equal Subagents::NOTIFY_CUSTOM_TYPE, pending.first[:custom_type]
      assert_equal "umbrella answer", manager.result(id: run[:id])["output"]
    end

    # --- helpers (the health/box families' discipline) ---

    def new_manager(**opts)
      manager = Subagents::Manager.new(cwd: @cwd, home: File.join(@home, "subagents"), env: default_env,
                                       identity: "pi", hooks: @hooks, **opts)
      @managers << manager
      manager
    end

    def default_env
      {"PATH" => ENV["PATH"], "HOME" => @home, "PI_API_KEY" => "test-key", "PI_API_BASE" => @server.url}
    end

    # Stages a run dir (the isolation-gate mk shape): status.json with the
    # optional ownership stamp + the control dirs.
    def stage_run(id, pid:, session_id: nil, state: "running", stderr: nil)
      dir = File.join(@home, "subagents", id)
      FileUtils.mkdir_p([dir, File.join(dir, "control", "steer-requests"),
                         File.join(dir, "control", "stop-requests"),
                         File.join(dir, "control", "supervisor-requests"),
                         File.join(dir, "control", "supervisor-replies"),
                         File.join(dir, "sessions")])
      payload = {"id" => id, "agent" => "worker", "task" => nil, "taskChars" => nil, "mode" => "single",
                 "state" => state, "pid" => pid, "cwd" => @cwd, "asyncDir" => dir,
                 "sessionRoot" => File.join(dir, "sessions"), "startedAt" => nil,
                 "lastUpdate" => nil, "toolCallId" => nil}
      payload["sessionId"] = session_id if session_id
      File.write(File.join(dir, "status.json"), JSON.generate(payload))
      File.write(File.join(dir, "runner.stderr.log"), stderr) if stderr
      dir
    end

    def stage_ask(dir, request_id, run_id:, reason: "need_decision", message: "which way?")
      payload = {type: Subagents::Supervisor::REQUEST_TYPE, id: request_id, createdAt: Subagents::Supervisor.now_ms,
                 reason:, message:, expectsReply: true, runId: run_id, agent: "worker"}
      path = File.join(dir, "control", "supervisor-requests", "#{request_id}.json")
      Subagents::Supervisor.atomic_write_json(path, payload)
      path
    end

    def read_pid(dir)
      JSON.parse(File.read(File.join(dir, "status.json")))["pid"]
    end

    # A REAL reaped pid (the health idiom): spawn, detach, wait for ESRCH.
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

    # A LIVE pid the test owns (a pgroup leader, killed in teardown).
    def live_pid
      pid = Process.spawn("sleep", "60", pgroup: true)
      Process.detach(pid)
      @spawns << pid
      sleep 0.05 # let it exec
      pid
    end

    def wait_owned_terminal(manager, id, timeout = 25)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      record = manager.runs.find { |candidate| candidate[:id] == id }
      until record && record[:state] != :running
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          flunk "owned run #{id} never settled"
        end
        sleep 0.1
        record = manager.runs.find { |candidate| candidate[:id] == id }
      end
    end
  end
end
