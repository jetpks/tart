# frozen_string_literal: true

require_relative "test_helper"
require "dry-struct"
require "fileutils"
require "tmpdir"

module Tart
  # The I44 shapes family (AC1–AC4 pins): construction + coercion
  # failures for every struct, the Model#to_h byte-shape pin (the merged
  # catalog entry hash, key order included), the catalog/boot equivalence
  # rows, the resolved-settings outcome table (the I43 precedence keys,
  # malformed values flowing through verbatim), the typed known-models
  # tables (contents key-for-key, MapError on a bad literal), and the
  # session-envelope tolerance table.
  class ShapesTest < Test
    def setup
      @root = Dir.mktmpdir("tart-shapes-")
    end

    def teardown
      FileUtils.rm_rf(@root)
    end

    def write_models(json)
      File.write(File.join(@root, "models.json"), json)
    end

    # --- B1: construction + the to_h byte shape ---

    def catalog_model(provider: "glm", overrides: {})
      Shapes::Model.new({id: "glm-5.3", name: "GLM 5.3", reasoning: true, context_window: 200_000,
                         max_tokens: 8192, thinking_level_map: {off: "low", medium: nil},
                         provider: provider}.merge(overrides))
    end

    def test_model_constructs_from_the_catalog_entry_shape
      model = catalog_model

      assert_equal "glm-5.3", model.id
      assert_equal "GLM 5.3", model.name
      assert_equal true, model.reasoning
      assert_equal 200_000, model.context_window
      assert_equal 8192, model.max_tokens
      assert_equal ({off: "low", medium: nil}), model.thinking_level_map
      assert_equal "glm", model.provider
    end

    def test_model_to_h_is_todays_entry_hash_key_order_included
      assert_equal(
        {id: "glm-5.3", name: "GLM 5.3", reasoning: true, context_window: 200_000,
         max_tokens: 8192, thinking_level_map: {off: "low", medium: nil}, compat: nil, provider: "glm"},
        catalog_model.to_h,
        "the merged build_model shape with the provider key appended LAST"
      )
      assert_equal %i[id name reasoning context_window max_tokens thinking_level_map compat provider],
        catalog_model.to_h.keys, "the DECLARED attribute order is the emission order"
    end

    def test_model_wrong_typed_input_raises_struct_errors
      assert_raises(Dry::Struct::Error) { catalog_model(overrides: {id: 5}) }
      assert_raises(Dry::Struct::Error) { catalog_model(overrides: {reasoning: "true"}) }
      assert_raises(Dry::Struct::Error) { catalog_model(overrides: {context_window: "200000"}) }
      assert_raises(Dry::Struct::Error) { catalog_model(overrides: {thinking_level_map: "high"}) }
      assert_raises(Dry::Struct::Error) { catalog_model(overrides: {compat: 5}) }
    end

    # --- I46: the compat subset shape -----------------------------------------

    def zai_compat(overrides = {})
      Shapes::ModelCompat.new({thinking_format: "zai", max_tokens_field: "max_tokens",
                               supports_developer_role: false, supports_reasoning_effort: true,
                               zai_tool_stream: true}.merge(overrides))
    end

    def test_model_compat_constructs_with_the_owner_subset_and_reads_nil_defaults
      compat = zai_compat

      assert_equal "zai", compat.thinking_format
      assert_equal "max_tokens", compat.max_tokens_field
      assert_equal false, compat.supports_developer_role
      assert_equal true, compat.supports_reasoning_effort
      assert_equal true, compat.zai_tool_stream

      # Every attribute is omittable at construction and nil-defaulted
      # (pi's Optional keys — absent = the detection stand-in).
      bare = Shapes::ModelCompat.new
      assert_nil bare.thinking_format
      assert_nil bare.max_tokens_field
      assert_nil bare.supports_developer_role
      assert_nil bare.supports_reasoning_effort
      assert_nil bare.zai_tool_stream
    end

    def test_model_compat_enum_and_bool_constraints_raise
      assert_raises(Dry::Struct::Error) { zai_compat(thinking_format: "nope") }
      assert_raises(Dry::Struct::Error) { zai_compat(max_tokens_field: "tokens") }
      assert_raises(Dry::Struct::Error) { zai_compat(supports_developer_role: "yes") }
      assert_raises(Dry::Struct::Error) { zai_compat(supports_reasoning_effort: 1) }
      assert_raises(Dry::Struct::Error) { zai_compat(zai_tool_stream: "true") }
      # The other ten pi thinkingFormat literals construct.
      %w[openai openrouter deepseek together baseten qwen chat-template
         qwen-chat-template string-thinking ant-ling].each do |format|
        assert_equal format, zai_compat(thinking_format: format).thinking_format
      end
      assert_equal "max_completion_tokens", zai_compat(max_tokens_field: "max_completion_tokens").max_tokens_field
    end

    def test_model_carries_the_typed_compat_and_defaults_nil
      model = catalog_model(overrides: {compat: zai_compat})

      assert_instance_of Shapes::ModelCompat, model.compat
      assert_equal "zai", model.compat.thinking_format
      assert_nil catalog_model.compat, "a compat-less entry reads nil (the default arm)"
    end

    def test_provider_constructs_with_nested_typed_models
      provider = Shapes::Provider.new(
        name: "GLM", base_url: "https://example.test/v1", api_key: "k", api: "openai-completions",
        models: [catalog_model]
      )

      assert_equal "GLM", provider.name
      assert_instance_of Shapes::Model, provider.models.first
      # Today's parse may omit the endpoint fields — they read nil.
      bare = Shapes::Provider.new(name: nil, base_url: nil, api_key: nil, api: nil, models: [])
      assert_nil bare.api
      assert_raises(Dry::Struct::Error) { Shapes::Provider.new(name: 5, models: []) }
    end

    def test_model_ref_and_thinking_facts_construct
      ref = Shapes::ModelRef.new(provider: "openai", id: "glm-5.3")
      assert_equal ({provider: "openai", id: "glm-5.3"}), ref.to_h

      facts = Shapes::ThinkingFacts.new(reasoning: true, thinking_level_map: {off: "low"})
      assert_equal true, facts.reasoning
      assert_nil Shapes::ThinkingFacts.new(reasoning: false, thinking_level_map: nil).thinking_level_map
      assert_raises(Dry::Struct::Error) { Shapes::ModelRef.new(provider: "openai", id: nil) }
      assert_raises(Dry::Struct::Error) { Shapes::ThinkingFacts.new(reasoning: nil, thinking_level_map: nil) }
    end

    # --- B1: catalog + boot equivalence through the real loaders ---

    def test_models_load_entries_to_h_equal_todays_entry_hashes
      write_models(<<~JSON)
        {"default": "glm/glm-5.3",
         "providers": {"glm": {"name": "GLM", "baseUrl": "https://example.test/v1", "apiKey": "k",
           "models": [{"id": "glm-5.3", "name": "GLM 5.3", "reasoning": true,
                       "contextWindow": 200000, "maxTokens": 8192,
                       "thinkingLevelMap": {"off": null, "low": "low"}},
                      {"id": "glm-5-air"}]}}}
      JSON

      config = Models.load(root: @root)
      assert_nil config.error
      assert_equal [
        {id: "glm-5.3", name: "GLM 5.3", reasoning: true, context_window: 200_000, max_tokens: 8192,
         thinking_level_map: {off: nil, low: "low"}, compat: nil, provider: "glm"},
        {id: "glm-5-air", name: "glm-5-air", reasoning: false, context_window: nil, max_tokens: nil,
         thinking_level_map: nil, compat: nil, provider: "glm"}
      ], config.model_entries.map(&:to_h), "line-for-line today's flattened entry hashes"
      assert_instance_of Shapes::Model, config.model_entries.first
      assert_instance_of Shapes::Provider, config.provider("glm")
    end

    def test_config_resolve_match_table_through_attribute_reads
      provider = lambda do |key, id|
        Shapes::Model.new(id: id, name: id, reasoning: false, context_window: nil,
          max_tokens: nil, thinking_level_map: nil, provider: key)
      end
      config = Models::Config.new(
        providers: {
          "glm" => Shapes::Provider.new(name: nil, base_url: nil, api_key: nil, api: nil,
            models: [provider.call("glm", "glm-5.3"), provider.call("glm", "air")]),
          "zai" => Shapes::Provider.new(name: nil, base_url: nil, api_key: nil, api: nil,
            models: [provider.call("zai", "glm-5.3")])
        },
        default: nil, error: nil
      )

      assert_equal "glm", config.resolve("GLM/GLM-5.3").provider
      assert_equal "zai", config.resolve("zai/glm-5.3").provider
      assert_equal "air", config.resolve("air").id
      assert_nil config.resolve("glm-5.3"), "a bare id ambiguous across providers is no match"
      assert_nil config.resolve("nope")
      assert_nil config.resolve("  ")
      assert_nil config.provider("nope")
      assert_instance_of Shapes::Provider, config.provider("glm")
    end

    def test_resolve_boot_model_returns_the_typed_ref_per_tier_and_identity
      settings = Settings::DEFAULTS.merge("defaultModel" => "settings-model", "defaultProvider" => "settings-provider")
      empty = Models::Config.new(providers: {}, default: nil, error: nil)

      assert_equal({provider: "p-env", id: "m-env"},
        Models.resolve_boot_model(empty, settings, env: {"PI_MODEL" => "m-env", "PI_PROVIDER" => "p-env"}).to_h)
      assert_equal({provider: "settings-provider", id: "m-env"},
        Models.resolve_boot_model(empty, settings, env: {"PI_MODEL" => "m-env"}).to_h)
      assert_equal({provider: "p-env", id: "settings-model"},
        Models.resolve_boot_model(empty, settings, env: {"PI_PROVIDER" => "p-env"}).to_h)
      assert_equal({provider: "p-env2", id: "m-env2"},
        Models.resolve_boot_model(empty, settings, identity: "tart",
          env: {"TART_MODEL" => "m-env2", "TART_PROVIDER" => "p-env2"}).to_h)
      assert_equal({provider: "settings-provider", id: "settings-model"},
        Models.resolve_boot_model(empty, settings, env: {}).to_h,
        "the settings tier (both identity namespaces ride the same keys)")
      assert_equal({provider: "p-env3", id: "m-foo"},
        Models.resolve_boot_model(empty, settings, identity: "foo", env: {"FOO_MODEL" => "m-foo", "FOO_PROVIDER" => "p-env3"}).to_h)
    end

    def test_thinking_facts_compose_catalog_first_known_tables_second
      entry = Shapes::Model.new(id: "m", name: "m", reasoning: false, context_window: nil,
        max_tokens: nil, thinking_level_map: {low: "low"}, provider: "glm")
      facts = Settings.thinking_facts(entry, {"modelReasoning" => true}, model_id: "m")
      assert_instance_of Shapes::ThinkingFacts, facts
      assert_equal false, facts.reasoning, "the entry's flag decides over the staged env"
      assert_equal ({low: "low"}), facts.thinking_level_map

      bare = Settings.thinking_facts(nil, {}, model_id: "accounts/fireworks/models/glm-5p3-flash")
      assert_equal false, bare.reasoning
      assert_equal Settings::THINKING_LEVEL_MAPS.fetch("accounts/fireworks/models/glm-5p3-flash"),
        bare.thinking_level_map, "known-tables-second"
    end

    # --- B2: ResolvedSettings.from_load — the precedence outcome table ---

    def merged(settings_hash)
      Settings::DEFAULTS.merge(settings_hash)
    end

    def test_resolved_settings_outcome_table_per_key
      resolved = Shapes::ResolvedSettings.from_load(
        merged("defaultModel" => "m-file", "defaultProvider" => "p-file", "apiBase" => "https://file.example",
               "apiKey" => "file-key", "contextWindow" => 123_456, "thinkingLevel" => "high",
               "defaultTools" => ["read", "+find"], "compaction" => {"enabled" => false, "reserveTokens" => 99}),
        identity: "pi", env: {}
      )

      # file-only rows (env absent, DEFAULTS below)
      assert_equal "m-file", resolved.default_model
      assert_equal "p-file", resolved.default_provider
      assert_equal "https://file.example", resolved.api_base
      assert_equal "file-key", resolved.api_key
      assert_equal 123_456, resolved.context_window
      assert_equal "high", resolved.thinking_level
      assert_equal %w[read find], resolved.default_tools
      assert_instance_of Shapes::CompactionSettings, resolved.compaction
      assert_equal false, resolved.compaction.enabled
      assert_equal 99, resolved.compaction.reserve_tokens
      refute resolved.compaction.to_h.key?(:keep_recent_tokens), "the present-keys slice only"
      assert_equal "pi", resolved.identity

      # env-over-file and all-tier rows
      overridden = Shapes::ResolvedSettings.from_load(merged("defaultModel" => "m-file", "apiKey" => "file-key"),
        identity: "pi", env: {"PI_MODEL" => "m-env", "PI_API_KEY" => "env-key"})
      assert_equal "m-env", overridden.default_model
      assert_equal "env-key", overridden.api_key

      # default-only rows (none above)
      bare = Shapes::ResolvedSettings.from_load(Settings::DEFAULTS, identity: "pi", env: {})
      assert_equal Settings::DEFAULTS.fetch("defaultModel"), bare.default_model
      assert_equal Settings::DEFAULTS.fetch("apiBase"), bare.api_base
      assert_equal "medium", bare.thinking_level
      assert_nil bare.context_window
      assert_equal Settings::DEFAULT_TOOLS, bare.default_tools
      assert_equal({enabled: true, reserve_tokens: 16_384, keep_recent_tokens: 20_000}, bare.compaction.to_h,
        "the DEFAULTS compaction block rides the slice")
    end

    def test_resolved_settings_flows_malformed_values_through_verbatim
      resolved = Shapes::ResolvedSettings.from_load(
        merged("defaultModel" => 5, "defaultProvider" => true, "apiBase" => [], "apiKey" => {"deep" => 1},
               "contextWindow" => "abc"),
        identity: "pi", env: {}
      )

      assert_equal 5, resolved.default_model, "the no-filter pin: raw values land verbatim"
      assert_equal true, resolved.default_provider
      assert_empty resolved.api_base
      assert_equal({"deep" => 1}, resolved.api_key)
      assert_nil resolved.context_window, "a malformed file-tier window reads as absent (the tier falls through)"
    end

    def test_resolved_settings_from_a_load_result_and_env_tier_only
      result = Settings::Result.new(settings: Settings::DEFAULTS, diagnostics: [])
      resolved = Shapes::ResolvedSettings.from_load(result, identity: "pi", env: {"PI_API_KEY" => "env-only"})
      assert_equal "env-only", resolved.api_key, "the env tier rides the identity namespace"

      result2 = Settings::Result.new(settings: Settings::DEFAULTS, diagnostics: [])
      assert_equal result2.settings.fetch("apiBase"), Shapes::ResolvedSettings.from_load(result2, identity: "pi").api_base
    end

    # --- B2: the typed known-models tables + the default level ---

    def test_typed_tables_contents_match_todays_literals
      assert_equal({"accounts/fireworks/models/glm-5p3-flash" => 1_048_573}, Settings::MODEL_CONTEXT_WINDOWS)
      assert_equal({"accounts/fireworks/models/glm-5p3-flash" => true}, Settings::MODEL_REASONING)
      assert_equal(
        {"accounts/fireworks/models/glm-5p3-flash" =>
          {off: "low", minimal: "low", low: "low", medium: "medium", high: "high", xhigh: "xhigh", max: "max"}},
        Settings::THINKING_LEVEL_MAPS
      )
      assert Settings::MODEL_CONTEXT_WINDOWS.frozen?
      assert Settings::THINKING_LEVEL_MAPS.frozen?
      assert Settings::THINKING_LEVEL_MAPS.values.first.frozen?, "the inner maps stay frozen too"
    end

    def test_default_thinking_level_single_sources_the_defaults_row
      assert_equal "medium", Settings::DEFAULT_THINKING_LEVEL
      assert_equal Settings::DEFAULTS.fetch("thinkingLevel"), Settings::DEFAULT_THINKING_LEVEL
    end

    def test_a_malformed_table_literal_fails_at_load_with_map_error
      map_type = Shapes::Types::Strict::Hash.map(Shapes::Types::Strict::String, Shapes::Types::Strict::Integer)
      assert_raises(Dry::Types::MapError) { map_type["glm" => "not-an-integer"] }

      nested = Shapes::Types::Strict::Hash.map(Shapes::Types::Strict::String,
        Shapes::Types::Strict::Hash.map(Shapes::Types::Strict::Symbol,
          Shapes::Types::Strict::String | Shapes::Types::Strict::Nil))
      assert_raises(Dry::Types::MapError) { nested["glm" => {off: 5}] }
    end

    # --- B3: the session envelopes' tolerance table ---

    def loaded_entry(json)
      JSON.parse(json)
    end

    def test_message_entry_envelope_from_a_loaded_line
      envelope = Shapes::MessageEntry.of(loaded_entry(
        '{"type":"message","id":"e1","parentId":null,"timestamp":"t","message":{"role":"user","content":"hi"}}'
      ))

      assert_instance_of Shapes::MessageEntry, envelope
      assert_equal "message", envelope.type
      assert_equal "user", envelope.role
      assert_equal ({"role" => "user", "content" => "hi"}), envelope.message,
        "the recorded body rides verbatim (recorded key style, tool fields included)"
    end

    def test_message_entry_tolerance_table_matches_the_guard_chain
      assert_nil Shapes::MessageEntry.of(nil), "non-Hash"
      assert_nil Shapes::MessageEntry.of(loaded_entry('{"type":"usage","id":"e"}')), "wrong type"
      assert_nil Shapes::MessageEntry.of(loaded_entry('{"type":"message","id":"e"}')), "body-less"
      assert_nil Shapes::MessageEntry.of(loaded_entry('{"type":"message","id":"e","message":"nope"}')), "non-Hash body"
      assert_nil Shapes::MessageEntry.of(loaded_entry(
        '{"type":"message","id":"e","message":{"content":"role-less"}}'
      )), "role-less"
      assert_nil Shapes::MessageEntry.of(loaded_entry(
        '{"type":"message","id":"e","message":{"role":5}}'
      )), "non-String role"
    end

    def test_compaction_entry_envelope_and_tolerance
      envelope = Shapes::CompactionEntry.of(loaded_entry(
        '{"type":"compaction","id":"e3","summary":"s","firstKeptEntryId":"e2","tokensBefore":42}'
      ))

      assert_equal "compaction", envelope.type
      assert_equal "e3", envelope.id
      assert_equal "e2", envelope.first_kept_entry_id
      assert_equal "s", envelope.summary
      assert_nil Shapes::CompactionEntry.of(nil)
      assert_nil Shapes::CompactionEntry.of(loaded_entry('{"type":"message","id":"e"}')), "only compactions wrap"
      assert Shapes::CompactionEntry.of(loaded_entry('{"type":"compaction"}')),
        "a field-less compaction still matches the scan (the nominal scan fields)"
    end

    def test_session_header_envelope_fields_and_tolerance
      envelope = Shapes::SessionHeader.of(loaded_entry(
        '{"type":"session","version":3,"id":"abc","timestamp":"t","cwd":"/tmp","parentSession":"/old"}'
      ))

      assert_equal "session", envelope.type
      assert_equal "abc", envelope.id
      assert_equal "/tmp", envelope.cwd
      assert_equal 3, envelope.version
      assert_equal "/old", envelope.parentSession
      assert envelope.key?("parentSession"), "the discovery read"
      assert_equal "/old", envelope["parentSession"]

      fresh = Shapes::SessionHeader.of(loaded_entry('{"type":"session","version":3,"id":"x","cwd":"/w"}'))
      refute fresh.key?("parentSession")
      assert_nil fresh["parentSession"], "absent keys read nil, never a raise"
      assert_nil Shapes::SessionHeader.of(loaded_entry('{"type":"not-a-session"}'))
      assert_nil Shapes::SessionHeader.of(loaded_entry('{"type":"session","id":null}')), "non-String id"
      assert_nil Shapes::SessionHeader.of(nil)
    end

    def test_context_message_coercions_and_recorded_order
      projected = Shapes::ContextMessage.new(JSON.parse(
        '{"role":"tool","tool_call_id":"call_1","content":"fixture.txt"}'
      ))

      assert_equal({role: :tool, tool_call_id: "call_1", content: "fixture.txt"}, projected.to_h,
        "the recorded key order is preserved (the wire shape)")
      assert_equal :tool, projected.role

      nil_content = Shapes::ContextMessage.new("role" => "assistant", "content" => nil, "tool_calls" => [])
      assert_equal({role: :assistant, content: "", tool_calls: []}, nil_content.to_h,
        "null content maps to the empty string in place")

      missing = Shapes::ContextMessage.new({"role" => "user"})
      assert_equal({role: :user, content: ""}, missing.to_h, "missing content gains the key LAST")
    end
  end
end
