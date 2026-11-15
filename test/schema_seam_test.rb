# frozen_string_literal: true

require_relative "test_helper"
require "digest"
require "json"
require "tmpdir"
require "fileutils"

module Tart
  # The I97 schema-seam-parity pins (the nine, arch §Pins): each tool's
  # declared PARAMETERS_SCHEMA literal is the SINGLE hand-maintained
  # declaration of its argument surface — the camel→snake binding map
  # (Law 1), the boot bijection at the registry choke point (Law 2), the
  # seam translation (Law 3), and the wire-keyed dry contracts (Law 4) are
  # all DERIVED from it, and schema↔kwargs drift is UNLOADABLE at boot.
  # Self-contained helpers (the I90/I94/I96 precedent). Hermetic: staged
  # tmpdir fixtures, `rg` from PATH (the suite's standing grep-tool idiom),
  # no network, no sleeps.
  class SchemaSeamTest < Test
    # Pin 6 — the I96 present-invalid payload bytes (bound defaults under
    # WIRE names), asserted verbatim.
    PRESENT_INVALID_BYTES =
      "Validation failed for tool \"web_search\":\n" \
      "  - query: must be a string\n" \
      "\n" \
      "Received arguments:\n" \
      "{\n" \
      "  \"query\": 42,\n" \
      "  \"numResults\": null,\n" \
      "  \"includeText\": false\n" \
      "}"

    # Pin 9 — the Law-7 constant: the canonical wire-declaration digest
    # (14 names sorted, "#{name}:" + JSON.generate(klass.parameters) per
    # line, joined "\n", sha256). Any wire byte movement reds this pin and
    # forces a deliberate re-pin.
    WIRE_DIGEST = "d4cc39c63f9363f07985550861d40f67f4711d9de8021afb1e69bee4f0407b30"

    # The fourteen wire tools (class-level proofs; no constructors needed).
    WIRE_TOOLS = {
      "read" => Tools::Read, "edit" => Tools::Edit, "write" => Tools::Write,
      "bash" => Tools::Bash, "find" => Tools::Find, "grep" => Tools::Grep,
      "ls" => Tools::Ls, "web_search" => Tools::WebSearch, "web_fetch" => Tools::WebFetch,
      "memory" => Tools::Memory, "subagent" => Tools::Subagent,
      "contact_supervisor" => Tools::ContactSupervisor,
      "architect_loop" => Tools::ArchitectLoop, "architect_compact" => Tools::ArchitectCompact
    }.freeze

    # --- pin 1 fixtures: each drift direction + a collision + a control ---

    class SeamPropWithoutKeyword < Fast::Completions::Tool
      include Tools::SafeExecute

      pi_name "seam_prop_no_kwarg"

      parameters({type: "object", properties: {"flag" => {type: "boolean"}}})

      def execute = "ok"
    end

    class SeamKeywordWithoutProp < Fast::Completions::Tool
      include Tools::SafeExecute

      pi_name "seam_kwarg_no_prop"

      parameters({type: "object", properties: {}})

      def execute(flag: nil) = "ok"
    end

    class SeamCollision < Fast::Completions::Tool
      include Tools::SafeExecute

      pi_name "seam_collision"

      parameters({type: "object", properties: {"aB" => {type: "string"}, "a_b" => {type: "string"}}})

      def execute(a_b: nil) = "ok"
    end

    class SeamMatching < Fast::Completions::Tool
      include Tools::SafeExecute

      pi_name "seam_matching"

      parameters({type: "object", properties: {"flag" => {type: "boolean"}}})

      def execute(flag: nil) = "ok"
    end

    def setup
      @dir = Dir.mktmpdir("t97-seam-")
    end

    def teardown
      FileUtils.rm_rf(@dir)
    end

    # Pin 1 — drift is unexpressible at the class level: each direction of
    # the bijection and a prop collision raise a loud ArgumentError naming
    # the tool and the offending names; a matching fixture passes.
    def test_schema_drift_is_unloadable_at_the_binding_proof
      error = assert_raises(ArgumentError) { SeamPropWithoutKeyword.verify_schema_binding! }

      assert_includes error.message, "seam_prop_no_kwarg"
      assert_includes error.message, '"flag"', "the unmapped property is named"

      error = assert_raises(ArgumentError) { SeamKeywordWithoutProp.verify_schema_binding! }

      assert_includes error.message, "seam_kwarg_no_prop"
      assert_includes error.message, ":flag", "the unadvertised keyword is named"

      error = assert_raises(ArgumentError) { SeamCollision.verify_schema_binding! }

      assert_includes error.message, "seam_collision"
      assert_includes error.message, ":a_b", "the collided snake kwarg is named"

      assert SeamMatching.verify_schema_binding!, "a matching schema/kwargs pair passes"
    end

    # Pin 2 — drift is unloadable at the registry choke point: a drifted
    # fixture registered through the real hooks seam makes Registry.build
    # RAISE (no loadout), while the same build without the fixture boots.
    def test_schema_drift_is_unloadable_through_the_registry_choke_point
      hooks = Hooks.new.register_tool(SeamPropWithoutKeyword.new)

      error = assert_raises(ArgumentError) do
        Tools::Registry.build(selected: %w[read], cwd: @dir, hooks:)
      end

      assert_includes error.message, "seam_prop_no_kwarg"

      tools = Tools::Registry.build(selected: %w[read], cwd: @dir)

      assert_includes tools.keys, "read"
    end

    # Pin 3 — all fourteen real wire tools pass the binding proof, and the
    # full built-in loadout boots clean through the registry.
    def test_the_fourteen_wire_tools_pass_the_binding_proof
      WIRE_TOOLS.each_value do |klass|
        assert klass.verify_schema_binding!, "#{klass} fails the binding proof"
      end

      tools = Tools::Registry.build(selected: Tools::Registry::TOOL_CLASSES.keys, cwd: @dir)

      assert_equal Tools::Registry::TOOL_CLASSES.keys, tools.keys
    end

    # Pin 4 — THE #21 cure: grep's advertised `ignoreCase` binds at the
    # seam, byte-equal to the snake spelling, and the default stays
    # case-sensitive.
    def test_grep_honors_the_advertised_ignore_case_end_to_end
      File.write(File.join(@dir, "case.txt"), "Hello World\n")
      grep = Tools::Grep.new(cwd: @dir)

      camel = grep.call("pattern" => "hello", "path" => "case.txt", "ignoreCase" => true)
      snake = grep.call("pattern" => "hello", "path" => "case.txt", "ignore_case" => true)
      plain = grep.call("pattern" => "hello", "path" => "case.txt")

      assert_equal snake, camel, "the advertised and snake spellings agree byte-for-byte"
      assert_includes camel, "case.txt:1: Hello World"
      assert_equal "No matches found", plain, "the default stays case-sensitive"
    end

    # Pin 5 — the I96 unknown-keyword belt keeps the wire spelling; the
    # mixed missing+unknown case still reports MISSING (the consult wins).
    def test_the_unknown_keyword_belt_keeps_the_wire_spelling
      belt = Tools::Grep.new(cwd: @dir).call("pattern" => "x", "bogus" => 1)[:error]

      assert_includes belt, "Validation failed for tool \"grep\":\n  - unknown keyword: :bogus\n"
      assert_includes belt, '"pattern": "x"'
      assert_includes belt, '"bogus": 1'

      mixed = Tools::Grep.new(cwd: @dir).call("bogus" => 1)[:error]

      assert_includes mixed, "  - pattern: is missing\n"
      refute_includes mixed, "unknown keyword"
    end

    # Pin 6 — wire-spelled arguments validate under WIRE paths, through the
    # seam and at the contract consult: grep's wrong-typed camel flag, the
    # EXACT I96 pin-4 camel bytes on web_search, web_fetch's url shape and
    # its pinned scheme rule.
    def test_wire_spelled_arguments_validate_with_wire_paths
      grep_error = Tools::Grep.new(cwd: @dir).call("pattern" => "p", "ignoreCase" => "yes")[:error]

      assert_includes grep_error, "  - ignoreCase: must be boolean"
      assert_includes grep_error, '"ignoreCase": "yes"'

      direct = Schemas::Tools.validate("grep", {pattern: "p", ignoreCase: "yes"})

      assert_includes direct[:error], "  - ignoreCase: must be boolean"

      assert_equal PRESENT_INVALID_BYTES, web_search.call("query" => 42)[:error]

      fetch_error = web_fetch.call("url" => 42)[:error]

      assert_includes fetch_error, "  - url: must be a string"
      assert_includes fetch_error, '"savePath": null'

      assert_equal Schemas::Tools::PINNED_URL_MESSAGE, web_fetch.call("url" => "ftp://x.example/page")[:error]
    end

    # Pin 7 — the renamed tools' snake kwargs validate under WIRE names
    # (the Law-5 remap proof): a camel path from a snake call, and the
    # pinned URL string via save_path.
    def test_renamed_kwargs_speak_the_wire_spelling_in_validation
      error = web_search.execute(query: "q", num_results: "5")[:error]

      assert_includes error, "  - numResults: must be an integer or must be a float"
      assert_includes error, '"numResults": "5"'

      assert_equal Schemas::Tools::PINNED_URL_MESSAGE,
        web_fetch.execute(url: "ftp://x.example/page", save_path: "p")[:error]
    end

    # Pin 8 — the contract registry covers EXACTLY the nine contracted
    # names; the contract-less belt (KeyError) holds for memory (I96 D3).
    def test_the_contract_registry_covers_exactly_the_nine_names
      assert_equal %w[bash edit find grep ls read web_fetch web_search write],
        Schemas::Tools::CONTRACTS.keys.sort

      error = assert_raises(KeyError) { Schemas::Tools.validate("memory", {}) }

      assert_includes error.message, 'no input contract registered for tool "memory"'
    end

    # Pin 9 — the wire declarations are byte-immobile: the canonical digest
    # over the fourteen declared schemas equals the frozen Law-7 constant.
    def test_the_wire_declarations_are_byte_immobile
      blob = WIRE_TOOLS.keys.sort.map { |name| "#{name}:#{JSON.generate(WIRE_TOOLS.fetch(name).parameters)}" }.join("\n")

      assert_equal WIRE_DIGEST, Digest::SHA256.hexdigest(blob)
    end

    private

    # The transport stubs are bare Objects — any leg that ever reached them
    # would NoMethodError loudly (these pins all fail at validation).
    def web_search
      Tools::WebSearch.new(cwd: @dir, env: {"EXA_API_KEY" => "pin-key"}, http: Object.new)
    end

    def web_fetch
      Tools::WebFetch.new(cwd: @dir, env: {"EXA_API_KEY" => "pin-key"}, http: Object.new)
    end
  end
end
