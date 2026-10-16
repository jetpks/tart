# frozen_string_literal: true

require "json"
require "fileutils"
require_relative "agent/session"
require_relative "shapes/types"
require_relative "shapes/model"

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
    # The model context-window known-tables tier (I08 carry-in): the
    # carried models have no pi-catalog row of their own, so the port's
    # resolution order ends in this table — pi's catalog value for the
    # model (models.dev registry, pi generate-models.ts source).
    ROOT_KEY = "settings.json"
    CONFIG_DIR = ".tart"

    # pi's runtime default thinking level (defaults.ts:3,
    # model-resolver.ts:646) — the single source of the DEFAULTS row below;
    # the render-side fallbacks read this constant. Typed at load: the
    # literal must speak Strict::String, or the boot fails right here.
    DEFAULT_THINKING_LEVEL = Shapes::Types::Strict::String["medium"].freeze

    DEFAULTS = {
      "identity" => Identity::DEFAULT,
      "defaultModel" => "accounts/fireworks/models/glm-5p3-flash",
      "defaultProvider" => "openai",
      "apiBase" => "https://api.fireworks.ai/inference/v1",
      "apiKey" => nil,
      "contextWindow" => nil,
      "thinkingLevel" => DEFAULT_THINKING_LEVEL,
      "compaction" => {"enabled" => true, "reserveTokens" => 16_384, "keepRecentTokens" => 20_000},
      # Footer model-metadata staging (rarely set; nil = resolve from the
      # model, see {model_reasoning_capable}).
      "modelReasoning" => nil,
      # The native memory module's gate (I47 — OQ-1): opt-in, default off —
      # ZERO observable change for every existing config (no tool, no
      # injection, no MOTD row). The env tier reads <IDENTITY>_MEMORY.
      "memory" => false,
      # The native subagents module's gate (I48 — OQ-1): the memory row's
      # opt-in pattern again — off = no subagent tool, no watcher, no run
      # dirs, every existing byte unchanged (the frozen wire digests are
      # the zero-behavior bar). The env tier reads <IDENTITY>_SUBAGENTS.
      "subagents" => false
    }.freeze

    # pi's ThinkingLevel vocabulary (model-schema.ts:2-3, agent types.ts:349).
    # The setting diverges from pi's schema key (defaultThinkingLevel,
    # settings-schema.ts:212) — recorded divergence.
    THINKING_LEVELS = %w[off minimal low medium high xhigh max].freeze

    # The boot tool loadout: pi's DEFAULT_TOOL_NAMES — its four core tools
    # in its order (settings-manager.ts:82; I41 parity — the pre-I41
    # 7-tool superset was the I10-recorded divergence). The search tools
    # come back through defaultTools: "+find" appends to the default,
    # plain lists replace it.
    DEFAULT_TOOLS = %w[read bash edit write].freeze

    # env → settings → built-in default, per key (AC2/AC4). The env KEY
    # rides the resolved identity's namespace ({Identity.env_key}):
    # pi mode reads PI_MODEL, tart TART_MODEL, foo FOO_MODEL — the SUFFIX
    # column here, prefixed at read time.
    RESOLUTION_ENV = {
      "defaultModel" => "MODEL",
      "defaultProvider" => "PROVIDER",
      "apiBase" => "API_BASE",
      "apiKey" => "API_KEY",
      "modelReasoning" => "MODEL_REASONING",
      "memory" => "MEMORY",
      # I48: the subagents gate's env tier, plus the thinkingLevel tier —
      # an ADDITIVE boot knob (the child spawn reads the routed level
      # through it; unset = today's resolution, no boot path calls it).
      "subagents" => "SUBAGENTS",
      "thinkingLevel" => "THINKING_LEVEL"
    }.freeze

    # The known-models tables (I08/I36), typed at load via the Shapes map
    # types: each literal is type-checked HERE — a malformed value fails
    # with a MapError at require time, never mid-boot. CONTENTS are
    # byte-identical to the pre-shapes literals (unit-pinned key-for-key)
    # and the applied Hashes are frozen exactly as before, inner maps too.

    MODEL_CONTEXT_WINDOWS = Shapes::Types::Strict::Hash.map(
      Shapes::Types::Strict::String, Shapes::Types::Strict::Integer
    )["accounts/fireworks/models/glm-5p3-flash" => 1_048_573].freeze

    # The known reasoning-capable models (same assumed-model class as
    # {MODEL_CONTEXT_WINDOWS}: ids the wire catalog has no entry for,
    # but the owner's daily-driver catalog declares reasoning — pi's
    # footer shows the level for them, so the port must too).
    MODEL_REASONING = Shapes::Types::Strict::Hash.map(
      Shapes::Types::Strict::String, Shapes::Types::Strict::Bool
    )["accounts/fireworks/models/glm-5p3-flash" => true].freeze

    # The known thinkingLevelMaps (the same known-models tier, I36): the
    # owner's daily-driver glm — the owner's effective pi map (the pi
    # override maps every level onto a String; off floors to "low"), so
    # the port's wire matches the live pi sessions. Symbol keys — the
    # parsed :thinking_level_map shape. Unknown model ids resolve to nil
    # (pi's map-less rule, {Models.supported_thinking_levels}).
    THINKING_LEVEL_MAPS = Shapes::Types::Strict::Hash.map(
      Shapes::Types::Strict::String,
      Shapes::Types::Strict::Hash.map(Shapes::Types::Strict::Symbol,
        Shapes::Types::Strict::String | Shapes::Types::Strict::Nil)
    )[
      "accounts/fireworks/models/glm-5p3-flash" => {
        off: "low", minimal: "low", low: "low", medium: "medium",
        high: "high", xhigh: "xhigh", max: "max"
      }
    ].each_value(&:freeze).freeze

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
    # model/provider/apiBase/apiKey resolution, AC2). The env tier speaks
    # the identity's namespace (AC4): resolve_setting("apiKey", settings,
    # identity: "foo") reads FOO_API_KEY. The tier VALUES are documented by
    # the {Schemas::Settings} string-key contracts; the three-source `||`
    # precedence arithmetic itself stays here (a schema cannot express it
    # honestly — pi's semantics).
    def resolve_setting(key, settings, identity: Identity::DEFAULT, env: ENV)
      env[Identity.env_key(identity, RESOLUTION_ENV.fetch(key))] || settings[key] || DEFAULTS[key]
    end

    # Explicit kwarg → <IDENTITY>_CONTEXT_WINDOW → settings.contextWindow →
    # model context window → registry-default table → nil (AC2/AC4; pi has
    # no contextWindow setting — the registry is its only source — recorded
    # port extension). The env tier rides the identity's namespace, like
    # every app env read. The tiers' accept/reject arithmetic rides the
    # {Schemas::Settings} contracts: the env tier's digit-string coercion
    # and the file/model tiers' positive-integer guards — a value failing
    # its contract tier reads as absent and the ladder falls through
    # (today's regex/guard outcomes, never new rejections).
    def resolve_context_window(explicit: nil, settings: {}, model: nil, identity: Identity::DEFAULT, env: ENV)
      return explicit if explicit

      env_window = Schemas::Settings.context_window_env(env[Identity.env_key(identity, "CONTEXT_WINDOW")])
      return env_window if env_window

      window = Schemas::Settings.context_window_value(settings["contextWindow"])
      return window if window

      window = Schemas::Settings.context_window_value(model&.context_window)
      return window if window

      MODEL_CONTEXT_WINDOWS[model&.id]
    end

    # The thinking level for the footer's "model • <level>" (pi footer.ts:
    # 236-239): a settings value in pi's vocabulary passes through; anything
    # else (missing, null, mistyped) falls back to pi's runtime default
    # DEFAULT_THINKING_LEVEL "medium" (defaults.ts:3, model-resolver.ts:646).
    # No env override — pi has none for it either. UNCLAMPED by design: the
    # boot composition clamps a copy for the session level (bin/tart, pi
    # createSdk sdk.ts:271-279) while this stays the · default badge's raw
    # source (pi badges getDefaultThinkingLevel() ?? DEFAULT unclamped —
    # thinking-selector.ts:71-72). The vocabulary check rides the view's
    # thinkingLevel contract ({Schemas::Settings.thinking_level}).
    def resolve_thinking_level(settings)
      Schemas::Settings.thinking_level(settings["thinkingLevel"]) || DEFAULTS.fetch("thinkingLevel")
    end

    # The FILE-declared thinking-level default (I40, pi settings-manager.ts
    # getDefaultThinkingLevel :758-760 — `settings.defaultThinkingLevel`,
    # undefined unless a settings FILE declares it): the {load} precedence
    # (project deep-merges over user) minus the DEFAULTS tier — the baked
    # built-in never counts, only a file's key. Re-read from disk per call,
    # so a mid-session {save} write is live (pi's settingsManager view).
    # A declared value outside {THINKING_LEVELS} reads as nil (pi's settings
    # schema cannot declare it). No env tier — pi has none for it either.
    # The switch path's default tier ({Render::Chat#apply_model_selection} —
    # pi _getThinkingLevelForModelSwitch, agent-session.ts:2670-2679); the
    # per-model override tier is a cut (itemized, no scoped-models surface).
    # The vocabulary check rides the view's thinkingLevel contract, like
    # {resolve_thinking_level}.
    def declared_thinking_level(root:, cwd:)
      user, = read_file(File.join(root, ROOT_KEY))
      project, = read_file(File.join(cwd, CONFIG_DIR, ROOT_KEY))
      Schemas::Settings.thinking_level(deep_merge(user, project)["thinkingLevel"])
    end

    # The footer's model-metadata fact (pi footer.ts:233-244 reads
    # state.model?.reasoning off the model entry): the wire model's own
    # reasoning flag is the fallback (the gem Model carries it natively).
    # The provider LABEL is never rendered: pi prefixes the model only
    # when its available-model snapshot spans >1 provider (footer.ts:246
    # -258) — the port's static snapshot is one provider, so the prefix
    # never fires. Stageable for rigs/mocks: the modelReasoning setting
    # (<IDENTITY>_MODEL_REASONING env) overrides everything; the staged
    # truthiness rides the modelReasoning contract
    # ({Schemas::Settings.model_reasoning} — nil = unstaged, the staged
    # vocabulary passes, anything else answers false: today's
    # `staged == true || staged == "true"` table); a model with no entry
    # and no flag falls to false — the owner's daily-driver glm declares
    # reasoning in the known-models table, and the footer/border parity
    # dies without it.
    def model_reasoning_capable(settings, model, identity: Identity::DEFAULT)
      staged = resolve_setting("modelReasoning", settings, identity:)
      outcome = Schemas::Settings.model_reasoning(staged)
      return outcome unless outcome.nil?

      MODEL_REASONING.fetch(model&.id) { model&.reasoning == true }
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

    # The known thinkingLevelMap for one model id (the boot/switch map
    # tier beside {MODEL_CONTEXT_WINDOWS}/{MODEL_REASONING}). nil = no
    # known map (pi's map-less rule).
    def known_thinking_level_map(model_id)
      THINKING_LEVEL_MAPS[model_id]
    end

    # The thinking facts for one model (I36), composed catalog-entry-first,
    # known-tables-second — ONE helper for the interactive boot, print
    # mode, and the switch path. Returns the typed Shapes::ThinkingFacts:
    # reasoning = the entry's flag when a catalog entry exists, else
    # {model_reasoning_capable}; the level map = the entry's map when
    # present, else the known table (keyed by +model_id+). +entry+ is the
    # catalog's typed model (Shapes::Model — nil when there is no catalog
    # match) and +settings+ nil (the switch path — the entry always
    # decides) is legal.
    def thinking_facts(entry, settings = nil, model_id: nil, model: nil, identity: Identity::DEFAULT)
      Shapes::ThinkingFacts.new(
        reasoning: entry ? entry.reasoning : model_reasoning_capable(settings, model, identity:),
        thinking_level_map: entry&.thinking_level_map || known_thinking_level_map(model_id)
      )
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

    # The write surface (I27, pi settings-manager.ts setDefaultModel /
    # setDefaultModelAndProvider → persistScopedSettings): merge the
    # updates over the CURRENT file contents — unknown and unmodified
    # keys survive verbatim (pi rewrites the whole scoped file, never a
    # schema projection) — then pretty-print. An unparseable existing
    # file counts as empty (the {read_file} idiom). +root+ is the user
    # config dir (~/.tart); the path is returned.
    def save(root, updates)
      path = File.join(root, ROOT_KEY)
      existing = File.file?(path) ? read_file(path).first : {}
      merged = deep_merge(existing, updates)
      FileUtils.mkdir_p(root)
      File.write(path, "#{JSON.pretty_generate(merged)}\n")
      path
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
