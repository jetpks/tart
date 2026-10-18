# frozen_string_literal: true

require_relative "test_helper"
require "fileutils"
require "tmpdir"

module Tart
  # The models.json catalog (I27 AC1): load/validate/JSONC/errors —
  # hermetic tmp roots (fake ~/.tart), no real ~/.tart. The boot-model
  # precedence is pinned per the spec order (env > models.json default >
  # Settings).
  class ModelsTest < Test
    def setup
      @root = Dir.mktmpdir("tart-models-")
      @path = File.join(@root, "models.json")
      @saved_env = %w[PI_MODEL PI_PROVIDER TART_MODEL TART_PROVIDER FOO_MODEL FOO_PROVIDER].to_h { |key| [key, ENV[key]] }
      @saved_env.each_key { |key| ENV.delete(key) }
    end

    def teardown
      FileUtils.rm_rf(@root)
      @saved_env.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
    end

    def write_models(json)
      File.write(@path, json)
    end

    def load_models
      Models.load(root: @root)
    end

    CATALOG = <<~JSON
      {
        // the daily driver
        "default": "glm/glm-5.3",
        "providers": {
          "glm": {
            "name": "GLM",
            "baseUrl": "https://example.test/v1",
            "apiKey": "k-catalog",
            "api": "openai-completions",
            "models": [
              {"id": "glm-5.3", "name": "GLM 5.3", "reasoning": true,
               "contextWindow": 200000, "maxTokens": 8192},
              {"id": "glm-5-air"}
            ]
          }
        }
      }
    JSON

    # --- load/validate ---

    def test_missing_file_falls_back_cleanly
      config = load_models
      assert_nil config.error
      assert_empty config.model_entries
      assert_nil config.default
    end

    def test_loads_the_catalog_with_entries_and_provider_config
      write_models(CATALOG)
      config = load_models

      assert_nil config.error
      assert_equal "glm/glm-5.3", config.default
      entry = config.model_entries.first
      assert_equal ({provider: "glm", id: "glm-5.3", name: "GLM 5.3", reasoning: true,
                     context_window: 200_000, max_tokens: 8192, thinking_level_map: nil,
                     compat: nil}), entry.to_h,
        "the typed entry's to_h IS today's entry hash (key order included)"
      assert_equal "https://example.test/v1", config.provider("glm").base_url
      assert_equal "k-catalog", config.provider("glm").api_key
    end

    def test_jsonc_comments_and_trailing_commas_are_tolerated
      write_models(CATALOG) # carries a // comment and a trailing "default" comma shape
      assert_nil load_models.error
    end

    def test_bom_is_stripped
      write_models("\uFEFF#{CATALOG}")
      assert_nil load_models.error
      assert_equal 2, load_models.model_entries.size
    end

    def test_invalid_json_surfaces_an_error_naming_the_file
      write_models("{oops")
      config = load_models

      assert config.error, "an invalid file surfaces an error"
      assert_includes config.error, @path, "the error names the file"
      assert_empty config.model_entries, "the catalog falls back empty"
    end

    def test_schema_violations_surface_an_error_naming_the_file
      write_models('{"providers": {"glm": {"models": [{"name": "no id"}]}}}')
      config = load_models

      assert config.error
      assert_includes config.error, @path
      assert_includes config.error, "id", "the required model id is named"
    end

    def test_schema_rejects_bad_types_and_non_positive_windows
      write_models('{"providers": {"glm": {"apiKey": 7, "models": [{"id": "m", "contextWindow": 0}]}}, "default": 9}')
      config = load_models

      assert config.error
      assert_match(/apiKey/, config.error)
      assert_match(/contextWindow/, config.error)
      assert_match(/default/, config.error)
    end

    def test_non_object_root_surfaces_an_error
      write_models("[]")
      assert load_models.error
    end

    # --- I46: the compat parse + the legacy bridge ------------------------------

    def test_owner_zai_catalog_loads_clean_with_the_typed_compat
      write_models(<<~JSON)
        {"providers": {"zai": {"name": "Z.AI", "baseUrl": "https://api.z.ai/api/coding/paas/v4",
          "apiKey": "k",
          "models": [{"id": "glm-5.3", "reasoning": true, "contextWindow": 1000000, "maxTokens": 131072,
            "thinkingLevelMap": {"off": null, "minimal": null, "low": "low", "medium": null,
                                 "high": "high", "xhigh": null, "max": "max"},
            "compat": {"supportsStore": false, "supportsDeveloperRole": false,
                       "supportsReasoningEffort": true, "maxTokensField": "max_tokens",
                       "thinkingFormat": "zai", "supportsStrictMode": true, "zaiToolStream": true}}]}}}
      JSON
      config = load_models

      assert_nil config.error, "the owner's live object (unknown supportsStore; supportsStrictMode now CARRIED) loads clean"
      compat = config.model_entries.first.compat
      assert_instance_of Shapes::ModelCompat, compat
      assert_equal "zai", compat.thinking_format
      assert_equal "max_tokens", compat.max_tokens_field
      assert_equal false, compat.supports_developer_role
      assert_equal true, compat.supports_reasoning_effort
      assert_equal true, compat.zai_tool_stream
      assert_equal true, compat.supports_strict_mode
    end

    def test_compat_absent_parses_nil_and_partial_compat_picks_the_six
      write_models('{"providers": {"a": {"models": [{"id": "m"}, {"id": "n", "compat": {"thinkingFormat": "zai", "madeUp": 1}}]}}}')
      config = load_models

      assert_nil config.error
      first, second = config.model_entries
      assert_nil first.compat, "a compat-less entry parses nil"
      assert_equal "zai", second.compat.thinking_format
      assert_nil second.compat.max_tokens_field
      assert_nil second.compat.supports_developer_role
      assert_nil second.compat.supports_reasoning_effort
      assert_nil second.compat.zai_tool_stream
      assert_nil second.compat.supports_strict_mode
    end

    def test_entry_compat_bridges_typed_and_legacy_raw_hash_entries
      typed = Shapes::Model.new(id: "m", name: "m", reasoning: true, context_window: nil,
        max_tokens: nil, thinking_level_map: nil, provider: "glm",
        compat: Shapes::ModelCompat.new(thinking_format: "zai"))
      config = Models::Config.new(providers: {}, default: nil, error: nil)
      assert_equal "zai", config.entry_compat(typed).thinking_format, "the typed attribute read"

      legacy_with = {id: "m", compat: Shapes::ModelCompat.new(thinking_format: "zai")}
      legacy_without = {id: "m"}
      assert_equal "zai", config.entry_compat(legacy_with).thinking_format, "the raw-hash read"
      assert_nil config.entry_compat(legacy_without), "nil default for a legacy entry declaring none"
    end

    # --- resolve (pi findExactModelReferenceMatch, reduced) ---

    def catalog
      typed_model = lambda do |provider, id, name, reasoning, context_window|
        Shapes::Model.new(id: id, name: name, reasoning: reasoning, context_window: context_window,
          max_tokens: nil, thinking_level_map: nil, provider: provider)
      end
      Models::Config.new(
        providers: {
          "glm" => Shapes::Provider.new(name: nil, base_url: nil, api_key: nil, api: nil,
                                        models: [typed_model.call("glm", "glm-5.3", "GLM 5.3", true, 200_000),
                                                 typed_model.call("glm", "air", "Air", false, nil)]),
          "zai" => Shapes::Provider.new(name: nil, base_url: nil, api_key: nil, api: nil,
                                        models: [typed_model.call("zai", "glm-5.3", "GLM 5.3 (zai)", true, nil)])
        },
        default: nil, error: nil
      )
    end

    def test_resolve_canonical_and_provider_scoped_and_bare
      assert_equal "glm", catalog.resolve("GLM/GLM-5.3").provider, "the canonical ref is case-insensitive"
      assert_equal "zai", catalog.resolve("zai/glm-5.3").provider, "the provider prefix disambiguates"
      assert_equal "Air", catalog.resolve("air").name, "a unique bare id matches"
    end

    def test_resolve_ambiguity_and_unknowns_are_no_match
      assert_nil catalog.resolve("glm-5.3"), "a bare id ambiguous across providers is no match"
      assert_nil catalog.resolve("nope")
      assert_nil catalog.resolve("  ")
    end

    # --- boot resolution (env > models.json default > Settings) ---

    def settings
      Settings::DEFAULTS.merge("defaultModel" => "settings-model", "defaultProvider" => "settings-provider")
    end

    # I69: the PI_* env-tier legs ride an EXPLICIT pi identity — the pins
    # test the pi-parity opt-in's env tier, not the (now tart) default.
    def test_boot_resolves_env_over_all
      boot = Models.resolve_boot_model(catalog, settings, identity: "pi",
        env: {"PI_MODEL" => "m-env", "PI_PROVIDER" => "p-env"})
      assert_equal ({provider: "p-env", id: "m-env"}), boot.to_h
    end

    def test_boot_env_model_alone_keeps_the_settings_provider
      boot = Models.resolve_boot_model(catalog, settings, identity: "pi", env: {"PI_MODEL" => "m-env"})
      assert_equal ({provider: "settings-provider", id: "m-env"}), boot.to_h
    end

    def test_boot_env_provider_alone_keeps_the_settings_model
      boot = Models.resolve_boot_model(catalog, settings, identity: "pi", env: {"PI_PROVIDER" => "p-env"})
      assert_equal ({provider: "p-env", id: "settings-model"}), boot.to_h
    end

    # The env keys ride the identity's namespace (I32 AC4).
    def test_boot_env_keys_follow_the_identity
      tart = Models.resolve_boot_model(catalog, settings, identity: "tart",
        env: {"TART_MODEL" => "m-env", "TART_PROVIDER" => "p-env"})
      assert_equal ({provider: "p-env", id: "m-env"}), tart.to_h
      foo = Models.resolve_boot_model(catalog, settings, identity: "foo", env: {"FOO_MODEL" => "m-foo"})
      assert_equal ({provider: "settings-provider", id: "m-foo"}), foo.to_h
      # A pi-key boot under identity tart is NOT read — the namespaces
      # don't bleed.
      assert_equal ({provider: "settings-provider", id: "settings-model"}),
        Models.resolve_boot_model(catalog, settings, identity: "tart", env: {"PI_MODEL" => "m-env"}).to_h
    end

    def test_boot_resolves_the_models_json_default_over_settings
      write_models(CATALOG)
      config = load_models
      boot = Models.resolve_boot_model(config, settings, env: {})
      assert_equal ({provider: "glm", id: "glm-5.3"}), boot.to_h
    end

    def test_boot_falls_through_to_settings_without_a_default
      write_models('{"providers": {"glm": {"models": [{"id": "glm-5.3"}]}}}')
      boot = Models.resolve_boot_model(load_models, settings, env: {})
      assert_equal ({provider: "settings-provider", id: "settings-model"}), boot.to_h
    end

    def test_boot_resolves_settings_alone_when_no_catalog
      boot = Models.resolve_boot_model(Models.load(root: @root), settings, env: {})
      assert_equal ({provider: "settings-provider", id: "settings-model"}), boot.to_h
    end

    # --- thinkingLevelMap (I36): parse, validate, resolve —
    # pi model-config.ts:38/:54 (the catalog field), model-schema.ts:14-15
    # (Partial Record<level, String|null>), models.ts:1224-1254
    # (supported/clamp), openai-completions.ts:745-755 + :969-976 (effort) ---

    def test_thinking_level_map_parses_symbolized_with_null_values
      write_models(<<~JSON)
        {"providers": {"glm": {"models": [{"id": "m", "reasoning": true,
          "thinkingLevelMap": {"off": null, "low": "low", "madeup": "x"}}]}}}
      JSON

      entry = load_models.model_entries.first
      assert_equal ({off: nil, low: "low", madeup: "x"}), entry.thinking_level_map,
        "symbolized keys, null kept, unknown level keys tolerated (pi's Partial-Record default)"
    end

    def test_thinking_level_map_absent_is_nil
      write_models('{"providers": {"glm": {"models": [{"id": "m"}]}}}')
      assert_nil load_models.model_entries.first.thinking_level_map
    end

    def test_thinking_level_map_schema_violations_surface_an_error
      write_models('{"providers": {"glm": {"models": [{"id": "m", "thinkingLevelMap": "high"}]}}}')
      config = load_models
      assert config.error
      assert_match(/thinkingLevelMap: expected an object/, config.error)

      write_models('{"providers": {"glm": {"models": [{"id": "m", "thinkingLevelMap": {"low": 5}}]}}}')
      config = load_models
      assert config.error
      assert_match(/thinkingLevelMap\.low: expected a string or null/, config.error)
    end

    def test_thinking_level_map_valid_shapes_load_clean
      write_models(<<~JSON)
        {"providers": {"glm": {"models": [{"id": "m", "thinkingLevelMap":
          {"off": null, "low": "low", "future_level": null}}]}}}
      JSON
      assert_nil load_models.error, "unknown level keys are tolerated (pi's Partial-Record default)"
    end

    # The owner's override map (every level a String; off floors to "low"
    # directly) — Settings::THINKING_LEVEL_MAPS' glm row.
    def owner_map
      {off: "low", minimal: "low", low: "low", medium: "medium", high: "high", xhigh: "xhigh", max: "max"}
    end

    # The live fireworks catalog map ({off:null, ...} — the grounding's
    # glm-5p3-flash shape).
    def catalog_map
      {off: nil, minimal: nil, low: "low", medium: nil, high: "high", xhigh: nil, max: "max"}
    end

    def test_resolve_reasoning_effort_owner_override
      assert_equal "low", Models.resolve_reasoning_effort("off", map: owner_map, reasoning: true),
        "the String off map value floors off directly"
      assert_equal "low", Models.resolve_reasoning_effort("minimal", map: owner_map, reasoning: true)
      assert_equal "medium", Models.resolve_reasoning_effort("medium", map: owner_map, reasoning: true)
      assert_equal "max", Models.resolve_reasoning_effort("max", map: owner_map, reasoning: true)
    end

    def test_resolve_reasoning_effort_live_catalog_map
      assert_equal "low", Models.resolve_reasoning_effort("off", map: catalog_map, reasoning: true),
        "the null-off floor clamps upward: off → low"
      assert_equal "low", Models.resolve_reasoning_effort("minimal", map: catalog_map, reasoning: true),
        "minimal (null) clamps forward to low"
      assert_equal "high", Models.resolve_reasoning_effort("medium", map: catalog_map, reasoning: true),
        "medium (null) clamps forward to high"
      assert_equal "max", Models.resolve_reasoning_effort("xhigh", map: catalog_map, reasoning: true),
        "xhigh (null) clamps forward to max"
      assert_equal "max", Models.resolve_reasoning_effort("max", map: catalog_map, reasoning: true)
    end

    def test_resolve_reasoning_effort_mapless
      assert_nil Models.resolve_reasoning_effort("off", map: nil, reasoning: true),
        "map-less off sends nothing"
      assert_equal "medium", Models.resolve_reasoning_effort("medium", map: nil, reasoning: true),
        "no map value falls back to the level itself"
      assert_equal "high", Models.resolve_reasoning_effort("xhigh", map: nil, reasoning: true),
        "map-less xhigh clamps down to high"
      assert_equal "high", Models.resolve_reasoning_effort("max", map: nil, reasoning: true)
    end

    def test_resolve_reasoning_effort_non_reasoning_sends_nothing
      assert_nil Models.resolve_reasoning_effort("high", map: owner_map, reasoning: false)
      assert_nil Models.resolve_reasoning_effort("off", map: owner_map, reasoning: false)
      assert_nil Models.resolve_reasoning_effort("medium", map: nil, reasoning: false)
    end

    def test_supported_thinking_levels_per_shape
      assert_equal %w[off], Models.supported_thinking_levels(map: owner_map, reasoning: false),
        "a non-reasoning model offers off alone"
      assert_equal Settings::THINKING_LEVELS, Models.supported_thinking_levels(map: owner_map, reasoning: true),
        "a full-String map offers the whole ladder"
      assert_equal %w[low high max], Models.supported_thinking_levels(map: catalog_map, reasoning: true),
        "null values mark levels unsupported"
      assert_equal %w[off minimal low medium high], Models.supported_thinking_levels(map: nil, reasoning: true),
        "the map-less rule: the ladder without xhigh/max"
      assert_equal %w[off minimal low medium high],
        Models.supported_thinking_levels(map: {off: "low"}, reasoning: true),
        "xhigh/max need a PRESENT entry even when other levels map"
    end

    def test_clamp_thinking_level_forward_then_backward
      assert_equal "low", Models.clamp_thinking_level("minimal", map: catalog_map, reasoning: true)
      assert_equal "max", Models.clamp_thinking_level("xhigh", map: catalog_map, reasoning: true)
      assert_equal "low", Models.clamp_thinking_level("off", map: catalog_map, reasoning: true),
        "the null-off rung is skipped forward"
      assert_equal "high", Models.clamp_thinking_level("max", map: nil, reasoning: true),
        "map-less max clamps backward to high"
      assert_equal "low", Models.clamp_thinking_level("bogus", map: catalog_map, reasoning: true),
        "an unknown level lands on the first supported"
      assert_equal "high", Models.clamp_thinking_level("high", map: catalog_map, reasoning: true),
        "an exactly-supported level passes through"
    end

    # --- I52: the compat→Dialect translation (zai as data, AC5) ---

    # The zai compat subset translates value-by-value onto the closed
    # Dialect vocabulary: the I46/I64 six keys + pi's zai store suppression
    # — with I64's supportsStrictMode threading (zai arm true).
    def test_dialect_for_translates_the_zai_compat
      compat = Shapes::ModelCompat.new(thinking_format: "zai", max_tokens_field: "max_tokens",
        supports_developer_role: false, supports_reasoning_effort: true, zai_tool_stream: true,
        supports_strict_mode: true)
      dialect = Models.dialect_for(compat)

      assert_equal :zai, dialect.thinking_format
      assert_equal "max_tokens", dialect.max_tokens_field
      assert_equal false, dialect.supports_developer_role
      assert_equal true, dialect.supports_reasoning_effort
      assert_equal true, dialect.zai_tool_stream
      assert_equal true, dialect.supports_strict_mode
      assert_equal false, dialect.supports_store
    end

    # The zai rename respects the compat's max_tokens_field; ANY other
    # compat (nil, a non-zai thinkingFormat) yields the DEFAULT dialect —
    # today's "only-zai arms" behavior verbatim.
    def test_dialect_for_nil_and_non_zai_compat_yield_the_default_dialect
      renamed = Models.dialect_for(Shapes::ModelCompat.new(thinking_format: "zai",
        max_tokens_field: "max_completion_tokens", supports_developer_role: true,
        supports_reasoning_effort: false, zai_tool_stream: false))
      assert_equal "max_completion_tokens", renamed.max_tokens_field
      assert_equal true, renamed.supports_developer_role
      assert_equal false, renamed.supports_reasoning_effort
      assert_equal false, renamed.zai_tool_stream
      assert_equal false, renamed.supports_store

      assert_equal :openai, Models.dialect_for(nil).thinking_format
      assert_equal :openai, Models.dialect_for(Shapes::ModelCompat.new(
        thinking_format: "deepseek", max_tokens_field: "max_tokens",
        supports_developer_role: false, supports_reasoning_effort: true,
        zai_tool_stream: false)).thinking_format
      assert Models.dialect_for(nil).equal?(Models.dialect_for(nil)),
        "the default arm is one frozen instance"
      # I64: the 14th key — non-strict everywhere off the zai arm (nil,
      # false, and the DEFAULT singleton itself).
      assert_equal false, Models.dialect_for(nil).supports_strict_mode
      assert_equal false, Models.dialect_for(Shapes::ModelCompat.new(
        thinking_format: "zai", supports_strict_mode: false)).supports_strict_mode
      assert_equal false, Models::DEFAULT_DIALECT.supports_strict_mode
    end

    # --- I64: the supportsStrictMode carry (the strict-compat gate) ------

    # The owner-catalog-shaped compat carries through the FULL chain:
    # models.json → parsed compat → Dialect → wire model. wire_model is
    # the single seam every construction path threads (boot, /model
    # switch, compaction one-shot, subagent children), so the flag rides
    # everywhere by construction — no per-path edits.
    def test_strict_compat_carries_through_load_dialect_and_wire_model
      write_models(<<~JSON)
        {"providers": {"zai": {"name": "Z.AI", "baseUrl": "https://api.z.ai/api/coding/paas/v4",
          "models": [{"id": "glm-5.3", "reasoning": true, "contextWindow": 200000,
            "compat": {"supportsStore": false, "supportsDeveloperRole": false,
                       "supportsReasoningEffort": true, "maxTokensField": "max_tokens",
                       "thinkingFormat": "zai", "supportsStrictMode": true, "zaiToolStream": true}}]}}}
      JSON
      config = load_models
      assert_nil config.error
      entry = config.model_entries.first

      assert_equal true, entry.compat.supports_strict_mode
      dialect = Models.dialect_for(entry.compat)
      assert_equal true, dialect.supports_strict_mode
      wire = Models.wire_model(model_id: entry.id, provider_key: "zai", reasoning: entry.reasoning,
        context_window: 200_000, compat: entry.compat)
      assert_equal true, wire.dialect.supports_strict_mode,
        "the strict flag rides the mounted wire model"
    end

    def test_strict_compat_absent_nil_or_false_yields_a_non_strict_zai_dialect
      absent = Models.dialect_for(Shapes::ModelCompat.new(thinking_format: "zai"))
      explicit_nil = Models.dialect_for(Shapes::ModelCompat.new(thinking_format: "zai", supports_strict_mode: nil))
      explicit_false = Models.dialect_for(Shapes::ModelCompat.new(thinking_format: "zai", supports_strict_mode: false))

      assert_equal false, absent.supports_strict_mode
      assert_equal false, explicit_nil.supports_strict_mode
      assert_equal false, explicit_false.supports_strict_mode
    end

    # The frozen boundary (I46's only-zai-arms shape): a NON-zai compat
    # declaring supportsStrictMode is tolerated-and-DROPPED — it rides
    # DEFAULT_DIALECT itself (pi's getCompat would thread it; recorded
    # divergence + known unknown, no such catalog entry exists here).
    def test_strict_compat_on_a_non_zai_arm_stays_the_default_dialect
      boundary = Models.dialect_for(Shapes::ModelCompat.new(supports_strict_mode: true))
      deepseek = Models.dialect_for(Shapes::ModelCompat.new(thinking_format: "deepseek", supports_strict_mode: true))

      assert Models::DEFAULT_DIALECT.equal?(boundary),
        "a compat-less/zai-less strict declaration rides the frozen DEFAULT singleton"
      assert Models::DEFAULT_DIALECT.equal?(deepseek)
      assert_equal false, boundary.supports_strict_mode
    end

    # --- I43: the schema-path pins (the contract replaced the hand-rolled
    # validate* family — same strings, same order, same entry shape) ---

    # The multi-error interleave: default, then provider fields, then the
    # models in order — the frozen Grounds §5 golden.
    def test_multi_error_interleave_order_is_frozen
      write_models('{"default": 5, "providers": {"a": {"name": 5, "models": [{"id": ""}, {"id": "m", "thinkingLevelMap": {"low": 5}}]}}}')

      assert_equal(
        "Invalid models.json schema:\n" \
        "  - default: expected a \"provider/model-id\" string\n" \
        "  - providers.a.name: expected a string\n" \
        "  - providers.a.models[0].id: required non-empty string\n" \
        "  - providers.a.models[1].thinkingLevelMap.low: expected a string or null\n" \
        "(#{@path})",
        load_models.error
      )
    end

    # The thinkingLevelMap symbolization through the schema-checked load:
    # a full-ladder catalog fixture (every level a String; off floors to
    # "low" — the owner's override shape) parses to the symbol-keyed map
    # the resolution functions consume.
    def test_full_ladder_map_catalog_fixture_symbolizes_through_the_schema_path
      write_models(<<~JSON)
        {"providers": {"glm": {"models": [{"id": "glm-5.3", "reasoning": true,
          "thinkingLevelMap": {"off": "low", "minimal": "low", "low": "low", "medium": "medium",
                               "high": "high", "xhigh": "xhigh", "max": "max"}}]}}}
      JSON

      config = load_models
      assert_nil config.error
      assert_equal Settings::THINKING_LEVEL_MAPS.fetch("accounts/fireworks/models/glm-5p3-flash"),
        config.model_entries.first.thinking_level_map,
        "the owner's override map round-trips symbolized through the contract path"
    end

    # --- I59 zai_max_tokens: the D1 entry-facts helpers (pi's definition
    # defaults ride the facts-THREADING seam, never catalog load) ---

    # The truth table (Grounds §4-c): a declared value passes through
    # verbatim; an entry that omits the field carries pi's modelFromJson
    # default (provider-composer.ts:242-243); NO entry means NO default —
    # the no-entry chain owns the window and wire_model's window fallback
    # owns the cap. The typed entries come off a real catalog load so the
    # shapes stay exactly what the boot threads.
    def test_zai_max_tokens_entry_context_window_truth_table
      write_models(CATALOG)
      declared, windowless = load_models.model_entries

      assert_equal 200_000, Models.entry_context_window(declared),
        "the declared contextWindow passes through verbatim"
      assert_equal 128_000, Models.entry_context_window(windowless),
        "a windowless ENTRY carries pi's definition default (provider-composer.ts:242)"
      assert_equal Models::DEFAULT_ENTRY_CONTEXT_WINDOW,
        Models.entry_context_window(windowless), "the default is the frozen constant"
      assert_nil Models.entry_context_window(nil),
        "NO entry means NO default — the no-entry chain owns the window"
    end

    def test_zai_max_tokens_entry_max_tokens_truth_table
      write_models(CATALOG)
      declared, windowless = load_models.model_entries

      assert_equal 8_192, Models.entry_max_tokens(declared),
        "the declared maxTokens passes through verbatim"
      assert_equal 16_384, Models.entry_max_tokens(windowless),
        "a capless ENTRY carries pi's definition default (provider-composer.ts:243) — " \
        "never the window fallback (the Face-1 400 shape)"
      assert_equal Models::DEFAULT_ENTRY_MAX_TOKENS, Models.entry_max_tokens(windowless),
        "the default is the frozen constant"
      assert_nil Models.entry_max_tokens(nil),
        "NO entry means NO default — wire_model's window fallback owns the cap"

      # The DECLARED pin (shapes_test's neighbor): the helpers read the
      # typed entry — catalog load itself stays defaulted-free, so the
      # loaded entry still carries the raw nil.
      assert_nil windowless.max_tokens, "no catalog-load defaulting (Shapes::Model#to_h stays DECLARED)"
    end

    # --- the vendored pi catalogue tier (I71 R2) — the fill-only law, the
    # frozen match rule, the hermetic inertness ---

    ZAI_BASE_URL = "https://api.z.ai/api/coding/paas/v4"

    def test_vendored_baseurl_match_fills_the_gap_entry
      write_models(JSON.generate({"providers" => {"zai" => {"name" => "Z.AI", "baseUrl" => ZAI_BASE_URL,
        "apiKey" => "k", "models" => [{"id" => "glm-5.3", "reasoning" => true}]}}}))
      entry = load_models.model_entries.first

      assert_equal 1_000_000, Models.entry_context_window(entry),
        "the vendored contextWindow fills the omitted field"
      assert_equal 131_072, Models.entry_max_tokens(entry),
        "the vendored maxTokens fills the capless entry"
      assert_equal "glm-5.3", load_models.model_entries.first.name,
        "the vendored tier is read-only: the loaded entry's name stays the declared id fallback"
    end

    def test_vendored_fills_only_omitted_fields_declared_values_win
      write_models(JSON.generate({"providers" => {"zai" => {"name" => "Z.AI", "baseUrl" => ZAI_BASE_URL,
        "apiKey" => "k", "models" => [{"id" => "glm-5.3", "name" => "Mine", "reasoning" => true,
        "contextWindow" => 200_000, "maxTokens" => 8_192,
        "thinkingLevelMap" => {"low" => "mine"},
        "compat" => {"thinkingFormat" => "openai"}}]}}}))
      entry = load_models.model_entries.first

      assert_equal 200_000, Models.entry_context_window(entry), "the declared window ALWAYS wins"
      assert_equal 8_192, Models.entry_max_tokens(entry), "the declared cap ALWAYS wins"
      assert_equal ({low: "mine"}), Settings.thinking_facts(entry, model_id: entry.id).thinking_level_map,
        "the declared map ALWAYS wins"
      assert_equal :openai, Models.dialect_for_entry(entry).thinking_format,
        "the declared non-zai compat ALWAYS wins (and rides the DEFAULT dialect)"
    end

    def test_vendored_match_is_baseurl_exact_case_and_trailing_slash_tolerant
      write_models(JSON.generate({"providers" => {"zai" => {"name" => "Z.AI",
        "baseUrl" => "HTTPS://API.Z.AI/API/CODING/PAAS/V4/", "apiKey" => "k",
        "models" => [{"id" => "GLM-5.3"}]}}}))
      entry = load_models.model_entries.first

      assert_equal 1_000_000, Models.entry_context_window(entry),
        "case-insensitive baseUrl compare, one trailing slash stripped both sides, id compare case-insensitive"
    end

    def test_vendored_key_arms_only_without_a_declared_baseurl
      # (b): the block declares NO baseUrl and its KEY equals the vendored name.
      write_models(JSON.generate({"providers" => {"ZAI" => {"name" => "Z.AI", "apiKey" => "k",
        "models" => [{"id" => "glm-5.3"}]}}}))
      assert_equal 1_000_000, Models.entry_context_window(load_models.model_entries.first),
        "the KEY arm matches case-insensitively (no baseUrl declared)"

      # The hermetic-suite inertness law: a zai-KEYED block WITH a baseUrl
      # that matches no vendored provider matches NOTHING — no bare-id
      # cross-provider fallback.
      write_models(JSON.generate({"providers" => {"zai" => {"name" => "Z.AI",
        "baseUrl" => "http://localhost:1/v1", "apiKey" => "k",
        "models" => [{"id" => "glm-5.3"}]}}}))
      entry = load_models.model_entries.first
      assert_equal Models::DEFAULT_ENTRY_CONTEXT_WINDOW, Models.entry_context_window(entry)
      assert_equal Models::DEFAULT_ENTRY_MAX_TOKENS, Models.entry_max_tokens(entry)
      assert_nil Models.resolved_compat(entry), "no match ⇒ no vendored compat"
    end

    def test_vendored_no_match_is_inert_and_no_entry_stays_nil
      write_models(CATALOG) # glm @ https://example.test/v1 — matches nothing vendored
      declared, windowless = load_models.model_entries

      assert_equal Models::DEFAULT_ENTRY_CONTEXT_WINDOW, Models.entry_context_window(windowless)
      assert_equal Models::DEFAULT_ENTRY_MAX_TOKENS, Models.entry_max_tokens(windowless)
      assert_nil Models.entry_context_window(nil), "nil entry ⇒ nil, unchanged"
      assert_nil Models.entry_max_tokens(nil), "nil entry ⇒ nil, unchanged"
      assert Models::DEFAULT_DIALECT.equal?(Models.dialect_for_entry(windowless)),
        "no match ⇒ the default dialect instance"
    end

    def test_vendored_dialect_for_entry_arms_both_ways
      write_models(JSON.generate({"providers" => {
        "zai" => {"name" => "Z.AI", "baseUrl" => ZAI_BASE_URL, "apiKey" => "k",
          "models" => [{"id" => "glm-5.3"}]},
        "openrouter" => {"name" => "OR", "baseUrl" => "https://openrouter.ai/api/v1", "apiKey" => "k",
          "models" => [{"id" => "z-ai/glm-5.3"}]}}}))
      zai, openrouter = load_models.model_entries

      d = Models.dialect_for_entry(zai)
      assert_equal :zai, d.thinking_format, "the vendored zai thinkingFormat builds the zai dialect"
      assert_equal "max_tokens", d.max_tokens_field
      assert_equal false, d.supports_developer_role
      assert_equal true, d.supports_reasoning_effort
      assert_equal true, d.zai_tool_stream
      refute Models::DEFAULT_DIALECT.equal?(d)

      # The I46/I64 boundary: the vendored openrouter thinkingFormat is NOT
      # zai — the DEFAULT dialect, the superset keys tolerated-and-dropped.
      plain = Models.dialect_for_entry(openrouter)
      assert Models::DEFAULT_DIALECT.equal?(plain),
        "the vendored openrouter compat rides the DEFAULT dialect (no vocabulary extension)"
    end

    def test_vendored_owner_catalog_shape_is_a_merge_noop
      # The owner's live models.json shape: every entry FULLY specified —
      # every seam reads the declared value, the vendored tier never fires.
      owner = {"default" => "openrouter/z-ai/glm-5.3", "providers" => {
        "zai" => {"name" => "Z.AI", "baseUrl" => ZAI_BASE_URL, "apiKey" => "k", "models" => [
          {"id" => "glm-5.3", "reasoning" => true, "contextWindow" => 1_000_000, "maxTokens" => 131_072,
           "thinkingLevelMap" => {"off" => nil, "low" => "low", "high" => "high", "max" => "max"},
           "compat" => {"supportsStore" => false, "supportsDeveloperRole" => false,
                        "supportsReasoningEffort" => true, "maxTokensField" => "max_tokens",
                        "thinkingFormat" => "zai", "supportsStrictMode" => true, "zaiToolStream" => true}}]}}}
      write_models(JSON.generate(owner))
      entry = load_models.model_entries.first

      assert_equal 1_000_000, Models.entry_context_window(entry)
      assert_equal 131_072, Models.entry_max_tokens(entry)
      assert_equal :zai, Models.dialect_for_entry(entry).thinking_format
      assert_equal 131_072, Models.entry_max_tokens(entry), "declared cap — no vendored fill"
    end

    def test_vendored_loaded_catalog_bytes_stay_stable
      write_models(JSON.generate({"providers" => {"zai" => {"name" => "Z.AI", "baseUrl" => ZAI_BASE_URL,
        "apiKey" => "k", "models" => [{"id" => "glm-5.3"}]}}}))
      entry = load_models.model_entries.first

      assert_equal({id: "glm-5.3", name: "glm-5.3", reasoning: false, context_window: nil,
                    max_tokens: nil, thinking_level_map: nil, compat: nil, provider: "zai"},
        entry.to_h,
        "the fill lives at the fact seams ONLY — Shapes::Model#to_h stays DECLARED")
      assert_nil entry.max_tokens, "no merge-at-load"
    end
  end
end
