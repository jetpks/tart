# frozen_string_literal: true

require_relative "types"

module Tart
  module Shapes
    # The Model-catalog value family (I44 B1): the typed shapes behind the
    # models.json catalog and the boot resolution. One Dry::Struct per
    # shape; attribute names are the Ruby-facing snake_case vocabulary;
    # construction is the type gate (the catalog schema — Schemas::Models —
    # has already validated the parsed file on the load path, so these
    # constructors never see the rejected input classes).
    #
    # Byte rule: Shapes::Model#to_h is DECLARED to equal today's catalog
    # entry hash — the merged-hash shape with the provider key appended
    # last — key order included (unit-pinned). No to_h output crosses a
    # byte-frozen surface (the JSONL write path stays Hash literals).
    #
    # The catalog's feeding input is symbol-keyed (the builders), so no
    # member here needs the JSON transform_keys idiom — that rides on the
    # session envelopes (shapes/session.rb), the parsed-JSON consumers.

    # One model's pi-compat dialect subset (I46, I64 — the port's carried
    # six keys of pi's ProviderCompatSchema, providers/compat-schema.ts:
    # every property Optional, the object additionalProperties true so
    # UNKNOWN keys are tolerated at the schema and dropped here):
    # thinkingFormat (a union of pi's 11 literals), maxTokensField (pi's
    # two literals), and the four booleans. Every attribute is nil-defaulted and
    # omittable at construction (.optional.default(nil) — reads nil, and
    # Model#to_h still emits the key) — pi's absent key means "use the
    # URL detection stand-in", which the request seam resolves per arm.
    class ModelCompat < Dry::Struct
      attribute :thinking_format,
        Types::Strict::String.enum(
          "openai", "openrouter", "deepseek", "together", "baseten", "zai", "qwen",
          "chat-template", "qwen-chat-template", "string-thinking", "ant-ling"
        ).optional.default(nil)
      attribute :max_tokens_field,
        Types::Strict::String.enum("max_tokens", "max_completion_tokens").optional.default(nil)
      attribute :supports_developer_role, Types::Strict::Bool.optional.default(nil)
      attribute :supports_reasoning_effort, Types::Strict::Bool.optional.default(nil)
      attribute :zai_tool_stream, Types::Strict::Bool.optional.default(nil)
      # I64: pi's constrainedSampling gate (detectCompat — OpenAI
      # compatibility alone does not imply strict JSON-schema tool
      # support). Declared after zai_tool_stream: the struct's declaration
      # order is the documented carry order; nil default like the five.
      attribute :supports_strict_mode, Types::Strict::Bool.optional.default(nil)
    end

    # One catalog model entry: {id:, name:, reasoning:, context_window:,
    # max_tokens:, thinking_level_map:, compat:, provider:}. The attribute
    # DECLARATION order is the to_h emission order — pinned equal to
    # today's entry hash (compat rides between the map and the provider:
    # a model field precedes the appended provider key, I46 Spec 1.2).
    class Model < Dry::Struct
      attribute :id, Types::Strict::String
      attribute :name, Types::Strict::String
      attribute :reasoning, Types::Strict::Bool
      attribute :context_window, Types::Strict::Integer.optional
      attribute :max_tokens, Types::Strict::Integer.optional
      attribute :thinking_level_map,
        Types::Strict::Hash.map(Types::Strict::Symbol, Types::Strict::String | Types::Strict::Nil).optional
      attribute :compat, Shapes::ModelCompat.optional.default(nil)
      attribute :provider, Types::Strict::String
    end

    # One provider config: the endpoint block (name/baseUrl/apiKey/api —
    # today's parse may omit them, hence optional) plus its typed models.
    class Provider < Dry::Struct
      attribute :name, Types::Strict::String.optional
      attribute :base_url, Types::Strict::String.optional
      attribute :api_key, Types::Strict::String.optional
      attribute :api, Types::Strict::String.optional
      attribute :models, Types::Strict::Array.of(Shapes::Model)
    end

    # The boot/runtime model reference (provider key + model id) — the
    # two-key shape the boot resolution and the menu markers trade.
    class ModelRef < Dry::Struct
      attribute :provider, Types::Strict::String
      attribute :id, Types::Strict::String
    end

    # The footer/border thinking facts for one model (I36), composed
    # catalog-entry-first, known-tables-second. The map keeps the
    # Model#thinking_level_map type (nil = the map-less rule).
    class ThinkingFacts < Dry::Struct
      attribute :reasoning, Types::Strict::Bool
      attribute :thinking_level_map,
        Types::Strict::Hash.map(Types::Strict::Symbol, Types::Strict::String | Types::Strict::Nil).optional
    end
  end
end
