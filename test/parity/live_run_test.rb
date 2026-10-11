# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/tart/parity"
require "open3"
require "tmpdir"

module Tart
  # Live end-to-end integration (AC3/AC4/AC4 evidence): runs s1 through the
  # real bin/pty-tester against installed pi and THIS worktree's tart.
  # Opt-in — it drives tmux, boots real processes and takes tens of seconds:
  #
  #   PTY_TESTER_LIVE=1 bundle exec rake test
  class ParityLiveRunTest < Test
    REPO_ROOT = File.expand_path("#{__dir__}/../..")
    BIN = File.join(REPO_ROOT, "bin/pty-tester")
    SCENARIO = File.join(REPO_ROOT, "parity/scenarios/s1_text_turn.yml")

    def test_s1_end_to_end_against_installed_pi_and_this_tart
      skip "set PTY_TESTER_LIVE=1 to run the live parity rig" unless ENV["PTY_TESTER_LIVE"] == "1"

      out = File.join(REPO_ROOT, "tmp", "parity-live-test-#{Process.pid}")
      FileUtils.rm_rf(out)
      git_status_before, = Open3.capture2("git", "-C", REPO_ROOT, "status", "--porcelain")
      output, status = Open3.capture2e(BIN, "run", SCENARIO, "--out", out)

      # AC3: exit 0 or 1 (candidates are expected today; 2 = rig failure).
      assert_includes [0, 1], status.exitstatus, "stderr+stdout: #{output}"

      summary_path = File.join(out, "summary.json")
      assert File.file?(summary_path), "summary.json written"
      summary = JSON.parse(File.read(summary_path))
      assert summary.key?("candidates")

      %w[pi tart].each do |app|
        app_result = summary.fetch("runs").first.fetch("apps").fetch(app)
        assert app_result.fetch("completed"), "#{app} completed"
        assert_equal app_result.fetch("expected_requests"), app_result.fetch("requests"),
          "#{app} mock request count matches the scenario"
        assert File.file?(app_result.fetch("capture")), "#{app} capture written"
      end

      # AC4: the staged dirs took the writes (never the real HOME): tart
      # records sessions under the staged HOME; pi under the staged agent dir.
      stage = summary.fetch("runs").first.fetch("stage")
      %w[pi tart].each do |app|
        root = app == "pi" ? File.join(stage, "agent", "pi") : File.join(stage, "home", app)
        assert staged_took_writes?(root), "staged #{app} root has writes: #{`find #{root} -mindepth 1 | head -20`}"
      end

      # AC4: no surviving app process, no leftover pty-tester-* tmux session.
      leftover_sessions = `tmux ls 2>/dev/null`.lines.grep(/pty-tester-/)
      assert_empty leftover_sessions, "leftover pty-tester sessions: #{leftover_sessions}"
      survivors = `ps -eo command`.lines.grep(/bin\/tart/).grep(/#{Regexp.escape(out)}/)
      assert_empty survivors, "surviving tart processes: #{survivors}"

      # AC4: the rig must not dirty the checkout — the status before the run
      # must survive untouched (a lane's own uncommitted deliverables are
      # pre-existing state, not rig dirt).
      git_status_after, = Open3.capture2("git", "-C", REPO_ROOT, "status", "--porcelain")
      assert_equal git_status_before, git_status_after, "rig must not dirty the worktree"
    ensure
      FileUtils.rm_rf(out) if defined?(out) && out
    end

    private

    def staged_took_writes?(root)
      Dir.exist?(root) && !Dir.empty?(root)
    end
  end
end
