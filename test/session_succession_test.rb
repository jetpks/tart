# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/mock_llm_server"
require "tmpdir"
require "fileutils"
require "json"

module Tart
  # The I101 session-succession pin battery: the un-collapsed consult and
  # the widened owner set (AC1), the fresh-start inherits-nothing posture
  # (AC2), the keep-work declaration (AC3), the registry bounds and the
  # back-and-forth laws (AC4), the consult discipline, and the live
  # end-to-end replacement. Hermetic: staged homes, real `bin/tart -p`
  # children on MockLLMServer, the duck-typed-loop swap idiom (the I99
  # pin-2 family), the wait_until discipline — ZERO live API calls.
  class SessionSuccessionTest < Test
    STAMP_A = "01aaa111-0000-7000-8000-00000000aaaa"
    STAMP_B = "01bbb222-0000-7000-8000-00000000bbbb"
    STAMP_C = "01ccc333-0000-7000-8000-00000000cccc"
    FOREIGN_STAMP = "01fff000-0000-7000-8000-00000000000f"

    def setup
      @server = MockLLMServer.new.start
      @home = Dir.mktmpdir("i101-succession-home-")
      @cwd = Dir.mktmpdir("i101-succession-cwd-")
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

    # --- pin 1 (AC1): the umbrella — the stamp follows the live recorder,
    # the swap widens ownership, the predecessor stays fully owned. ---

    def test_the_stamp_follows_the_live_recorder_and_the_swap_widens_ownership
      @server.script([{type: :stream, content: "predecessor answer"},
                      {type: :stream, content: "successor answer"},
                      {type: :stream, content: "spare"}])
      loop_a = duck_loop(STAMP_A)
      loop_b = duck_loop(STAMP_B)
      current = [loop_a]
      manager = new_manager(agent: -> { current.first })

      run_a = manager.spawn_run(agent: "worker", task: "predecessor run", async: true,
                               timeout_ms: 0, tool_timeout_ms: 0)
      @spawns << run_a[:pgid] if run_a[:pgid]
      assert_equal STAMP_A, status_stamp(run_a[:dir]), "the first spawn stamps the first recorder id"
      assert_equal STAMP_A, manager.session_owner_id

      # The predecessor run is steerable BEFORE the swap (follow_up queues
      # deterministically — no consumption bet).
      receipt = manager.steer(id: run_a[:id], message: "steer the predecessor", mode: "follow_up")
      assert_includes %i[delivered queued], receipt[:state]

      # The replacement (/new shape): swap the live loop.
      current[0] = loop_b
      assert_equal STAMP_B, manager.session_owner_id, "the owner follows the live recorder"
      assert_equal [STAMP_B, STAMP_A], manager.owner_session_ids, "the owner set is [successor, predecessor]"
      assert_equal [STAMP_A], manager.inherited_session_ids(STAMP_B)

      run_b = manager.spawn_run(agent: "worker", task: "successor run", async: true,
                               timeout_ms: 0, tool_timeout_ms: 0)
      @spawns << run_b[:pgid] if run_b[:pgid]
      assert_equal STAMP_B, status_stamp(run_b[:dir]), "the successor stamps its OWN recorder id"
      assert_equal STAMP_A, status_stamp(run_a[:dir]), "the predecessor stamp is never rewritten"

      ids = manager.runs.map { |record| record[:id] }
      assert_includes ids, run_a[:id]
      assert_includes ids, run_b[:id]
      row_ids = manager.box_snapshot.fetch(:rows).map { |row| row[:id] }
      assert_includes row_ids, run_a[:id], "the box carries the predecessor row"
      assert_includes row_ids, run_b[:id]

      # The predecessor stays stoppable; the stop settle preserves its stamp.
      assert_equal "Stop requested for async run #{run_a[:id]}.", manager.stop(id: run_a[:id])
      wait_owned_terminal(manager, run_a[:id])
      assert_equal "stopped", JSON.parse(File.read(File.join(run_a[:dir], "status.json")))["state"]
      assert_equal STAMP_A, status_stamp(run_a[:dir]), "the stop settle preserves the stamp"

      # The successor's result is readable through the successor.
      wait_owned_terminal(manager, run_b[:id])
      result = manager.result(id: run_b[:id])
      assert result, "the successor's result is readable"
      assert_equal true, result["success"]
    end

    # --- pin 2 (AC1): the predecessor's DISK runs stay owned after the
    # swap (fleet adoption + targeted admission; foreign stays refused). ---

    def test_predecessor_disk_runs_stay_owned_after_the_swap
      dir_a = stage_run("01aaa111-0000-7000-8000-000000000001", pid: live_pid, session_id: STAMP_A)
      dir_f = stage_run("01bbb222-0000-7000-8000-000000000002", pid: live_pid, session_id: FOREIGN_STAMP)
      bytes_a = File.read(File.join(dir_a, "status.json"))
      bytes_f = File.read(File.join(dir_f, "status.json"))

      current = [duck_loop(STAMP_A)]
      manager = new_manager(agent: -> { current.first })
      assert_equal STAMP_A, manager.session_owner_id

      current[0] = duck_loop(STAMP_B)
      assert_equal STAMP_B, manager.session_owner_id

      # The A-stamped dir is adopted through the fleet read (sweep_home).
      list = manager.status(id: nil)
      assert_includes list, "- 01aaa111-0000-7000-8000-000000000001 | running | single | worker"
      # Targeted admission serves it (adopted into the registry).
      assert_includes manager.status(id: "01aaa111-0000-7000-8000-000000000001"),
                      "Run: 01aaa111-0000-7000-8000-000000000001"
      assert_includes manager.runs.map { |record| record[:id] }, "01aaa111-0000-7000-8000-000000000001"

      # The FOREIGN-stamped dir stays invisible + refused (the pinned bytes).
      refute_includes list, "01bbb222-0000-7000-8000-000000000002"
      error = assert_raises(ArgumentError) { manager.status(id: "01bbb222-0000-7000-8000-000000000002") }
      assert_equal "unknown subagent run \"01bbb222-0000-7000-8000-000000000002\". " \
                   "Active runs: 01aaa111-0000-7000-8000-000000000001.", error.message
      assert_nil manager.result(id: "01bbb222-0000-7000-8000-000000000002")

      # No disk write to either dir.
      assert_equal bytes_a, File.read(File.join(dir_a, "status.json"))
      assert_equal bytes_f, File.read(File.join(dir_f, "status.json"))
      [dir_a, dir_f].each do |dir|
        assert_empty Dir.children(File.join(dir, "control", "steer-requests")), dir
        assert_empty Dir.children(File.join(dir, "control", "stop-requests")), dir
        refute File.file?(File.join(dir, "result.json")), dir
      end
    end

    # --- pin 3 (AC1/D6): the predecessor's asks stay owned through the
    # channel (the register-shaped resolver; the foreign ask never). ---

    def test_predecessor_asks_stay_owned_through_the_channel
      rid_a = "11111111-1111-4111-8111-111111111111"
      rid_f = "22222222-2222-4222-8222-222222222222"
      dir_a = stage_run("01aaa111-0000-7000-8000-000000000003", pid: live_pid, session_id: STAMP_A)
      dir_f = stage_run("01bbb222-0000-7000-8000-000000000004", pid: live_pid, session_id: FOREIGN_STAMP)
      stage_ask(dir_a, rid_a, run_id: "01aaa111-0000-7000-8000-000000000003")
      stage_ask(dir_f, rid_f, run_id: "01bbb222-0000-7000-8000-000000000004")
      foreign_path = File.join(dir_f, "control", "supervisor-requests", "#{rid_f}.json")

      current = [duck_loop(STAMP_A)]
      manager = new_manager(agent: -> { current.first })
      manager.session_owner_id

      current[0] = duck_loop(STAMP_B)
      manager.session_owner_id # the replacement is recorded at the consult

      channel = Subagents::SupervisorChannel.new(home: File.join(@home, "subagents"), hooks: @hooks,
                                                 kernel: nil, agent: nil,
                                                 owner_id: -> { manager.owner_session_ids })
      @channels << channel
      channel.start
      wait_until { !channel.pending.empty? }

      # The inherited ask registered + surfaced, EXACTLY once; the foreign
      # ask never.
      assert_equal [rid_a], channel.pending.map { |request| request[:id] }
      drained = @hooks.pending_next_turn
      assert_equal 1, drained.size
      assert_equal Subagents::Supervisor::REQUEST_CUSTOM_TYPE, drained.first[:custom_type]
      assert_equal true, drained.first[:display]
      assert_includes drained.first[:content], rid_a

      # The foreign ask is still on disk (never registered or unlinked) and
      # the reply fallback refuses its id.
      assert File.file?(foreign_path), "the foreign ask was never unlinked"
      error = assert_raises(ArgumentError) { channel.reply(reply_to: rid_f, message: "nope") }
      assert_includes error.message, "No pending supervisor request found for reply_to '#{rid_f}'"
      assert File.file?(foreign_path), "the refused reply never removed the foreign file"

      # The inherited ask is fully serviceable: reply lands, the file unlinks.
      assert_equal "Replied to supervisor request #{rid_a}.",
                   channel.reply(reply_to: rid_a, message: "inherited answer")
      refute File.file?(File.join(dir_a, "control", "supervisor-requests", "#{rid_a}.json"))
      assert File.file?(File.join(dir_a, "control", "supervisor-replies", "#{rid_a}.json"))
    end

    # --- pin 4 (AC2): a fresh manager (a whole predecessor PROCESS's
    # output) inherits nothing — the I99 D7 posture against succession
    # stamps too. ---

    def test_a_fresh_manager_inherits_nothing
      dir_a = stage_run("01aaa111-0000-7000-8000-000000000005", pid: live_pid, session_id: STAMP_A)
      dir_b = stage_run("01bbb222-0000-7000-8000-000000000006", pid: live_pid, session_id: STAMP_B)
      dir_u = stage_run("01ccc333-0000-7000-8000-000000000007", pid: live_pid)
      bytes = [dir_a, dir_b, dir_u].map { |dir| [dir, File.read(File.join(dir, "status.json"))] }.to_h

      # A fresh manager with a FRESH recorder id: A-stamped, B-stamped, and
      # unstamped dirs are all foreign.
      manager = new_manager(agent: -> { duck_loop(STAMP_C) })
      assert_equal STAMP_C, manager.session_owner_id

      assert_equal Subagents::Manager::FLEET_EMPTY_LINE, manager.status(id: nil), "the fleet is byte-exact empty"
      assert_empty manager.box_snapshot.fetch(:rows), "the box renders nothing foreign"
      assert_empty manager.runs, "no record, no adoption"
      %w[01aaa111-0000-7000-8000-000000000005
         01bbb222-0000-7000-8000-000000000006
         01ccc333-0000-7000-8000-000000000007].each do |id|
        error = assert_raises(ArgumentError) { manager.status(id: id) }
        assert_equal "unknown subagent run \"#{id}\". Active runs: (none).", error.message
        assert_nil manager.result(id: id)
      end

      # Every dir byte-identical after: no status/control/result write.
      bytes.each do |dir, content|
        assert_equal content, File.read(File.join(dir, "status.json")), dir
        assert_empty Dir.children(File.join(dir, "control", "steer-requests")), dir
        assert_empty Dir.children(File.join(dir, "control", "stop-requests")), dir
        assert_empty Dir.children(File.join(dir, "control", "supervisor-requests")), dir
        refute File.file?(File.join(dir, "result.json")), dir
      end
    end

    # --- pin 5 (AC3): the keep-work declaration — a keep-marked
    # replacement inherits NOTHING (records pruned, asks dropped). ---

    def test_keep_work_declaration_inherits_nothing
      @server.script([{type: :stream, content: "kept run"},
                      {type: :stream, content: "successor keeps working"},
                      {type: :stream, content: "spare"}])
      current = [duck_loop(STAMP_A)]
      manager = new_manager(agent: -> { current.first })
      run_a = manager.spawn_run(agent: "worker", task: "kept run", async: true, timeout_ms: 0, tool_timeout_ms: 0)
      @spawns << run_a[:pgid] if run_a[:pgid]
      assert_equal STAMP_A, manager.session_owner_id

      # The REAL drop path: an ask on the SPAWNED (A-stamped) run dir,
      # registered through the register-shaped channel while owned.
      rid_own = "44444444-4444-4444-8444-444444444444"
      stage_ask(run_a[:dir], rid_own, run_id: run_a[:id])
      channel = Subagents::SupervisorChannel.new(home: File.join(@home, "subagents"), hooks: @hooks,
                                                 kernel: nil, agent: nil,
                                                 owner_id: -> { manager.owner_session_ids })
      manager.supervisor_channel = channel
      @channels << channel
      channel.start
      wait_until { !channel.pending.empty? }

      # The /leave-work mark on the CURRENT session, then the replacement.
      manager.keep_session_work(manager.session_owner_id)
      current[0] = duck_loop(STAMP_B)
      assert_equal STAMP_B, manager.session_owner_id
      assert_equal [STAMP_B], manager.owner_session_ids, "the kept session rides no chain"

      # The spawned run's pending ask is DROPPED (never answered); its file
      # stays on disk.
      wait_until { channel.pending.empty? }
      error = assert_raises(ArgumentError) { channel.reply(reply_to: rid_own, message: "late") }
      assert_includes error.message, "No pending supervisor request found for reply_to '#{rid_own}'"
      assert File.file?(File.join(run_a[:dir], "control", "supervisor-requests", "#{rid_own}.json")),
             "the dropped ask's file stays on disk, never answered"

      # The predecessor's records are PRUNED from every surface.
      assert_empty manager.runs
      assert_empty manager.box_snapshot.fetch(:rows)

      # A STAGED A-stamped dir (predecessor-process output) is invisible +
      # refused, and its ask is neither surfaced nor answerable: after the
      # swap the widened guard refuses it on every tick.
      dir_a = stage_run("01aaa111-0000-7000-8000-000000000008", pid: live_pid, session_id: STAMP_A)
      rid_staged = "33333333-3333-4333-8333-333333333333"
      stage_ask(dir_a, rid_staged, run_id: "01aaa111-0000-7000-8000-000000000008")
      bytes_a = File.read(File.join(dir_a, "status.json"))
      sleep(Subagents::Supervisor::POLL_INTERVAL * 4) # let several ticks run
      assert_empty channel.pending, "the staged ask never registers after the swap"
      error = assert_raises(ArgumentError) { channel.reply(reply_to: rid_staged, message: "nope") }
      assert_includes error.message, "No pending supervisor request found for reply_to '#{rid_staged}'"
      assert File.file?(File.join(dir_a, "control", "supervisor-requests", "#{rid_staged}.json")),
             "the refused staged ask's file is never removed"

      list = manager.status(id: nil)
      refute_includes list, "01aaa111-0000-7000-8000-000000000008"
      error = assert_raises(ArgumentError) { manager.status(id: "01aaa111-0000-7000-8000-000000000008") }
      assert_equal "unknown subagent run \"01aaa111-0000-7000-8000-000000000008\". Active runs: (none).", error.message

      # The declared session's disk bytes are never written again.
      assert_equal bytes_a, File.read(File.join(dir_a, "status.json"))

      # The successor's own spawn stamps B and stays owned.
      run_b = manager.spawn_run(agent: "worker", task: "successor run", async: true,
                               timeout_ms: 0, tool_timeout_ms: 0)
      @spawns << run_b[:pgid] if run_b[:pgid]
      assert_equal STAMP_B, status_stamp(run_b[:dir])
      assert_includes manager.runs.map { |record| record[:id] }, run_b[:id]
    end

    # --- pin 6 (AC3/D4/L5): /leave-work registers through the hooks seam;
    # invoking the handler marks the CURRENT session; builtins untouched. ---

    def test_leave_work_is_registered_through_the_hooks_seam
      reg_hooks = Hooks.new
      manager = Subagents.register(hooks: reg_hooks, cwd: @cwd, home: File.join(@home, "reg"),
                                   env: default_env, identity: "pi", root: File.join(@home, "root"))
      @managers << manager
      row = reg_hooks.registered_commands.find { |command| command[:name] == "leave-work" }
      assert row, "/leave-work is registered"
      assert_equal "Leave this session's subagent work behind on the next /new or /resume", row[:description]
      assert_equal false, row[:args]
      refute Commands::BUILTINS.key?("leave-work"), "registered commands never shadow a builtin"

      # Invoking the handler marks the CURRENT session: a subsequent
      # replacement then inherits nothing (the pin-5 shape, through the
      # real registered handler on a Manager/agent pair).
      loop_a = duck_loop(STAMP_A)
      loop_b = duck_loop(STAMP_B)
      current = [loop_a]
      pair_hooks = Hooks.new
      pair = Subagents.register(hooks: pair_hooks, cwd: @cwd, home: File.join(@home, "pair"),
                                env: default_env, identity: "pi", root: File.join(@home, "root"),
                                agent: -> { current.first })
      @managers << pair
      assert_equal STAMP_A, pair.session_owner_id
      handler = pair_hooks.command_handler("leave-work")
      assert handler, "the dispatch table carries the handler"
      handler.call("")
      current[0] = loop_b
      assert_equal STAMP_B, pair.session_owner_id
      assert_equal [STAMP_B], pair.owner_session_ids, "the marked session's replacement inherits nothing"
      assert_empty pair.runs, "the marked session's records pruned"
    end

    # --- pin 7 (AC4): the chain bound, the registry cap, the kept cap. ---

    def test_chain_bounds_and_registry_caps
      succ = ->(i) { format("01s%05d-0000-7000-8000-%012d", i, i) }

      # Ten successive replacements: the last inherits EXACTLY the 8 newest
      # predecessors, newest first (MAX_INHERITED_SESSIONS).
      chained = new_manager
      (2..11).each { |i| chained.record_session_replacement(succ.(i), succ.(i - 1)) }
      assert_equal 8, chained.inherited_session_ids(succ.(11)).size
      assert_equal [10, 9, 8, 7, 6, 5, 4, 3].map { |i| succ.(i) },
                   chained.inherited_session_ids(succ.(11)), "the 8 newest predecessors, newest first"

      # The registry cap (MAX_RECORDED_SESSIONS): 65 recorded sessions
      # FIFO-evict the oldest key — the first-recorded session's own chain
      # is gone, so it no longer widens anyone.
      capped = new_manager
      (2..66).each { |i| capped.record_session_replacement(succ.(100 + i), succ.(100 + i - 1)) }
      assert_empty capped.inherited_session_ids(succ.(102)),
                   "the oldest recorded session's chain was evicted"
      assert_equal 8, capped.inherited_session_ids(succ.(166)).size
      final_id = succ.(300)
      capped.record_session_replacement(final_id, succ.(102))
      assert_equal [succ.(102)], capped.inherited_session_ids(final_id),
                   "the evicted root contributes no chain"

      # The kept set caps at 64: the oldest mark no longer suppresses
      # inheritance; a live kept mark still does.
      keeper = new_manager
      keys = (1..65).map { |i| succ.(400 + i) }
      keys.each { |id| keeper.keep_session_work(id) }
      x = succ.(600)
      y = succ.(601)
      keeper.record_session_replacement(x, keys[0])
      assert_equal [keys[0]], keeper.inherited_session_ids(x),
                   "the evicted oldest mark no longer suppresses inheritance"
      keeper.record_session_replacement(y, keys[1])
      assert_empty keeper.inherited_session_ids(y), "a live kept mark suppresses inheritance"
    end

    # --- pin 8 (AC4): the back-and-forth de-dup + live-again + startup
    # laws (pi's two-call law, verbatim sequence). ---

    def test_back_and_forth_dedup_and_live_again_laws
      a = "01a00000-0000-7000-8000-00000000000a"
      b = "01b00000-0000-7000-8000-00000000000b"
      root = "01r00000-0000-7000-8000-00000000000r"
      c = "01c00000-0000-7000-8000-00000000000c"

      manager = new_manager
      # The pi two-call law: B replaces A; A is live again (a non-startup
      # start); A replaces B back.
      manager.record_session_replacement(b, a)
      manager.record_session_start(a, startup: false)
      manager.record_session_replacement(a, b)
      assert_equal [b], manager.inherited_session_ids(a),
                   "the chain is free of the session itself (the de-dup law)"
      assert_empty manager.inherited_session_ids(b),
                   "the live-again arm removed A from B's chain"

      # The pure de-dup arm: without the live-again start, the back-swap
      # still drops the successor from its own chain.
      fresh = new_manager
      fresh.record_session_replacement(b, a)
      fresh.record_session_replacement(a, b)
      assert_equal [b], fresh.inherited_session_ids(a)
      assert_equal [a], fresh.inherited_session_ids(b)

      # startup: true clears the session's own chain AND its kept mark;
      # afterwards a replacement of that session inherits as usual.
      kept = new_manager
      kept.record_session_replacement(a, root) # A has an own chain
      kept.keep_session_work(a)
      kept.record_session_replacement(b, a)
      assert_empty kept.inherited_session_ids(b), "a kept predecessor inherits nothing"
      kept.record_session_start(a, startup: true)
      assert_empty kept.inherited_session_ids(a), "the startup cleared A's own chain"
      kept.record_session_replacement(c, a)
      assert_equal [a], kept.inherited_session_ids(c),
                   "the kept mark was spent by the startup: a replacement of A inherits as usual"
    end

    # --- pin 9 (AC2/D2/D6): the consult discipline — boot mints, raising
    # callables, stable windows, raising resolvers. ---

    def test_the_consult_discipline
      # Agent-less: the boot mint is stable, the owner set is [boot].
      bare = new_manager
      boot = bare.session_owner_id
      assert_instance_of String, boot
      refute_empty boot
      assert_equal boot, bare.session_owner_id, "stable within one Manager's life"
      assert_equal [boot], bare.owner_session_ids
      assert_empty bare.inherited_session_ids(boot)

      # A raising agent callable: the consult returns the boot mint and
      # NEVER raises (the parent_session_id rescue).
      raising = new_manager(agent: -> { raise "consult boom" })
      boot2 = raising.session_owner_id
      assert_instance_of String, boot2
      assert_equal boot2, raising.session_owner_id
      assert_equal [boot2], raising.owner_session_ids

      # Repeated consults within one window record nothing.
      stable = new_manager(agent: -> { duck_loop(STAMP_A) })
      id = stable.session_owner_id
      3.times { assert_equal id, stable.session_owner_id }
      assert_equal [id], stable.owner_session_ids
      assert_empty stable.inherited_session_ids(id), "a stable window records no chain"

      # The channel: a raising owner resolver reads FALSE — the ask never
      # registers across several poll ticks and the poll machinery stays
      # healthy (never a spin, never a raise into the loop).
      dir = stage_run("01aaa111-0000-7000-8000-000000000009", pid: live_pid, session_id: STAMP_A)
      rid = "55555555-5555-4555-8555-555555555555"
      stage_ask(dir, rid, run_id: "01aaa111-0000-7000-8000-000000000009")
      ask_path = File.join(dir, "control", "supervisor-requests", "#{rid}.json")
      channel = Subagents::SupervisorChannel.new(home: File.join(@home, "subagents"), hooks: @hooks,
                                                 kernel: nil, agent: nil,
                                                 owner_id: -> { raise "owner boom" })
      @channels << channel
      channel.start
      sleep(Subagents::Supervisor::POLL_INTERVAL * 4) # let several ticks run
      assert_empty channel.pending, "a raising consult reads false: the ask never registers"
      assert File.file?(ask_path), "the ask file is untouched"
      channel.stop
      channel.start # the poll machinery survives the raising ticks
      channel.stop
    end

    # --- pin 10 (AC1): the live end-to-end replacement — a real child
    # completes ACROSS a mid-flight swap; the successor sees everything. ---

    def test_the_in_process_replacement_end_to_end
      @server.script([{type: :stream, content: "mid-flight answer"},
                      {type: :stream, content: "spare"}])
      current = [duck_loop(STAMP_A)]
      manager = new_manager(agent: -> { current.first })

      run_a = manager.spawn_run(agent: "worker", task: "mid-flight", async: true,
                               timeout_ms: 0, tool_timeout_ms: 0)
      @spawns << run_a[:pgid] if run_a[:pgid]
      assert_equal STAMP_A, manager.session_owner_id

      # The swap while the child runs.
      current[0] = duck_loop(STAMP_B)
      assert_equal STAMP_B, manager.session_owner_id

      wait_owned_terminal(manager, run_a[:id])
      row = manager.box_snapshot.fetch(:rows).find { |candidate| candidate[:id] == run_a[:id] }
      assert row, "the successor's box shows the completed row"
      assert_equal "completed", row[:state]

      pending = @hooks.pending_next_turn
      assert_equal 1, pending.size, "exactly one completion notification"
      assert_equal Subagents::NOTIFY_CUSTOM_TYPE, pending.first[:custom_type]
      assert_equal "mid-flight answer", manager.result(id: run_a[:id])["output"]
    end

    # --- helpers (the ownership family's discipline) ---

    def new_manager(**opts)
      manager = Subagents::Manager.new(cwd: @cwd, home: File.join(@home, "subagents"), env: default_env,
                                       identity: "pi", hooks: @hooks, **opts)
      @managers << manager
      manager
    end

    def default_env
      {"PATH" => ENV["PATH"], "HOME" => @home, "PI_API_KEY" => "test-key", "PI_API_BASE" => @server.url}
    end

    # The duck-typed loop + recorder pair (the I99 pin-2 swap idiom).
    def duck_loop(id)
      recorder = Struct.new(:id, :path).new(id, "/x/#{id}.jsonl")
      Struct.new(:recorder).new(recorder)
    end

    def status_stamp(dir)
      JSON.parse(File.read(File.join(dir, "status.json")))["sessionId"]
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
