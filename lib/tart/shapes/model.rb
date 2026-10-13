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

    # One catalog model entry: {id:, name:, reasoning:, context_window:,
    # max_tokens:, thinking_level_map:, provider:}. The attribute
    # DECLARATION order is the to_h emission order — pinned equal to
    # today's entry hash.
    class Model < Dry::Struct
      attribute :id, Types::Strict::String
      attribute :name, Types::Strict::String
      attribute :reasoning, Types::Strict::Bool
      attribute :context_window, Types::Strict::Integer.optional
      attribute :max_tokens, Types::Strict::Integer.optional
      attribute :thinking_level_map,
        Types::Strict::Hash.map(Types::Strict::Symbol, Types::Strict::String | Types::Strict::Nil).optional
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
