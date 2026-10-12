# frozen_string_literal: true

require_relative "../../../test/test_helper"
require_relative "../lib/tui_split_rig"

module TuiSplitRig
  # Registry matching: data-driven classification, first match wins.
  class RegistryTest < Tart::Test
    RIG_ROOT = File.expand_path("#{__dir__}/..")
    SEED = File.join(RIG_ROOT, "registry.yml")
    # The one owner-ruled non-path pin: the footer model segment's
    # provider prefix (pi's >1-provider gate over a snapshot the port
    # cannot reproduce — footer.ts:246-258).
    SANCTIONED_NON_PATH = ["footer-provider-prefix", "compaction-token-estimate"].freeze

    def test_seed_registry_loads_and_classifies_staged_paths
      registry = Registry.load(SEED)
      assert_equal "staged-sandbox-path",
        registry.classify("~/arch/…/run-1/sandbox/pi-run-1 (master)")
      assert_equal "staged-sandbox-path",
        registry.classify("/Users/eric/arch/…/run-1/sandbox/tart-run-3 (master)")
      assert_equal "parity-run-path", registry.classify("staged home run-2/home/tart/.config")
    end

    def test_unmatched_lines_return_nil_the_unknown_candidate
      registry = Registry.load(SEED)
      assert_nil registry.classify("❯ hello")
      assert_nil registry.classify("tart v0.1.0")
    end

    def test_seed_registry_contains_only_path_or_sandbox_classes
      registry = Registry.load(SEED)
      refute_empty registry.rules
      registry.rules.each do |rule|
        next if SANCTIONED_NON_PATH.include?(rule.name)

        assert_match(/path|sandbox/, rule.name, "seed registry must stay path/sandbox-only: #{rule.name}")
      end
    end

    def test_first_matching_class_wins
      path = File.join(Dir.mktmpdir("tui-split-rig-registry-"), "r.yml")
      File.write(path, <<~YML)
        classes:
          - name: broad
            pattern: 'foo'
          - name: narrow
            pattern: 'foo bar'
      YML
      registry = Registry.load(path)
      assert_equal "broad", registry.classify("foo bar")
    end

    def test_bad_registry_is_a_rig_error
      assert_raises(Error) { Registry.load("/nonexistent/registry.yml") }
      path = File.join(Dir.mktmpdir("tui-split-rig-registry-"), "bad.yml")
      File.write(path, "classes:\n  - name: only-name\n")
      assert_raises(Error) { Registry.load(path) }
    end
  end
end
