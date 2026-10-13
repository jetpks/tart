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
                     context_window: 200_000, max_tokens: 8192, thinking_level_map: nil}), entry
      assert_equal "https://example.test/v1", config.provider("glm").fetch(:base_url)
      assert_equal "k-catalog", config.provider("glm").fetch(:api_key)
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

    # --- resolve (pi findExactModelReferenceMatch, reduced) ---

    def catalog
      Models::Config.new(
        providers: {
          "glm" => {name: nil, base_url: nil, api_key: nil, api: nil,
                    models: [{provider: "glm", id: "glm-5.3", name: "GLM 5.3", reasoning: true,
                              context_window: 200_000, max_tokens: nil},
                             {provider: "glm", id: "air", name: "Air", reasoning: false,
                              context_window: nil, max_tokens: nil}]},
          "zai" => {name: nil, base_url: nil, api_key: nil, api: nil,
                    models: [{provider: "zai", id: "glm-5.3", name: "GLM 5.3 (zai)", reasoning: true,
                              context_window: nil, max_tokens: nil}]}
        },
        default: nil, error: nil
      )
    end

    def test_resolve_canonical_and_provider_scoped_and_bare
      assert_equal "glm", catalog.resolve("GLM/GLM-5.3").fetch(:provider), "the canonical ref is case-insensitive"
      assert_equal "zai", catalog.resolve("zai/glm-5.3").fetch(:provider), "the provider prefix disambiguates"
      assert_equal "Air", catalog.resolve("air").fetch(:name), "a unique bare id matches"
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

    def test_boot_resolves_env_over_all
      boot = Models.resolve_boot_model(catalog, settings, env: {"PI_MODEL" => "m-env", "PI_PROVIDER" => "p-env"})
      assert_equal ({provider: "p-env", id: "m-env"}), boot
    end

    def test_boot_env_model_alone_keeps_the_settings_provider
      boot = Models.resolve_boot_model(catalog, settings, env: {"PI_MODEL" => "m-env"})
      assert_equal ({provider: "settings-provider", id: "m-env"}), boot
    end

    def test_boot_env_provider_alone_keeps_the_settings_model
      boot = Models.resolve_boot_model(catalog, settings, env: {"PI_PROVIDER" => "p-env"})
      assert_equal ({provider: "p-env", id: "settings-model"}), boot
    end

    # The env keys ride the identity's namespace (I32 AC4).
    def test_boot_env_keys_follow_the_identity
      tart = Models.resolve_boot_model(catalog, settings, identity: "tart",
        env: {"TART_MODEL" => "m-env", "TART_PROVIDER" => "p-env"})
      assert_equal ({provider: "p-env", id: "m-env"}), tart
      foo = Models.resolve_boot_model(catalog, settings, identity: "foo", env: {"FOO_MODEL" => "m-foo"})
      assert_equal ({provider: "settings-provider", id: "m-foo"}), foo
      # A pi-key boot under identity tart is NOT read — the namespaces
      # don't bleed.
      assert_equal ({provider: "settings-provider", id: "settings-model"}),
        Models.resolve_boot_model(catalog, settings, identity: "tart", env: {"PI_MODEL" => "m-env"})
    end

    def test_boot_resolves_the_models_json_default_over_settings
      write_models(CATALOG)
      config = load_models
      boot = Models.resolve_boot_model(config, settings, env: {})
      assert_equal ({provider: "glm", id: "glm-5.3"}), boot
    end

    def test_boot_falls_through_to_settings_without_a_default
      write_models('{"providers": {"glm": {"models": [{"id": "glm-5.3"}]}}}')
      boot = Models.resolve_boot_model(load_models, settings, env: {})
      assert_equal ({provider: "settings-provider", id: "settings-model"}), boot
    end

    def test_boot_resolves_settings_alone_when_no_catalog
      boot = Models.resolve_boot_model(Models.load(root: @root), settings, env: {})
      assert_equal ({provider: "settings-provider", id: "settings-model"}), boot
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
      assert_equal ({off: nil, low: "low", madeup: "x"}), entry[:thinking_level_map],
        "symbolized keys, null kept, unknown level keys tolerated (pi's Partial-Record default)"
    end

    def test_thinking_level_map_absent_is_nil
      write_models('{"providers": {"glm": {"models": [{"id": "m"}]}}}')
      assert_nil load_models.model_entries.first[:thinking_level_map]
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
        config.model_entries.first[:thinking_level_map],
        "the owner's override map round-trips symbolized through the contract path"
    end
  end
end
