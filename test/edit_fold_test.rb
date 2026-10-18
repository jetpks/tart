# frozen_string_literal: true

require_relative "test_helper"
require "json"
require "digest"
require "tmpdir"
require "fileutils"

module Tart
  # The I77 folded-into-`path` recovery battery (AC1/AC2 — the recorded
  # 06:58Z six-call class): the verbatim recorded payload with its
  # canonical-JSON sha asserted, the execution-level cure, the
  # unchanged-pass-through cousins, the byte-identical pinned rejection,
  # and the legacy-shapes regression guard. Zero live legs — the
  # reproduction is pinned here, at the argument/executor seam.
  class EditFoldTest < Test
    PINNED = Schemas::Tools::PINNED_EDITS_MESSAGE

    # The RECORDED payload verbatim (the file bytes: raw newlines between
    # the tail's tokens, `\n` ESCAPES inside the inner values — the strict
    # parse leg). Canonical-JSON sha (python json.dumps(args, sort_keys=True)
    # form) asserted below.
    RECORDED = %q({"path": "architect.yaml\nedits: [\n{\"oldText\": \"  narrator:\\\\n    model: openrouter/z-ai/glm-5.3-flash\\\\n    thinking: low\",\n \"newText\": \"  narrator:\\\\n    model: openrouter/mistralai/devstral-2512\\\\n    thinking: low\"}]", "edits": []})

    # The raw-newline emission class (the edit-fold-repro gate's embedding):
    # raw newlines INSIDE the inner string values — NOT strict JSON, the
    # repair-parse leg.
    RAW_NEWLINE = %q({"path": "architect.yaml\nedits: [\n{\"oldText\": \"  narrator:\n    model: openrouter/z-ai/glm-5.3-flash\n    thinking: low\",\n \"newText\": \"  narrator:\n    model: openrouter/mistralai/devstral-2512\n    thinking: low\"}]", "edits": []})

    WANT_EDITS = [{"oldText" => "  narrator:\n    model: openrouter/z-ai/glm-5.3-flash\n    thinking: low",
                   "newText" => "  narrator:\n    model: openrouter/mistralai/devstral-2512\n    thinking: low"}]

    def recorded_args
      JSON.parse(RECORDED)
    end

    def canonical_sha(args)
      # python json.dumps(args, sort_keys=True) form (", " / ": " separators).
      Digest::SHA256.hexdigest(%({"edits": [], "path": ) + JSON.generate(args["path"]) + %(}))
    end

    # ---- pin 1: the recorded payload, verbatim, recovers ----

    def test_edit_fold_recorded_payload_sha_and_recovery
      args = recorded_args
      assert_equal "16b4bc25c33c8795a474e3277eb56db06d31a6cfbfb46d1e94c45c36a0613cd3",
        canonical_sha(args), "the embedded payload must be the recorded six-call bytes"

      got = Tools::Edit.normalize_arguments(args.transform_keys(&:to_sym))
      assert_equal "architect.yaml", got[:path]
      assert_equal WANT_EDITS, got[:edits]
    end

    def test_edit_fold_recorded_payload_recovers_with_string_root_keys
      got = Tools::Edit.normalize_arguments(recorded_args)
      assert_equal "architect.yaml", got["path"]
      assert_equal WANT_EDITS, got["edits"]
    end

    def test_edit_fold_raw_newline_class_recovers_through_the_repair_parse
      args = JSON.parse(RAW_NEWLINE)
      got = Tools::Edit.normalize_arguments(args.transform_keys(&:to_sym))
      assert_equal "architect.yaml", got[:path]
      assert_equal WANT_EDITS, got[:edits]
    end

    # ---- pin 2: the recovered call EXECUTES (six rounds + the bash+python
    # fallback cure in ONE call) ----

    def test_edit_fold_recovered_call_executes_against_a_staged_file
      dir = Dir.mktmpdir("t77ef-")
      begin
        file = File.join(dir, "architect.yaml")
        File.write(file, "  narrator:\n    model: openrouter/z-ai/glm-5.3-flash\n    thinking: low\n")
        out = Tools::Edit.new(cwd: dir).call(**recorded_args.transform_keys(&:to_sym))
        assert_equal "Successfully replaced 1 block(s) in architect.yaml.", out
        assert File.read(file).include?("openrouter/mistralai/devstral-2512"), "the staged file was cured"
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    # ---- pins 3/4: trigger failures pass through UNCHANGED and still
    # reject with the byte-identical pinned message ----

    def test_edit_fold_unparseable_tail_stays_unchanged_and_rejects_pinned
      bad = {path: "a.rb\nedits: [oops", edits: []}
      assert_equal bad, Tools::Edit.normalize_arguments(bad), "arguments unchanged"
      assert_equal({error: PINNED}, Schemas::Tools.validate("edit", bad), "pinned rejection byte-identical")
    end

    def test_edit_fold_no_newline_empty_edits_stays_unchanged_and_rejects_pinned
      plain = {path: "a.rb", edits: []}
      assert_equal plain, Tools::Edit.normalize_arguments(plain), "arguments unchanged"
      assert_equal({error: PINNED}, Schemas::Tools.validate("edit", plain), "pinned rejection byte-identical")
    end

    def test_edit_fold_non_edits_prefixed_tail_stays_unchanged
      stray = {path: "a.rb\nsome: [x]", edits: []}
      assert_equal stray, Tools::Edit.normalize_arguments(stray)
    end

    # ---- pin 5: non-empty edits beside a folded-looking path WIN ----

    def test_edit_fold_non_empty_edits_win_over_a_folded_looking_path
      busy = {path: "a.rb\nedits: [{\"oldText\": \"x\", \"newText\": \"y\"}]",
              edits: [{oldText: "z", newText: "w"}]}
      got = Tools::Edit.normalize_arguments(busy)
      assert_equal "a.rb\nedits: [{\"oldText\": \"x\", \"newText\": \"y\"}]", got[:path]
      assert_equal [{oldText: "z", newText: "w"}], got[:edits]
    end

    # ---- pin 6: an ABSENT edits key recovers ----

    def test_edit_fold_absent_edits_key_recovers
      got = Tools::Edit.normalize_arguments({path: "a.rb\nedits: [{\"oldText\": \"x\", \"newText\": \"y\"}]"})
      assert_equal({path: "a.rb", edits: [{"oldText" => "x", "newText" => "y"}]}, got)
    end

    # ---- pin 7: a multi-edit tail recovers ALL edits ----

    def test_edit_fold_multi_edit_tail_recovers_all_edits
      folded = {path: "a.rb\nedits: [{\"oldText\": \"x\", \"newText\": \"y\"}, {\"oldText\": \"p\", \"newText\": \"q\"}]",
                edits: []}
      got = Tools::Edit.normalize_arguments(folded)
      assert_equal "a.rb", got[:path]
      assert_equal [{"oldText" => "x", "newText" => "y"}, {"oldText" => "p", "newText" => "q"}], got[:edits]
    end

    # ---- pin 8: both root-key spellings recover ----

    def test_edit_fold_both_root_key_spellings_recover
      sym = Tools::Edit.normalize_arguments({path: "a.rb\nedits: [{\"oldText\": \"x\", \"newText\": \"y\"}]", edits: []})
      assert_equal({path: "a.rb", edits: [{"oldText" => "x", "newText" => "y"}]}, sym)
      str = Tools::Edit.normalize_arguments({"path" => "a.rb\nedits: [{\"oldText\": \"x\", \"newText\": \"y\"}]", "edits" => []})
      assert_equal({"path" => "a.rb", "edits" => [{"oldText" => "x", "newText" => "y"}]}, str)
    end

    # ---- pin 9: the pinned rejection is byte-identity ----

    def test_edit_fold_pinned_rejection_message_byte_identity
      assert_equal "Edit tool input is invalid. edits must contain at least one replacement.", PINNED
      assert_equal({error: PINNED}, Schemas::Tools.validate("edit", {path: "a.rb", edits: []}))
      assert_equal({error: PINNED}, Schemas::Tools.validate("edit", {path: "a.rb", edits: "nope"}))
    end

    # ---- pin 10 (the legacy-shapes guard): the three existing
    # prepareEditArguments classes still normalize ----

    def test_edit_fold_legacy_shapes_still_normalize
      # edits as a JSON string
      got = Tools::Edit.normalize_arguments({path: "a.rb", edits: "[{\"oldText\": \"x\", \"newText\": \"y\"}]"})
      assert_equal([{ "oldText" => "x", "newText" => "y" }], got[:edits])
      # a single edit object
      got = Tools::Edit.normalize_arguments({path: "a.rb", edits: {oldText: "x", newText: "y"}})
      assert_equal([{oldText: "x", newText: "y"}], got[:edits])
      # legacy top-level oldText/newText
      got = Tools::Edit.normalize_arguments({path: "a.rb", oldText: "x", newText: "y"})
      assert_equal([{oldText: "x", newText: "y"}], got[:edits])
      assert_nil got[:oldText]
      assert_nil got[:newText]
    end
  end
end
