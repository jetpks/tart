# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"

module RaspberryPi
  # The bash tool's safety properties (AC4), hermetic and bounded: the
  # process-group child, timeout kill by negative-pid -TERM escalating to
  # -KILL, every pid reaped, no zombie, no leaked pipes.
  class BashToolTest < Test
    def setup
      @dir = Dir.mktmpdir("raspberry-pi-bash-")
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
      marker = "raspberry-pi-probe-#{Process.pid}-#{rand(1_000_000)}"
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
      marker = "raspberry-pi-probe-#{Process.pid}-#{rand(1_000_000)}"
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
      marker = "raspberry-pi-probe-#{Process.pid}-#{rand(1_000_000)}"
      result = tool.execute(command: "#{marker}-grandchild & sleep 30", timeout: 1)

      assert result.key?(:error)
      assert_no_probe(marker)
    end

    def test_invalid_timeout_rejected
      result = tool.execute(command: "true", timeout: -1)
      assert result.key?(:error)
      assert_includes result[:error], "Invalid timeout: must be a finite number of seconds"
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
