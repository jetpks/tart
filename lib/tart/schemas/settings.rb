# frozen_string_literal: true

require "dry-schema"

require_relative "../settings"

module Tart
  module Schemas
    # B1 — settings resolution (port of pi's settings-manager.ts semantics,
    # reduced to the port's carried key set). Two things live here:
    #
    # - The carried-key FILE_VIEW: the typed documentation of the settings
    #   file shape (pi settings-schema.ts, reduced). It is TOLERANT
    #   (validate_keys off — pi additionalProperties: true,
    #   settings-schema.ts:446) and NON-FILTERING — it never gates
    #   {Settings.load}: pi does not validate settings files ("a malformed
    #   value replaces instead of throwing", settings-manager.ts:126), so a
    #   type-invalid file value lands in Result#settings verbatim (pinned by
    #   the no-filter test).
    # - The resolution contracts consumed by Settings' resolution helpers,
    #   preserving each helper's public signature and outcome table exactly:
    #   a value failing its contract tier reads as ABSENT at that tier and
    #   the chain falls through (today's regex/guard outcomes, never new
    #   rejections). The `env || settings || DEFAULTS` precedence arithmetic
    #   itself cannot be expressed as one schema honestly (three-source
    #   `||`) — it stays in {Settings.resolve_setting}.
    module Settings
      module_function

      # The env tier of the context-window ladder
      # (<IDENTITY>_CONTEXT_WINDOW): a digit-string coerces to an Integer,
      # anything else reads as absent. The Params-flavored format? gate is
      # today's /\A\d+\z/ match expressed as a contract — "+5", "-5", " 5",
      # "5.5" and "" stay absent (AC2 fall-through table). value, not
      # maybe: the Params flavor coerces "" to nil BEFORE the predicates,
      # so a maybe would let the empty string through as "absent-at-the-
      # schema" and crash the Integer step — the nil guard lives in the
      # helper instead.
      ENV_CONTEXT_WINDOW = Dry::Schema.Params do
        required(:contextWindow).value(:string, format?: /\A\d+\z/)
      end.freeze

      # The file/model tiers of the context-window ladder: an Integer > 0
      # passes; nil, 0, negatives, floats and strings read as absent
      # (today's `is_a?(Integer) && positive?` guards).
      VALUE_CONTEXT_WINDOW = Dry::Schema.JSON do
        required(:contextWindow).maybe(:integer, gt?: 0)
      end.freeze

      # The staged modelReasoning vocabulary (settings-manager.ts:126's
      # flows-through world: the setting is staged as true|false|"true"|
      # "false" or nil).
      MODEL_REASONING_VIEW = Dry::Schema.JSON do
        required(:modelReasoning).maybe(included_in?: [true, false, "true", "false"])
      end.freeze

      # The typed view of the settings FILE: every carried key with today's
      # effective type, unknown keys tolerated. Memoized rather than built
      # at require time because the thinkingLevel row reads
      # Settings::THINKING_LEVELS, and settings.rb requires this file before
      # its own module body runs (circular require — building here would
      # raise). The instance is built once and frozen (the pattern contract:
      # never re-defined per call).
      def file_view
        @file_view ||= Dry::Schema.JSON do
          config.validate_keys = false
          optional(:identity).maybe(:string)
          optional(:defaultModel).maybe(:string)
          optional(:defaultProvider).maybe(:string)
          optional(:apiBase).maybe(:string)
          optional(:apiKey).maybe(:string)
          optional(:contextWindow).maybe(:integer)
          optional(:thinkingLevel).maybe(:string, included_in?: ::Tart::Settings::THINKING_LEVELS)
          optional(:compaction).maybe(:hash) do
            optional(:enabled).maybe(:bool)
            optional(:reserveTokens).maybe(:integer, gt?: 0)
            optional(:keepRecentTokens).maybe(:integer, gt?: 0)
          end
          optional(:modelReasoning).maybe(included_in?: [true, false, "true", "false"])
          optional(:defaultTools).maybe(:array) { each(:string) }
        end.freeze
      end

      # The thinkingLevel vocabulary row of the view, standalone: the
      # resolution helpers' `THINKING_LEVELS.include?` check rides this
      # contract (same memoization reason as {file_view}).
      def thinking_level_view
        @thinking_level_view ||= Dry::Schema.JSON do
          required(:thinkingLevel).maybe(:string, included_in?: ::Tart::Settings::THINKING_LEVELS)
        end.freeze
      end

      # The env tier: nil → nil (absent), a digit-string → Integer,
      # everything else → nil (absent — the tier falls through).
      def context_window_env(value)
        return nil if value.nil?
        return nil if ENV_CONTEXT_WINDOW.call(contextWindow: value).failure?

        Integer(value, 10)
      end

      # The file/model tiers: the value itself when it is an Integer > 0,
      # else nil (absent).
      def context_window_value(value)
        return nil if VALUE_CONTEXT_WINDOW.call(contextWindow: value).failure?

        value
      end

      # The thinkingLevel vocabulary: the level verbatim when it speaks
      # pi's vocabulary, else nil.
      def thinking_level(value)
        return nil if thinking_level_view.call(thinkingLevel: value).failure?

        value
      end

      # The staged modelReasoning truthiness: nil = unstaged (the caller
      # falls through to the registry/table); the staged vocabulary passes
      # through to today's `staged == true || staged == "true"` arithmetic;
      # any non-nil value outside the vocabulary answers false (AC2's
      # outcome table — a non-nil staged value short-circuits the registry
      # tier with false, never the fallback).
      def model_reasoning(value)
        return nil if value.nil?
        return value == true || value == "true" if MODEL_REASONING_VIEW.call(modelReasoning: value).success?

        false
      end
    end
  end
end
