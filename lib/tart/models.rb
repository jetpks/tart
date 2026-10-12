# frozen_string_literal: true

require "json"
require_relative "agent/session"

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

      errors = validate(parsed)
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
        max_tokens: model["maxTokens"]
      }
    end

    # The schema subset, validated by hand (pi TypeBox compile reduced):
    # the named keys type-check, unknown keys are tolerated (pi's
    # TypeBox default), "id" is required on every model.
    def validate(parsed)
      return ["  - root: expected a JSON object"] unless parsed.is_a?(Hash)

      errors = []
      validate_default(parsed["default"], errors)
      validate_providers(parsed["providers"], errors)
      errors
    end

    def validate_default(default, errors)
      return if default.nil? || default.is_a?(String)

      errors << "  - default: expected a \"provider/model-id\" string"
    end

    def validate_providers(providers, errors)
      unless providers.is_a?(Hash)
        errors << "  - providers: expected an object of providers"
        return
      end

      providers.each do |key, provider|
        unless provider.is_a?(Hash)
          errors << "  - providers.#{key}: expected an object"
          next
        end
        validate_provider_fields(key, provider, errors)
        validate_models(key, provider["models"], errors)
      end
    end

    def validate_provider_fields(key, provider, errors)
      %w[name baseUrl apiKey api].each do |field|
        value = provider[field]
        errors << "  - providers.#{key}.#{field}: expected a string" if !value.nil? && !value.is_a?(String)
      end
    end

    def validate_models(key, models, errors)
      return if models.nil?
      unless models.is_a?(Array)
        errors << "  - providers.#{key}.models: expected an array"
        return
      end

      models.each_with_index do |model, i|
        unless model.is_a?(Hash)
          errors << "  - providers.#{key}.models[#{i}]: expected an object"
          next
        end
        errors << "  - providers.#{key}.models[#{i}].id: required non-empty string" unless model["id"].is_a?(String) && !model["id"].empty?
        validate_model_fields(key, i, model, errors)
      end
    end

    def validate_model_fields(key, index, model, errors)
      errors << "  - providers.#{key}.models[#{index}].name: expected a string" if !model["name"].nil? && !model["name"].is_a?(String)
      errors << "  - providers.#{key}.models[#{index}].reasoning: expected a boolean" if !model["reasoning"].nil? && ![true, false].include?(model["reasoning"])
      %w[contextWindow maxTokens].each do |field|
        value = model[field]
        next if value.nil? || (value.is_a?(Integer) && value.positive?)

        errors << "  - providers.#{key}.models[#{index}].#{field}: expected a positive integer"
      end
    end
  end
end
