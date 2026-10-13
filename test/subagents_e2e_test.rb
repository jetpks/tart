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
      refute sj["task"].to_s.include?(A_CHILD_TASK), "the task text is never recorded (pi redacts)"
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
      # Script order: the parent's tool-result turn is issued ~instantly
      # after the start message, while the child still owes a ~350ms
      # interpreter boot (Grounds §4 probe B) — so the child's request
      # arrives LAST and gets the slow stream. The margin is two orders of
      # magnitude; a flipped order fails loud on the stdout pin below.
      @server.script([
        {type: :stream, tool_calls: [{id: "c1", name: "subagent",
                                      arguments: {agent: "worker", task: B_CHILD_TASK, async: true}}]},
        {type: :stream, content: B_FINAL},
        {type: :slow_stream, content: B_CHILD_SLOW, chunk_every: 0.05}
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
  end
end
