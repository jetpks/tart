# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/mock_llm_server"
require "fileutils"
require "tmpdir"

module Tart
  # Settings load/merge/resolve (AC2) + the I08 registry-default carry-in:
  # hermetic tmp dirs (fake ~/.tart root), no real ~/.tart. The
  # out-of-the-box compaction proof runs the loop on a MockLLMServer.
  class SettingsTest < Test
    def setup
      @root = Dir.mktmpdir("tart-settings-user-")
      @cwd = Dir.mktmpdir("tart-settings-project-")
      @user_path = File.join(@root, "settings.json")
      @project_path = File.join(@cwd, ".tart", "settings.json")
      @saved_env = %w[PI_MODEL PI_PROVIDER PI_API_KEY PI_API_BASE PI_CONTEXT_WINDOW PI_MODEL_REASONING
                      TART_MODEL TART_PROVIDER TART_API_KEY TART_API_BASE TART_CONTEXT_WINDOW TART_MODEL_REASONING]
        .to_h { |key| [key, ENV[key]] }
      @saved_env.each_key { |key| ENV.delete(key) }
    end

    def teardown
      FileUtils.rm_rf(@root)
      FileUtils.rm_rf(@cwd)
      @saved_env.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
      @server&.stop
    end

    def write_settings(path, json)
      FileUtils.mkpath(File.dirname(path))
      File.write(path, json)
    end

    def load_settings
      Settings.load(cwd: @cwd, root: @root)
    end

    # --- files + merge ---

    def test_defaults_hold_with_no_files
      result = load_settings
      assert_empty result.diagnostics
      assert_equal Settings::DEFAULTS.fetch("defaultModel"), result.settings["defaultModel"]
      assert_equal 16_384, result.settings["compaction"]["reserveTokens"]
      assert_equal 20_000, result.settings["compaction"]["keepRecentTokens"]
      assert result.settings.dig("compaction", "enabled")
    end

    def test_project_deep_merges_over_user
      write_settings(@user_path, '{"compaction": {"reserveTokens": 1000, "keepRecentTokens": 500}}')
      write_settings(@project_path, '{"compaction": {"reserveTokens": 2000}, "defaultModel": "m-project"}')

      settings = load_settings.settings
      assert_equal "m-project", settings["defaultModel"]
      assert_equal 2000, settings["compaction"]["reserveTokens"]
      assert_equal 500, settings["compaction"]["keepRecentTokens"], "user keys survive under a project override"
    end

    def test_unknown_keys_warn_and_do_not_break_the_run
      write_settings(@project_path, '{"defaultModel": "m", "notARealKey": 1}')

      result = load_settings
      assert_equal "m", result.settings["defaultModel"]
      warning = result.diagnostics.find { |d| d.message.include?("notARealKey") }
      refute_nil warning
      assert_equal @project_path, warning.path
    end

    def test_invalid_json_falls_back_to_defaults_with_a_diagnostic
      write_settings(@user_path, "{not json")
      result = load_settings

      assert_equal Settings::DEFAULTS.fetch("defaultModel"), result.settings["defaultModel"]
      assert result.diagnostics.first.message.include?("invalid settings JSON")
    end

    # --- the write surface (I27, the ctrl+s set-as-default path) ---

    def test_save_writes_the_updates_and_the_file_round_trips
      path = Settings.save(@root, "defaultProvider" => "glm", "defaultModel" => "glm-5.3")

      assert_equal @user_path, path
      settings = load_settings.settings
      assert_equal "glm-5.3", settings["defaultModel"]
      assert_equal "glm", settings["defaultProvider"]
    end

    def test_save_preserves_unknown_and_unmodified_keys
      write_settings(@user_path, '{"defaultModel": "m", "notARealKey": {"deep": [1]}, "compaction": {"reserveTokens": 1000}}')

      Settings.save(@root, "defaultProvider" => "glm")
      saved = JSON.parse(File.read(@user_path))

      assert_equal "m", saved["defaultModel"], "unmodified keys survive"
      assert_equal ({"deep" => [1]}), saved["notARealKey"], "unknown keys are preserved verbatim (never clobbered)"
      assert_equal 1000, saved.dig("compaction", "reserveTokens"), "nested blocks survive"
      assert_equal "glm", saved["defaultProvider"]
      refute saved.key?("thinkingLevel"), "only the asked-for keys are written"
    end

    def test_save_creates_the_dir_and_over_an_unparseable_file_starts_fresh
      path = Settings.save(File.join(@root, "nested"), "thinkingLevel" => "high")

      assert_equal File.join(@root, "nested", "settings.json"), path
      assert_equal "high", JSON.parse(File.read(path))["thinkingLevel"]

      FileUtils.rm_rf(@root)
      FileUtils.mkpath(@root)
      File.write(@user_path, "{not json")
      Settings.save(@root, "thinkingLevel" => "low")
      assert_equal "low", JSON.parse(File.read(@user_path))["thinkingLevel"]
    end

    # --- env → settings → built-in default, per key ---

    def test_model_provider_api_base_and_api_key_resolve_env_over_settings_over_default
      write_settings(@user_path,
        '{"defaultModel": "m-file", "defaultProvider": "p-file", "apiBase": "https://file.example", "apiKey": "file-key"}')

      assert_equal "m-file", Settings.resolve_setting("defaultModel", load_settings.settings)
      ENV["PI_MODEL"] = "m-env"
      assert_equal "m-env", Settings.resolve_setting("defaultModel", load_settings.settings)

      assert_equal "p-file", Settings.resolve_setting("defaultProvider", load_settings.settings)
      ENV["PI_PROVIDER"] = "p-env"
      assert_equal "p-env", Settings.resolve_setting("defaultProvider", load_settings.settings)

      assert_equal "https://file.example", Settings.resolve_setting("apiBase", load_settings.settings)
      ENV["PI_API_BASE"] = "https://env.example"
      assert_equal "https://env.example", Settings.resolve_setting("apiBase", load_settings.settings)

      assert_equal "file-key", Settings.resolve_setting("apiKey", load_settings.settings)
      ENV["PI_API_KEY"] = "env-key"
      assert_equal "env-key", Settings.resolve_setting("apiKey", load_settings.settings)
    end

    # The namespace follows the identity (owner ruling 3): pi reads PI_,
    # tart TART_, any other name its own uppercased prefix.
    def test_env_namespace_follows_the_identity
      ENV["PI_API_KEY"] = "pi-key"
      ENV["TART_API_KEY"] = "tart-key"
      ENV["FOO_MODEL"] = "foo-model"
      assert_equal "pi-key", Settings.resolve_setting("apiKey", {}, identity: "pi")
      assert_equal "tart-key", Settings.resolve_setting("apiKey", {}, identity: "tart")
      assert_equal "foo-model", Settings.resolve_setting("defaultModel", {}, identity: "foo")
      assert_equal 99, Settings.resolve_context_window(identity: "foo", env: {"FOO_CONTEXT_WINDOW" => "99"})
    end

    # --- the identity seam (I16, free-form since I32): CLI > TART_IDENTITY
    # env > settings identity > default "pi" — the resolution precedence
    # table; any non-empty value names a face ---

    def test_identity_resolves_cli_over_env_over_settings_over_default
      assert_equal "pi", Identity.resolve(settings: {}, env: {}), "no config → the default"
      assert_equal "tart", Identity.resolve(settings: {"identity" => "tart"}, env: {}), "settings row"
      assert_equal "tart", Identity.resolve(settings: {"identity" => "pi"}, env: {"TART_IDENTITY" => "tart"}),
        "env over settings"
      assert_equal "pi", Identity.resolve(cli: "pi", settings: {"identity" => "tart"}, env: {"TART_IDENTITY" => "tart"}),
        "CLI over everything"
    end

    # Owner ruling 1 (2026-10-12): white-labelable out of the box — any
    # non-empty value resolves and names its env namespace.
    def test_identity_is_free_form
      assert_equal "foo", Identity.resolve(settings: {"identity" => "foo"}, env: {})
      assert_equal "my-agent", Identity.resolve(cli: "my-agent", settings: {}, env: {})
      assert_equal "FOO_", Identity.env_prefix("foo")
      assert_equal "TART_", Identity.env_prefix("tart")
      assert_equal "FOO_API_KEY", Identity.env_key("foo", "API_KEY")
      assert_equal "PI_CONTEXT_WINDOW", Identity.env_key("pi", "CONTEXT_WINDOW")
    end

    def test_settings_layer_defaults_the_identity_key
      assert_equal Identity::DEFAULT, load_settings.settings["identity"],
        "the identity key rides Settings::DEFAULTS (no unknown-key warning, the pi default)"
      write_settings(@user_path, '{"identity": "tart"}')
      assert_equal "tart", load_settings.settings["identity"]
      assert load_settings.diagnostics.none? { |d| d.message.include?("identity") },
        "identity is a known key — no warning"
    end

    def test_empty_or_whitespace_identity_is_the_clean_abort_path
      ["", "   ", "\t\n"].each do |blank|
        assert_raises(Identity::Error) { Identity.resolve(cli: blank, settings: {}, env: {}) }
        assert_raises(Identity::Error) { Identity.resolve(settings: {"identity" => blank}, env: {}) }
        assert_raises(Identity::Error) { Identity.resolve(env: {"TART_IDENTITY" => blank}, settings: {}) }
      end
    end

    # --- footer model metadata (I16): staged env/settings over the model ---

    # The provider label is RETIRED: pi prefixes the model only when its
    # available-model snapshot spans >1 provider (footer.ts:246-258) —
    # the port's static snapshot is one, the prefix never fires.
    def test_reasoning_resolves_staged_over_model
      model = RubyLLM::Model.default("mock-1", "openai") # an assumed model: no reasoning
      refute Settings.model_reasoning_capable({}, model)

      assert Settings.model_reasoning_capable({"modelReasoning" => true}, model)
      refute Settings.model_reasoning_capable({"modelReasoning" => false}, model)
      assert Settings.model_reasoning_capable({"modelReasoning" => "true"}, model), "the env layer stages strings"
    end

    # An assumed model falls back to the known-models table (the owner's
    # daily-driver glm — pi's footer shows its level, so the port's must).
    def test_assumed_model_reasoning_reads_the_known_table
      model = RubyLLM::Model.default("accounts/fireworks/models/glm-5p3-flash", "openai")
      assert Settings.model_reasoning_capable({}, model), "the daily-driver model is reasoning-capable"

      unknown = RubyLLM::Model.default("totally-unknown", "openai")
      refute Settings.model_reasoning_capable({}, unknown)
    end

    def test_reasoning_reads_the_registry_model
      # A registry entry (real model) — when the entry lists reasoning —
      # carries the reasoning capability (pi reads state.model?.reasoning,
      # footer.ts:233-244).
      model = RubyLLM.models.find("gpt-5.6")
      assert_equal model.supports?(:reasoning), Settings.model_reasoning_capable({}, model)
      refute Settings.model_reasoning_capable({}, nil)
    end

    # --- context window: kwarg → env → settings → model → registry table ---

    def test_context_window_resolution_order
      model = RubyLLM::Model.new(id: "m-1", context_window: 5000)
      # The registry-default table is the last resort for a model the
      # pinned ruby_llm registry misses (context_window nil, live-verified).
      windowless = RubyLLM::Model.new(id: "accounts/fireworks/models/glm-5p3-flash", context_window: nil)

      assert_equal 9, Settings.resolve_context_window(explicit: 9, model:)
      ENV["PI_CONTEXT_WINDOW"] = "99"
      assert_equal 99, Settings.resolve_context_window(model:)
      ENV.delete("PI_CONTEXT_WINDOW")
      assert_equal 5000, Settings.resolve_context_window(model:)
      assert_equal 1_048_573, Settings.resolve_context_window(model: windowless)
      assert_nil Settings.resolve_context_window(model: RubyLLM::Model.new(id: "unknown-model"))

      write_settings(@project_path, '{"contextWindow": 12345}')
      assert_equal 12_345, Settings.resolve_context_window(settings: load_settings.settings, model: windowless)
    end

    def test_default_chat_resolves_the_registry_default_out_of_the_box
      context = RubyLLM.context do |config|
        config.openai_api_key = "k"
        config.openai_api_base = "http://localhost:1/v1"
      end
      chat = context.chat(model: "accounts/fireworks/models/glm-5p3-flash", provider: "openai",
                          protocol: :chat_completions, assume_model_exists: true)

      assert_equal 1_048_573,
        Settings.resolve_context_window(settings: load_settings.settings, model: chat.model)
    end

    # --- thinking level (pi's vocabulary + default; the footer's right side) ---

    def test_thinking_level_resolves_settings_over_pi_s_default
      # Out of the box: pi's DEFAULT_THINKING_LEVEL (defaults.ts:3), and the
      # key is known (no unknown-key warning).
      result = load_settings
      assert_equal "medium", Settings.resolve_thinking_level(result.settings)
      assert_empty result.diagnostics

      # Any vocabulary value passes through (user over project).
      write_settings(@user_path, '{"thinkingLevel": "low"}')
      write_settings(@project_path, '{"thinkingLevel": "high"}')
      assert_equal "high", Settings.resolve_thinking_level(load_settings.settings)

      # Off-vocabulary or null values fall back to the default.
      write_settings(@project_path, '{"thinkingLevel": "loud"}')
      assert_equal "medium", Settings.resolve_thinking_level(load_settings.settings)
      write_settings(@project_path, '{"thinkingLevel": null}')
      assert_equal "medium", Settings.resolve_thinking_level(load_settings.settings)
    end

    # The FILE-declared default (I40, pi settings-manager.ts:758-760 —
    # getDefaultThinkingLevel is undefined unless a settings FILE declares
    # the key; the baked built-in never counts). The switch path's default
    # tier (chat.rb apply_model_selection — pi
    # _getThinkingLevelForModelSwitch agent-session.ts:2670-2679).
    def test_declared_thinking_level_reads_the_user_file
      write_settings(@user_path, '{"thinkingLevel": "xhigh"}')

      assert_equal "xhigh", Settings.declared_thinking_level(root: @root, cwd: @cwd)
    end

    def test_declared_thinking_level_project_overrides_user
      write_settings(@user_path, '{"thinkingLevel": "xhigh"}')
      write_settings(@project_path, '{"thinkingLevel": "low"}')

      assert_equal "low", Settings.declared_thinking_level(root: @root, cwd: @cwd),
        "project over user (the {load} precedence)"
    end

    def test_declared_thinking_level_user_value_survives_a_keyless_project_file
      write_settings(@user_path, '{"thinkingLevel": "xhigh"}')
      write_settings(@project_path, '{"defaultModel": "m-project"}')

      assert_equal "xhigh", Settings.declared_thinking_level(root: @root, cwd: @cwd),
        "per-key deep merge: an unrelated project key never clobbers the user's declaration"
    end

    def test_declared_thinking_level_is_nil_when_no_file_declares_the_key
      assert_nil Settings.declared_thinking_level(root: @root, cwd: @cwd),
        "no files at all — the baked DEFAULTS[thinkingLevel] never counts"

      write_settings(@user_path, '{"defaultModel": "m"}')
      assert_nil Settings.declared_thinking_level(root: @root, cwd: @cwd),
        "files without the key — still undeclared (pi's defaultThinkingLevel is undefined)"
    end

    def test_declared_thinking_level_off_vocabulary_value_reads_as_nil
      write_settings(@user_path, '{"thinkingLevel": "loud"}')

      assert_nil Settings.declared_thinking_level(root: @root, cwd: @cwd),
        "pi's settings schema cannot declare an off-vocabulary level"
    end

    def test_declared_thinking_level_re_reads_across_a_save
      assert_nil Settings.declared_thinking_level(root: @root, cwd: @cwd)

      Settings.save(@root, "thinkingLevel" => "high")

      assert_equal "high", Settings.declared_thinking_level(root: @root, cwd: @cwd),
        "re-read from disk per call — a mid-session persist is live"
    end

    # --- the known-models thinkingLevelMap tier + the fact composition (I36) ---

    def test_known_thinking_level_map_reads_the_daily_driver
      map = Settings.known_thinking_level_map("accounts/fireworks/models/glm-5p3-flash")
      assert_equal "low", map.fetch(:off), "the owner's override floors off to low"
      assert_equal "medium", map.fetch(:medium)
      assert_equal "max", map.fetch(:max)
      assert_nil Settings.known_thinking_level_map("mock-1"), "unknown ids have no known map"
      assert_nil Settings.known_thinking_level_map(nil)
    end

    def test_thinking_facts_catalog_entry_wins
      entry = {id: "m", reasoning: false, thinking_level_map: {low: "low"}}
      facts = Settings.thinking_facts(entry, {"modelReasoning" => true}, model_id: "m")
      assert_equal false, facts[:reasoning], "the entry's flag decides over the staged env"
      assert_equal ({low: "low"}), facts[:thinking_level_map]
    end

    def test_thinking_facts_known_tables_when_the_entry_declares_none
      entry = {id: "accounts/fireworks/models/glm-5p3-flash", reasoning: true, thinking_level_map: nil}
      facts = Settings.thinking_facts(entry, nil, model_id: entry[:id])
      assert_equal true, facts[:reasoning]
      assert_equal Settings.known_thinking_level_map(entry[:id]), facts[:thinking_level_map],
        "a map-less entry falls back to the known table (catalog-entry-first, known-tables-second)"
    end

    def test_thinking_facts_without_a_catalog_entry
      model = RubyLLM::Model.default("mock-1", "openai")
      facts = Settings.thinking_facts(nil, {}, model_id: "mock-1", model: model)
      assert_equal false, facts[:reasoning], "model_reasoning_capable decides (an assumed mock: not reasoning)"
      assert_nil facts[:thinking_level_map], "no known map for the unknown id"

      glm = Settings.thinking_facts(nil, {}, model_id: "accounts/fireworks/models/glm-5p3-flash",
        model: RubyLLM::Model.default("accounts/fireworks/models/glm-5p3-flash", "openai"))
      assert glm[:reasoning], "the known-models table declares the daily driver reasoning-capable"
      assert_equal Settings.known_thinking_level_map("accounts/fireworks/models/glm-5p3-flash"), glm[:thinking_level_map]
    end

    # --- defaultTools ---

    def test_default_tools_plain_names_replace_the_base
      assert_equal Settings::DEFAULT_TOOLS, Settings.selected_tools({})

      assert_equal %w[grep], Settings.selected_tools({"defaultTools" => ["grep"]})
      assert_empty Settings.selected_tools({"defaultTools" => []})
    end

    def test_default_tools_modifiers_apply_in_order_onto_the_base
      assert_equal %w[read write edit bash find grep ls mcp],
        Settings.selected_tools({"defaultTools" => ["+mcp"]})
      assert_equal %w[read write edit find grep ls],
        Settings.selected_tools({"defaultTools" => ["-bash"]})
      # A mixed list: plain names form the selection, modifiers then apply.
      assert_equal %w[grep read], Settings.selected_tools({"defaultTools" => ["grep", "+read", "-bash"]})
    end

    def test_project_modifiers_compose_onto_the_user_selection
      write_settings(@user_path, '{"defaultTools": ["read", "bash"]}')
      write_settings(@project_path, '{"defaultTools": ["+grep", "-read"]}')

      assert_equal %w[bash grep], Settings.selected_tools(load_settings.settings)
    end

    def test_project_plain_list_replaces_the_user_list
      write_settings(@user_path, '{"defaultTools": ["read", "bash"]}')
      write_settings(@project_path, '{"defaultTools": ["ls"]}')

      assert_equal %w[ls], Settings.selected_tools(load_settings.settings)
    end

    # --- compaction kwargs mapping ---

    def test_compaction_kwargs_map_camel_case_json_to_loop_kwargs
      assert_empty Settings.compaction_kwargs({})
      write_settings(@project_path, '{"compaction": {"enabled": false, "keepRecentTokens": 5}}')
      kwargs = Settings.compaction_kwargs(load_settings.settings)

      # Settings resolve complete post-merge, so every kwarg is present.
      assert_equal({enabled: false, reserve_tokens: 16_384, keep_recent_tokens: 5}, kwargs)
      settings = Compaction::Settings.resolve(kwargs)
      refute settings.enabled
      assert_equal 16_384, settings.reserve_tokens
      assert_equal 5, settings.keep_recent_tokens
    end

    # --- the I08 carry-in, closed: the default chat compacts out of the box ---

    # The MockLLMServer cannot script usage (its responses hardcode
    # prompt_tokens 10 — read-only this lane), so the test crosses the
    # resolved window's threshold by shrinking the reserve through the
    # loop's compaction kwarg — no env override, no settings files; the
    # window itself is the registry-default 1_048_573. The next turn's
    # wire payload proves the history was replaced by [summary, kept tail].
    def test_default_chat_compacts_with_zero_configuration
      @server = MockLLMServer.new.start
      @server.script([
        {type: :message, content: "the answer"},
        {type: :message, content: "a summary of the prior turns"},
        {type: :message, content: "the second answer"},
        {type: :message, content: "a second summary"},
      ])
      dir = Dir.mktmpdir("tart-settings-session-")
      recorder = Agent::Session::Recorder.new(cwd: dir, root: @root)
      chat = RubyLLM.context do |config|
        config.openai_api_key = "k"
        config.openai_api_base = @server.url
      end.chat(model: "accounts/fireworks/models/glm-5p3-flash", provider: "openai",
               protocol: :chat_completions, assume_model_exists: true)

      window = Settings.resolve_context_window(settings: load_settings.settings, model: chat.model)
      assert_equal 1_048_573, window

      events = []
      agent = Agent::Loop.new(chat:, tools: {}, on_event: ->(e) { events << e }, recorder:,
                              context_window: window,
                              compaction: {reserve_tokens: 1_048_570, keep_recent_tokens: 1})
      kernel_run = ->(prompt) { Core::Loop.new(session: ScriptedSession.new).run { agent.run(prompt) } }
      kernel_run.call("hello")
      kernel_run.call("again")

      assert events.any? { |e| e[:type] == :compaction }, "the threshold trigger fired out of the box"

      # The post-compaction request carries [summary, kept tail], not the
      # pre-compaction history.
      wire = @server.captured_requests[2]["messages"]
      assert_equal :user, wire.first["role"].to_sym
      assert_includes wire.first["content"], "a summary of the prior turns"
      refute wire.any? { |message| message["content"].to_s.include?("hello") },
        "the compacted turns are gone from the context"

      entries = Agent::Session.load_entries(recorder.path)
      compaction = entries.find { |entry| entry["type"] == "compaction" }
      refute_nil compaction, "the compaction is recorded as a session entry"
      assert compaction["tokensBefore"].is_a?(Integer)
    ensure
      FileUtils.rm_rf(dir)
    end
  end
end
