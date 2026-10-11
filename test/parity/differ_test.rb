# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/tart/parity"

module Tart
  # Differ + registry on the shipped synthetic fixtures — both directions of
  # AC2: every difference line covered (clean?) and at least one uncovered
  # (candidates). The fixture names are frozen (the gates reference them).
  class ParityDifferTest < Test
    FIXTURES = File.expand_path("fixtures", __dir__)

    def test_covered_pair_classifies_every_difference_line
      differ = run_diff("covered-a.capture", "covered-b.capture", "registry-covers.yml")
      refute_empty differ.classifications
      assert_empty differ.candidates
      assert_predicate differ, :clean?
      assert_equal %w[test-logo-art test-sandbox-path], differ.per_class.keys.sort
    end

    def test_gapped_pair_surfaces_unknown_candidates
      differ = run_diff("gapped-a.capture", "gapped-b.capture", "registry-gaps.yml")
      refute_empty differ.candidates
      refute_predicate differ, :clean?
      assert_includes differ.per_class.keys, "unknown-candidate"
      assert_includes differ.per_class.keys, "test-sandbox-path"
      assert_includes differ.candidates.map { |c| c.op.line }, "> hello again"
      # prompt lines (a AND b) and reply lines match no class in the gapped
      # registry; the path noise stays sanctioned.
      assert_equal 4, differ.per_class.fetch("unknown-candidate")
    end

    def test_unified_has_diff_hunks_over_the_raw_lines
      differ = run_diff("covered-a.capture", "covered-b.capture", "registry-covers.yml")
      unified = differ.unified.join("\n")
      assert_match(/\A@@ -\d+,\d+ \+\d+,\d+ @@/, unified)
      assert_match(/\+  ▒▒▒▒▒▒/, unified)
      assert_match(/\+footer-cwd \/stage\/run-b-sandbox-22/, unified)
    end

    private

    def run_diff(a, b, registry)
      Parity::Differ.diff(
        File.read(File.join(FIXTURES, a)),
        File.read(File.join(FIXTURES, b)),
        Parity::Registry.load(File.join(FIXTURES, registry))
      )
    end
  end
end
