# frozen_string_literal: true

require "json"
require_relative "agent/session"
require_relative "settings"
require_relative "schemas/models"
require_relative "shapes/model"
require_relative "models/vendored"

module Tart
  module Models
    # The models.json catalog (I27 — port of pi's core/model-config.ts,
    # reduced to the port's carried schema subset): providers with
    # {name, baseUrl, apiKey, api} and their models
    # {id, name, reasoning, contextWindow, maxTokens}. JSONC-tolerant
    # (parse_jsonc — // comments + trailing commas, string literals
    # untouched, utils/json.ts) and BOM-stripped (utils/text.ts).
    #
    # Error surface (pi ModelConfig.load :135-170): the loader NEVER
    # raises — a load/parse/schema failure sets Config#error (the message
    # names the file) with an empty catalog; the boot proceeds on the
    # Settings defaults and the error is reported, never a crash.
    ROOT_KEY = "models.json"

    # The catalog shape: the typed providers (Shapes::Provider — the
    # endpoint block plus its typed models) keyed by the models.json key,
    # and the flattened typed model entries ({model_entries}).
    Config = Struct.new(:providers, :default, :error, keyword_init: true) do
      # Every model entry across providers. The LOADED catalog (build via
      # {Models.build_providers}) carries typed Shapes::Provider values and
      # yields typed Shapes::Model entries; a HAND-BUILT config fed the
      # legacy raw-hash provider shape keeps today's raw merged-hash
      # entries (the frozen discovery-shape contract the /model dispatch
      # pins — no re-shaping of values the config was handed verbatim).
      def model_entries
        providers.flat_map do |key, provider|
          if provider.is_a?(Shapes::Provider)
            provider.models
          else
            provider[:models].map { |model| model.merge(provider: key) }
          end
        end
      end

      # The provider's typed config (build_chat's endpoint seam), or nil
      # for an unknown key.
      def provider(key)
        providers[key]
      end

      # The entry's catalog field — the typed attribute read, with the
      # raw-hash read preserved for legacy-fed entries (see
      # {model_entries}).
      def entry_field(entry, field)
        entry.respond_to?(field) ? entry.public_send(field) : entry.fetch(field)
      end

      # The entry's compat (I46) — the typed attribute read, with the
      # raw-hash read preserved for legacy-fed entries (see
      # {model_entries}); nil when the entry declares none. The same
      # bridge shape as {entry_field}.
      def entry_compat(entry)
        entry.respond_to?(:compat) ? entry.compat : entry[:compat]
      end

      # Exact model-reference match (pi findExactModelReferenceMatch,
      # model-resolver.ts:82-118, reduced): a unique canonical
      # "provider/id" wins; then an explicit provider/id pair; then a
      # unique bare id. Ambiguity is no match (pi literal).
      def resolve(reference)
        needle = reference.to_s.strip.downcase
        return nil if needle.empty?

        entries = model_entries
        canonical = entries.select { |entry| "#{entry_field(entry, :provider)}/#{entry_field(entry, :id)}".downcase == needle }
        return canonical.first if canonical.size == 1
        return nil if canonical.size > 1

        provider_key, id = needle.split("/", 2)
        if id && !id.empty?
          scoped = entries.select do |entry|
            entry_field(entry, :provider).downcase == provider_key && entry_field(entry, :id).downcase == id
          end
          return scoped.first if scoped.size == 1
        end

        bare = entries.select { |entry| entry_field(entry, :id).downcase == needle }
        bare.size == 1 ? bare.first : nil
      end
    end

    module_function

    def load(root: Agent::Session.default_root)
      path = File.join(root, ROOT_KEY)
      return Config.new(providers: {}, default: nil, error: nil) unless File.file?(path)

      parsed = parse_jsonc(File.read(path).delete_prefix("\uFEFF"))
      unless parsed
        return Config.new(providers: {}, default: nil,
          error: "Failed to parse models.json (#{path})")
      end

      errors = Schemas::Models.validate(parsed)
      unless errors.empty?
        return Config.new(providers: {}, default: nil,
          error: "Invalid models.json schema:\n#{errors.join("\n")}\n(#{path})")
      end

      Config.new(providers: build_providers(parsed), default: parsed["default"], error: nil)
    rescue StandardError => e
      Config.new(providers: {}, default: nil, error: "Failed to load models.json: #{e.message} (#{path})")
    end

    # pi's modelFromJson definition defaults (provider-composer.ts:242-243):
    # `contextWindow: definition.contextWindow ?? 128000`, `maxTokens:
    # definition.maxTokens ?? 16384` — applied at model-DEFINITION time,
    # i.e. ONLY where a models.json entry exists. They ride the
    # facts-threading seam below (never catalog load — Shapes::Model#to_h
    # stays DECLARED == the parsed entry — and never Settings
    # .resolve_context_window); a NO-entry boot has no definition and the
    # no-entry chain owns the window (Grounds §4-b: env → settings →
    # known-tables → 0, the cap nil → wire_model's window fallback).
    DEFAULT_ENTRY_CONTEXT_WINDOW = 128_000
    DEFAULT_ENTRY_MAX_TOKENS = 16_384

    # The entry's declared window, else the vendored tier's fill (I71 R2 —
    # the tier slots BETWEEN the declared value and the definition default:
    # an ENTRY that omits the field + a vendored match ⇒ the vendored
    # value), else pi's 128_000 definition default when an entry EXISTS;
    # nil without an entry (the no-entry chain's signal — no default may
    # leak into an entry-less boot). A user-declared value ALWAYS wins —
    # the fill-only law.
    def entry_context_window(entry)
      return nil unless entry
      entry.context_window || vendored_integer(entry, "contextWindow") || DEFAULT_ENTRY_CONTEXT_WINDOW
    end

    # The entry's declared cap, else the vendored tier's fill (same slot —
    # I71 R2), else pi's 16_384 definition default when an entry EXISTS
    # (never the window fallback — the big-declared-window fallback is the
    # Face-1 400); nil without an entry.
    def entry_max_tokens(entry)
      return nil unless entry
      entry.max_tokens || vendored_integer(entry, "maxTokens") || DEFAULT_ENTRY_MAX_TOKENS
    end

    # The vendored tier's integer fill for the entry (I71 R2): the matched
    # vendored model's fact, or nil (no match / non-integer fact — the
    # definition default then applies). Read-only: the loaded catalog is
    # never touched.
    def vendored_integer(entry, field)
      value = vendored_facts(entry)&.[](field)
      value.is_a?(Integer) ? value : nil
    end

    # The vendored tier's facts for the entry (I71 R2): the matched
    # vendored model's RAW pi facts hash (the tier's own schema — never
    # the models.json CatalogContract), nil when the entry matches
    # nothing. NEVER raises — the never-raise boot law (a missing/corrupt
    # vendor file is a degraded tier, never a boot error, never a warning).
    def vendored_facts(entry)
      Vendored.facts_for_entry(entry)
    end

    # The entry's compat through the vendored fill (I71 R2): the entry's
    # declared compat when it carries one, else the matched vendored
    # compat (built through the existing build_compat six-key pick — the
    # vendored superset keys are tolerated-and-dropped, the I46 law), else
    # nil. The fill the boot/switch threading feeds the wire model's
    # dialect derivation with.
    def resolved_compat(entry)
      return nil unless entry

      declared = entry.respond_to?(:compat) ? entry.compat : entry[:compat]
      declared || vendored_compat(entry)
    end

    # The vendored tier's compat fill for the entry (I71 R2): the matched
    # vendored model's compat through build_compat's six-key pick, nil
    # when the entry matches nothing. NEVER raises.
    def vendored_compat(entry)
      facts = vendored_facts(entry)
      build_compat(facts&.[]("compat")) if facts
    end

    # The dialect for a catalog ENTRY (I71 R2, the new public seam): the
    # entry's declared compat, vendored-filled — `dialect_for(entry.compat
    # || vendored compat)`. The boot/switch threading consults this seam
    # (the threaded compat is the RESOLVED one, so the wire model's
    # dialect derivation sees the fill); {dialect_for} itself and the
    # {wire_model} signature are UNCHANGED — existing direct-call pins
    # hold.
    def dialect_for_entry(entry)
      dialect_for(resolved_compat(entry))
    end

    # The wire model (Grounds D7): the catalog facts + the resolved
    # window into the gem's Model. +context_window+ MUST arrive as an
    # Integer — the caller runs the existing resolution chain (catalog →
    # env → known-tables → Settings::MODEL_CONTEXT_WINDOWS default tier);
    # the Chat's placeholder passes 0 (pi's `contextWindow ?? 0`, the
    # threshold-disabled shape). +max_tokens+ falls back to the window —
    # the gem's pi-clamp caps the key at context − estimate − 4096, so
    # the fallback approximates the old key-omission semantics. The
    # dialect rides by construction (D6): the compat translates to a
    # Fast::Completions::Dialect inside {dialect_for}.
    def wire_model(model_id:, provider_key:, reasoning:, context_window:,
                   max_tokens: nil, thinking_level_map: nil, compat: nil)
      Fast::Completions::Model.new(
        id: model_id.to_s,
        reasoning: reasoning == true,
        context_window: context_window,
        max_tokens: max_tokens || context_window,
        thinking_level_map: thinking_level_map,
        dialect: dialect_for(compat),
        provider: provider_key
      )
    end

    # The compat→Dialect translation (D6 — zai as data): the I46/I64 six-key
    # compat subset maps onto the closed Dialect vocabulary — a zai
    # thinkingFormat builds the zai-shaped declaration (the gem's shipped
    # :zai values: max_tokens rename, no developer role, effort enabled,
    # tool_stream, pi's zai store suppression, and I64's strict-sampling
    # gate — supports_strict_mode threads the compat's
    # supportsStrictMode; nil/false/absent stay false, pi detectCompat's
    # "OpenAI compatibility alone does not imply it"); ANY other compat
    # (nil, a non-zai thinkingFormat) rides the DEFAULT dialect — today's
    # "only-zai arms" behavior verbatim (a non-zai compat declaring
    # supportsStrictMode is tolerated-and-DROPPED: the frozen boundary).
    #
    # BOTH arms declare supports_finish_reason: false — pi's
    # finish-inference arm (the gem infers the stop reason from the
    # content when a stream ends without one, openai-completions.ts
    # :690-692). RECEIVE-side only — the key never reaches the wire — so
    # every wire byte holds; it exists because the hermetic mock's
    # :slow_stream shape predates the gem's finish-reason discipline (the
    # replaced client tolerated a finish-less stream; the gem errors), and
    # the completing-slow-stream pins (steering, subagents e2e) speak that
    # shape. The rig scenarios all carry finish_reason and never arm it.
    def dialect_for(compat)
      return DEFAULT_DIALECT unless compat&.thinking_format == "zai"

      Fast::Completions::Dialect.new(
        thinking_format: :zai,
        max_tokens_field: compat.max_tokens_field == "max_tokens" ? "max_tokens" : "max_completion_tokens",
        supports_developer_role: compat.supports_developer_role == true,
        supports_reasoning_effort: compat.supports_reasoning_effort == true,
        zai_tool_stream: compat.zai_tool_stream == true,
        supports_strict_mode: compat.supports_strict_mode == true,
        supports_store: false,
        supports_finish_reason: false
      )
    end

    # The plain arm (the nil/non-zai compat translation) — one frozen
    # instance; see {dialect_for} for the finish-inference declaration.
    DEFAULT_DIALECT = Fast::Completions::Dialect.new(supports_finish_reason: false).freeze

    # pi stripJsonComments (utils/json.ts:1-5) + the parse: // line
    # comments and trailing commas removed, string literals preserved —
    # two masking passes, string-or-match alternation each. nil on a
    # parse failure (the caller sets the error).
    def parse_jsonc(text)
      text = text.gsub(%r{"(?:\\.|[^"\\])*"|//[^\n]*}) { |m| m.start_with?('"') ? m : "" }
      text = text.gsub(/"(?:\\.|[^"\\])*"|,(\s*[}\]])/) { Regexp.last_match(1) || Regexp.last_match(0) }
      JSON.parse(text)
    rescue JSON::ParserError
      nil
    end

    # The boot model (I27): <IDENTITY>_MODEL/<IDENTITY>_PROVIDER env > the
    # models.json "default" reference > Settings defaultModel/
    # defaultProvider — the env keys ride the identity's namespace (AC4).
    # Deviation from pi's findInitialModel precedence
    # (model-resolver.ts:511-580 — CLI > scoped > settings saved-default
    # > first-available), itemized: pi has no models.json default key and
    # puts the settings default first; the port prefers a declared
    # catalog default over its compiled-in Settings default so a user's
    # models.json outranks the shipped fireworks default.
    def resolve_boot_model(config, settings, identity: Identity::DEFAULT, env: ENV)
      if (model = env[Identity.env_key(identity, "MODEL")])
        return Shapes::ModelRef.new(provider: env[Identity.env_key(identity, "PROVIDER")] || settings["defaultProvider"], id: model)
      end
      if (provider = env[Identity.env_key(identity, "PROVIDER")])
        return Shapes::ModelRef.new(provider:, id: settings["defaultModel"])
      end
      if config&.default && (entry = config.resolve(config.default))
        return Shapes::ModelRef.new(provider: entry.provider, id: entry.id)
      end

      Shapes::ModelRef.new(provider: settings["defaultProvider"], id: settings["defaultModel"])
    end

    def build_providers(parsed)
      parsed.fetch("providers").to_h do |key, provider|
        built = Shapes::Provider.new(
          name: provider["name"],
          base_url: provider["baseUrl"],
          api_key: provider["apiKey"],
          api: provider["api"],
          models: (provider["models"] || []).map { |model| build_model(model, provider: key) }
        )
        # The vendored tier's per-entry baseUrl record (I71 R2 — the match
        # rule needs the provider BLOCK's baseUrl, which the bare typed
        # entry doesn't carry): auxiliary lookup state beside the typed
        # catalog — the catalog bytes are untouched.
        Vendored.register_entries(built.base_url, built.models)
        [key, built]
      end
    end

    # The typed catalog entry (Shapes::Model) — the provider KEY feeds the
    # +provider:+ attribute at build (the merged-hash shape's last key).
    # The to_h of the built struct is DECLARED equal to today's entry hash
    # (key order included — the shapes unit pin); the load path only ever
    # constructs from schema-VALID parsed files, so the strict types never
    # see the rejected input classes and {load} still never raises.
    def build_model(model, provider:)
      Shapes::Model.new(
        id: model.fetch("id"),
        name: model["name"] || model["id"],
        reasoning: model["reasoning"] == true,
        context_window: model["contextWindow"],
        max_tokens: model["maxTokens"],
        thinking_level_map: build_thinking_level_map(model["thinkingLevelMap"]),
        compat: build_compat(model["compat"]),
        provider:
      )
    end

    # The pi compat subset (I46, I64): the six carried keys picked off the
    # parsed object (symbolized into the struct), UNKNOWN keys dropped —
    # the schema tolerates them (pi additionalProperties:true) and the
    # struct carries only the dialect the request seam reads. nil when the
    # entry carries no compat (the model rides today's default arm). The
    # load path only ever constructs from schema-VALID parsed files, so
    # the strict types never see the rejected input classes.
    def build_compat(raw)
      return nil unless raw.is_a?(Hash)

      Shapes::ModelCompat.new(
        thinking_format: raw["thinkingFormat"],
        max_tokens_field: raw["maxTokensField"],
        supports_developer_role: raw["supportsDeveloperRole"],
        supports_reasoning_effort: raw["supportsReasoningEffort"],
        zai_tool_stream: raw["zaiToolStream"],
        supports_strict_mode: raw["supportsStrictMode"]
      )
    end

    # pi ThinkingLevelMap (model-schema.ts:14-15 — Partial Record<level,
    # String|null>): a String value rides the wire verbatim, null marks the
    # level unsupported. Keys symbolized for the resolution functions
    # ({supported_thinking_levels} family). undeclared → nil (the map-less
    # rule: pi's ladder without xhigh/max). The schema-side check for the
    # same field lives in {Schemas::Models} (exact error lines, same
    # Partial-Record tolerance); this builder is the VALID path only.
    def build_thinking_level_map(raw)
      return nil unless raw.is_a?(Hash)

      raw.transform_keys(&:to_sym)
    end

    # pi getSupportedThinkingLevels (models.ts:1224-1233): a non-reasoning
    # model supports ["off"] alone; a reasoning model offers the
    # {Settings::THINKING_LEVELS} ladder filtered through the map — a null
    # value marks the level unsupported, xhigh/max need a PRESENT entry
    # (a missing map key excludes them; the map-less rule is off..high).
    # The map is the parsed :thinking_level_map shape (symbol keys); the
    # level speaks the Settings vocabulary (Strings).
    def supported_thinking_levels(map:, reasoning:)
      return ["off"] unless reasoning

      Settings::THINKING_LEVELS.filter do |level|
        key = level.to_sym
        present = map&.key?(key)
        next false if present && map[key].nil? # null marks the level unsupported
        next false if (level == "xhigh" || level == "max") && !present # a PRESENT entry is required

        true
      end
    end

    # pi clampThinkingLevel (models.ts:1235-1254): an exactly-supported
    # level passes; otherwise pi's scan — forward from the requested rung
    # to the ladder's top, then backward from just below it, first
    # supported candidate wins; an unknown level lands on the first
    # supported one (the JS `indexOf → -1` early return).
    def clamp_thinking_level(level, map:, reasoning:)
      available = supported_thinking_levels(map:, reasoning:)
      return level if available.include?(level)

      ladder = Settings::THINKING_LEVELS
      requested = ladder.index(level)
      return available.first || "off" if requested.nil?

      forward = ladder[requested..] || []
      backward = ladder[0...requested].reverse
      (forward + backward).find { |candidate| available.include?(candidate) } || available.first || "off"
    end

    # The reasoning_effort for the wire (pi openai-completions.ts:745-755
    # + :969-976, the generic openai-completions branch — the port's single
    # chat-completions seam is that class): nil sends NO reasoning_effort —
    # a non-reasoning model, or a level clamping to "off" with no String
    # `off` map value (map-less off). Otherwise the clamped level's map
    # value, falling back to the level itself (`map[clamped] || clamped`,
    # pi's `??` — equivalent for String|nil values); the "off" clamp sends
    # the map's String `off` value only (the owner's override floors
    # off→"low" directly; a null-off map clamps upward through the clamp
    # before this sees "off").
    def resolve_reasoning_effort(level, map:, reasoning:)
      return nil unless reasoning

      clamped = clamp_thinking_level(level, map:, reasoning:)
      if clamped == "off"
        off = map&.[](:off)
        off.is_a?(String) ? off : nil
      else
        map&.[](clamped.to_sym) || clamped
      end
    end
  end
end
