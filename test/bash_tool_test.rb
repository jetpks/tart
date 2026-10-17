# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"

module Tart
  # The bash tool's safety properties (AC4), hermetic and bounded: the
  # process-group child, timeout kill by negative-pid -TERM escalating to
  # -KILL, every pid reaped, no zombie, no leaked pipes.
  class BashToolTest < Test
    def setup
      @dir = Dir.mktmpdir("tart-bash-")
    end

    def teardown
      FileUtils.rm_rf(@dir)
    end

    def test_output_streams_and_normal_exit
      result = execute_tool(command: "echo out; echo err >&2")
      assert_includes result, "out"
      assert_includes result, "err"
    end

    def test_non_zero_exit_is_an_error_result_with_status_line
      result = execute_tool(command: "exit 3")
      assert result.key?(:error)
      assert_includes result[:error], "Command exited with code 3"
    end

    def test_timeout_kills_process_group_with_term_and_reaps
      marker = "tart-probe-#{Process.pid}-#{rand(1_000_000)}"
      command = "echo #{marker}; sleep 30"

      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = execute_tool(command:, timeout: 1)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0

      assert result.key?(:error), "a timed-out command must be an error result"
      assert_includes result[:error], "Command timed out after 1 seconds"
      assert_operator elapsed, :<, 5, "the kill path must be bounded"
      assert_no_probe(marker)
    end

    def test_term_ignored_escalates_to_kill
      marker = "tart-probe-#{Process.pid}-#{rand(1_000_000)}"
      command = "trap '' TERM; echo #{marker}; sleep 30"

      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = execute_tool(command:, timeout: 1)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0

      assert result.key?(:error)
      # TERM grace (5s) elapsed, then -KILL: bounded, not unbounded.
      assert_operator elapsed, :>=, 1.0
      assert_operator elapsed, :<, 10
      assert_no_probe(marker)
    end

    def test_child_in_its_own_group_dies_with_the_parent_command
      # A backgrounded grandchild in the group must not survive the kill.
      marker = "tart-probe-#{Process.pid}-#{rand(1_000_000)}"
      result = execute_tool(command: "#{marker}-grandchild & sleep 30", timeout: 1)

      assert result.key?(:error)
      assert_no_probe(marker)
    end

    def test_invalid_timeout_rejected
      result = execute_tool(command: "true", timeout: -1)
      assert result.key?(:error)
      assert_includes result[:error], "Invalid timeout: must be a finite number of seconds"
    end

    # I43: the timeout gate is the contract rule now — same pinned message
    # for the non-finite/zero cases, pi's loop wrapper for wrong types.
    def test_non_finite_and_zero_timeouts_reject_with_the_pinned_message
      pinned = {error: "Invalid timeout: must be a finite number of seconds"}
      assert_equal pinned, execute_tool(command: "true", timeout: Float::INFINITY)
      assert_equal pinned, execute_tool(command: "true", timeout: 0)
    end

    def test_wrong_typed_timeout_rejects_with_the_wrapper_vocabulary
      result = execute_tool(command: "true", timeout: "5")

      assert result.is_a?(Hash) && result.key?(:error)
      assert result[:error].start_with?("Validation failed for tool \"bash\":\n  - timeout: "),
        result[:error].inspect
      assert_includes result[:error], "Received arguments:"
    end

    def test_cancellation_kills_process_group_and_propagates
      marker = "tart-probe-#{Process.pid}-#{rand(1_000_000)}"
      error = nil
      watcher = Thread.new do
        begin
          Async do
            # The interrupt cancels the tool's TASK (the gem checkpoints
            # read the task state — no flag pairing anywhere): the cancel
            # lands at the execute's next cooperative wait and propagates
            # through the tool's group-kill rescue.
            child = Async::Task.current.async do
              begin
                tool.execute(command: "echo #{marker}; sleep 30")
              rescue Async::Cancel => e
                error = e
                raise
              end
            end
            sleep 0.3 # let the command start
            child.cancel # the interrupt
            begin
              child.wait
            rescue Async::Cancel
              nil # a cancelled child's wait is quiet in async 2.x
            end
          end.wait
        rescue Async::Cancel
          nil
        end
      end
      watcher.join(10)

      assert_instance_of Async::Cancel, error
      assert_no_probe(marker)
    end

    def test_output_truncation_shows_tail_and_spills_full_output
      result = execute_tool(command: "seq 1 3000")
      assert_includes result, "[Showing lines 1001-3000 of 3000"
      assert_includes result, "Full output: #{tool.details[:full_output_path]}"
      assert File.exist?(tool.details[:full_output_path])
    end

    # ---- run_user: the !-prefix executor (pi bash-executor.ts) over the
    # same spawn core — the BashResult assembly, no model-facing notice,
    # no error wrapping. ----

    def test_run_user_reports_non_zero_exit_without_error_wrapping
      outcome = run_user_tool("echo out; exit 3")

      assert_equal 3, outcome.exit_code
      refute outcome.cancelled, "a non-zero exit REPORTS — it does not raise into an error result"
      assert_includes outcome.content, "out"
      refute_includes outcome.content, "Showing lines", "no model-facing notice"
      refute_includes outcome.content, "Command exited"
    end

    def test_run_user_carries_truncation_details_and_spills
      outcome = run_user_tool("seq 1 2100")

      assert outcome.truncation.truncated
      assert_match(%r{/tart-bash-[0-9a-f]{16}\.log\z}, outcome.full_output_path,
        "the spill name is pi's fixed 16-hex shape (output-files.ts:15-17)")
      assert_equal 2000, outcome.truncation.output_lines
      assert File.exist?(outcome.full_output_path)
    end

    def test_run_user_cancellation_returns_partial_output_and_kills_the_group
      marker = "tart-probe-#{Process.pid}-#{rand(1_000_000)}"
      outcome = nil
      Async do |root|
        task = root.async { outcome = tool.run_user("echo #{marker}; sleep 30") }
        sleep 0.3 # the command is running
        task.stop # the escape-cancel path (@user_bash_task.stop)
      end

      assert outcome.cancelled, "the aborted command reports cancelled"
      assert_nil outcome.exit_code, "pi: exitCode undefined when cancelled"
      assert_includes outcome.content, marker, "the output produced so far returns"
      assert_no_probe(marker)
    end

    # I50 de-bridge AC4: a cancelled bash run leaves NO zombie. The tool
    # task is stopped mid-run (the escape-cancel shape); a stopped task
    # takes its child reaper task with it (async stop_children), the group
    # -KILL guarantees the child's death, and SOMEONE reaps (the surviving
    # reaper, else the rescue's bounded self-reap) — the pid is GONE from
    # the process table after the unwind: reaped, not zombie.
    def test_cancelled_bash_run_leaves_no_zombie
      pid_file = File.join(@dir, "child-pid")
      outcome = nil
      Async do |root|
        task = root.async { tool.execute(command: "echo $$ > #{pid_file}; sleep 5") }
        wait_until { File.exist?(pid_file) } # the command is running
        task.stop # the escape-cancel path
        begin
          outcome = task.wait
        rescue Async::Cancel
          outcome = :cancelled
        end
      end

      pid = File.read(pid_file).strip
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
      state = nil
      while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        state = `ps -o stat= -p #{pid} 2>/dev/null`.to_s.strip
        break if state.empty?

        refute state.start_with?("Z"), "the killed child is a ZOMBIE (stat=#{state.inspect})"
        sleep 0.05
      end
      assert_empty state, "the killed child must be reaped (gone from the process table)"
    end

    # ---- the chunk seam (I38 — pi executeBashWithOperations' onChunk,
    # bash-executor.ts:96-98: per pipe read, CR-REMOVED text). ----

    # AC3: the joined callback stream equals the returned content after
    # its CR-strip — the seam hands the same discipline the settled bytes
    # carry (Grounds 2).
    def test_run_user_streamed_chunks_join_to_the_returned_content
      chunks = []
      outcome = run_user_tool("printf 'alpha\\n'; sleep 0.2; printf 'beta\\r\\ngamma'",
        on_chunk: ->(text) { chunks << text })

      assert_operator chunks.length, :>=, 2, "both pipe reads fired the seam"
      assert_equal outcome.content, chunks.join,
        "the joined callback stream equals the returned content after its CR-strip"
      refute_includes chunks.join, "\r", "CR removed per chunk, not just at the snapshot"
    end

    # The seam fires during the run (pi appendOutput + requestRender per
    # chunk, interactive-mode.ts:7050-7057) — not once at the return.
    def test_run_user_fires_the_seam_midflight_not_after_the_return
      seen_after_return = nil
      returned = false
      outcome = run_user_tool("printf 'early\\n'; sleep 0.3; printf 'late\\n'",
        on_chunk: ->(text) { seen_after_return ||= text if returned })
      returned = true

      assert_includes outcome.content, "early"
      assert_nil seen_after_return, "chunks fired before run_user returned"
    end

    # A CR-only chunk strips to nothing — the joined stream is unaffected
    # (the chat-level append is inert on "").
    def test_run_user_cr_only_chunk_strips_to_nothing
      chunks = []
      run_user_tool("printf 'a\\rb'", on_chunk: ->(text) { chunks << text })

      assert chunks.all? { |text| !text.include?("\r") }, "CR removed per chunk (AC3)"
      assert_equal "ab", chunks.join
    end

    # The seam rides run_user alone: the model-facing execute passes
    # nothing (its render is the I34 pending block — pi's tool path
    # streams no chunk callback either).
    def test_execute_takes_no_chunk_callback
      assert_includes Tools::Bash.instance_method(:run_user).parameters.flatten, :on_chunk,
        "the on_chunk seam rides run_user"
      refute_includes Tools::Bash.instance_method(:execute).parameters.flatten, :on_chunk,
        "execute passes nothing — no callback can fire on the model-facing path"
    end

    # AC3: fast commands pay no poll quantum — exit detection is evented
    # (reaper task + Queue), so `echo` rounds to Took 0.0s like pi.
    def test_fast_commands_pay_no_poll_quantum
      durations = Array.new(10) do
        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = execute_tool(command: "echo pty-tester")
        assert_includes result, "pty-tester"
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
      end
      median = durations.sort[4, 2].sum / 2
      assert_operator median, :<, 0.05, "durations: #{durations.map { it.round(4) }}"
    end

    # ---- the session-env exposure family (I41 AC3 — pi's
    # resolveSpawnContext, bash.ts:186-208): the TOOL path composes the
    # child env (scrub-then-set, per-spawn resolution); run_user keeps
    # plain inheritance. ----

    # (a) the five vars present with correct sources.
    def test_session_environment_exposes_pis_five_vars_from_the_readers
      # I69 move: EXPLICIT pi identity (the default resolved tart; the pin
      # tests the pi-parity opt-in's five-var exposure).
      env = child_env(env_tool(identity: "pi", session_env: {
        "SESSION_ID" => -> { "sess-1" }, "SESSION_FILE" => -> { "/tmp/s-1.jsonl" },
        "PROVIDER" => -> { "mock" }, "MODEL" => -> { "glm-5.3" },
        "REASONING_LEVEL" => -> { "high" }
      }))
      assert_equal "sess-1", env["PI_SESSION_ID"]
      assert_equal "/tmp/s-1.jsonl", env["PI_SESSION_FILE"]
      assert_equal "mock", env["PI_PROVIDER"]
      assert_equal "glm-5.3", env["PI_MODEL"]
      assert_equal "high", env["PI_REASONING_LEVEL"]
    end

    # (b) a nil-ing reader leaves its var UNSET but still scrubs an
    # inherited value.
    def test_session_environment_nil_reader_unsets_but_still_scrubs_inherited_value
      ENV["TART_MODEL"] = "inherited-model"
      env = child_env(env_tool(identity: "tart",
        session_env: {"MODEL" => -> { nil }, "SESSION_ID" => -> { "s-1" }}))

      refute env.key?("TART_MODEL"), "the inherited value is scrubbed even though the reader nils"
      assert_equal "s-1", env["TART_SESSION_ID"], "the truthy readers still expose"
    ensure
      ENV.delete("TART_MODEL")
    end

    # (c) an inherited parent var never reaches the child — the scrub
    # happens even when NOTHING is exposed.
    def test_session_environment_inherited_parent_var_never_reaches_the_child
      ENV["PI_SESSION_ID"] = "parent-leak"
      # I69 move: EXPLICIT pi identity (the PI_* scrub is pi-mode's shape).
      env = child_env(env_tool(identity: "pi", session_env: {}))

      refute env.key?("PI_SESSION_ID"), "the parent's value leaks past the scrub"
    ensure
      ENV.delete("PI_SESSION_ID")
    end

    # (d) run_user exposes NOTHING and does NOT scrub — pi's user-bash
    # executor passes no env (bash-executor.ts:48-100): the inherited
    # values ride unscrubbed, the readers never fire. (Vars the test sets
    # itself — the parent harness may carry live PI_* of its own.)
    def test_session_environment_run_user_exposes_nothing_and_never_scrubs
      ENV["PI_SESSION_ID"] = "parent-leak"
      ENV["PI_REASONING_LEVEL"] = "parent-level"
      outcome = run_user_tool('printf "session=%s level=%s" "$PI_SESSION_ID" "$PI_REASONING_LEVEL"',
        tool: env_tool(identity: Identity::PI,
          session_env: {"SESSION_ID" => -> { "composed" }, "REASONING_LEVEL" => -> { "composed-level" }}))

      assert_equal "session=parent-leak level=parent-level", outcome.content,
        "plain inheritance: inherited values ride UNSCRUBBED, the readers never fire"
    ensure
      ENV.delete("PI_SESSION_ID")
      ENV.delete("PI_REASONING_LEVEL")
    end

    # (e) the child keys follow the identity's namespace. The cross-prefix
    # vars are neutralized in the parent (the scrub is prefix-scoped — a
    # foreign-prefix var would legitimately inherit through, pi's rule).
    def test_session_environment_keys_follow_the_identity_namespace
      session_vars = %w[PI_SESSION_ID TART_SESSION_ID FOO_SESSION_ID]
      saved = session_vars.to_h { |key| [key, ENV[key]] }
      begin
        saved.each_key { |key| ENV.delete(key) }
        {
          Identity::PI => "PI_SESSION_ID",
          "tart" => "TART_SESSION_ID",
          "foo" => "FOO_SESSION_ID"
        }.each do |identity, key|
          env = child_env(env_tool(identity:, session_env: {"SESSION_ID" => -> { "s-#{identity}" }}))
          assert_equal "s-#{identity}", env[key]
          (session_vars - [key]).each do |other|
            refute env.key?(other), "#{other} set under identity #{identity}"
          end
        end
      ensure
        saved.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
      end
    end

    # (f) values resolve AT SPAWN — a reader whose value changes between
    # two executes is honored twice (pi's per-command-start resolution).
    def test_session_environment_values_resolve_at_spawn_time
      model = "first"
      # I69 move: EXPLICIT pi identity (the PI_* exposure is pi-mode's shape).
      exposing = env_tool(identity: "pi", session_env: {"MODEL" => -> { model }})

      assert_equal "first", child_env(exposing)["PI_MODEL"]
      model = "second"
      assert_equal "second", child_env(exposing)["PI_MODEL"], "the reader re-resolved at the second spawn"
    end

    # (g) pi-mode parity shape: exactly pi's five key names exposed — the
    # rest of the parent's PI_* inherits untouched (pi's prefix-scoped
    # rule: only its own five are scrubbed, bash.ts:187-191).
    def test_session_environment_pi_mode_shape_is_exactly_pis_five_keys
      composed = Tools::Bash::SESSION_ENV_SUFFIXES.map { |suffix| "PI_#{suffix}" }
      # I69 move: EXPLICIT pi identity (the pin tests pi-mode's exact shape).
      env = child_env(env_tool(identity: "pi", session_env: {
        "SESSION_ID" => -> { "s" }, "SESSION_FILE" => -> { "f" }, "PROVIDER" => -> { "p" },
        "MODEL" => -> { "m" }, "REASONING_LEVEL" => -> { "l" }
      }))

      assert_equal (ENV.keys.grep(/\API_/) - composed + composed).sort, env.keys.grep(/\API_/).sort,
        "the parent's PI_* minus the five scrubbed, plus the five composed — nothing else"
      assert_equal({"PI_SESSION_ID" => "s", "PI_SESSION_FILE" => "f", "PI_PROVIDER" => "p",
                    "PI_MODEL" => "m", "PI_REASONING_LEVEL" => "l"}, env.slice(*composed))
    end

    private

    # The de-bridged tool runs ON a reactor fiber in production (the reaper
    # task and the scheduler's process_wait live there — I50), so the test
    # drives it the same way. Assertions unchanged.
    def execute_tool(command:, timeout: nil, tool: self.tool)
      on_reactor { tool.execute(command:, timeout:) }
    end

    def run_user_tool(command, on_chunk: nil, tool: self.tool)
      on_reactor { tool.run_user(command, on_chunk:) }
    end

    def on_reactor
      Async { yield }.wait
    end

    def tool
      @tool ||= Tools::Bash.new(cwd: @dir)
    end

    # A bash tool wired with the launcher's exposure seams (identity +
    # readers, I41).
    def env_tool(identity: Identity::DEFAULT, session_env: {})
      Tools::Bash.new(cwd: @dir, identity:, session_env:)
    end

    # One execute round-trip: the child's `env` output as a hash (only
    # VAR=VALUE lines parse — inherited multi-line values stay inert).
    def child_env(exposing_tool)
      result = execute_tool(command: "env", tool: exposing_tool)
      raise "env failed: #{result[:error]}" if result.is_a?(Hash)

      result.split("\n").select { |line| line.include?("=") }.to_h { |line| line.split("=", 2) }
    end

    # No zombie, no leaked process: nothing matching the unique marker may
    # remain (the marker appears in /proc pgrep -f output only while the
    # command's process group lives).
    def assert_no_probe(marker)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
      while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        output = `pgrep -fl #{marker} 2>/dev/null`
        return if output.strip.empty?

        sleep 0.1
      end
      flunk "probe processes still alive after kill: #{output}"
    end
  end
end
