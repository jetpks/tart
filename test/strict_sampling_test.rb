# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/mock_llm_server"
require_relative "../lib/tart/tools/memory"
require "tmpdir"
require "fileutils"
require "json"
require "digest"

module Tart
  # I64 — the strict-sampling consumer flow end-to-end: the four pi-tagged
  # tools' declarations reach the wire as the strict REWRITE + `strict: true`
  # on a strict-capable (zai) dialect, everything else stays byte-frozen
  # (no strict key off the zai arm, verbatim parameters for undeclared
  # tools), and the supportsStrictMode compat carry threads load → shape →
  # Dialect → wire model. The recorded-wire vehicle is the real Agent stack
  # over a MockLLMServer (the agent_loop_test pattern) — no client doubles.
  class StrictSamplingTest < Test
    # The Grounds-frozen strict rewrites (the landed engine applied to the
    # four string-keyed declared schemas) — hash-pinned AND digest-pinned
    # below. Key order [type, properties, required, additionalProperties]:
    # tart's declared order preserved, the engine appends additionalProperties.
    FROZEN_REWRITE_DIGESTS = {
      "bash" => "a6c8a972736069994badf4f85cacae7549ef564697f8fc77cc693c1b392ca254",
      "read" => "bfce07b51dfaa08d4a4c61b22f5f4efcb8f8bb89cc49baf6e834ac67eae45ad3",
      "edit" => "e34ab9c2d955de1b60ffb86f5caa961f15626ccdd219ca07425e8f8fecfe3b9c",
      # The write digest is the strict rewrite of the ACTUAL declared
      # schema (lib/tart/tools/write.rb — "Path to the file to write
      # (relative or absolute)"). The spec session's frozen numeral
      # e7565c49… was computed from a mis-transcribed description ("to
      # write to") in its probe; D4's byte-preservation of the file's
      # descriptions governs (PHASE 0 disagreement, flagged in the report).
      "write" => "b0b84973437c1ee95fa804c3637831939aa776f6daead968a3621848b845833c",
    }.freeze

    # The owner's live catalog shape (zai, glm-5.3): supportsStrictMode CARRIED,
    # supportsStore still the tolerated-and-dropped unknown.
    ZAI_MODELS_JSON = <<~JSON
      {"providers": {"zai": {"name": "Z.AI", "baseUrl": "https://api.z.ai/api/coding/paas/v4",
        "apiKey": "k", "api": "openai-completions",
        "models": [{"id": "glm-5.3", "reasoning": true, "contextWindow": 200000,
          "compat": {"supportsStore": false, "supportsDeveloperRole": false,
                     "supportsReasoningEffort": true, "maxTokensField": "max_tokens",
                     "thinkingFormat": "zai", "supportsStrictMode": true, "zaiToolStream": true}}]}}}
    JSON

    def setup
      @server = MockLLMServer.new.start
      @dir = Dir.mktmpdir("tart-strict-")
    end

    def teardown
      @server.stop
      FileUtils.rm_rf(@dir)
    end

    # --- group 1: the mock-wire pair (the recorded-wire gate) -------------

    # A live-catalog-shaped zai model through the FULL flow (models.json →
    # Models.load → entry → the loop's apply_facts → wire_model) with the
    # five-tool loadout: the four declared tools ship the strict rewrite +
    # "strict" => true right after "parameters"; the undeclared ls ships
    # "strict" => false with verbatim parameters; tool_stream rides (the
    # zai arm).
    def test_zai_strict_dialect_ships_the_strict_rewrite_and_the_undeclared_false
      @server.script([{type: :message, content: "ok"}])
      body = capture_wire(compat_flow: :zai)

      functions = body["tools"].to_h { |t| [t["function"]["name"], t["function"]] }
      assert_equal %w[bash read edit write ls], body["tools"].map { |t| t["function"]["name"] },
        "the loadout order is the wire order"

      FROZEN_REWRITE_DIGESTS.each do |name, digest|
        fn = functions.fetch(name)
        assert_equal true, fn["strict"], "#{name} must ship strict on the zai dialect"
        assert_equal %w[name description parameters strict], fn.keys,
          "#{name}: the strict key sits right after parameters (pi's key order)"
        # The frozen rewrite, hash-equality AND digest.
        assert_equal expected_rewrite(name), fn["parameters"],
          "#{name}: parameters must be EXACTLY the Grounds-frozen strict rewrite"
        assert_equal digest, Digest::SHA256.hexdigest(JSON.generate(fn["parameters"])),
          "#{name}: the rewrite digest moved"
      end

      ls_fn = functions.fetch("ls")
      assert_equal false, ls_fn["strict"], "the undeclared tool ships strict FALSE on a strict dialect"
      assert_equal %w[name description parameters strict], ls_fn.keys
      assert_equal wire_shape(Tart::Tools::Ls::PARAMETERS_SCHEMA), ls_fn["parameters"],
        "the undeclared tool's parameters stay verbatim"

      assert_equal true, body["tool_stream"], "the zai arm rides tool_stream"
    end

    # The byte-freeze control: a compat-less (fireworks/mock-shaped) model
    # through the SAME loadout — no function object carries a strict key,
    # every parameters hash is verbatim-equal to its declared schema (the
    # conversion is serialization-neutral; this pins it at the wire seam).
    def test_compat_less_model_ships_no_strict_keys_and_verbatim_parameters
      @server.script([{type: :message, content: "ok"}])
      body = capture_wire(compat_flow: :none)

      assert body["tools"].any?
      body["tools"].each do |tool|
        fn = tool["function"]
        refute fn.key?("strict"), "#{fn["name"]}: no strict key off the zai arm"
        assert_equal %w[name description parameters], fn.keys
        declared = Object.const_get(Tart::Tools::Registry::TOOL_CLASSES.fetch(fn["name"]))
        assert_equal wire_shape(declared::PARAMETERS_SCHEMA), fn["parameters"],
          "#{fn["name"]}: verbatim parameters on the non-strict wire"
      end
      refute body.key?("tool_stream"), "no tool_stream off the zai arm"
    end

    # --- group 2: the loud string-key/resolution pins ----------------------

    # Per declared tool: the resolver returns TRUE on a strict dialect
    # (nil would mean the declaration is silently inert — the symbol-key
    # hazard the conversion eliminates), the schema is string-keyed
    # THROUGHOUT, and the root type reads by string key.
    def test_declared_tools_resolve_strict_with_string_keyed_schemas
      %w[Bash Read Edit Write].each do |name|
        klass = Tart::Tools.const_get(name)
        tool = klass.new(cwd: @dir)

        assert_equal({"type" => "json_schema", "strict" => "prefer"}, klass.constrained_sampling,
          "#{name}: exactly pi's tag")
        assert_equal true, Fast::Completions::ConstrainedSampling.resolve_json_schema_strict_sampling(tool, true),
          "#{name}: must resolve STRICT — nil means the schema silently fell back loose (re-symbolized keys?)"
        params = tool.parameters
        assert params.keys.all?(String), "#{name}: top-level keys must be string-keyed"
        assert deeply_string_keyed?(params), "#{name}: nested keys must be string-keyed too"
        assert_equal "object", params["type"], "#{name}: the root type reads by string key"
      end
    end

    # The hazard itself, pinned so the pin above never rots: a re-symbolized
    # schema makes "prefer" return NIL (silent loose fallback) — the failure
    # mode the string-key conversion exists to eliminate.
    def test_re_symbolized_schema_resolves_nil_the_silent_inert_shape
      symbol_tool = Class.new(Fast::Completions::Tool) do
        def self.constrained_sampling = {"type" => "json_schema", "strict" => "prefer"}

        def self.parameters
          {type: "object", properties: {"a" => {type: "string"}}, required: ["a"]}
        end

        def self.name = "SymbolTool"

        def name = "SymbolTool"
      end
      assert_nil Fast::Completions::ConstrainedSampling.resolve_json_schema_strict_sampling(symbol_tool, true),
        "a symbol-keyed root must NOT resolve strict (the silent-inert hazard)"
    end

    # The untagged inventory (itemized in Grounds): pi tags exactly the four;
    # every other tool class reads nil — on a strict dialect they ride
    # "strict" => false + verbatim (pi's undeclared behavior).
    def test_untagged_inventory_reads_nil
      assert_nil Tart::Tools::Find.new(cwd: @dir).constrained_sampling
      assert_nil Tart::Tools::Grep.new(cwd: @dir).constrained_sampling
      assert_nil Tart::Tools::Ls.new(cwd: @dir).constrained_sampling
      assert_nil Tart::Tools::ContactSupervisor.new(cwd: @dir).constrained_sampling
      assert_nil Tart::Tools::Memory.new(cwd: @dir).constrained_sampling
      assert_nil Tart::Tools::Subagent.new(manager: Object.new).constrained_sampling
      assert_nil Tart::Mcp::Tool.new(wire_name: "mcp__s__t", server: "s", remote_name: "t",
        description: "d", input_schema: {"type" => "object", "properties" => {}},
        client: Object.new).constrained_sampling
    end

    # --- group 3: the compat-flow units ------------------------------------

    def test_strict_mode_carries_from_models_json_to_the_wire_model
      config = load_fixture
      assert_nil config.error
      entry = config.model_entries.first

      assert_equal true, entry.compat.supports_strict_mode
      assert_equal true, Models.dialect_for(entry.compat).supports_strict_mode
      wire = Models.wire_model(model_id: entry.id, provider_key: "zai", reasoning: entry.reasoning,
        context_window: 200_000, compat: entry.compat)
      assert_equal true, wire.dialect.supports_strict_mode,
        "the flag rides the mounted wire model (every construction path threads wire_model)"
    end

    def test_strict_mode_absent_nil_or_false_stays_false
      absent = Models.dialect_for(Shapes::ModelCompat.new(thinking_format: "zai"))
      explicit_nil = Models.dialect_for(Shapes::ModelCompat.new(thinking_format: "zai", supports_strict_mode: nil))
      explicit_false = Models.dialect_for(Shapes::ModelCompat.new(thinking_format: "zai", supports_strict_mode: false))

      assert_equal [false, false, false], [absent, explicit_nil, explicit_false].map(&:supports_strict_mode),
        "OpenAI compatibility alone does not imply strict (pi detectCompat)"
    end

    def test_non_zai_strict_declaration_stays_the_frozen_default_dialect
      boundary = Models.dialect_for(Shapes::ModelCompat.new(supports_strict_mode: true))
      deepseek = Models.dialect_for(Shapes::ModelCompat.new(thinking_format: "deepseek", supports_strict_mode: true))

      assert Models::DEFAULT_DIALECT.equal?(boundary),
        "a non-zai strict declaration rides the DEFAULT singleton (tolerated-and-dropped)"
      assert Models::DEFAULT_DIALECT.equal?(deepseek)
      assert_equal false, Models::DEFAULT_DIALECT.supports_strict_mode
    end

    # --- harness ------------------------------------------------------------

    def load_fixture(root: @dir)
      File.write(File.join(root, "models.json"), ZAI_MODELS_JSON)
      Models.load(root: root)
    end

    # The recorded-wire capture: the real loop over the real client on the
    # mock endpoint; one request, parsed body returned. The compat threads
    # the LOOP constructor (the boot's own path — the loop re-applies the
    # facts onto the chat at construction).
    def capture_wire(compat_flow:)
      entry = load_fixture.model_entries.first
      client = Fast::Completions::Client.new(base_url: @server.url, api_key: "test-key", timeout: 10)
      chat = Agent::Chat.new(client:, model_id: entry.id, provider_key: "zai")
      tools = Tools::Registry.build(selected: %w[bash read edit write ls], cwd: @dir)
      loop_kwargs = {chat:, tools:, system_prompt: "strict wire gate", context_window: 200_000,
                     model_reasoning: entry.reasoning, thinking_level_map: entry.thinking_level_map}
      case compat_flow
      when :zai then loop_kwargs[:compat] = entry.compat
      when :none then loop_kwargs[:compat] = nil
      end
      agent = Agent::Loop.new(**loop_kwargs)

      kernel = Core::Loop.new(session: ScriptedSession.new)
      kernel.run { agent.run("hello") }

      requests = @server.captured_requests
      assert_equal 1, requests.size, "exactly one request captured"
      requests.first
    end

    # The declared schema as the wire carries it (JSON round-trip — the
    # parsed body's parameters are string-keyed whatever the declaration).
    def wire_shape(schema)
      JSON.parse(JSON.generate(schema))
    end

    # The Grounds-frozen rewrite literals (string-keyed).
    def expected_rewrite(name)
      @rewrites ||= {
        "bash" => JSON.parse(<<~JSON),
          {"type":"object","properties":{"command":{"type":"string","description":"Shell command to execute"},
           "timeout":{"anyOf":[{"type":"number","description":"Timeout in seconds (optional, no default timeout)"},
           {"type":"null"}]}},"required":["command","timeout"],"additionalProperties":false}
        JSON
        "read" => JSON.parse(<<~JSON),
          {"type":"object","properties":{"path":{"type":"string","description":"Path to the file to read (relative or absolute)"},
           "offset":{"anyOf":[{"type":"number","description":"Line number to start reading from (1-indexed)"},{"type":"null"}]},
           "limit":{"anyOf":[{"type":"number","description":"Maximum number of lines to read"},{"type":"null"}]}},
           "required":["path","offset","limit"],"additionalProperties":false}
        JSON
        "edit" => JSON.parse(<<~JSON),
          {"type":"object","properties":{"path":{"type":"string","description":"Path to the file to edit (relative or absolute)"},
           "edits":{"type":"array","description":"One or more targeted replacements. Each edit is matched against the original file, not incrementally. Do not include overlapping or nested edits. If two changes touch the same block or nearby lines, merge them into one edit instead.",
           "items":{"type":"object","properties":{
             "oldText":{"type":"string","description":"Exact text for one targeted replacement. It must be unique in the original file and must not overlap with any other edits[].oldText in the same call."},
             "newText":{"type":"string","description":"Replacement text for this targeted edit."}},
             "required":["oldText","newText"],"additionalProperties":false}}},
           "required":["path","edits"],"additionalProperties":false}
        JSON
        "write" => JSON.parse(<<~JSON),
          {"type":"object","properties":{
           "path":{"type":"string","description":"Path to the file to write (relative or absolute)"},
           "content":{"type":"string","description":"Content to write to the file"}},
           "required":["path","content"],"additionalProperties":false}
        JSON
      }
      @rewrites.fetch(name)
    end

    def deeply_string_keyed?(value)
      case value
      when Hash then value.keys.all?(String) && value.values.all? { |v| deeply_string_keyed?(v) }
      when Array then value.all? { |v| deeply_string_keyed?(v) }
      else true
      end
    end
  end
end
