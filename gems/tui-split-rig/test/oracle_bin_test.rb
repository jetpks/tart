# frozen_string_literal: true

require_relative "../../../test/test_helper"
require_relative "../lib/tui_split_rig"
require "fileutils"
require "shellwords"
require "tmpdir"

module TuiSplitRig
  # The I67 oracle resolution seam (R1) and the tart-pane docs pin (R2),
  # moved to the promoted worktree by I114: the promoted standing
  # worktree build/pi-oracle-v1.6.0 @ v1.6.0 is the rig's ONLY default
  # oracle — the system pi on PATH is never consulted, the retired
  # repos/pi v1.1.0 clone is flag/env-reachable only, and both panes
  # resolve the SAME install (the staged bin/pi symlink tart's
  # pi_package_dir walk realpaths through).
  class OracleBinTest < Tart::Test
    # The promoted pi oracle is local-only; skip whole-file on CI runners.
    def setup
      skip "promoted pi oracle worktree absent (local grounding artifact)" unless TuiSplitRig.oracle_available?
    end

    REPO_ROOT = File.expand_path("#{__dir__}/../../..")
    SCENARIO = File.join(REPO_ROOT, "gems/tui-split-rig/scenarios/s1_text_turn.yml")

    def test_oracle_bin_resolution_order_flag_then_env_then_worktree_default
      Dir.mktmpdir do |t|
        tart_root = File.join(t, "tart")
        FileUtils.mkdir(tart_root)
        # The worktree layout beside the injected tart root:
        # <tmp>/build/pi-oracle-v1.6.0/packages/coding-agent/dist/bundle/cli.js
        # (the deterministic relative derivation — no git fallback for
        # explicit roots, so a tmpdir fixture stages the same layout).
        cli = File.join(t, "build", "pi-oracle-v1.6.0", "packages", "coding-agent", "dist", "bundle", "cli.js")
        FileUtils.mkdir_p(File.dirname(cli))
        File.write(cli, "#!/bin/sh\n")
        FileUtils.chmod("+x", cli)

        # flag wins over everything (the --pi-bin override, verbatim).
        assert_equal "/explicit/pi",
          TuiSplitRig.resolve_pi_bin(flag: "/explicit/pi",
                                     env: {"TUI_SPLIT_RIG_PI_BIN" => "/env/pi"},
                                     tart_root: tart_root)
        # env beats the worktree default (the TUI_SPLIT_RIG_PI_BIN hatch).
        assert_equal "/env/pi",
          TuiSplitRig.resolve_pi_bin(env: {"TUI_SPLIT_RIG_PI_BIN" => "/env/pi"},
                                     tart_root: tart_root)
        # worktree default: derived relative to the injected tart root
        # (absolute, no PATH consult, no git fallback for explicit roots).
        assert_equal File.expand_path(cli),
          TuiSplitRig.resolve_pi_bin(env: {}, tart_root: tart_root)
      end
    end

    def test_oracle_bin_missing_worktree_raises_error_naming_the_expected_path
      Dir.mktmpdir do |t|
        tart_root = File.join(t, "checkout")
        FileUtils.mkdir(tart_root)
        error = assert_raises(Error) { TuiSplitRig.resolve_pi_bin(env: {}, tart_root: tart_root) }
        assert_match(%r{packages/coding-agent/dist/bundle/cli\.js}, error.message)
      end
    end

    def test_oracle_bin_real_repo_default_resolves_the_promoted_worktree_cli
      bin = TuiSplitRig.resolve_pi_bin(env: {})
      assert File.absolute_path?(bin)
      assert File.executable?(bin), "resolved default not executable: #{bin}"
      assert_match(%r{build/pi-oracle-v1\.6\.0/packages/coding-agent/dist/bundle/cli\.js\z}, bin)
      refute_match(%r{repos/pi/}, bin, "the retired pinned clone is never the default again")
    end

    def test_oracle_bin_promoted_worktree_reports_version_1_6_0
      bin = TuiSplitRig.resolve_pi_bin(env: {})
      # PI_PACKAGE_DIR is stripped: pi's getPackageDir prefers the env
      # over the __dirname walk (coding-agent config.ts:393-405).
      out = %x(env -u PI_PACKAGE_DIR node #{Shellwords.escape(bin)} --version)
      assert_equal "1.6.0", out.strip
    end

    def test_oracle_bin_default_never_resolves_the_path_pi
      path_pi = %x(sh -c "command -v pi").to_s.strip
      refute_equal path_pi, TuiSplitRig.resolve_pi_bin(env: {}) unless path_pi.empty?
    end

    def test_oracle_bin_stage_tart_home_symlinks_pi_into_the_promoted_worktree
      runner = Runner.new(scenario: Scenario.load(SCENARIO))
      Dir.mktmpdir do |home|
        link = File.join(home, "bin", "pi")
        runner.stage_tart_home(home, 1234)
        assert File.symlink?(link), "staged bin/pi missing: #{link}"
        assert_match(%r{build/pi-oracle-v1\.6\.0/packages/coding-agent/dist/bundle/cli\.js\z}, File.realpath(link))
      end
    end
  end
end
