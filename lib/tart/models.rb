# frozen_string_literal: true

require "json"
require_relative "agent/session"
require_relative "settings"
require_relative "schemas/models"

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

    # The port's carried wire: the chat-completions seam on the openai
    # slug (the recorded standing reduction — no other native provider).
    # A models.json provider KEY names an ENDPOINT CONFIG (baseUrl/
    # apiKey/api), not a wire provider: pi's api field picks the Api
    # class; the port maps every non-native key onto this one seam
    # (live-verified: ruby_llm 2.1 Models.resolve raises "Unknown
    # provider" for anything but a registered slug — models.rb:203,
    # provider.rb:608-611).
    WIRE_PROVIDER = "openai"

    # The catalog shape: one hash per provider (key → config) and one
    # frozen hash per model entry — {provider:, id:, name:, reasoning:,
    # context_window:, max_tokens:} once flattened ({model_entries}).
    Config = Struct.new(:providers, :default, :error, keyword_init: true) do
      # Every model entry across providers, tagged with its provider key.
      def model_entries
        providers.flat_map { |key, provider| provider.fetch(:models).map { |model| model.merge(provider: key) } }
      end

      # The provider's config hash (build_chat's baseUrl/apiKey/api seam),
      # or nil for an unknown key.
      def provider(key)
        providers[key]
      end

      # Exact model-reference match (pi findExactModelReferenceMatch,
      # model-resolver.ts:82-118, reduced): a unique canonical
      # "provider/id" wins; then an explicit provider/id pair; then a
      # unique bare id. Ambiguity is no match (pi literal).
      def resolve(reference)
        needle = reference.to_s.strip.downcase
        return nil if needle.empty?

        entries = model_entries
        canonical = entries.select { |entry| "#{entry[:provider]}/#{entry[:id]}".downcase == needle }
        return canonical.first if canonical.size == 1
        return nil if canonical.size > 1

        provider_key, id = needle.split("/", 2)
        if id && !id.empty?
          scoped = entries.select { |entry| entry[:provider].downcase == provider_key && entry[:id].downcase == id }
          return scoped.first if scoped.size == 1
        end

        bare = entries.select { |entry| entry[:id].downcase == needle }
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

    # The wire provider for a provider key: a native ruby_llm slug
    # passes through (the Settings defaultProvider contract preserved),
    # everything else rides the port's single chat-completions seam.
    def wire_provider(key)
      return key.to_s if key && RubyLLM::Provider.providers.key?(key.to_sym)

      WIRE_PROVIDER
    end

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
        return {provider: env[Identity.env_key(identity, "PROVIDER")] || settings["defaultProvider"], id: model}
      end
      if (provider = env[Identity.env_key(identity, "PROVIDER")])
        return {provider:, id: settings["defaultModel"]}
      end
      if config&.default && (entry = config.resolve(config.default))
        return {provider: entry[:provider], id: entry[:id]}
      end

      {provider: settings["defaultProvider"], id: settings["defaultModel"]}
    end

    def build_providers(parsed)
      parsed.fetch("providers").transform_values do |provider|
        {
          name: provider["name"],
          base_url: provider["baseUrl"],
          api_key: provider["apiKey"],
          api: provider["api"],
          models: (provider["models"] || []).map { |model| build_model(model) }
        }
      end
    end

    def build_model(model)
      {
        id: model.fetch("id"),
        name: model["name"] || model["id"],
        reasoning: model["reasoning"] == true,
        context_window: model["contextWindow"],
        max_tokens: model["maxTokens"],
        thinking_level_map: build_thinking_level_map(model["thinkingLevelMap"])
      }
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
