# frozen_string_literal: true

require_relative "../../../test/test_helper"
require_relative "../lib/tui_split_rig"
require "open3"

module TuiSplitRig
  # The frozen CLI contract (BRIEF §2): exit 0 = all difference lines
  # sanctioned; 1 = unknown-candidate lines exist; 2 = rig failure. Proven
  # cold against the shipped fixtures via the real binary.
  class CliTest < Tart::Test
    REPO_ROOT = File.expand_path("#{__dir__}/../../..")
    BIN = File.join(REPO_ROOT, "gems/tui-split-rig/bin/tui-split-rig")
    FIXTURES = File.expand_path("fixtures", __dir__)

    def test_covered_fixture_pair_exits_zero
      output, status = run_diff("covered-a.capture", "covered-b.capture", "registry-covers.yml")
      assert_equal 0, status.exitstatus, output
    end

    def test_gapped_fixture_pair_exits_one_with_candidate_lines
      output, status = run_diff("gapped-a.capture", "gapped-b.capture", "registry-gaps.yml")
      assert_equal 1, status.exitstatus, output
      assert_includes output, "unknown-candidate"
      assert_includes output, "> hello again"
    end

    def test_missing_capture_is_a_rig_failure
      output, status = run_diff("nope.capture", "covered-b.capture", "registry-covers.yml")
      assert_equal 2, status.exitstatus, output
    end

    def test_unknown_verb_is_a_rig_failure
      output, status = Open3.capture2e(BIN, "frobnicate")
      assert_equal 2, status.exitstatus, output
    end

    private

    def run_diff(a, b, registry)
      Open3.capture2e(BIN, "diff", File.join(FIXTURES, a), File.join(FIXTURES, b),
        "--registry", File.join(FIXTURES, registry))
    end
  end
end
