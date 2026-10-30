# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/mock_llm_server"
require "open3"
require "tmpdir"
require "fileutils"
require "json"
require "rbconfig"
require "shellwords" # I42's require — the root-ladder backtick uses String#shellescape (judge-applied at integration: the lane dropped it; standalone runs lack rake's transitive load)

module Tart
  # The I48 subagents e2e instrument (four legs over AC2/AC3/AC4): tart's
  # delegation core end-to-end — REAL `bin/tart -p` parent subprocesses
  # against the MockLLMServer where the parent process is the subject
  # (leg A foreground delegation, leg B async + the print-parent drain),
  # and the parent-side Manager API driven in-process where a parent
  # subprocess adds nothing (leg C steer-reach, leg D stop + deadline).
  #
  # I42 discipline throughout (test/e2e_session_test.rb is the template):
  # a fresh staged HOME per leg (the owner's ~/.tart is never written), a
  # CLOSED subprocess env via unsetenv_others, the printed [i48-e2e]
  # staging lines the gate greps, and full teardown (manager shutdown,
  # stray-child sweep, server stop, dirs removed). The opt-in gate rides
  # staged settings {"subagents": true} (OQ-1) and the run dirs stage under
  # <IDENTITY>_SUBAGENTS_HOME (OQ-2).
  #
  # The machinery (lib/tart/subagents.rb and friends) is the CORE lane's;
  # this file is RED at base by design — every leg's first frozen-surface
  # touch is Tart::Subagents.home, so at base each leg fails with the
  # declared NameError — and must be GREEN on the integrated tree.
  #
  # Stream pacing: MockLLMServer#slow_stream inserts a real inter-chunk
  # pause per character (spec_pause is a fixed 0.1s on this tree;
  # chunk_every is advisory). Every window below is sized with ≥3× margin
  # at the observed pace, so an implementation that one day honors
  # chunk_every can only shorten a stream, never open it past a bound.
  class SubagentsE2ETest < Test
    REPO_ROOT = File.expand_path("#{__dir__}/..")

    # A watchdogged parent run must never hang the battery (a broken
    # integrated-tree drain, say, fails the leg instead).
    PARENT_DEADLINE_S = 180

    # The routed-model pin (Specification §4: the routing pair rides the
    # child env): a distinctive staged PI_MODEL — both the parent's and the
    # child's wire `model` field must equal it.
    ROUTED_MODEL = "accounts/fireworks/models/glm-e2e-routed"

    # --- Leg A: foreground delegation end-to-end.
    A_PROMPT = "e2e leg A: delegate the check to a worker and report"
    A_CHILD_TASK = "e2e child task: report the leg A answer"
    A_CHILD_ANSWER = "leg A child answer: delegation works"
    A_FINAL = "leg A parent final: the child answered"

    # --- Leg B: async delegation + the print-parent drain.
    B_PROMPT = "e2e leg B: delegate this to a worker in the background"
    B_CHILD_TASK = "e2e child task: work on this slowly for leg B"
    B_CHILD_SLOW = "leg B child answer streamed slowly" # 34 chars ≈ 3.4s at 0.1s/char
    B_FINAL = "leg B parent final: returned before the child finished"

    # --- Leg C: steer-reach into a running child.
    C_TASK = "e2e child task: stream slowly then answer for leg C"
    C_LONG = "leg C child first turn streamed slowly to hold the steer window open" # ≈ 6.9s window
    C_STEER = "STEER-E2E-MARKER: switch focus to the steering test"
    C_STEERED_ANSWER = "leg C child answer after steering"

    # --- Leg D: stop mid-stream + the run deadline.
    D_STOP_TASK = "e2e child task: stream until stopped for leg D"
    D_STOP_STREAM = "stop target streaming until stopped" # ≈ 3.5s window, inside stop's 5s grace
    D_DEADLINE_TASK = "e2e child task: stream until the deadline fires for leg D"
    D_DEADLINE_STREAM = "deadline target streaming until the deadline fires" # ≈ 5s ≫ the 1.5s deadline

    def setup
      @server = MockLLMServer.new.start
      @home = Dir.mktmpdir("i48-e2e-home-")
      @manager = nil
      @captures = []
      @pending_notifications = []
      puts "[i48-e2e] staged HOME: #{@home}"
      puts "[i48-e2e] mock server: #{@server.url}"
    end

    def teardown
      # In-process legs first: shutdown stops any straggler run BEFORE the
      # server socket dies, so teardown never manufactures a run failure.
      begin
        @manager&.shutdown
      rescue StandardError
        nil
      end
      kill_stray_children
      @server&.stop
      FileUtils.rm_rf(@home) if @home && File.directory?(@home)
    end

    # Leg A (AC2 foreground + AC4 hermeticity): a real parent print run —
    # subagents ON via staged settings — whose scripted model calls the
    # subagent tool async:false. The CHILD is a real print subprocess
    # against the same server; its output must ride back verbatim as the
    # tool result in the parent's SECOND captured request, and the run
    # artifacts (status/result/session) must sit under the staged
    # <IDENTITY>_SUBAGENTS_HOME. Capture order is deterministic here: the
    # foreground parent BLOCKS the child through request 2.
    def test_leg_a_foreground_delegation_end_to_end
      stage_subagents_home
      stage_home
      @server.script([
        {type: :stream, tool_calls: [{id: "c1", name: "subagent",
                                      arguments: {agent: "worker", task: A_CHILD_TASK, async: false}}]},
        {type: :stream, content: A_CHILD_ANSWER},
        {type: :stream, content: A_FINAL}
      ])

      stdout, stderr, status = tart_sub(A_PROMPT)
      assert_equal 0, status.exitstatus, "leg A parent exits 0 (stderr: #{stderr})"
      assert_includes stdout, A_FINAL, "the parent's final response lands on stdout"

      drain_captures
      assert_equal 3, @captures.size, "parent request, child request, parent tool-result turn"
      parent_req, child_req, parent_req2 = @captures
      assert parent_req["tools"].to_a.any? { |t| t.dig("function", "name") == "subagent" },
        "the opt-in gate puts the subagent tool on the parent wire"
      assert_equal ROUTED_MODEL, parent_req["model"], "the parent boots the staged routed model"
      assert_equal ROUTED_MODEL, child_req["model"], "the child rides the routed model (Specification §4)"
      assert_includes child_req["messages"].last["content"].to_s, A_CHILD_TASK,
        "the child request carries the delegated task"

      tool_result = tool_message(parent_req2, "c1")
      assert_includes tool_result, A_CHILD_ANSWER, "the child's output is the parent's tool result"
      assert_equal A_CHILD_ANSWER, tool_result.strip,
        "the foreground result is the child's final text (stdout bytes, §7)"

      # One run dir under the staged home, completed, with the result file.
      run_dir = the_only_run_dir
      sj = status_json(run_dir)
      assert_equal "completed", sj["state"]
      assert_equal false, sj.fetch("timedOut", nil), "a completed run never sets timedOut"
      # I81 Law 3 re-pin (declared in the lane prompt as a behavior-
      # contradicting pin inside the touch set): the RAW task now rides
      # status.json verbatim.
      assert_equal A_CHILD_TASK, sj["task"], "the spawn's raw task is on disk verbatim"
      rj = result_json(run_dir)
      assert_equal true, rj["success"]
      assert_equal A_CHILD_ANSWER, rj["output"].to_s.strip

      sessions = Dir.glob(File.join(run_dir, "sessions", "**", "*.jsonl"))
      assert_equal 1, sessions.size, "the child records its session under the run dir"
      puts "[i48-e2e] leg A: exit 0, child output rode the tool result, run #{File.basename(run_dir)} completed"
    end

    # Leg B (AC2 async + drain): the parent delegates async:true — the
    # `Async: <agent> [<id>]` start message rides the parent's tool result
    # — its own turn completes while the child slow-streams, and the parent
    # PROCESS waits (the print drain) long enough to record the
    # subagent-notify custom_message on its session before exit 0.
    def test_leg_b_async_delegation_and_print_drain
      stage_subagents_home
      stage_home
      # I87 Law 2 (kill the arrival-order bet): each response routes by
      # REQUEST CONTENT, not arrival order — the parent's tool-result turn
      # is identified by the c1 tool message, the child's first request by
      # the delegated task text, the parent's opening turn by the leg
      # prompt. At base the script shifted blindly and bet the child's
      # ~350ms interpreter boot loses to the parent's instant tool-result
      # turn; under sustained 8-way load the boot starves, the order
      # flips, and the stdout pin inverts (the measured class-(f) firing).
      # Every response below is byte-identical to the old order-shifted
      # script; only the ROUTING is deterministic now.
      @server.script([
        {type: :stream, tool_calls: [{id: "c1", name: "subagent",
                                      arguments: {agent: "worker", task: B_CHILD_TASK, async: true}}],
         match: ->(req) { req["messages"].to_a.any? { |m| m["role"] == "user" && m["content"].to_s.include?(B_PROMPT) } }},
        {type: :stream, content: B_FINAL,
         match: ->(req) { req["messages"].to_a.any? { |m| m["role"] == "tool" && m["tool_call_id"] == "c1" } }},
        {type: :slow_stream, content: B_CHILD_SLOW, chunk_every: 0.05,
         match: ->(req) { req["messages"].to_a.any? { |m| m["role"] == "user" && m["content"].to_s.include?(B_CHILD_TASK) } }}
      ])

      stdout, stderr, status = tart_sub(B_PROMPT)
      assert_equal 0, status.exitstatus, "leg B parent exits 0 (stderr: #{stderr})"
      assert_equal B_FINAL, stdout.strip, "the drain adds no extra stdout (OQ-4)"

      drain_captures
      parent_req2 = @captures.find do |r|
        r["messages"].to_a.any? { |m| m["role"] == "tool" && m["tool_call_id"] == "c1" }
      end
      assert parent_req2, "the parent's tool-result turn was captured"
      start_message = tool_message(parent_req2, "c1")
      assert start_message.start_with?("Async: worker ["),
        "the §7 async start headline rides the tool result: #{start_message[0, 80].inspect}"
      run_id = start_message[/\[([0-9a-f-]{36})\]/, 1]
      assert run_id, "the start message names the run id"
      assert_equal "7", run_id[14], "run ids are uuidv7 (OQ-3)"
      assert_includes start_message, "native completion wakes you", "the §7 guidance line"
      assert_includes start_message, 'subagent({ action: "status"', "the one-shot status check line"

      child_req = @captures.find do |r|
        r["messages"].to_a.any? { |m| m["role"] == "user" && m["content"].to_s.include?(B_CHILD_TASK) }
      end
      assert child_req, "the async child's request was captured"
      assert_equal ROUTED_MODEL, child_req["model"], "the async child rides the routed model too"
      assert_equal [run_id], Dir.children(@subagents_home).sort, "one run dir under the staged home"

      # The drain's products: the notification closes the parent's session
      # file (no model turn recorded it), and the child settled completed
      # on disk while the parent waited for it.
      files = session_files
      assert_equal 1, files.size, "exactly one parent session under the staged HOME"
      entries = Agent::Session.load_entries(files.first)
      notice = entries.last
      assert_equal "custom_message", notice["type"], "session tail: #{entries.last(2).map { |e| e["type"] }.inspect}"
      assert_equal "subagent-notify", notice["customType"]
      assert notice["content"].start_with?("Background task completed: **worker**"),
        "the §7 header bytes: #{notice["content"][0, 60].inspect}"
      assert_includes notice["content"], "Session file: "
      assert_includes notice["content"], "Run dir: "
      assert_includes notice["content"], run_id
      assert_equal false, notice["display"], "completed notices are model-visible only (§2.6 display rule)"

      run_dir = File.join(@subagents_home, run_id)
      assert_equal "completed", status_json(run_dir)["state"]
      assert_equal 1, Dir.glob(File.join(run_dir, "sessions", "**", "*.jsonl")).size
      puts "[i48-e2e] leg B: exit 0, drain held past the final print, run #{run_id} completed"
    end

    # Leg C (AC3 steer, the T1 pin): the test IS the parent — an in-process
    # Manager + Hooks, no parent subprocess. Spawn async through the
    # dispatch surface (async defaults TRUE), steer mid-stream, and pin the
    # correlated-consumption receipt: delivered ONLY for the child's own
    # steer-log entry naming the minted request id, with the steer text
    # reaching the child's NEXT captured request as a user message.
    def test_leg_c_steer_reaches_a_running_child
      home = stage_subagents_home
      @server.script([
        {type: :slow_stream, content: C_LONG, chunk_every: 0.05},
        {type: :stream, content: C_STEERED_ANSWER}
      ])
      @hooks = Hooks.new
      @manager = Tart::Subagents::Manager.new(cwd: REPO_ROOT, home: home, env: child_env,
        identity: "pi", hooks: @hooks)

      # The builtin table the spawn resolves (§1/§6); the worker's
      # allowlist order is the wire order (I41).
      agents = Tart::Subagents::BUILTIN_AGENTS
      assert_equal %w[oracle reviewer worker], agents.keys.sort
      assert_equal %w[read grep find ls bash edit write], agents["worker"][:tools]

      tool = Tart::Tools::Subagent.new(manager: @manager)
      start = tool.execute(agent: "worker", task: C_TASK, timeout_ms: 0).to_s
      run = @manager.runs.first
      assert run, "the dispatch registered the run"
      id = run[:id]
      assert_equal "Async: worker [#{id}]", start.split("\n").first,
        "the dispatch returns the §7 start message (async defaults true)"

      # The child's first request proves it is mid-turn; the slow stream
      # holds the turn open for the steer to land and wait at the boundary.
      wait_for_captures(15, "the child's first request") { child_requests(C_TASK).size == 1 }
      assert_equal :running, @manager.runs.first[:state]

      receipt = @manager.steer(id: id, message: C_STEER, mode: "steer", ack_timeout_ms: 30_000)
      assert_equal :delivered, receipt[:state],
        "the receipt reports the child's correlated consumption: #{receipt.inspect}"
      assert_equal 36, receipt[:request_id].to_s.length
      assert_equal "Steering delivered to async run #{id} (request #{receipt[:request_id]}).",
        receipt[:text], "the §7 steer receipt bytes"

      log = File.readlines(File.join(run[:dir], "control", "steer-log.jsonl")).map { |l| JSON.parse(l) }
      assert log.any? { |e| e["requestId"] == receipt[:request_id] },
        "the child's steer log names the SAME request id (T1)"

      wait_until_bounded(25, "the steered run to complete") { !@manager.outstanding? }
      assert_equal :completed, @manager.runs.first[:state]
      drain_captures
      steered = @captures.find do |r|
        r["messages"].to_a.any? { |m| m["role"] == "user" && m["content"].to_s.include?(C_STEER) }
      end
      assert steered, "the steer text rode a captured child request"
      first_child = child_requests(C_TASK).first
      assert first_child, "the child's first request was captured"
      refute first_child["messages"].to_a.any? { |m| m["role"] == "user" && m["content"].to_s.include?(C_STEER) },
        "the steer was NOT folded into the first request"
      assert_operator @captures.index(steered), :>, @captures.index(first_child),
        "the steer reached the child's NEXT request, not the first"
      assert_equal C_STEERED_ANSWER, result_json(run[:dir])["output"].to_s.strip
      assert_equal "completed", status_json(run[:dir])["state"]

      # The completion notification queued on the hooks — the in-process
      # seam the print drain records from (§2.6).
      notify = wait_until_bounded(10, "the subagent-notify notification") do
        @pending_notifications.concat(@hooks.pending_next_turn)
        @pending_notifications.find { |p| p[:custom_type] == "subagent-notify" }
      end
      assert notify[:content].start_with?("Background task completed: **worker**"),
        "the §7 notification header through the real watcher"
      assert_ps_clean(@manager.runs.first[:pid])
      puts "[i48-e2e] leg C: steer delivered (request #{receipt[:request_id]}), child steered + completed"
    end

    # Leg D (AC3 stop/T3 + AC4 deadline/T2): (1) stop mid-stream — the §7
    # receipt, stopped with timedOut false, and NO zombie (ps -p empty —
    # Process.detach owns the reap); (2) a 1500ms run deadline — stopped
    # with timedOut true inside the ~15s bound.
    def test_leg_d_stop_and_run_deadline
      home = stage_subagents_home
      @hooks = Hooks.new
      @manager = Tart::Subagents::Manager.new(cwd: REPO_ROOT, home: home, env: child_env,
        identity: "pi", hooks: @hooks)

      @server.script([{type: :slow_stream, content: D_STOP_STREAM, chunk_every: 0.05}])
      run = @manager.spawn_run(agent: "worker", task: D_STOP_TASK, async: true, timeout_ms: 0)
      wait_for_captures(15, "the stop target's first request") { child_requests(D_STOP_TASK).size == 1 }
      receipt = @manager.stop(id: run[:id])
      assert_equal "Stop requested for async run #{run[:id]}.", receipt.to_s, "the §7 stop receipt bytes"
      wait_until_bounded(10, "the stopped state") { run_state(run[:id]) == :stopped }
      sj = status_json(run[:dir])
      assert_equal "stopped", sj["state"]
      assert_equal false, sj.fetch("timedOut", nil), "a user stop never sets timedOut"
      assert_ps_clean(run[:pid])

      @captures = []
      @server.script([{type: :slow_stream, content: D_DEADLINE_STREAM, chunk_every: 0.05}])
      deadline_run = @manager.spawn_run(agent: "worker", task: D_DEADLINE_TASK, async: true, timeout_ms: 1500)
      wait_until_bounded(15, "the deadline state") { run_state(deadline_run[:id]) == :stopped }
      sjd = status_json(deadline_run[:dir])
      assert_equal "stopped", sjd["state"]
      assert_equal true, sjd["timedOut"], "the run deadline lands stopped + timedOut true"
      assert_ps_clean(deadline_run[:pid])
      puts "[i48-e2e] leg D: stop (stopped/timedOut false) + deadline (stopped/timedOut true), no zombies"
    end

    private

    # --- staging (the I42 discipline) ---

    # The home seam (OQ-2), driven through both tiers: the
    # <IDENTITY>_SUBAGENTS_HOME env override wins; the fallback is the
    # agent root's subagents dir (Session.default_root-based — HOME-agnostic
    # by construction, so the pin never touches the owner's tree). This is
    # every leg's first frozen-surface touch: at base it fails with the
    # DECLARED NameError.
    def stage_subagents_home
      @subagents_home = File.join(@home, "subagents-staged")
      assert_equal @subagents_home, Tart::Subagents.home(env: { "PI_SUBAGENTS_HOME" => @subagents_home }, identity: "pi"),
        "the env tier of Subagents.home (OQ-2)"
      assert_equal File.join(Agent::Session.default_root, "subagents"), Tart::Subagents.home(env: {}, identity: "pi"),
        "the fallback tier of Subagents.home (OQ-2: <agent root>/subagents)"
      FileUtils.mkdir_p(@subagents_home)
      puts "[i48-e2e] subagents home: #{@subagents_home}"
      @subagents_home
    end

    # The staged settings: the I42 full-7 defaultTools + the opt-in gate
    # row (OQ-1). At base the row is a tolerated unknown-key diagnostic
    # (settings.rb unknown_key_diagnostics); on the integrated tree it is
    # the known gate row.
    def stage_home
      FileUtils.mkdir_p(File.join(@home, ".tart"))
      File.write(File.join(@home, ".tart", "settings.json"), JSON.generate(
        "subagents" => true,
        "defaultTools" => %w[read bash edit write find grep ls]
      ))
    end

    # Space-root resolution (the I42 pattern verbatim): TART_E2E_SPACE > the
    # main-checkout parent when it validates > the checkout root itself.
    def space_root
      @space_root ||= begin
        return ENV.fetch("TART_E2E_SPACE") if ENV["TART_E2E_SPACE"]

        candidate = main_checkout_parent
        candidate && valid_space?(candidate) ? candidate : REPO_ROOT
      end
    end

    def main_checkout_parent
      out = `git -C #{REPO_ROOT.shellescape} rev-parse --path-format=absolute --git-common-dir 2>/dev/null`
      return nil unless $?.success? && !out.strip.empty?

      checkout = out.strip.sub(%r{/\.git\z}, "")
      [checkout, File.expand_path("..", checkout), File.expand_path("../..", checkout)]
        .find { |path| valid_space?(path) }
    end

    def valid_space?(path)
      File.directory?(File.join(path, "repos", "tart")) ||
        File.file?(File.join(path, "space.yaml")) || File.directory?(File.join(path, "architecture"))
    end

    # The staged sessions dir for the space root (Session.default_root
    # under the staged HOME).
    def session_files
      dir = Agent::Session.dir_path(space_root, root: File.join(@home, ".tart"))
      File.directory?(dir) ? Dir.glob(File.join(dir, "*.jsonl")).sort_by { |path| File.mtime(path) } : []
    end

    # The parent subprocess env: CLOSED (unsetenv_others in tart_sub — no
    # live keys, no owner TART_* leaks, no HERDR_* pane state), staged HOME,
    # the mock endpoint, the routed model, the staged runs home, and the
    # I42 absent-MCP pointer.
    def tart_env
      {
        "PATH" => ENV.fetch("PATH", nil),
        "HOME" => @home,
        # See e2e_session_test's tart_env: the child boots tart itself and
        # needs BUNDLE_PATH to resolve vendored CI gems.
        "BUNDLE_PATH" => ENV.fetch("BUNDLE_PATH", nil),
        # I69 move: the parent boots stage the PI_-parity opt-in
        # EXPLICITLY (the (now tart) default never rides these pins).
        "TART_IDENTITY" => "pi",
        "PI_API_KEY" => "e2e-key",
        "PI_API_BASE" => @server.url,
        "PI_MODEL" => ROUTED_MODEL,
        "PI_SUBAGENTS_HOME" => @subagents_home,
        "TART_MCP_CONFIG" => File.join(@home, "absent-mcp.json")
      }
    end

    # The in-process legs' parent env: CLOSED at the source so the child's
    # §4 env derivation has nothing owner-specific to leak.
    def child_env
      {
        "PATH" => ENV.fetch("PATH", nil),
        "HOME" => @home,
        "TART_IDENTITY" => "pi", # I69 move: explicit pi-parity staging
        "PI_API_KEY" => "e2e-key",
        "PI_API_BASE" => @server.url,
        "PI_SUBAGENTS_HOME" => @subagents_home
      }
    end

    # The parent runner: I42's capture3 shape plus a HARD watchdog — a hung
    # parent fails the leg instead of hanging the battery. pgroup: true so
    # the escalation reaches the whole parent tree; the async child runs in
    # its OWN pgroup (Specification §4) and is torn down by the sweep.
    def tart_sub(prompt)
      out_r, out_w = IO.pipe
      err_r, err_w = IO.pipe
      pid = Process.spawn(tart_env, RbConfig.ruby, File.join(REPO_ROOT, "bin", "tart"),
        "-p", prompt, space_root, chdir: REPO_ROOT, unsetenv_others: true,
        pgroup: true, out: out_w, err: err_w)
      out_w.close
      err_w.close
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + PARENT_DEADLINE_S
      status = nil
      loop do
        _pid, status = Process.waitpid2(pid, Process::WNOHANG)
        break if status

        next if Process.clock_gettime(Process::CLOCK_MONOTONIC) <= deadline

        begin
          Process.kill("-TERM", -pid)
          sleep 2
          Process.kill("-KILL", -pid)
        rescue StandardError
          nil
        end
        Process.waitpid2(pid)
        out_r.close
        err_r.close
        raise "bin/tart -p exceeded the #{PARENT_DEADLINE_S}s watchdog and was killed"
      end
      [out_r.read, err_r.read, status]
    end

    # --- bounded polling (every wait carries an explicit bound) ---

    def wait_until_bounded(timeout, what)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        value = yield
        return value if value
        raise "timed out after #{timeout}s waiting for #{what}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep 0.05
      end
    end

    def wait_for_captures(timeout, what)
      wait_until_bounded(timeout, what) do
        drain_captures
        yield
      end
    end

    def drain_captures
      @captures.concat(@server.captured_requests)
    end

    # Requests that carry the delegated task as a user message — the child
    # discriminator (parent requests carry the parent prompt instead; the
    # steered follow-up carries the task in its replayed context too).
    def child_requests(task)
      @captures.select do |r|
        r.is_a?(Hash) && r["messages"].to_a.any? do |m|
          m["role"] == "user" && m["content"].to_s.include?(task)
        end
      end
    end

    def run_state(id)
      run = @manager.runs.find { |r| r[:id] == id }
      run ? run[:state] : nil
    end

    # No zombie (the T3 pin): the pid must vanish from the process table
    # within a small reap allowance.
    def assert_ps_clean(pid)
      wait_until_bounded(5, "pid #{pid} to be reaped (no zombie — T3)") do
        `ps -p #{Integer(pid)} -o pid=`.strip.empty?
      end
    end

    # --- artifact readers ---

    def the_only_run_dir
      dirs = Dir.children(@subagents_home).sort
      assert_equal 1, dirs.size, "exactly one run dir under the staged subagents home: #{dirs.inspect}"
      File.join(@subagents_home, dirs.first)
    end

    def status_json(run_dir)
      JSON.parse(File.read(File.join(run_dir, "status.json")))
    end

    def result_json(run_dir)
      JSON.parse(File.read(File.join(run_dir, "result.json")))
    end

    def tool_message(request, call_id)
      message = request["messages"].find { |m| m["role"] == "tool" && m["tool_call_id"] == call_id }
      assert message, "the request carries call #{call_id}'s tool result"
      message["content"].to_s
    end

    # Defense-in-depth teardown: a NON-terminal run still holding a live
    # pid (a leg that failed mid-way) gets its pgroup terminated so the
    # battery never leaks a child. Terminal runs are already reaped.
    def kill_stray_children
      Dir.glob(File.join(@subagents_home.to_s, "*", "status.json")).each do |path|
        json = JSON.parse(File.read(path))
        next if %w[completed failed stopped].include?(json["state"].to_s)

        pid = json["pid"]
        next unless pid.is_a?(Integer) && pid != Process.pid
        begin
          Process.kill(0, pid)
        rescue StandardError
          next
        end
        target = json["pgid"].is_a?(Integer) ? -json["pgid"] : pid
        begin
          Process.kill("-TERM", target)
          puts "[i48-e2e] teardown: TERM'd stray child pid #{pid}"
        rescue StandardError
          nil
        end
      rescue JSON::ParserError, Errno::ENOENT
        next
      end
    end

    # *****************************************************************
    # I49 subagents-profiles-intercom, lane e2e (legs E and F). Every byte
    # above is the I48 judged instrument — UNTOUCHED; everything below is
    # this lane's appends. The machinery the new legs drive
    # (Subagents::Profiles, Subagents::Supervisor, Tools::ContactSupervisor,
    # the Manager's root: kwarg) is the CORE lane's and does not exist on
    # this tree: each leg's FIRST frozen-surface touch is a bare constant
    # reference, so at base each leg fails with exactly the declared
    # NameError and must be GREEN on the integrated tree.
    # *****************************************************************

    # --- Leg E: the print-parent intercom shape end-to-end.
    E_PROMPT = "e2e leg E: delegate to a worker that will need a supervisor decision"
    E_CHILD_TASK = "e2e child task: ask the supervisor before answering for leg E"
    E_ASK_MESSAGE = "e2e leg E ask: may I proceed with the delegated task?"
    # 32 chars ≈ 3.2s at the MockLLMServer's real 0.1s/char pacing
    # (chunk_every is NOT honored — I48 P0-10). Long enough that the child
    # boots and asks while the parent still runs; the drain adds no stdout.
    E_FINAL = "leg E parent final: ask recorded"

    # --- Leg F: profiles end-to-end (both discovery tiers + the bridge).
    F_RESEARCHER_TASK = "e2e child task: research the leg F subject"
    F_RESEARCHER_BODY = "You are the e2e researcher profile. Find things fast."
    # The units gate's proven shape (provider/id:level — the :level suffix
    # rides Subagents.resolve_model; provider "mock" maps onto the port's
    # single chat-completions seam, so the child's WIRE model field is the
    # bare id, exactly like leg A's ROUTED_MODEL rode PI_MODEL verbatim).
    F_RESEARCHER_MODEL = "mock/glm-e2e-profile:high"
    F_RESEARCHER_MODEL_ID = "glm-e2e-profile"
    F_RESEARCHER_FINAL = "leg F researcher done"
    F_WORKER_TASK = "e2e child task: implement the leg F override"
    F_WORKER_BODY = "Project-tier worker body for leg F."
    F_WORKER_FINAL = "leg F project worker done"
    # A distinctive token of the builtin worker's frozen prompt — its
    # ABSENCE from the override run's system-prompt.md proves the project
    # tier replaced BUILTIN_AGENTS (not merged with it).
    F_BUILTIN_WORKER_TOKEN = "You are `worker`: the implementation subagent."

    public

    # Leg E (AC2's print-parent surface + bound): a REAL parent print run
    # (bin/tart -p, staged settings {"subagents": true}, closed env) whose
    # scripted model spawns an ASYNC child (timeout_ms: 6000 — the run
    # deadline is the child's bound, because the sanctioned child env set
    # carries NO <IDENTITY>_INTERCOM_ASK_TIMEOUT_MS key: the child asks at
    # the 600s default and the RUN deadline kills the waiting asker — the
    # spec's ask-unanswered path). Script slots are consumed in ARRIVAL
    # order across BOTH processes on the shared server; the bet (the I48
    # leg-B precedent): the parent's tool-result turn is issued ~instantly
    # after the spawn while the child still owes its ~350ms interpreter
    # boot (I48 Grounds §4 probe B measured ~357ms cold) — margin ≈100×;
    # a flipped order fails loud (the parent's second turn would execute
    # the child's contact_supervisor script and exit non-zero).
    # Ruled semantics under test (OQ-8c): the parent's own turn COMPLETES
    # and the print parent NEVER answers the ask — the drain records the
    # surfaced ask as a custom_message entry on the parent's session and
    # no reply file is ever written; the child proceeds at its bound
    # (stopped + timedOut) and the parent still exits 0.
    def test_leg_e_print_parent_intercom_shape
      i49_stage_home
      stage_subagents_home
      stage_home

      begin
        # FIRST frozen-surface touch — at base this leg is RED exactly here
        # (NameError: uninitialized constant Tart::Subagents::Supervisor).
        assert_equal "subagent_supervisor_request", Tart::Subagents::Supervisor::REQUEST_CUSTOM_TYPE,
          "the surfaced customType byte (OQ-3 — pi supervisor-ui.js:3, byte-exact)"

        @server.script([
          {type: :stream, tool_calls: [{id: "c1", name: "subagent",
                                        arguments: {agent: "worker", task: E_CHILD_TASK, async: true,
                                                    timeout_ms: 6000}}]},
          {type: :stream, content: E_FINAL},
          {type: :stream, tool_calls: [{id: "ask1", name: "contact_supervisor",
                                        arguments: {reason: "need_decision", message: E_ASK_MESSAGE}}]}
        ])

        stdout, stderr, status = tart_sub(E_PROMPT)
        assert_equal 0, status.exitstatus, "leg E parent exits 0 (stderr: #{stderr})"
        assert_equal E_FINAL, stdout.strip,
          "a print parent never answers the ask mid-run; the drain adds no stdout (OQ-8c)"

        drain_captures
        assert_equal 3, @captures.size,
          "parent spawn turn, parent final turn, child ask turn (captured: #{@captures.map { |r| r['model'] }.inspect})"
        parent_req2 = @captures.find do |r|
          r["messages"].to_a.any? { |m| m["role"] == "tool" && m["tool_call_id"] == "c1" }
        end
        child_req = child_requests(E_CHILD_TASK).first
        assert parent_req2, "the parent's tool-result turn was captured"
        assert child_req, "the async child's request was captured"
        start_message = tool_message(parent_req2, "c1")
        run_id = start_message[/\[([0-9a-f-]{36})\]/, 1]
        assert run_id, "the start message names the run id: #{start_message[0, 80].inspect}"

        # The bounded child: stopped + timedOut (the ask-unanswered path),
        # reaped — no orphan.
        run_dir = File.join(@subagents_home, run_id)
        sj = status_json(run_dir)
        assert_equal "stopped", sj["state"],
          "the child proceeds at its bound (the spawn's run deadline, T2)"
        assert_equal true, sj["timedOut"], "a deadline stop sets timedOut"
        assert_equal run_id, sj["id"]
        assert_equal false, result_json(run_dir)["success"], "the killed asker has no successful result"
        # The child's ONE wire request evidences the bridge directly: its
        # allowlist declares contact_supervisor and its system prompt carries
        # the bridge instruction. The ask itself is pinned below through the
        # parent-session §4.4 bytes — the child BLOCKS inside the tool call
        # (no second wire request exists) until the run deadline kills it, so
        # an assistant tool_call can never appear in a captured request.
        # (Judge note: the lane's original wire-search form was mechanically
        # unsatisfiable for exactly this reason — repaired at integration,
        # the I36/I48 integrated-tree-only class.)
        child_tools = child_req["tools"].to_a.map { |t| t.dig("function", "name") }.compact
        assert_includes child_tools, "contact_supervisor",
          "the bridged child declares contact_supervisor on the wire: #{child_tools.inspect}"
        child_prompt = child_req["messages"].find { |m| %w[developer system].include?(m["role"]) }
        assert_includes child_prompt["content"].to_s, Tart::Subagents::Supervisor::BRIDGE_INSTRUCTION,
          "the bridge instruction is appended to the child's system prompt (D5)"
        assert_ps_clean(sj["pid"])

        # The drain's product: the ask rides the parent's session file as a
        # custom_message entry with the §4.4 bytes. The request FILE is
        # swept by the channel's terminal run sweep before exit, so the
        # request id is read back from the surfaced hint (36-char uuid) and
        # every OTHER byte is pinned against the independently sourced
        # run id (start message + status.json) and agent label.
        files = session_files
        assert_equal 1, files.size, "exactly one parent session under the staged HOME"
        entries = Agent::Session.load_entries(files.first)
        ask = entries.find { |e| e["type"] == "custom_message" && e["customType"] == "subagent_supervisor_request" }
        assert ask, "the parent's drain recorded the surfaced ask " \
          "(session tail: #{entries.last(3).map { |e| [e['type'], e['customType']].compact }.inspect})"
        request_id = ask["content"].to_s[/reply_to: "([0-9a-f-]{36})"/, 1]
        assert request_id, "the ask's Reply-with hint names the request id: #{ask['content'].inspect}"
        want_ask = "Subagent needs a supervisor decision.\nRun: #{run_id}\nAgent: worker\n\n" \
          "#{E_ASK_MESSAGE}\n\n" \
          "Reply with: subagent({ action: \"reply\", reply_to: \"#{request_id}\", message: \"...\" })\n\n" \
          "Live guidance: subagent({ action: \"steer\", id: \"#{run_id}\", message: \"...\" }) " \
          "(Reply to the pending request first.)"
        assert_equal want_ask, ask["content"], "the §4.4 surfaced-ask bytes (reasonHeading/Run/Agent/hint/steer line)"
        assert_equal true, ask["display"], "the ask surfaces display: true (§4.3)"
        notify = entries.find { |e| e["customType"] == "subagent-notify" }
        assert notify, "the bounded child's settle still notifies (I48 §2.6, async)"
        assert_operator entries.index(ask), :<, entries.index(notify),
          "the ask is recorded before the completion notice (it landed first)"

        # NO reply is ever written (the print parent never answers), and the
        # channel's terminal sweep leaves no request file after the run ends
        # (T3's after-drain/shutdown letter — bounded poll).
        replies = File.join(run_dir, "control", "supervisor-replies")
        requests = File.join(run_dir, "control", "supervisor-requests")
        assert File.directory?(replies), "the spawn created the supervisor-replies control dir"
        assert File.directory?(requests), "the spawn created the supervisor-requests control dir"
        assert_empty Dir.children(replies).reject { |f| f.start_with?(".") },
          "NO reply file is ever written under the run dir (OQ-8c)"
        wait_until_bounded(5, "the channel's terminal sweep to clear the request files") do
          Dir.children(requests).reject { |f| f.start_with?(".") }.empty?
        end
        puts "[i48-e2e] leg E: exit 0, ask recorded on the parent session (request #{request_id}), " \
          "child bounded stopped/timedOut, no reply file, requests swept"
      ensure
        # The leg's own teardown path: bounded, assertion-free (an ensure
        # must never mask the leg's failure), idempotent with the shared
        # teardown that runs after it.
        i49_leg_cleanup
      end
      assert_i49_hygiene
    end

    # Leg F (AC1/AC3 end-to-end): the profile tier drives a REAL spawn. The
    # test is the parent (in-process Manager — leg C's shape) with the
    # additive root: kwarg carrying the staged USER tier (Session.default_root
    # reads the process Dir.home, never staged in-process; root: is the
    # driven surface). Script slots are consumed in order, but the spawns
    # are SEQUENTIAL — each run is waited to completion before the next
    # spawn — so there is no cross-process order bet on this leg; every
    # wait is bounded. Pinned: the merged discovery table (user profile,
    # project override over the builtin, builtins retained), the profile's
    # model on the child's WIRE, the argv --tools tail + the same allowlist
    # on the wire (bridge tool LAST), the closed-env channel/agent keys,
    # the profile body + bridge block in system-prompt.md, and the project
    # tier REPLACING the builtin worker body.
    def test_leg_f_profiles_end_to_end
      i49_stage_home
      stage_subagents_home
      stage_i49_profiles

      begin
        # FIRST frozen-surface touch — at base this leg is RED exactly here
        # (NameError: uninitialized constant Tart::Subagents::Profiles).
        table = Tart::Subagents::Profiles.resolve_table(cwd: @project_dir, root: File.join(@home, ".tart"), env: {})
        researcher_row = table["researcher"]
        assert researcher_row, "the user-tier profile is discovered into the merged table"
        assert_equal %w[read grep find ls bash], researcher_row[:tools], "the profile's tool list (order preserved)"
        assert_equal F_RESEARCHER_MODEL, researcher_row[:model], "the profile's raw model string"
        assert_equal :user, researcher_row[:source]
        worker_row = table["worker"]
        assert_equal :project, worker_row[:source], "the project tier wins the same-name overlay"
        assert_equal %w[read grep], worker_row[:tools]
        assert worker_row[:system_prompt].to_s.include?(F_WORKER_BODY), "the project body replaced the builtin's"
        assert table["oracle"] && table["reviewer"], "the builtins stay in the merged table"
        spec = Tart::Subagents::Profiles.resolve("researcher", cwd: @project_dir, root: File.join(@home, ".tart"), env: {})
        assert spec[:system_prompt].to_s.include?(F_RESEARCHER_BODY), "resolve returns the profile spec"

        @server.script([
          {type: :stream, content: F_RESEARCHER_FINAL},
          {type: :stream, content: F_WORKER_FINAL}
        ])
        @hooks = Hooks.new
        @manager = Tart::Subagents::Manager.new(cwd: @project_dir, home: @subagents_home, env: child_env,
          identity: "pi", hooks: @hooks, root: File.join(@home, ".tart"))

        tool = Tart::Tools::Subagent.new(manager: @manager)
        start = tool.execute(agent: "researcher", task: F_RESEARCHER_TASK, timeout_ms: 0).to_s
        researcher = @manager.runs.first
        assert researcher, "the dispatch registered the run"
        assert_equal "Async: researcher [#{researcher[:id]}]", start.split("\n").first,
          "the profile's name rides the §7 start headline"

        wait_for_captures(15, "the researcher child's request") { child_requests(F_RESEARCHER_TASK).size == 1 }
        child = child_requests(F_RESEARCHER_TASK).first
        assert_equal F_RESEARCHER_MODEL_ID, child["model"],
          "the profile's model rides the child's wire (call model: > profile model > parent)"
        assert_equal %w[read grep find ls bash contact_supervisor],
          child["tools"].to_a.map { |t| t.dig("function", "name") },
          "the child wire tools are the profile list + the bridge tool LAST (wire order = allowlist order)"

        argv, child_environment = @manager.spawn_argv_and_env(researcher)
        assert_equal "read,grep,find,ls,bash,contact_supervisor", argv[argv.index("--tools") + 1],
          "the argv allowlist gains contact_supervisor LAST (the D5 bridge)"
        refute argv.include?("--resume"), "context: fresh spawns without the fork resume"
        assert_equal File.join(researcher[:dir], "control"), child_environment["PI_SUPERVISOR_CHANNEL"],
          "the channel env key points at the run dir's control dir (D3)"
        assert_equal "researcher", child_environment["PI_SUBAGENTS_AGENT"], "the agent label env key (D3)"
        assert_equal F_RESEARCHER_MODEL_ID, child_environment["PI_MODEL"]
        assert_equal "mock", child_environment["PI_PROVIDER"]
        assert_equal "high", child_environment["PI_THINKING_LEVEL"], "the profile's thinking level routes"

        prompt = File.read(File.join(researcher[:dir], "system-prompt.md"))
        assert prompt.include?(F_RESEARCHER_BODY), "the profile body IS the child's system prompt"
        assert prompt.end_with?(Tart::Subagents::Supervisor::BRIDGE_INSTRUCTION),
          "system-prompt.md = the profile body + the bridge block (D5)"
        assert prompt.include?("Intercom orchestration channel:\n"), "the bridge marker"
        assert prompt.include?('contact_supervisor({ reason: "need_decision", message: "<question>" })'),
          "the bridge template bytes (pi DEFAULT_INTERCOM_BRIDGE_TEMPLATE verbatim)"
        assert prompt.include?("Do not use contact_supervisor for routine completion handoffs."),
          "the bridge closing rule byte-carried"

        wait_until_bounded(25, "the researcher run to complete") { run_state(researcher[:id]) == :completed }
        assert_equal F_RESEARCHER_FINAL, result_json(researcher[:dir])["output"].to_s.strip
        assert_ps_clean(researcher[:pid])

        # The PROJECT tier: spawning the builtin NAME resolves to the
        # project override (its body + tools), never the builtin table.
        start2 = tool.execute(agent: "worker", task: F_WORKER_TASK, timeout_ms: 0).to_s
        worker = @manager.runs.find { |r| r[:id] != researcher[:id] }
        assert worker, "the second run registered"
        assert_equal "Async: worker [#{worker[:id]}]", start2.split("\n").first
        wait_until_bounded(25, "the worker run to complete") { run_state(worker[:id]) == :completed }
        worker_prompt = File.read(File.join(worker[:dir], "system-prompt.md"))
        assert worker_prompt.include?(F_WORKER_BODY), "the PROJECT-tier body lands in the run dir"
        refute worker_prompt.include?(F_BUILTIN_WORKER_TOKEN),
          "the override wins over BUILTIN_AGENTS (replaced, not merged)"
        worker_argv, = @manager.spawn_argv_and_env(worker)
        assert_equal "read,grep,contact_supervisor", worker_argv[worker_argv.index("--tools") + 1],
          "the override's comma-string tool list + the bridge tool last"
        assert_equal F_WORKER_FINAL, result_json(worker[:dir])["output"].to_s.strip
        assert_ps_clean(worker[:pid])
        puts "[i48-e2e] leg F: profile model/tools/bridge rode the researcher spawn; " \
          "the project worker override won; both runs completed"
      ensure
        i49_leg_cleanup
      end
      assert_i49_hygiene
    end

    private

    # --- i49 leg staging + teardown (appended helpers; the I48 helpers
    # above are untouched) ---

    # The i49 legs' staged HOME: a fresh i49-e2e- prefixed tmpdir (the
    # greppable scratch bar). The setup hook's i48-e2e- dir is unused by
    # these legs and removed HERE, so the shared teardown's rm_rf(@home)
    # removes exactly this leg's scratch — and the leg-end hygiene
    # assertion can prove no i49-e2e-* dir survives.
    def i49_stage_home
      FileUtils.rm_rf(@home)
      @home = Dir.mktmpdir("i49-e2e-home-")
      @project_dir = File.join(@home, "project")
      FileUtils.mkdir_p(@project_dir)
      # I70 explicit-staging law (the runner's R3, mirrored): the staged
      # HOME carries the EXPLICIT subagents opt-out — the child print boot
      # never rides the app default (which flipped ON in I70), so the leg F
      # child wire stays the allowlist + bridge shape. Leg E's stage_home
      # overwrites this with its explicit opt-in row after.
      FileUtils.mkdir_p(File.join(@home, ".tart"))
      File.write(File.join(@home, ".tart", "settings.json"), JSON.generate({"subagents" => false}))
      puts "[i48-e2e] i49 staged HOME: #{@home}"
      puts "[i48-e2e] i49 project cwd: #{@project_dir}"
    end

    # Leg F's staged profiles: the USER tier (<HOME>/.tart/agents —
    # recursive discovery, frontmatter over a system-prompt body; the
    # tolerated unknown key systemPromptMode must not block the load) and
    # the PROJECT tier (<cwd>/.tart/agents) overriding the builtin worker
    # with a comma-string tools list.
    def stage_i49_profiles
      user_dir = File.join(@home, ".tart", "agents")
      project_agents = File.join(@project_dir, ".tart", "agents")
      FileUtils.mkdir_p([user_dir, project_agents])
      File.write(File.join(user_dir, "researcher.md"), <<~MD)
        ---
        description: E2E leg F researcher profile
        tools: read, grep, find, ls, bash
        model: #{F_RESEARCHER_MODEL}
        thinking: high
        context: fresh
        systemPromptMode: replace
        ---

        #{F_RESEARCHER_BODY}
      MD
      File.write(File.join(project_agents, "worker.md"), <<~MD)
        ---
        description: PROJECT OVERRIDE WORKER
        tools: read, grep
        ---

        #{F_WORKER_BODY}
      MD
    end

    # The i49 legs' failure-safe cleanup — bounded operations only, NO
    # assertions (an ensure must never mask the leg's own failure), and
    # idempotent with the shared teardown that runs after it
    # (MockLLMServer#stop rescues the double close; Manager#shutdown is
    # rescued here; the dir removal is guarded). The I48 bytes above are
    # the judged instrument, so the lane-prompt teardown bar — no
    # i49-e2e-* dirs, no live child pids — lives HERE plus in
    # assert_i49_hygiene instead of an edit to the shared teardown.
    def i49_leg_cleanup
      begin
        @manager&.shutdown
      rescue StandardError
        nil
      end
      kill_stray_children
      begin
        @server&.stop
      rescue StandardError
        nil
      end
      FileUtils.rm_rf(@home) if @home && File.directory?(@home)
      @manager = nil
      @subagents_home = nil
      @home = nil
    end

    # The i49 teardown bar, asserted on each new leg's success path: no
    # i49-e2e-* scratch dir survives anywhere. The no-live-child-pids half
    # is pinned INSIDE each leg (assert_ps_clean on every spawned child
    # pid) with kill_stray_children TERM'ing any non-terminal straggler
    # here before the dirs go away.
    def assert_i49_hygiene
      assert_empty Dir.glob(File.join(Dir.tmpdir, "i49-e2e-*")),
        "no i49-e2e-* scratch dirs survive the leg"
    end

    # (minitest discovers public test methods only — the i49 helper block
    # above ended in a `private` region; the E legs must be discovered.)
    public

    # *****************************************************************
    # I70 subagents-default-on, the E1–E4 legs: the I48/I49 harness driven
    # with NO settings.json staged — the parent boots DEFAULT-ON (the
    # flip), riding only the staged <IDENTITY>_SUBAGENTS_HOME + the closed
    # env + explicit TART_IDENTITY=pi + the PI_* mock facts (the harness
    # convention). Each leg mirrors its A–D shape with the opt-in staging
    # REMOVED; the A–D legs above stay byte-unchanged (the opt-in tier is
    # not re-litigated). Leg names carry default_on (the gate's -n filter).
    # *****************************************************************

    # The default-on condition itself, pinned on every E leg before the
    # boot: the staged HOME carries NO settings.json and the env carries
    # no subagents row — the boot resolves the DEFAULTS tier.
    def assert_no_staged_settings
      refute File.exist?(File.join(@home, ".tart", "settings.json")),
        "the E legs stage NO settings.json — the parent must boot default-on"
      refute child_env["PI_SUBAGENTS"], "no subagents env row rides the E legs"
    end

    # E1 (the leg-A shape): foreground child round-trip on the DEFAULT-ON
    # wire — the parent request carries read/bash/edit/write + subagent
    # (declared LAST, the I47 merge order) with no settings staged at all.
    def test_default_on_e1_foreground_child_round_trip
      stage_subagents_home
      assert_no_staged_settings
      @server.script([
        {type: :stream, tool_calls: [{id: "c1", name: "subagent",
                                      arguments: {agent: "worker", task: A_CHILD_TASK, async: false}}]},
        {type: :stream, content: A_CHILD_ANSWER},
        {type: :stream, content: A_FINAL}
      ])

      stdout, stderr, status = tart_sub(A_PROMPT)
      assert_equal 0, status.exitstatus, "leg E1 parent exits 0 (stderr: #{stderr})"
      assert_includes stdout, A_FINAL, "the parent's final response lands on stdout"

      drain_captures
      assert_equal 3, @captures.size, "parent request, child request, parent tool-result turn"
      parent_req, child_req, parent_req2 = @captures
      assert_equal %w[read bash edit write subagent], parent_req["tools"].to_a.map { |t| t.dig("function", "name") },
        "the DEFAULT-ON wire (no staged settings): the subagent tool declared LAST"
      assert_equal ROUTED_MODEL, child_req["model"], "the child rides the routed model"
      assert_includes child_req["messages"].last["content"].to_s, A_CHILD_TASK,
        "the child request carries the delegated task"
      tool_result = tool_message(parent_req2, "c1")
      assert_equal A_CHILD_ANSWER, tool_result.strip,
        "the foreground result is the child's final text"

      run_dir = the_only_run_dir
      assert_equal "completed", status_json(run_dir)["state"]
      assert_equal A_CHILD_ANSWER, result_json(run_dir)["output"].to_s.strip
      assert_equal 1, Dir.glob(File.join(run_dir, "sessions", "**", "*.jsonl")).size,
        "the child records its session under the staged run dir"
      puts "[i48-e2e] leg E1: default-on boot (no staged settings), foreground round-trip completed"
    end

    # E2 (the leg-B shape): async detached + completion notify + the
    # print-parent drain — the parent boots default-on with no settings.
    def test_default_on_e2_async_detached_notify_and_print_drain
      stage_subagents_home
      assert_no_staged_settings
      # I87 Law 2 (kill the arrival-order bet — the leg-B shape): responses
      # route by REQUEST CONTENT (see test_leg_b above), so the child's
      # slow boot can never flip which request takes which response. The
      # firing class-(f) inversion (the stdout pin carrying the child's
      # answer) is impossible by construction now; every assertion below
      # is unchanged.
      @server.script([
        {type: :stream, tool_calls: [{id: "c1", name: "subagent",
                                      arguments: {agent: "worker", task: B_CHILD_TASK, async: true}}],
         match: ->(req) { req["messages"].to_a.any? { |m| m["role"] == "user" && m["content"].to_s.include?(B_PROMPT) } }},
        {type: :stream, content: B_FINAL,
         match: ->(req) { req["messages"].to_a.any? { |m| m["role"] == "tool" && m["tool_call_id"] == "c1" } }},
        {type: :slow_stream, content: B_CHILD_SLOW, chunk_every: 0.05,
         match: ->(req) { req["messages"].to_a.any? { |m| m["role"] == "user" && m["content"].to_s.include?(B_CHILD_TASK) } }}
      ])

      stdout, stderr, status = tart_sub(B_PROMPT)
      assert_equal 0, status.exitstatus, "leg E2 parent exits 0 (stderr: #{stderr})"
      assert_equal B_FINAL, stdout.strip, "the drain adds no extra stdout"

      drain_captures
      parent_req2 = @captures.find do |r|
        r["messages"].to_a.any? { |m| m["role"] == "tool" && m["tool_call_id"] == "c1" }
      end
      assert parent_req2, "the parent's tool-result turn was captured"
      start_message = tool_message(parent_req2, "c1")
      assert start_message.start_with?("Async: worker ["), "the §7 async start headline"
      run_id = start_message[/\[([0-9a-f-]{36})\]/, 1]
      assert run_id, "the start message names the run id"
      assert_equal [run_id], Dir.children(@subagents_home).sort, "one run dir under the staged home"

      files = session_files
      assert_equal 1, files.size, "exactly one parent session under the staged HOME"
      entries = Agent::Session.load_entries(files.first)
      notice = entries.last
      assert_equal "custom_message", notice["type"], "session tail: #{entries.last(2).map { |e| e["type"] }.inspect}"
      assert_equal "subagent-notify", notice["customType"]
      assert notice["content"].start_with?("Background task completed: **worker**"), "the §7 notification header"
      assert_equal false, notice["display"], "completed notices are model-visible only"

      run_dir = File.join(@subagents_home, run_id)
      assert_equal "completed", status_json(run_dir)["state"], "the child settled completed on disk"
      puts "[i48-e2e] leg E2: default-on boot, async drain recorded run #{run_id} completed"
    end

    # E3 (the leg-C shape): the steering receipt — correlated consumption
    # by request id, the in-process Manager with the default-on HOME.
    def test_default_on_e3_steering_receipt
      home = stage_subagents_home
      assert_no_staged_settings
      @server.script([
        {type: :slow_stream, content: C_LONG, chunk_every: 0.05},
        {type: :stream, content: C_STEERED_ANSWER}
      ])
      @hooks = Hooks.new
      @manager = Tart::Subagents::Manager.new(cwd: REPO_ROOT, home: home, env: child_env,
        identity: "pi", hooks: @hooks)

      tool = Tart::Tools::Subagent.new(manager: @manager)
      start = tool.execute(agent: "worker", task: C_TASK, timeout_ms: 0).to_s
      run = @manager.runs.first
      assert run, "the dispatch registered the run"
      id = run[:id]
      assert_equal "Async: worker [#{id}]", start.split("\n").first, "the §7 start message"

      wait_for_captures(15, "the child's first request") { child_requests(C_TASK).size == 1 }
      assert_equal :running, @manager.runs.first[:state]

      receipt = @manager.steer(id: id, message: C_STEER, mode: "steer", ack_timeout_ms: 30_000)
      assert_equal :delivered, receipt[:state],
        "the receipt reports the child's correlated consumption: #{receipt.inspect}"
      assert_equal 36, receipt[:request_id].to_s.length
      assert_equal "Steering delivered to async run #{id} (request #{receipt[:request_id]}).",
        receipt[:text], "the §7 steer receipt bytes"

      log = File.readlines(File.join(run[:dir], "control", "steer-log.jsonl")).map { |line| JSON.parse(line) }
      assert log.any? { |entry| entry["requestId"] == receipt[:request_id] },
        "the child's steer log names the SAME request id (T1)"

      wait_until_bounded(25, "the steered run to complete") { !@manager.outstanding? }
      assert_equal :completed, @manager.runs.first[:state]
      drain_captures
      steered = @captures.find do |r|
        r["messages"].to_a.any? { |m| m["role"] == "user" && m["content"].to_s.include?(C_STEER) }
      end
      assert steered, "the steer text rode a captured child request"
      first_child = child_requests(C_TASK).first
      assert_operator @captures.index(steered), :>, @captures.index(first_child),
        "the steer reached the child's NEXT request, not the first"
      assert_equal C_STEERED_ANSWER, result_json(run[:dir])["output"].to_s.strip
      assert_ps_clean(@manager.runs.first[:pid])
      puts "[i48-e2e] leg E3: default-on home, steer delivered (request #{receipt[:request_id]}), completed"
    end

    # E4 (the leg-D shape): stop — graceful interrupt, state stopped,
    # timedOut false, no zombie — on the default-on HOME.
    def test_default_on_e4_stop
      home = stage_subagents_home
      assert_no_staged_settings
      @hooks = Hooks.new
      @manager = Tart::Subagents::Manager.new(cwd: REPO_ROOT, home: home, env: child_env,
        identity: "pi", hooks: @hooks)

      @server.script([{type: :slow_stream, content: D_STOP_STREAM, chunk_every: 0.05}])
      run = @manager.spawn_run(agent: "worker", task: D_STOP_TASK, async: true, timeout_ms: 0)
      wait_for_captures(15, "the stop target's first request") { child_requests(D_STOP_TASK).size == 1 }
      receipt = @manager.stop(id: run[:id])
      assert_equal "Stop requested for async run #{run[:id]}.", receipt.to_s, "the §7 stop receipt bytes"
      wait_until_bounded(10, "the stopped state") { run_state(run[:id]) == :stopped }
      sj = status_json(run[:dir])
      assert_equal "stopped", sj["state"]
      assert_equal false, sj.fetch("timedOut", nil), "a user stop never sets timedOut"
      assert_ps_clean(run[:pid])
      puts "[i48-e2e] leg E4: default-on home, stop lands stopped/timedOut false, no zombies"
    end

    # *****************************************************************
    # I80 child-encoding-hygiene, lane core. Every byte above is the
    # judged instrument — UNTOUCHED; this leg is the lane's append. It
    # reuses leg A's EXACT machinery (staged HOME, the closed locale-less
    # tart_env — ALREADY the defect environment, no new staging,
    # MockLLMServer, the foreground subagent call) with a Diátaxis-grade
    # non-ASCII task AND child answer. At base the locale-blind
    # read_output swallowed the byte-exact child answer to "" and the run
    # settled failed with the JSON.generate BINARY warning recorded as the
    # error (the devstral-docs failure class, probe B). The three laws
    # (child locale + boot UTF-8 + the byte-hygienic readers) make the
    # whole child boundary byte-exact.
    # *****************************************************************

    ENC_PROMPT = "I80 encoding e2e: delegate the Diátaxis note — résumé ✓ (á é ü)"
    ENC_CHILD_TASK = "I80 encoding child task: write the Diátaxis note — résumé ✓ (á é ü)"
    ENC_CHILD_ANSWER = "I80 encoding answer: Diátaxis — résumé ✓ (á é ü) OK"
    ENC_FINAL = "I80 encoding parent final: the child answered byte-exact"

    def test_encoding_e2e_non_ascii_round_trip
      stage_subagents_home
      stage_home
      @server.script([
        {type: :stream, tool_calls: [{id: "c1", name: "subagent",
                                      arguments: {agent: "worker", task: ENC_CHILD_TASK, async: false}}]},
        {type: :stream, content: ENC_CHILD_ANSWER},
        {type: :stream, content: ENC_FINAL}
      ])

      stdout, stderr, status = tart_sub(ENC_PROMPT)
      assert_equal 0, status.exitstatus, "the parent exits 0 (stderr: #{stderr})"
      assert_equal ENC_FINAL, stdout.chomp, "the parent's final stdout is byte-exact"
      assert_empty stderr, "the parent's own stderr carries ZERO lines (the boot law's leg)"

      drain_captures
      child_req = child_requests(ENC_CHILD_TASK).first
      assert child_req, "the child's wire request was captured"
      child_user = child_req["messages"].select { |m| m["role"] == "user" }.last
      assert_equal ENC_CHILD_TASK, child_user["content"],
        "the child wire request carries the task BYTE-EXACT"

      run_dir = the_only_run_dir
      stderr_log = File.read(File.join(run_dir, "runner.stderr.log"))
      refute stderr_log.include?("passed as BINARY"),
        "runner.stderr.log carries ZERO 'passed as BINARY' lines: #{stderr_log[0, 200].inspect}"

      sj = status_json(run_dir)
      assert_equal "completed", sj["state"]
      assert_equal ENC_CHILD_TASK.length, sj["taskChars"],
        "taskChars is the task's CHARACTER count"
      # I81 Law 3 re-pin (declared in the lane prompt as a behavior-
      # contradicting pin inside the touch set): the raw task rides verbatim.
      assert_equal ENC_CHILD_TASK, sj["task"], "the spawn's raw task is on disk byte-exact"

      rj = result_json(run_dir)
      assert_equal true, rj["success"]
      assert_equal ENC_CHILD_ANSWER, rj["output"],
        "result.json output equals the child answer BYTE-EXACT"
      puts "[i48-e2e] encoding leg: exit 0, task + answer rode the boundary byte-exact, " \
           "run #{File.basename(run_dir)} completed"
    end

    # *****************************************************************
    # I81 agent-loading-forensics, lane core. Every byte above is the
    # judged instrument — UNTOUCHED except the two DECLARED Law-3 re-pins
    # above (leg A's and the encoding leg's task-null refutes, both
    # inside this touch-set file); this leg is the lane's append. THREE
    # process generations on the leg-A machinery (staged HOME + a staged
    # agents dir, MockLLMServer, real `bin/tart -p` subprocesses): the
    # parent's model calls `subagent` on a CUSTOM coordinator agent whose
    # `tools:` carry `subagent` AND an unknown entry (`bg_wait` — the
    # live 07:40Z specimen name); the child's captured wire proves the
    # Law-1 drop (bg_wait absent, subagent declared LAST) and the Law-2
    # grant (the child spawns the grandchild); the grandchild's output
    # rides back through the chain; the Law-3 forensics run live on BOTH
    # run dirs (single-sessions transcripts, raw task text on disk).
    # *****************************************************************

    N_PROMPT = "e2e nested leg: delegate through the coordinator"
    N_CHILD_TASK = "e2e nested child task: the coordinator delegates the check"
    N_GRANDCHILD_TASK = "e2e nested grandchild task: report the leg-N answer"
    N_GRANDCHILD_ANSWER = "leg N grandchild answer: two levels deep"
    N_CHILD_ANSWER = "leg N child answer: the grandchild reported"
    N_FINAL = "leg N parent final: the chain answered"

    def test_nested_e2e_three_generations_custom_coordinator
      stage_subagents_home
      stage_home
      # The staged USER-tier agents dir (the parent AND the child resolve
      # profiles from the same staged HOME's default agent root).
      agents_dir = File.join(@home, ".tart", "agents")
      FileUtils.mkdir_p(agents_dir)
      File.write(File.join(agents_dir, "coordinator.md"), <<~MD)
        ---
        description: e2e nested coordinator (custom agent)
        tools: read, bash, bg_wait, subagent
        ---

        You are the e2e nested coordinator. Delegate the leg-N check to the worker.
      MD

      # Script slots consumed in ARRIVAL order; every generation blocks
      # on the next (foreground spawns), so the order is deterministic:
      # parent spawn turn → child spawn turn → grandchild turn → child
      # tool-result turn → parent tool-result turn.
      @server.script([
        {type: :stream, tool_calls: [{id: "c1", name: "subagent",
                                      arguments: {agent: "coordinator", task: N_CHILD_TASK, async: false}}]},
        {type: :stream, tool_calls: [{id: "c2", name: "subagent",
                                      arguments: {agent: "worker", task: N_GRANDCHILD_TASK, async: false}}]},
        {type: :stream, content: N_GRANDCHILD_ANSWER},
        {type: :stream, content: N_CHILD_ANSWER},
        {type: :stream, content: N_FINAL}
      ])

      stdout, stderr, status = tart_sub(N_PROMPT)
      assert_equal 0, status.exitstatus, "the parent exits 0 (stderr: #{stderr})"
      assert_equal N_FINAL, stdout.strip, "the parent's final stdout is the chain's answer"

      drain_captures
      assert_equal 5, @captures.size,
        "parent spawn, child spawn, grandchild, child tool-result, parent tool-result " \
        "(captured: #{@captures.size})"

      # Law 1 + Law 2 on the child's captured wire: the custom
      # coordinator's spec tools after the drop (read, bash) + the bridge
      # union (contact_supervisor) + the registered merge (subagent LAST);
      # the unknown bg_wait is ABSENT.
      child_req = child_requests(N_CHILD_TASK).first
      assert child_req, "the child's spawn request was captured"
      assert_equal %w[read bash contact_supervisor subagent],
        child_req["tools"].to_a.map { |t| t.dig("function", "name") },
        "the dropped unknown name is absent; subagent is declared LAST (the merge order)"

      # The grandchild: the child's model spawned the builtin worker.
      grand_req = child_requests(N_GRANDCHILD_TASK).first
      assert grand_req, "the grandchild's request was captured"
      assert_equal %w[read grep find ls bash edit write contact_supervisor subagent],
        grand_req["tools"].to_a.map { |t| t.dig("function", "name") },
        "the grandchild (the builtin worker) also declares subagent LAST (the depth-1 grant)"

      # The chain: the grandchild's output rode the child's tool result;
      # the child's output rode the parent's tool result.
      child_replay = child_requests(N_CHILD_TASK).last
      assert_includes tool_message(child_replay, "c2"), N_GRANDCHILD_ANSWER,
        "the grandchild's output is the child's tool result"
      parent_req2 = @captures.find do |r|
        r["messages"].to_a.any? { |m| m["role"] == "tool" && m["tool_call_id"] == "c1" }
      end
      assert parent_req2, "the parent's tool-result turn was captured"
      assert_equal N_CHILD_ANSWER, tool_message(parent_req2, "c1").strip,
        "the child's output is the parent's tool result (verbatim, §7)"

      # TWO run dirs under the staged home (the child + the grandchild).
      runs = Dir.children(@subagents_home).sort.map do |child|
        [child, status_json(File.join(@subagents_home, child))]
      end
      assert_equal 2, runs.size, "the child and grandchild runs both landed under the staged home"
      child_run = runs.find { |_d, sj| sj["task"] == N_CHILD_TASK }
      grand_run = runs.find { |_d, sj| sj["task"] == N_GRANDCHILD_TASK }
      assert child_run, "the child run's status carries the raw spawn task (Law 3)"
      assert grand_run, "the grandchild run's status carries the raw spawn task (Law 3)"
      assert_equal N_GRANDCHILD_ANSWER, result_json(File.join(@subagents_home, grand_run[0]))["output"].to_s.strip
      assert_equal N_CHILD_ANSWER, result_json(File.join(@subagents_home, child_run[0]))["output"].to_s.strip

      # Law 3 LIVE on both generations: single-sessions transcripts and
      # the status sessionRoot = the transcript's container.
      [child_run, grand_run].each do |(name, sj)|
        run_dir = File.join(@subagents_home, name)
        sessions = Dir.glob(File.join(run_dir, "sessions", "**", "*.jsonl"))
        assert_equal 1, sessions.size, "#{name}: exactly one transcript"
        relative = sessions.first.delete_prefix("#{run_dir}/").split("/")
        assert_equal "sessions", relative.first
        assert_equal 3, relative.length, "#{name}: exactly ONE sessions segment (#{relative.inspect})"
        assert_equal File.join(run_dir, "sessions"), sj["sessionRoot"],
          "#{name}: sessionRoot is the transcript's container"
        assert_equal "completed", sj["state"]
      end
      puts "[i48-e2e] nested leg: exit 0, three generations (parent → coordinator → worker → grandchild), " \
           "drop + grant on the child wire, runs #{child_run[0]} + #{grand_run[0]} completed"
    end
  end
end
