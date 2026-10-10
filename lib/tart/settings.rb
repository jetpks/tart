# frozen_string_literal: true

require "json"
require_relative "agent/session"

module Tart
  module Settings
    # Settings load/merge/resolve (port of pi's settings-manager.ts,
    # reduced to the port's carried key set).
    #
    # Files (pi SettingsManager.create :317-325): user settings from
    # <root>/settings.json (pi: agentDir/settings.json), project settings
    # from <cwd>/.tart/settings.json (pi: cwd/.pi/settings.json); project
    # deep-merges over user (deepMergeSettings :141-146). Missing keys fall
    # back to the built-in defaults (SETTINGS_DEFAULTS). A JSON parse
    # failure is a diagnostic, not a crash — the file counts as absent
    # (tryLoadFromStorage :367-379). pi tolerates unknown keys silently
    # (settings-schema.ts:446 additionalProperties: true); the port warns
    # (recorded divergence — the port's key set is explicit and small).
    # pi gates project settings on project trust; the port has no trust
    # feature and always loads them (recorded cut).
    #
    # defaultTools semantics (settings-manager.ts:80-130 + docs/settings.md
    # "Tools"): plain names replace the base selection; `+name`/`-name`
    # apply in order. Across layers: a project list with any plain name
    # replaces the user's list; a list of only modifiers appends
    # (mergeDefaultTools :119-125).
    #
    # The model context-window registry-default table (I08 carry-in): the
    # pinned ruby_llm registry misses the default fireworks model
    # (RubyLLM.models.find raises ModelNotFoundError, live-verified), so
    # the port's resolution order ends in this table — pi's catalog value
    # for the model (models.dev registry, pi generate-models.ts source).
    ROOT_KEY = "settings.json"
    CONFIG_DIR = ".tart"

    DEFAULTS = {
      "defaultModel" => "accounts/fireworks/models/glm-5p3-flash",
      "defaultProvider" => "openai",
      "apiBase" => "https://api.fireworks.ai/inference/v1",
      "apiKey" => nil,
      "contextWindow" => nil,
      "compaction" => {"enabled" => true, "reserveTokens" => 16_384, "keepRecentTokens" => 20_000}
    }.freeze

    # The port's built-in tool base (bin/tart's loadout; pi's
    # DEFAULT_TOOL_NAMES is its four core tools — recorded divergence).
    DEFAULT_TOOLS = %w[read write edit bash find grep ls].freeze

    # env → settings → built-in default, per key (AC2).
    RESOLUTION_ENV = {
      "defaultModel" => "TART_MODEL",
      "defaultProvider" => "TART_PROVIDER",
      "apiBase" => "TART_API_BASE",
      "apiKey" => "TART_API_KEY"
    }.freeze

    MODEL_CONTEXT_WINDOWS = {
      "accounts/fireworks/models/glm-5p3-flash" => 1_048_573
    }.freeze

    Diagnostic = Struct.new(:type, :message, :path, keyword_init: true)

    Result = Struct.new(:settings, :diagnostics, keyword_init: true)

    module_function

    def load(cwd:, root: Agent::Session.default_root, env: ENV)
      user_path = File.join(root, ROOT_KEY)
      project_path = File.join(cwd, CONFIG_DIR, ROOT_KEY)
      user, user_diags = read_file(user_path)
      project, project_diags = read_file(project_path)

      diagnostics = user_diags + project_diags
      known = DEFAULTS.keys + %w[defaultTools]
      diagnostics.concat(unknown_key_diagnostics(user, user_path, known))
      diagnostics.concat(unknown_key_diagnostics(project, project_path, known))

      tools = merge_default_tools(user["defaultTools"], project["defaultTools"])
      settings = deep_merge(DEFAULTS, deep_merge(user, project))
      settings["defaultTools"] = tools
      Result.new(settings:, diagnostics:)
    end

    # env → settings → built-in default for one carried key (bin/tart's
    # model/provider/apiBase/apiKey resolution, AC2).
    def resolve_setting(key, settings, env: ENV)
      env[RESOLUTION_ENV.fetch(key)] || settings[key] || DEFAULTS[key]
    end

    # Explicit kwarg → TART_CONTEXT_WINDOW → settings.contextWindow →
    # model context window → registry-default table → nil (AC2; pi has no
    # contextWindow setting — the registry is its only source — recorded
    # port extension).
    def resolve_context_window(explicit: nil, settings: {}, model: nil, env: ENV)
      return explicit if explicit

      env_value = env["TART_CONTEXT_WINDOW"]
      return Integer(env_value, 10) if env_value&.match?(/\A\d+\z/)

      window = settings["contextWindow"]
      return window if window.is_a?(Integer) && window.positive?

      window = model&.context_window
      return window if window.is_a?(Integer) && window.positive?

      MODEL_CONTEXT_WINDOWS[model&.id]
    end

    # The compaction settings as Agent::Loop kwargs (camelCase JSON keys →
    # the loop's symbol kwargs; only present keys pass, so the loop's
    # built-in defaults hold for the rest).
    def compaction_kwargs(settings)
      compaction = settings["compaction"] || {}
      {
        enabled: compaction["enabled"],
        reserve_tokens: compaction["reserveTokens"],
        keep_recent_tokens: compaction["keepRecentTokens"]
      }.select { |_key, value| !value.nil? }
    end

    # The resolved tool selection for Tools::Registry.build(selected:):
    # no setting → the built-in base; otherwise pi's resolveDefaultTools
    # (:126-133) on the port's base.
    def selected_tools(settings)
      entries = settings["defaultTools"]
      return DEFAULT_TOOLS.dup if entries.nil?

      plain = entries.select { |entry| !tool_modifier?(entry) }
      base = plain.empty? && !entries.empty? ? DEFAULT_TOOLS : plain
      apply_tool_modifiers(base, entries)
    end

    def tool_modifier?(entry)
      entry.is_a?(String) && (entry.start_with?("+") || entry.start_with?("-"))
    end

    # pi applyToolModifiers (:110-118): +name adds, -name removes, in
    # order; other entries ignored.
    def apply_tool_modifiers(base, entries)
      tools = base.dup
      entries.each do |entry|
        next unless tool_modifier?(entry)

        name = entry[1..]
        index = tools.index(name)
        if entry.start_with?("+") && index.nil? && !name.empty?
          tools << name
        elsif entry.start_with?("-") && index
          tools.delete_at(index)
        end
      end
      tools
    end

    # pi mergeDefaultTools (:119-125): overrides win wholesale unless it is
    # a list of only modifiers, which appends to the base list.
    def merge_default_tools(base, overrides)
      return base if overrides.nil?
      return overrides if !base.is_a?(Array) || !overrides.is_a?(Array) || !overrides.all? { |entry| tool_modifier?(entry) }

      [*base, *overrides]
    end

    # pi deepMergeObjects (:63-83): nested plain objects merge recursively,
    # everything else overrides.
    def deep_merge(base, overrides)
      base.merge(overrides) do |_key, base_value, override_value|
        if base_value.is_a?(Hash) && override_value.is_a?(Hash)
          deep_merge(base_value, override_value)
        else
          override_value
        end
      end
    end

    # pi tryLoadFromStorage (:367-379): a file that fails to parse counts
    # as absent (defaults hold), the error surfaces as a diagnostic.
    def read_file(path)
      return [{}, []] unless File.file?(path)

      parsed = JSON.parse(File.read(path).sub(/\A\xEF\xBB\xBF/, ""))
      return [parsed, []] if parsed.is_a?(Hash)

      [{}, [Diagnostic.new(type: "warning", message: "settings file is not a JSON object", path:)]]
    rescue JSON::ParserError => e
      [{}, [Diagnostic.new(type: "warning", message: "invalid settings JSON: #{e.message}", path:)]]
    end

    def unknown_key_diagnostics(settings, path, known)
      return [] unless settings.is_a?(Hash)

      settings.keys.reject { |key| known.include?(key) }.map do |key|
        Diagnostic.new(type: "warning", message: "unknown settings key: #{key}", path:)
      end
    end
  end
end
