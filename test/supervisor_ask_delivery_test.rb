# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/mock_llm_server"
require "tmpdir"
require "fileutils"
require "json"
require "securerandom"

module Tart
  # The I100 supervisor-ask-delivery pins: the blocked-parent valve (the D1
  # constant + payload shape, the no-register/no-surface law, the
  # predicate's negative arms + the nil default, the I99 ownership
  # precedence, the unseen-retry law), the child's error law (the
  # ArgumentError-verbatim tool error), the foreground attention marks
  # (the box_snapshot facts, the D3 render leg, the D2 terminal-flip and
  # dir-vanish clears), and the hermetic live leg — a real foreground
  # child over the MockLLMServer whose ask is valve-answered, reported as
  # a tool error, completed, and mark-cleared. Hermetic: staged homes,
  # direct-constructed channels + the production register path,
  # MockLLMServer, real bin/tart -p children. ZERO live API calls; no
  # timing bets — the wait_until discipline throughout.
  class SupervisorAskDeliveryTest < Test
    # D1 — the valve message's frozen bytes (the pin restates the constant
    # so a drift fails here first, with the diff in the message).
    D1_ERROR = "Supervisor unavailable: the parent is blocked in a foreground subagent call and cannot answer this request. " \
               "Report the blocker and any partial results, then stop. Relaunch the subagent with async: true to allow supervisor replies."

    FOREIGN_STAMP = "01fff000-0000-7000-8000-00000000000f"

    def setup
      @server = MockLLMServer.new.start
      @home = Dir.mktmpdir("i100-ask-home-")
      @cwd = Dir.mktmpdir("i100-ask-cwd-")
      @hooks = Hooks.new
      @kernel = fake_kernel
      @managers = []
      @channels = []
      @threads = []
      @spawns = []
    end

    def teardown
      @channels.each { |channel| channel.stop rescue nil }
      @managers.each(&:shutdown)
      @threads.each { |thread| thread.join(1) rescue nil }
      @server.stop
      @spawns.each do |pid|
        Process.kill("KILL", -pid)
      rescue StandardError
        nil
      end
      FileUtils.rm_rf(@home)
      FileUtils.rm_rf(@cwd)
    end

    # --- pin 1 (AC1): the D1 constant + the written payload's shape ---

    def test_valve_constant_and_payload_shape
      assert_equal D1_ERROR, Subagents::Supervisor::BLOCKED_PARENT_ERROR

      run = fake_run("worker")
      channel = new_channel(predicate: ->(run_id) { run_id == run[:id] })
      staged = stage_ask(run[:dir], run_id: run[:id], message: "PAYLOAD-SHAPE-ASK")
      reply = reply_path_for(run[:dir], staged[:id])
      wait_until { File.file?(reply) }

      payload = JSON.parse(File.read(reply))
      assert_equal Subagents::Supervisor::REPLY_TYPE, payload["type"]
      assert_equal staged[:id], payload["requestId"]
      assert_instance_of Integer, payload["createdAt"]
      assert_equal "", payload["message"], "the valve message is the empty String"
      assert_equal Subagents::Supervisor::BLOCKED_PARENT_ERROR, payload["error"]
      assert_equal %w[type requestId createdAt message error], payload.keys,
                   "tart's reply_payload key order + the error key appended last (D1)"
    end

    # --- pin 2 (AC1/AC3): the valve answers WITHOUT registering or surfacing ---

    def test_valve_answers_a_foreground_ask_without_registering_or_surfacing
      run = fake_run("worker")
      channel = new_channel(predicate: ->(run_id) { run_id == run[:id] })
      staged = stage_ask(run[:dir], run_id: run[:id], message: "VALVED-ASK")
      reply = reply_path_for(run[:dir], staged[:id])

      wait_until { File.file?(reply) }
      wait_until { !File.file?(File.join(run[:dir], "control", "supervisor-requests", "#{staged[:id]}.json")) }

      assert_empty channel.pending, "the valved ask never registers pending"
      assert_empty @hooks.pending_next_turn, "the valved ask never surfaces (no queue entry)"
      assert_equal({tool: "contact_supervisor", since: staged[:createdAt]},
                   channel.foreground_attention[run[:id]],
                   "the mark rides the run id with the asking tool + the ask's createdAt")
      refute_empty @kernel.calls, "the box draw kick rode the kernel bridge"
    end

    # --- pin 3 (AC1): the predicate's false arm keeps today's bytes ---

    def test_valve_never_fires_when_the_run_is_not_foreground_awaited
      run = fake_run("worker")
      channel = new_channel(predicate: ->(_run_id) { false })
      staged = stage_ask(run[:dir], run_id: run[:id], message: "NOT-AWAITED-ASK")
      reply = reply_path_for(run[:dir], staged[:id])

      surfaced = wait_surfaced("NOT-AWAITED-ASK")
      refute_nil surfaced, "the ask registers + surfaces with today's bytes"
      assert_equal Subagents::Supervisor::REQUEST_CUSTOM_TYPE, surfaced[:custom_type]
      assert_equal [staged[:id]], channel.pending.map { |request| request[:id] }
      assert_empty channel.foreground_attention, "no mark without the valve"

      sleep Subagents::Supervisor::POLL_INTERVAL * 3
      refute File.file?(reply), "no valve reply for a non-awaited run"
    end

    # --- pin 4 (AC1): the nil default is today's bytes (the D5 shape) ---

    def test_nil_predicate_is_today_s_bytes
      run = fake_run("worker")
      channel = new_channel # no foreground_awaited: kwarg at all
      staged = stage_ask(run[:dir], run_id: run[:id], message: "NIL-PREDICATE-ASK")
      reply = reply_path_for(run[:dir], staged[:id])

      surfaced = wait_surfaced("NIL-PREDICATE-ASK")
      refute_nil surfaced, "the nil-default channel surfaces exactly as base"
      assert_equal true, surfaced[:display]
      assert_equal [staged[:id]], channel.pending.map { |request| request[:id] }
      refute_empty @kernel.calls, "the base wake kick still rides kernel.async"
      assert_empty channel.foreground_attention
      sleep Subagents::Supervisor::POLL_INTERVAL * 3
      refute File.file?(reply), "the nil predicate NEVER valves"
    end

    # --- pin 5 (AC1): the I99 ownership guard precedes the valve ---

    def test_valve_respects_session_ownership
      owner = "01owne100-0000-7000-8000-000000000001"
      odir = stage_run_dir("01ccc333-0000-7000-8000-000000000005", session_id: owner)
      fdir = stage_run_dir("01ccc333-0000-7000-8000-000000000006", session_id: FOREIGN_STAMP)
      # Both asks staged BEFORE the channel starts; the predicate is
      # unconditionally true — ONLY the ownership guard can refuse.
      stage_ask(odir, run_id: "01ccc333-0000-7000-8000-000000000005", message: "OWNED-VALVED")
      foreign = stage_ask(fdir, run_id: "01ccc333-0000-7000-8000-000000000006", message: "FOREIGN-ASK")
      foreign_path = File.join(fdir, "control", "supervisor-requests", "#{foreign[:id]}.json")
      foreign_bytes = File.read(foreign_path)

      channel = new_channel(predicate: ->(_run_id) { true }, owner: owner)
      owned = File.basename(Dir.glob(File.join(odir, "control", "supervisor-requests", "*.json")).first, ".json")
      owned_reply = reply_path_for(odir, owned)
      wait_until { File.file?(owned_reply) } # the owned ask was valved — the poll is live

      refute File.file?(reply_path_for(fdir, foreign[:id])), "the foreign ask was never valved"
      assert_equal foreign_bytes, File.read(foreign_path), "the foreign file is byte-untouched"
      assert_empty channel.pending, "neither ask registered (one valved, one foreign)"
      assert_empty @hooks.pending_next_turn, "neither ask surfaced"
      assert_equal ["01ccc333-0000-7000-8000-000000000005"], channel.foreground_attention.keys,
                   "only the OWNED run is marked"
    end

    # --- pin 6 (AC2): the child's error law — the valve is a TOOL ERROR ---

    def test_child_tool_raises_the_error_reply_verbatim
      ctrl = new_ctrl
      tool = tool_for(ctrl)
      answerer = Thread.new do
        100.times do
          files = Dir.children(File.join(ctrl, "supervisor-requests")).reject { |f| f.start_with?(".") }
          if (file = files.first)
            begin
              id = JSON.parse(File.read(File.join(ctrl, "supervisor-requests", file)))["id"]
            rescue Errno::ENOENT
              next # the child unlinked its consumed request between the snapshot and the read
            end
            sleep 0.05
            Subagents::Supervisor.atomic_write_json(
              File.join(ctrl, "supervisor-replies", "#{id}.json"),
              {type: Subagents::Supervisor::REPLY_TYPE, requestId: id,
               createdAt: Subagents::Supervisor.now_ms, message: "",
               error: Subagents::Supervisor::BLOCKED_PARENT_ERROR})
            next
          end
          sleep 0.05
        end
      end

      result = tool.execute(reason: "need_decision", message: "blocked parent ask?")

      assert_equal({error: Subagents::Supervisor::BLOCKED_PARENT_ERROR}, result,
                   "SafeExecute keeps the ArgumentError verbatim in the {error:} result")
      assert_empty Dir.children(File.join(ctrl, "supervisor-requests")).reject { |f| f.start_with?(".") },
                   "the request file is unlinked on the reply path before the raise"
    ensure
      answerer.kill if answerer
    end

    # --- pin 7 (AC3): the marks flow to the snapshot and the render ---

    def test_marks_flow_to_the_box_snapshot_and_render
      @server.script([
        {type: :stream, tool_calls: [{id: "ask1", name: "contact_supervisor",
                                      arguments: {reason: "need_decision", message: "MARK-ASK"}}]},
        {type: :stream, content: "CHILD DONE AFTER MARK"}
      ])
      manager = new_manager
      # The register shape: the channel consults the Manager's awaited
      # window (L1) and the Manager's session owner (I99).
      channel = new_channel(predicate: ->(run_id) { manager.foreground_run_awaited?(run_id) },
                            owner: manager.session_owner_id)
      manager.supervisor_channel = channel
      spawner = foreground_spawn(manager, "run into the mark")

      request_path = wait_request_file(manager, "MARK-ASK")
      run_id = run_id_for(request_path)
      reply = reply_path_for_request(request_path)
      wait_until { File.file?(reply) }

      # The mark window: the valve set it in the reply tick; the child
      # cannot settle until its own next poll (250ms cadence) plus a model
      # round — the bounded wait rides wait_until, not a sleep bet.
      marked = nil
      wait_until do
        marked = manager.box_snapshot[:rows].find { |row| row[:id] == run_id }
        marked && marked[:attention] == true && marked[:attention_tool] == "contact_supervisor"
      end

      # The single form (the step_activity leg) composes the tool prefix.
      lines = Render::SubagentBox.render(rows: [marked], now: marked[:last_update], frame: 0,
                                         width: 120, main_level: "off").map { |l| l.spans.map(&:content).join }
      assert lines.any? { |l| l.include?("tool contact_supervisor · no activity for") },
             "the marked row renders `tool contact_supervisor · <attention label>`"

      # The pending-derived leg: an adopted (async) run's ask registers
      # pending — attention with NO tool fact — and renders today's bytes.
      adopted_id = "01eee000-0000-7000-8000-000000000001"
      adopt_dir = stage_run_dir(adopted_id, pid: live_pid, session_id: manager.session_owner_id)
      manager.status(id: nil) # the fleet read adopts the staged dir
      stage_ask(adopt_dir, run_id: adopted_id, message: "PENDING-DERIVED-ASK")
      wait_until { channel.pending.any? { |request| request[:run_id] == adopted_id } }
      row2 = manager.box_snapshot[:rows].find { |row| row[:id] == adopted_id }
      refute_nil row2
      assert_equal true, row2[:attention]
      assert_nil row2[:attention_tool], "async asks' pending-derived attention carries no tool fact"

      # The multi form (the job_activity leg) over captured row facts:
      # BOTH attention rows render their labels; only the marked one
      # carries the tool prefix.
      lines = Render::SubagentBox.render(rows: [marked, row2], now: marked[:last_update], frame: 0,
                                         width: 120, main_level: "off").map { |l| l.spans.map(&:content).join }
      assert_equal 2, lines.count { |l| l.include?("no activity for") }, "both attention rows render labels"
      assert lines.any? { |l| l.include?("tool contact_supervisor · ") }, "the multi form keeps the tool prefix"
      lines2 = Render::SubagentBox.render(rows: [row2], now: row2[:last_update], frame: 0,
                                          width: 120, main_level: "off").map { |l| l.spans.map(&:content).join }
      assert lines2.any? { |l| l.include?("no activity for") }, "the pending-derived row renders the attention label"
      refute lines2.any? { |l| l.include?("tool contact_supervisor") }, "no prefix without the tool fact (today's bytes)"

      wait_terminal(manager, run_id, 40)
      wait_until { !spawner.alive? }
    end

    # --- pin 8 (AC3/D2): the marks clear on the terminal flip + dir vanish ---

    def test_marks_clear_on_the_terminal_flip_and_dir_vanish
      manager = new_manager
      id1 = "01ddd000-0000-7000-8000-000000000001"
      dir1 = stage_run_dir(id1, pid: live_pid, session_id: manager.session_owner_id)
      manager.status(id: nil) # adopt the staged running record
      channel = new_channel(predicate: ->(run_id) { [id1, "01ddd000-0000-7000-8000-000000000002"].include?(run_id) },
                            owner: manager.session_owner_id)
      manager.supervisor_channel = channel

      staged = stage_ask(dir1, run_id: id1, message: "CLEAR-LEG-1")
      wait_until { File.file?(reply_path_for(dir1, staged[:id])) }
      wait_until { !channel.foreground_attention.empty? }
      row = manager.box_snapshot[:rows].find { |candidate| candidate[:id] == id1 }
      assert_equal true, row[:attention]
      assert_equal "contact_supervisor", row[:attention_tool]

      # Leg 1 — the terminal flip: status.json state → completed; one poll
      # later the mark is gone and the row's attention fact is false.
      status = JSON.parse(File.read(File.join(dir1, "status.json")))
      status["state"] = "completed"
      Subagents::Supervisor.atomic_write_json(File.join(dir1, "status.json"), status)
      wait_until { channel.foreground_attention.empty? }
      row = manager.box_snapshot[:rows].find { |candidate| candidate[:id] == id1 }
      assert_equal false, row[:attention], "the cleared mark leaves no attention fact"

      # Leg 2 — the dir vanish: a second mark whose run dir is deleted.
      id2 = "01ddd000-0000-7000-8000-000000000002"
      dir2 = stage_run_dir(id2, pid: live_pid, session_id: manager.session_owner_id)
      staged2 = stage_ask(dir2, run_id: id2, message: "CLEAR-LEG-2")
      wait_until { File.file?(reply_path_for(dir2, staged2[:id])) }
      assert channel.foreground_attention.key?(id2)
      FileUtils.rm_rf(dir2)
      wait_until { channel.foreground_attention.empty? }
      assert_empty channel.foreground_attention
    end

    # --- pin 9 (AC1): a failed valve write stays unseen and retries ---

    def test_valve_write_failure_retries_next_tick
      run = fake_run("worker")
      staged = stage_ask(run[:dir], run_id: run[:id], message: "RETRY-ASK")
      reply = reply_path_for(run[:dir], staged[:id])
      request = File.join(run[:dir], "control", "supervisor-requests", "#{staged[:id]}.json")
      attempts = []
      stub_failing_atomic_write(attempts)
      channel = new_channel(predicate: ->(run_id) { run_id == run[:id] })

      # The failed tick: the write raised, the path was left UNSEEN, the
      # request file survived. The stub raises on EVERY call while
      # installed (the "one shot" is the install — restore is the unstub
      # event), so this window is race-free.
      wait_until { !attempts.empty? }
      refute File.file?(reply), "no reply on the failed tick"
      assert File.file?(request), "the unseen request file survives for the retry"

      restore_atomic_write
      wait_until { File.file?(reply) }
      payload = JSON.parse(File.read(reply))
      assert_equal Subagents::Supervisor::BLOCKED_PARENT_ERROR, payload["error"]
      assert_equal "", payload["message"]
      refute File.file?(request), "the retried valve consumed the request"
    ensure
      restore_atomic_write
    end

    # --- pin 10 (AC1/AC3): the hermetic foreground round trip ---

    def test_the_foreground_round_trip_is_valve_answered_and_completes
      @server.script([
        {type: :stream, tool_calls: [{id: "ask1", name: "contact_supervisor",
                                      arguments: {reason: "need_decision", message: "ROUND-TRIP-VALVE-ASK"}}]},
        {type: :stream, content: "CHILD DONE AFTER VALVE"}
      ])
      saved_manager = Subagents.current_manager
      manager = Subagents.register(
        hooks: @hooks, kernel: nil, agent: nil, cwd: @cwd, home: File.join(@home, "subagents"),
        identity: "pi",
        env: {"PATH" => ENV["PATH"], "HOME" => @home,
              "PI_API_KEY" => "pin-key", "PI_API_BASE" => @server.url},
        root: File.join(@home, ".tart")
      )
      @managers << manager # register's channel stops with the manager
      spawner = foreground_spawn(manager, "ask the supervisor mid-run")

      request_path = wait_request_file(manager, "ROUND-TRIP-VALVE-ASK")
      run_id = run_id_for(request_path)
      reply = reply_path_for_request(request_path)
      wait_until { File.file?(reply) } # arrival asserted, no ms bet
      payload = JSON.parse(File.read(reply))
      assert_equal Subagents::Supervisor::REPLY_TYPE, payload["type"]
      assert_equal File.basename(request_path, ".json"), payload["requestId"]
      assert_equal "", payload["message"]
      assert_equal Subagents::Supervisor::BLOCKED_PARENT_ERROR, payload["error"]

      # The child's NEXT captured request carries the valve error as the
      # tool result — and never the timeout bytes.
      messages = []
      wait_until do
        @server.captured_requests.each { |request| messages.concat(request["messages"]) }
        messages.any? { |message| message["role"] == "tool" &&
          message["content"].to_s.include?("Supervisor unavailable") }
      end
      refute messages.any? { |message| message["role"] == "tool" &&
        message["content"].to_s.include?("Timed out waiting for supervisor reply") },
        "the child never rode the ask deadline"

      assert_equal :completed, wait_terminal(manager, run_id, 40)
      wait_until { !spawner.alive? } # the blocked spawn thread returned
      wait_until do
        row = manager.box_snapshot[:rows].find { |candidate| candidate[:id] == run_id }
        row && row[:attention] != true
      end
      refute File.file?(request_path), "the request file is gone"
    ensure
      Subagents.current_manager = saved_manager
    end

    # --- harness ---

    def fake_kernel
      kernel = Object.new
      kernel.define_singleton_method(:async) do |&block|
        (@calls ||= []) << block
        nil
      end
      kernel.define_singleton_method(:calls) { @calls ||= [] }
      kernel
    end

    def new_manager(**opts)
      manager = Subagents::Manager.new(cwd: @cwd, home: File.join(@home, "subagents"),
                                       env: default_env, identity: "pi", hooks: @hooks,
                                       kernel: @kernel, root: File.join(@home, ".tart"), **opts)
      @managers << manager
      manager
    end

    def default_env
      {"PATH" => ENV["PATH"], "HOME" => @home, "PI_API_KEY" => "test-key", "PI_API_BASE" => @server.url}
    end

    def new_channel(predicate: nil, owner: nil)
      channel = Subagents::SupervisorChannel.new(home: File.join(@home, "subagents"), hooks: @hooks,
                                                 kernel: @kernel, agent: nil,
                                                 owner_id: (owner && -> { owner }),
                                                 foreground_awaited: predicate)
      channel.start
      @channels << channel
      channel
    end

    # A synthetic disk-first run dir (the intercom family's fake_run shape).
    def fake_run(agent, state: "running")
      id = "01900000-0000-7000-8000-#{SecureRandom.hex(6)}"
      dir = File.join(@home, "subagents", id)
      FileUtils.mkdir_p([File.join(dir, "control", "supervisor-requests"),
                         File.join(dir, "control", "supervisor-replies")])
      Subagents::Supervisor.atomic_write_json(File.join(dir, "status.json"),
                                              {"id" => id, "agent" => agent, "state" => state})
      {id:, dir:, agent:, state: state.to_sym}
    end

    # The I99 staging shape (the full status key set + the optional stamp).
    # Real time anchors (the box family's write_status discipline): the
    # adopted record's activity label needs startedAt/lastUpdate to render
    # "no activity for <age>".
    def stage_run_dir(id, pid: nil, session_id: nil, state: "running")
      dir = File.join(@home, "subagents", id)
      FileUtils.mkdir_p([dir, File.join(dir, "control", "steer-requests"),
                         File.join(dir, "control", "stop-requests"),
                         File.join(dir, "control", "supervisor-requests"),
                         File.join(dir, "control", "supervisor-replies"),
                         File.join(dir, "sessions")])
      now = Subagents::Supervisor.now_ms
      payload = {"id" => id, "agent" => "worker", "task" => nil, "taskChars" => nil, "mode" => "single",
                 "state" => state, "pid" => pid, "cwd" => @cwd, "asyncDir" => dir,
                 "sessionRoot" => File.join(dir, "sessions"), "startedAt" => now,
                 "lastUpdate" => now + 30_000, "toolCallId" => nil}
      payload["sessionId"] = session_id if session_id
      File.write(File.join(dir, "status.json"), JSON.generate(payload))
      dir
    end

    # Returns the WRITTEN payload (pins read its createdAt/id back).
    def stage_ask(dir, run_id:, reason: "need_decision", message: "which way?", request_id: SecureRandom.uuid)
      payload = {type: Subagents::Supervisor::REQUEST_TYPE, id: request_id,
                 createdAt: Subagents::Supervisor.now_ms, reason:, message:,
                 expectsReply: true, runId: run_id, agent: "worker",
                 expiresAt: Subagents::Supervisor.now_ms + 60_000}
      path = File.join(dir, "control", "supervisor-requests", "#{request_id}.json")
      Subagents::Supervisor.atomic_write_json(path, payload)
      payload
    end

    def new_ctrl
      run_dir = File.join(@home, "synthetic-#{SecureRandom.uuid}")
      ctrl = File.join(run_dir, "control")
      FileUtils.mkdir_p([File.join(ctrl, "supervisor-requests"), File.join(ctrl, "supervisor-replies")])
      ctrl
    end

    def tool_for(ctrl, timeout_ms: nil, agent: "scout")
      env = {"PATH" => ENV["PATH"], "HOME" => @home,
             "PI_SUPERVISOR_CHANNEL" => ctrl, "PI_SUBAGENTS_AGENT" => agent}
      env["PI_INTERCOM_ASK_TIMEOUT_MS"] = timeout_ms if timeout_ms
      Tools::ContactSupervisor.new(cwd: @cwd, env: env, identity: "pi")
    end

    def foreground_spawn(manager, task)
      thread = Thread.new do
        Thread.current.report_on_exception = false
        manager.spawn_run(agent: "worker", task:, async: false, timeout_ms: 0, tool_timeout_ms: 0)
      end
      @threads << thread
      thread
    end

    def reply_path_for(run_dir, request_id)
      File.join(run_dir, "control", "supervisor-replies", "#{request_id}.json")
    end

    # The reply path derived from the REQUEST FILE's path: dirname×3 is the
    # run dir (the helper takes the run dir and joins control/ itself).
    def reply_path_for_request(request_path)
      reply_path_for(File.dirname(File.dirname(File.dirname(request_path))),
                     File.basename(request_path, ".json"))
    end

    def run_id_for(request_path)
      File.basename(File.dirname(File.dirname(File.dirname(request_path))))
    end

    def wait_request_file(manager, message)
      path = nil
      wait_until do
        path = Dir.glob(File.join(manager.home, "*", "control", "supervisor-requests", "*.json")).find do |candidate|
          JSON.parse(File.read(candidate))["message"] == message
        rescue JSON::ParserError, Errno::ENOENT
          false
        end
        path
      end
      path
    end

    def wait_surfaced(message)
      hit = nil
      wait_until do
        batch = @hooks.pending_next_turn
        hit = batch.find do |entry|
          entry[:custom_type] == Subagents::Supervisor::REQUEST_CUSTOM_TYPE &&
            entry[:content].to_s.include?(message)
        end
        hit
      end
      hit
    end

    def wait_terminal(manager, id, timeout = 25)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      record = nil
      while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        record = manager.runs.find { |candidate| candidate[:id] == id }
        break if record && record[:state] != :running

        sleep 0.1
      end
      flunk "run #{id} never settled: #{record && record[:state]}" unless record && record[:state] != :running
      record[:state]
    end

    # A REAL live pid the test owns (a pgroup leader, killed in teardown —
    # the ownership family's idiom).
    def live_pid
      pid = Process.spawn("sleep", "60", pgroup: true)
      Process.detach(pid)
      @spawns << pid
      sleep 0.05 # let it exec
      pid
    end

    # The TOCTOU stub idiom (the intercom family's Dir.singleton_class
    # shape) at the Supervisor write seat: raises for EVERY write while
    # installed so the failed-tick window is race-free; restore through
    # +restore_atomic_write+ in the pin's body and ensure.
    def stub_failing_atomic_write(attempts)
      Subagents::Supervisor.singleton_class.send(:alias_method, :ask_delivery_unstubbed_write, :atomic_write_json)
      Subagents::Supervisor.singleton_class.send(:define_method, :atomic_write_json) do |path, payload|
        attempts << path
        raise Errno::EIO, "stubbed valve write failure"
      end
    end

    def restore_atomic_write
      return unless Subagents::Supervisor.singleton_class.method_defined?(:ask_delivery_unstubbed_write)

      Subagents::Supervisor.singleton_class.send(:alias_method, :atomic_write_json, :ask_delivery_unstubbed_write)
      Subagents::Supervisor.singleton_class.send(:remove_method, :ask_delivery_unstubbed_write)
    end
  end
end
