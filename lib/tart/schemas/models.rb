# frozen_string_literal: true

require "dry-validation"

module Tart
  module Schemas
    # B2 — models.json (port of pi's core/model-config.ts load-side schema
    # check, reduced to the port's carried subset). One contract over the
    # parsed root produces, on failure, today's exact error LINES in today's
    # exact order (the Grounds fixture table is the frozen contract); the
    # `Invalid models.json schema:\n` header and `\n(<path>)` suffix stay in
    # {Models.load}. Every check is a rule so the failure strings and the
    # evaluation order are ours — never dry's default prose: default →
    # providers, per provider the fields (name, baseUrl, apiKey, api) then
    # the models array, per model id → name → reasoning → thinkingLevelMap
    # → contextWindow/maxTokens. Servers iterate in parsed insertion order,
    # so the multi-error interleave matches the hand-rolled family this
    # contract replaces (Models.validate*, deleted). Failures never raise —
    # {Models.load} keeps error-as-field.
    module Models
      ROOT_LINE = "  - root: expected a JSON object"

      class CatalogContract < Dry::Validation::Contract
        json do
          # Bare key declarations only: they symbolize the JSON root's top
          # keys for the rules (nested content keeps its parsed string keys)
          # and carry NO predicates, so every rejection below is ours.
          optional(:default)
          optional(:providers)
        end

        rule(:default) do
          key.failure(%q{expected a "provider/model-id" string}) unless value.nil? || value.is_a?(String)
        end

        rule(:providers) do
          unless value.is_a?(Hash)
            key.failure("expected an object of providers")
            next
          end

          value.each do |provider_key, provider|
            provider_path = [:providers, provider_key]
            unless provider.is_a?(Hash)
              key(provider_path).failure("expected an object")
              next
            end

            %w[name baseUrl apiKey api].each do |field|
              field_value = provider[field]
              key([*provider_path, field]).failure("expected a string") if !field_value.nil? && !field_value.is_a?(String)
            end

            models = provider["models"]
            next if models.nil?
            unless models.is_a?(Array)
              key([*provider_path, :models]).failure("expected an array")
              next
            end

            models.each_with_index do |model, index|
              model_path = [*provider_path, :models, index]
              unless model.is_a?(Hash)
                key(model_path).failure("expected an object")
                next
              end

              key([*model_path, :id]).failure("required non-empty string") unless
                model["id"].is_a?(String) && !model["id"].empty?
              key([*model_path, :name]).failure("expected a string") if
                !model["name"].nil? && !model["name"].is_a?(String)
              key([*model_path, :reasoning]).failure("expected a boolean") if
                !model["reasoning"].nil? && ![true, false].include?(model["reasoning"])

              map = model["thinkingLevelMap"]
              if map.is_a?(Hash)
                # pi ThinkingLevelMapSchema (model-schema.ts:14-15 — Partial
                # Record<level, String|null>): unknown level keys tolerated,
                # null kept.
                map.each do |level, level_value|
                  next if level_value.nil? || level_value.is_a?(String)

                  key([*model_path, :thinkingLevelMap, level]).failure("expected a string or null")
                end
              else
                key([*model_path, :thinkingLevelMap]).failure("expected an object") unless map.nil?
              end

              %w[contextWindow maxTokens].each do |field|
                window = model[field]
                next if window.nil? || (window.is_a?(Integer) && window.positive?)

                key([*model_path, field]).failure("expected a positive integer")
              end
            end
          end
        end
      end

      CONTRACT = CatalogContract.new.freeze

      module_function

      # The full line list for a parsed models.json body — empty when valid.
      # Non-Hash roots are the boundary's guard line (Contract#call raises
      # on non-Hash input, so the contract only ever sees a Hash).
      def validate(parsed)
        return [ROOT_LINE] unless parsed.is_a?(Hash)

        CONTRACT.call(parsed).errors.to_a.map { |message| format_line(message) }
      end

      # The pi line shape: "  - providers.a.models[0].id: required non-empty
      # string" — dotted keys, BRACKETED indices (pi's model-config.ts path
      # style; the tool-input wrapper's dotted indices are pi's
      # validation.ts style — the two boundaries keep their own).
      def format_line(message)
        "  - #{format_path(message.path)}: #{message_text(message)}"
      end

      def format_path(path)
        path.map.with_index do |part, index|
          next "[#{part}]" if part.is_a?(Integer)

          index.zero? ? part.to_s : ".#{part}"
        end.join
      end

      # Rule failures carry the exact string as text; dry's sum-type
      # messages (integer-or-float) answer to_s instead.
      def message_text(message)
        message.respond_to?(:text) ? message.text : message.to_s
      end
    end
  end
end
