# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "tmpdir"
require "fileutils"

module Tart
  # The I94 edit-integrity battery (issue #15): an applied edit can never
  # report failure — the tool's result is structurally independent of
  # display-metadata generation, the unified patch derives from the ONE
  # line_diff_parts recipe (git-apply-clean, byte-exact round-trips), and
  # safe_execute tells the truth with context while pi's ArgumentError
  # contract messages stay byte-exact.
  #
  # Hermetic: no network, no live LLM. The only injections are the two
  # sanctioned metadata-crash/cancellation stubs (pins E3–E5 — the defect
  # class demands them) and the declared `git apply` shells for the
  # round-trip pins (git is on the dev machine and the CI runners).
  class EditIntegrityTest < Test
    ORIG = File.read(File.expand_path("fixtures/edit_i15_repro_orig.md", __dir__))
    EDITS = JSON.parse(File.read(File.expand_path("fixtures/edit_i15_repro_edits.json", __dir__)))["edits"]
      .map { |e| {oldText: e["oldText"], newText: e["newText"]} }.freeze

    def setup
      @dir = Dir.mktmpdir("tart-edit-integrity-")
    end

    def teardown
      FileUtils.remove_entry(@dir)
    end

    def write_file(name, content)
      path = File.join(@dir, name)
      File.write(path, content)
      path
    end

    # The orig with the four recorded replacements applied in order — each
    # oldText is unique in the file (the tool enforces uniqueness), so a
    # first-occurrence replacement per edit is the exact oracle. Block form:
    # replacement text must ride verbatim (no $-escape processing).
    def expected_content
      EDITS.reduce(ORIG) { |content, edit| content.sub(edit[:oldText]) { edit[:newText] } }
    end

    # The ONE sanctioned injection shape (the gate leg-1 driver idiom):
    # swap EditDiff.generate_unified_patch for a raiser and restore the
    # original afterward — load-bearing, rake runs the suite in one process.
    def with_metadata_raiser(exception_class, message)
      original = Tools::EditDiff.method(:generate_unified_patch)
      Tools::EditDiff.define_singleton_method(:generate_unified_patch) { |*| raise exception_class, message }
      yield
    ensure
      Tools::EditDiff.define_singleton_method(:generate_unified_patch, original)
    end

    # git-apply round-trip: the patch applied to the ORIGINAL content must
    # reproduce the new bytes byte-exact. The file is written under the
    # name embedded in the patch's frozen envelope — git apply targets it.
    def assert_patch_round_trips(orig_content, new_content, patch)
      Dir.mktmpdir("tart-edit-apply-") do |apply_dir|
        patched_name = patch[/\A--- (.+)\n/, 1]
        File.write(File.join(apply_dir, patched_name), orig_content)
        File.write(File.join(apply_dir, "p.diff"), patch)
        assert system("git", "-C", apply_dir, "apply", "--check", "p.diff",
                      out: File::NULL, err: File::NULL), "git apply --check must accept the patch"
        assert system("git", "-C", apply_dir, "apply", "p.diff",
                      out: File::NULL, err: File::NULL), "git apply must succeed"
        assert_equal new_content, File.read(File.join(apply_dir, patched_name)),
          "the patch applied to the original must reproduce the new bytes byte-exact"
      end
    end

    def trivial_edits
      [{oldText: "bravo", newText: "BRAVO"}]
    end

    # ---- pin 1: the i15 shape end-to-end ----

    def test_the_i15_repro_reports_success_applies_all_four_edits_and_the_patch_round_trips
      write_file("ARCHITECT.md", ORIG)
      tool = Tools::Edit.new(cwd: @dir)
      result = tool.execute(path: "ARCHITECT.md", edits: EDITS)

      assert_equal "Successfully replaced 4 block(s) in ARCHITECT.md.", result,
        "the reported result is the pi success string"
      assert_equal expected_content, File.read(File.join(@dir, "ARCHITECT.md")),
        "all four edits must land byte-exact"
      patch = tool.details[:patch]
      assert patch.is_a?(String) && !patch.empty?, "the unified patch rides on success"
      assert patch.start_with?("--- ARCHITECT.md\n+++ ARCHITECT.md\n@@ "), "the frozen envelope"
      assert_patch_round_trips(ORIG, expected_content, patch)
    end

    # ---- pin 2: the grouper's three shapes ----

    def test_unified_patch_round_trips_adjacent_disjoint_and_single_line_insert_shapes
      base = Array.new(12) { |i| "line#{i + 1}" }.join("\n") + "\n"

      # Two edits inside one context window merge to ONE hunk (gap ≤ 2×context).
      adjacent_new = base.sub("line2\n", "LINE2\n").sub("line5\n", "LINE5\n")
      patch = Tools::EditDiff.generate_unified_patch("f.txt", base, adjacent_new)
      assert_equal 1, patch.scan(/^@@ /).length, "adjacent edits merge to one hunk"
      assert_patch_round_trips(base, adjacent_new, patch)

      # Two edits far apart (gap > 2×context) stay two hunks.
      far_new = base.sub("line2\n", "LINE2\n").sub("line12\n", "LINE12\n")
      patch = Tools::EditDiff.generate_unified_patch("f.txt", base, far_new)
      assert_equal 2, patch.scan(/^@@ /).length, "far-apart edits stay two hunks"
      assert_patch_round_trips(base, far_new, patch)

      # A single-line insertion.
      insert_new = base.sub("line3\n", "line3\ninserted\n")
      patch = Tools::EditDiff.generate_unified_patch("f.txt", base, insert_new)
      assert_equal 1, patch.scan(/^@@ /).length, "one insertion, one hunk"
      assert_patch_round_trips(base, insert_new, patch)
    end

    # ---- pin 3: the metadata-independence invariant (the sanctioned crash) ----

    def test_a_metadata_crash_never_flips_a_completed_mutation
      path = write_file("f.txt", "alpha\nbravo\ncharlie\n")
      tool = Tools::Edit.new(cwd: @dir)
      result = nil
      with_metadata_raiser(RuntimeError, "injected metadata crash") do
        result = tool.execute(path: "f.txt", edits: trivial_edits)
      end

      assert_equal "Successfully replaced 1 block(s) in f.txt.", result,
        "a completed mutation is never reported as a failure"
      assert_equal "alpha\nBRAVO\ncharlie\n", File.read(path), "the file is written"
      assert_nil tool.details, "the degraded call carries NO details (no placeholder patch)"
    end

    # ---- pin 4: the guard's warn line ----

    def test_a_metadata_crash_warns_with_class_and_message
      write_file("f.txt", "alpha\nbravo\ncharlie\n")
      tool = Tools::Edit.new(cwd: @dir)
      assert_output(nil, /edit: display metadata generation failed: RuntimeError: injected/) do
        with_metadata_raiser(RuntimeError, "injected metadata crash") do
          tool.execute(path: "f.txt", edits: trivial_edits)
        end
      end
    end

    # ---- pin 5: cancellation always propagates, before the write ----

    def test_cancellation_propagates_through_the_metadata_guard
      path = write_file("f.txt", "alpha\nbravo\ncharlie\n")
      tool = Tools::Edit.new(cwd: @dir)
      assert_raises(Fast::Completions::CancelledError) do
        with_metadata_raiser(Fast::Completions::CancelledError, "cancel injected") do
          tool.execute(path: "f.txt", edits: trivial_edits)
        end
      end
      assert_equal "alpha\nbravo\ncharlie\n", File.read(path),
        "the file is NOT written — the guard re-raises before the write"
    end

    # ---- pin 6: safe_execute's two error shapes ----

    def test_safe_execute_error_shapes
      raising_tool = Class.new do
        include Tools::SafeExecute

        def execute(raised)
          safe_execute { raise raised }
        end
      end.new

      result = raising_tool.execute(NoMethodError.new("boom"))
      assert_match(/\ANoMethodError: boom \(at .+\)\z/, result[:error],
                   "an internal defect carries class + first backtrace line")

      result = raising_tool.execute(ArgumentError.new("pi contract message"))
      assert_equal({error: "pi contract message"}, result,
                   "ArgumentError is pi's contract raise — byte-exact, no annotation")
    end
  end
end
