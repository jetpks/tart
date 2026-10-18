# frozen_string_literal: true

require_relative "test_helper"
require "socket"
require "json"
require "tmpdir"
require "fileutils"

module Tart
  # The herdr reporter (I47 — AC3, herdr-agent-state.ts v9 verbatim; Grounds
  # §5): the env gate, the byte-pinned UNIX-socket requests, retry-once with
  # swallowed failures, latest-wins coalescing, the state machine with dedup
  # + the forced session_start publish, the herdr:blocked channel, and the
  # TUI-only gate. The gate `herdr-reporter` drives the same surface.
  class HerdrTest < Test
    def setup
      @dir = Dir.mktmpdir("tart-herdr-")
      @sock = File.join(@dir, "h.sock")
      @server = UNIXServer.new(@sock)
      @env = {"HERDR_ENV" => "1", "HERDR_SOCKET_PATH" => @sock, "HERDR_PANE_ID" => "p7"}
    end

    def teardown
      @server.close
      FileUtils.rm_rf(@dir)
    end

    # Accepts one connection, reads the newline-terminated request, replies
    # one byte, closes; returns the parsed request.
    def read_one(deliver: true)
      client = @server.accept
      line = client.gets
      client.write("ok") if deliver
      client.close
      JSON.parse(line)
    end

    def quiet?
      IO.select([@server], nil, nil, 0.2).nil?
    end

    # --- the env gate ---

    def test_enabled_requires_all_three_vars
      assert Herdr.enabled?(@env)
      refute Herdr.enabled?(@env.reject { |k, _| k == "HERDR_ENV" })
      refute Herdr.enabled?(@env.merge("HERDR_ENV" => "0"))
      refute Herdr.enabled?(@env.reject { |k, _| k == "HERDR_SOCKET_PATH" })
      refute Herdr.enabled?(@env.reject { |k, _| k == "HERDR_PANE_ID" })
    end

    # --- the Reporter's byte-pinned requests ---

    def test_session_report_shape_and_the_path_preferred_ref
      reporter = Herdr::Reporter.new(socket_path: @sock, timeouts: [20, 20])
      reporter.report_session({"agent_session_path" => "/tmp/s.json", "agent_session_id" => "sid-9"},
        pane_id: "p7", reason: "startup")
      request = read_one

      assert_equal "pane.report_agent_session", request["method"]
      # I69 wire: tart's OWN name (source never starts "herdr:" — the
      # reserved native pair was gauntlet-dropped; detect/mod.rs:330-348).
      assert request["id"].start_with?("tart:session:"), "the session id format (tart:session:<ms>:<rand>)"
      params = request["params"]
      assert_equal "p7", params["pane_id"]
      assert_equal "tart", params["source"]
      assert_equal "tart", params["agent"]
      assert_equal "startup", params["session_start_source"]
      assert_equal "/tmp/s.json", params["agent_session_path"]
      # I69 wire: the seq base sits in pi's Date.now()*1000 class (epoch-ms
      # × 1000 ≈ 1.79×10¹⁵; the old ~10¹² Time.now.to_i scale is gone).
      assert_operator params["seq"], :>=, 1_000_000_000_000_000, "the Date.now()*1000 seq class"
      # I69 wire: the resume command rides every session-ref report
      # (socket-api.mdx:692); the id wins over the path.
      assert_equal ["tart", "-r", "sid-9"], params["resume_argv"]
    end

    def test_session_report_without_a_reason_omits_the_source_field
      reporter = Herdr::Reporter.new(socket_path: @sock, timeouts: [20, 20])
      reporter.report_session({"agent_session_id" => "sid"}, pane_id: "p7")

      params = read_one["params"]

      refute params.key?("session_start_source")
      assert_equal "sid", params["agent_session_id"], "the id ref rides when no path exists"
      assert_equal ["tart", "-r", "sid"], params["resume_argv"]
    end

    # I69 wire: the id-less ref falls back to the session-file PATH.
    def test_session_resume_argv_falls_back_to_the_path
      reporter = Herdr::Reporter.new(socket_path: @sock, timeouts: [20, 20])
      reporter.report_session({"agent_session_path" => "/tmp/p2.jsonl"}, pane_id: "p7")

      assert_equal ["tart", "-r", "/tmp/p2.jsonl"], read_one["params"]["resume_argv"]
    end

    def test_session_report_without_a_ref_sends_nothing
      reporter = Herdr::Reporter.new(socket_path: @sock, timeouts: [20, 20])
      reporter.report_session(nil, pane_id: "p7")

      assert quiet?, "pi reportSession: no ref, no request"
    end

    def test_state_report_shape_seq_monotonic_and_message_omission
      reporter = Herdr::Reporter.new(socket_path: @sock, timeouts: [20, 20])
      ref = {"agent_session_path" => "/tmp/s.json"}
      reporter.report_session(ref, pane_id: "p7", reason: "startup")
      first = read_one
      reporter.report_state("working", session_ref: ref, pane_id: "p7")
      state = read_one

      assert_equal "pane.report_agent", state["method"]
      assert_equal "working", state["params"]["state"]
      refute state["params"].key?("message"), "message omitted when nil (JSON.stringify drops undefined)"
      assert_operator state["params"]["seq"], :>, first["params"]["seq"], "seq monotonic across report kinds"

      reporter.report_state("blocked", message: "needs approval", session_ref: ref, pane_id: "p7")
      blocked = read_one
      assert_equal "blocked", blocked["params"]["state"]
      assert_equal "needs approval", blocked["params"]["message"]
    end

    # I69 wire: ref-carrying state reports carry the resume command too.
    def test_state_report_carries_resume_argv_on_a_session_ref
      reporter = Herdr::Reporter.new(socket_path: @sock, timeouts: [20, 20])
      reporter.report_state("working", session_ref: {"agent_session_id" => "sid-11"}, pane_id: "p7")

      assert_equal ["tart", "-r", "sid-11"], read_one["params"]["resume_argv"]
    end

    # I69 wire (panes.rs:1561 — validate_optional_resume_argv runs BEFORE
    # the state event in both handlers, so an invalid argv fails the WHOLE
    # report): an apostrophe-bearing path drops the resume_argv, NEVER the
    # report. The same rule covers control characters (socket-api.mdx:692).
    def test_poisoned_session_ref_drops_resume_argv_never_the_report
      reporter = Herdr::Reporter.new(socket_path: @sock, timeouts: [20, 20])
      reporter.report_state("idle", session_ref: {"agent_session_path" => "/tmp/e's.jsonl"}, pane_id: "p7")
      poisoned = read_one
      assert_equal "tart", poisoned["params"]["source"], "the report still sends"
      refute poisoned["params"].key?("resume_argv"), "the poisoned argv attaches NOTHING"

      reporter.report_state("working", session_ref: {"agent_session_path" => "/tmp/e\ts.jsonl"}, pane_id: "p7")
      refute read_one["params"].key?("resume_argv"), "a control character fails the predicate too"

      reporter.report_state("idle", session_ref: {"agent_session_id" => ""}, pane_id: "p7")
      refute read_one["params"].key?("resume_argv"), "an empty target builds nothing"
    end

    # I69 wire: a ref-LESS state report carries no resume_argv.
    def test_refless_state_report_carries_no_resume_argv
      reporter = Herdr::Reporter.new(socket_path: @sock, timeouts: [20, 20])
      reporter.report_state("blocked", message: "ask", session_ref: nil, pane_id: "p7")

      refute read_one["params"].key?("resume_argv")
    end

    def test_same_state_and_message_reports_dedup
      reporter = Herdr::Reporter.new(socket_path: @sock, timeouts: [20, 20])
      ref = {"agent_session_path" => "/tmp/s.json"}
      reporter.report_state("working", session_ref: ref, pane_id: "p7")
      read_one
      reporter.report_state("working", session_ref: ref, pane_id: "p7")
      reporter.report_state("working", session_ref: ref, pane_id: "p7")

      assert quiet?, "deduped same-state reports must not connect"
    end

    def test_socket_failures_are_swallowed_and_retried_once
      reporter = Herdr::Reporter.new(socket_path: File.join(@dir, "missing.sock"), timeouts: [20, 20])
      reporter.report_state("idle", session_ref: {"agent_session_path" => "/s"}, pane_id: "p7")
      reporter.report_session({"agent_session_path" => "/s"}, pane_id: "p7")

      assert quiet?, "failures resolve undelivered — the harness never crashes on herdr"
    end

    def test_states_coalesce_latest_wins_while_a_send_is_in_flight
      hold = Queue.new
      lines = Queue.new
      deliveries = Queue.new
      acceptor = Thread.new do
        held = false
        loop do
          begin
            client = @server.accept
            line = client.gets
            lines << line
            hold.pop unless held # hold ONLY the first send in flight
            held = true
            client.write("ok")
            client.close
            deliveries << JSON.parse(line)
          rescue StandardError
            nil # a client the reporter already abandoned (post-timeout)
          end
        end
      rescue StandardError
        nil
      end

      reporter = Herdr::Reporter.new(socket_path: @sock, timeouts: [500, 500])
      reporter.report_state("working", session_ref: nil, pane_id: "p7")
      wait_until { lines.size == 1 } # the first send is in flight
      reporter.report_state("working", session_ref: nil, pane_id: "p7") # deduped (same state+message)
      reporter.report_state("blocked", message: "ask user", session_ref: nil, pane_id: "p7")
      hold << :release

      first = deliveries.pop
      second = deliveries.pop
      assert_equal "working", first["params"]["state"]
      assert_equal "blocked", second["params"]["state"],
        "only the LATEST queued state sends after the in-flight one"
      assert_equal "ask user", second["params"]["message"]
      # seq is allocated at enqueue (pi queueState) — the winner carries the
      # LAST allocated seq even though the intermediates never sent.
      assert_operator second["params"]["seq"], :>, first["params"]["seq"]
    ensure
      acceptor.kill if acceptor
    end

    # --- the registered state machine ---

    def test_register_full_lifecycle_over_the_seam
      hooks = Hooks.new
      Herdr.register(hooks: hooks, env: @env)
      ctx = {cwd: @dir, mode: "tui", session: {"agent_session_path" => "/tmp/s.json", "agent_session_id" => "sid"}, identity: "pi"}

      hooks.emit({"type" => "session_start", "reason" => "resume"}, context: ctx)
      session_report = read_one
      forced = read_one
      assert_equal "pane.report_agent_session", session_report["method"]
      assert_equal "resume", session_report["params"]["session_start_source"]
      assert_equal "tart", session_report["params"]["source"], "the wire speaks tart's own name in BOTH modes"
      assert_equal ["tart", "-r", "sid"], session_report["params"]["resume_argv"]
      assert_equal "pane.report_agent", forced["method"]
      assert_equal "idle", forced["params"]["state"], "the forced publish at session_start"
      refute forced["params"].key?("message")
      assert_equal ["tart", "-r", "sid"], forced["params"]["resume_argv"], "the forced publish carries the ref's resume command"

      hooks.emit({"type" => "agent_start"}, context: ctx)
      agent_session = read_one
      working = read_one
      assert_equal "pane.report_agent_session", agent_session["method"]
      refute agent_session["params"].key?("session_start_source"), "the agent_start re-report has no source"
      assert_equal "working", working["params"]["state"]

      hooks.emit({"type" => "herdr:blocked", "active" => true, "label" => "ask user"}, context: ctx)
      blocked = read_one
      assert_equal "blocked", blocked["params"]["state"]
      assert_equal "ask user", blocked["params"]["message"]

      hooks.emit({"type" => "herdr:blocked", "active" => false}, context: ctx)
      cleared = read_one
      assert_equal "working", cleared["params"]["state"], "count back to 0 returns to working"
      refute cleared["params"].key?("message")

      hooks.emit({"type" => "agent_end", "interrupted" => false, "messages" => []}, context: ctx)
      idle = read_one
      assert_equal "idle", idle["params"]["state"]
    end

    def test_print_mode_roots_nothing
      hooks = Hooks.new
      Herdr.register(hooks: hooks, env: @env)
      ctx = {cwd: @dir, mode: "print", session: {"agent_session_path" => "/tmp/s.json"}, identity: "pi"}

      hooks.emit({"type" => "session_start", "reason" => "startup"}, context: ctx)
      hooks.emit({"type" => "agent_start"}, context: ctx)

      assert quiet?, "print mode is headless — the TUI-only gate roots nothing"
    end

    def test_env_off_registers_inert
      hooks = Hooks.new
      Herdr.register(hooks: hooks, env: @env.merge("HERDR_ENV" => "0"))
      ctx = {cwd: @dir, mode: "tui", session: {"agent_session_path" => "/tmp/s.json"}, identity: "pi"}

      hooks.emit({"type" => "session_start", "reason" => "startup"}, context: ctx)
      hooks.emit({"type" => "agent_start"}, context: ctx)

      assert quiet?, "the env gate is off — no socket, no state"
    end
  end
end
