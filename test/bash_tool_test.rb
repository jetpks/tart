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
      result = tool.execute(command: "echo out; echo err >&2")
      assert_includes result, "out"
      assert_includes result, "err"
    end

    def test_non_zero_exit_is_an_error_result_with_status_line
      result = tool.execute(command: "exit 3")
      assert result.key?(:error)
      assert_includes result[:error], "Command exited with code 3"
    end

    def test_timeout_kills_process_group_with_term_and_reaps
      marker = "tart-probe-#{Process.pid}-#{rand(1_000_000)}"
      command = "echo #{marker}; sleep 30"

      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = tool.execute(command:, timeout: 1)
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
      result = tool.execute(command:, timeout: 1)
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
      result = tool.execute(command: "#{marker}-grandchild & sleep 30", timeout: 1)

      assert result.key?(:error)
      assert_no_probe(marker)
    end

    def test_invalid_timeout_rejected
      result = tool.execute(command: "true", timeout: -1)
      assert result.key?(:error)
      assert_includes result[:error], "Invalid timeout: must be a finite number of seconds"
    end

    def test_cancellation_kills_process_group_and_propagates
      marker = "tart-probe-#{Process.pid}-#{rand(1_000_000)}"
      cancelled = false
      checkpoint = -> { raise RubyLLM::CancelledError, "cancelled" if cancelled }

      error = nil
      watcher = Thread.new do
        RubyLLM::Support::Cancellation.watch(checkpoint) do
          tool.execute(command: "echo #{marker}; sleep 30")
        end
      rescue RubyLLM::CancelledError => e
        error = e
      end

      sleep 0.3 # let the command start
      cancelled = true # the interrupt: chat.cancel flips the flag
      watcher.join(10)

      assert_instance_of RubyLLM::CancelledError, error
      assert_no_probe(marker)
    end

    def test_output_truncation_shows_tail_and_spills_full_output
      result = tool.execute(command: "seq 1 3000")
      assert_includes result, "[Showing lines 1001-3000 of 3000"
      assert_includes result, "Full output: #{tool.details[:full_output_path]}"
      assert File.exist?(tool.details[:full_output_path])
    end

    # ---- run_user: the !-prefix executor (pi bash-executor.ts) over the
    # same spawn core — the BashResult assembly, no model-facing notice,
    # no error wrapping. ----

    def test_run_user_reports_non_zero_exit_without_error_wrapping
      outcome = tool.run_user("echo out; exit 3")

      assert_equal 3, outcome.exit_code
      refute outcome.cancelled, "a non-zero exit REPORTS — it does not raise into an error result"
      assert_includes outcome.content, "out"
      refute_includes outcome.content, "Showing lines", "no model-facing notice"
      refute_includes outcome.content, "Command exited"
    end

    def test_run_user_carries_truncation_details_and_spills
      outcome = tool.run_user("seq 1 2100")

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

    # ---- the chunk seam (I38 — pi executeBashWithOperations' onChunk,
    # bash-executor.ts:96-98: per pipe read, CR-REMOVED text). ----

    # AC3: the joined callback stream equals the returned content after
    # its CR-strip — the seam hands the same discipline the settled bytes
    # carry (Grounds 2).
    def test_run_user_streamed_chunks_join_to_the_returned_content
      chunks = []
      outcome = tool.run_user("printf 'alpha\\n'; sleep 0.2; printf 'beta\\r\\ngamma'",
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
      outcome = tool.run_user("printf 'early\\n'; sleep 0.3; printf 'late\\n'",
        on_chunk: ->(text) { seen_after_return ||= text if returned })
      returned = true

      assert_includes outcome.content, "early"
      assert_nil seen_after_return, "chunks fired before run_user returned"
    end

    # A CR-only chunk strips to nothing — the joined stream is unaffected
    # (the chat-level append is inert on "").
    def test_run_user_cr_only_chunk_strips_to_nothing
      chunks = []
      tool.run_user("printf 'a\\rb'", on_chunk: ->(text) { chunks << text })

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
    # (reaper thread + Queue), so `echo` rounds to Took 0.0s like pi.
    def test_fast_commands_pay_no_poll_quantum
      durations = Array.new(10) do
        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = tool.execute(command: "echo pty-tester")
        assert_includes result, "pty-tester"
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
      end
      median = durations.sort[4, 2].sum / 2
      assert_operator median, :<, 0.05, "durations: #{durations.map { it.round(4) }}"
    end

    private

    def tool
      @tool ||= Tools::Bash.new(cwd: @dir)
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
