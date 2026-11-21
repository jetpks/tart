# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"

module Tart
  # I102 (KB I17 S1) — the rg deadline: a stuck rg (never writes, never
  # exits) is killed by the watchdog at TOOL_TIMEOUT_S and the call returns
  # the teaching-refusal envelope instead of hanging the session. The fake
  # rg honors TERM (trap → exit) per the frozen spec, so the process-group
  # kill is exercised through the TERM path.
  class GrepDeadlineTest < Test
    def setup
      @dir = Dir.mktmpdir("tart-grep-deadline-")
      File.write(File.join(@dir, "apple.txt"), "one\n")
      @fake_bin = File.join(@dir, "bin")
      FileUtils.mkdir_p(@fake_bin)
      @saved_path = ENV["PATH"]
      @saved_timeout = ENV["TOOL_TIMEOUT_S"]
    end

    def teardown
      ENV["PATH"] = @saved_path
      ENV["TOOL_TIMEOUT_S"] = @saved_timeout
      FileUtils.rm_rf(@dir)
    end

    # g1 — the deadline fires, the envelope teaches, the group is gone,
    # and the calling thread survives (returns well within timeout+10).
    def test_deadline_fires_and_returns_teaching_envelope
      inject_stuck_rg(honor_term: true)
      ENV["TOOL_TIMEOUT_S"] = "1"
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = Tools::Grep.new(cwd: @dir).execute(pattern: "hello", path: @dir, glob: "*.json")
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      assert elapsed < 11, "calling thread must survive: took #{elapsed.round(1)}s"
      assert_hash_error result
      assert_equal \
        "TOOL_TIMEOUT: grep exceeded 1s and was killed (pattern=hello path=#{@dir} glob=*.json). " \
        "Narrow the search: a smaller path, a tighter glob, or a more specific pattern.",
        result[:error]
      # the fake rg's whole process group is gone
      leftovers = `pgrep -f "#{@fake_bin}/rg" 2>/dev/null`.strip
      assert_equal "", leftovers, "stuck rg survived the deadline: #{leftovers}"
    end

    # A target that IGNORES TERM must not wedge the call either — the
    # escalation is time-based (TERM, grace, liveness probe, KILL). This
    # is the regression test for the probed defect: a rescue-only chain
    # (TERM rescue KILL) never escalates, because the TERM SEND succeeds.
    def test_deadline_kills_term_ignoring_rg
      inject_stuck_rg(honor_term: false)
      ENV["TOOL_TIMEOUT_S"] = "1"
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = Tools::Grep.new(cwd: @dir).execute(pattern: "hello")
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      assert_hash_error result
      assert_includes result[:error], "grep exceeded 1s"
      assert elapsed < 11, "TERM-ignoring rg wedged the call: #{elapsed.round(1)}s"
      leftovers = `pgrep -f "#{@fake_bin}/rg" 2>/dev/null`.strip
      assert_equal "", leftovers, "TERM-ignoring rg survived the KILL escalation: #{leftovers}"
    end

    # g1 — glob=nil renders as "-" in the refusal.
    def test_deadline_envelope_renders_absent_glob_as_dash
      inject_stuck_rg(honor_term: true)
      ENV["TOOL_TIMEOUT_S"] = "1"
      result = Tools::Grep.new(cwd: @dir).execute(pattern: "x", path: @dir)
      assert_hash_error result
      assert_includes result[:error], "(pattern=x path=#{@dir} glob=-)."
    end

    # g2 — TOOL_TIMEOUT_S configures the deadline (fires ~2 s).
    def test_deadline_configurable_via_env
      inject_stuck_rg(honor_term: true)
      ENV["TOOL_TIMEOUT_S"] = "2"
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = Tools::Grep.new(cwd: @dir).execute(pattern: "hello")
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      assert_hash_error result
      assert_includes result[:error], "grep exceeded 2s"
      assert elapsed >= 1.8, "deadline fired too early (#{elapsed.round(1)}s)"
      assert elapsed < 12, "deadline did not stay bounded (#{elapsed.round(1)}s)"
    end

    # g2 — non-numeric junk falls back to the default without crashing;
    # the grep itself completes normally.
    def test_non_numeric_timeout_falls_back_without_crashing
      ENV["TOOL_TIMEOUT_S"] = "not-a-number"
      result = Tools::Grep.new(cwd: @dir).execute(pattern: "one")
      assert_equal "apple.txt:1: one", result
    end

    # The degenerate explicit values (zero, negative) also fall back —
    # an instantly-firing or nonsensical deadline would break every grep.
    def test_zero_and_negative_timeouts_fall_back
      ENV["TOOL_TIMEOUT_S"] = "0"
      assert_equal "apple.txt:1: one", Tools::Grep.new(cwd: @dir).execute(pattern: "one")
      ENV["TOOL_TIMEOUT_S"] = "-5"
      assert_equal "apple.txt:1: one", Tools::Grep.new(cwd: @dir).execute(pattern: "one")
    end

    # Normal paths unchanged: the watchdog retires quietly on completion.
    def test_normal_grep_unaffected_by_watchdog
      result = Tools::Grep.new(cwd: @dir).execute(pattern: "one")
      assert_equal "apple.txt:1: one", result
      assert_equal "No matches found", Tools::Grep.new(cwd: @dir).execute(pattern: "zzz")
    end

    private

    def inject_stuck_rg(honor_term: true)
      fake = File.join(@fake_bin, "rg")
      trap_line = honor_term ? "trap 'exit 0' TERM" : "trap '' TERM"
      File.write(fake, <<~SH)
        #!/bin/bash
        # stuck rg (TERM #{honor_term ? "honored" : "IGNORED"}): sleeps forever
        # and never writes a byte — the wedge shape.
        #{trap_line}
        sleep 300
      SH
      File.chmod(0o755, fake)
      ENV["PATH"] = "#{@fake_bin}:#{ENV['PATH']}"
    end

    def assert_hash_error(result)
      assert result.is_a?(Hash) && result.key?(:error), "expected {error:} envelope, got #{result.inspect}"
    end
  end
end
