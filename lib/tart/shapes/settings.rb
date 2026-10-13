# frozen_string_literal: true

require_relative "types"
require_relative "model"

require_relative "../settings"
require_relative "../schemas/settings"

module Tart
  module Shapes
    # The resolved-settings value family (I44 B2): the typed view of the
    # RESOLVED settings, built ONCE per boot from the merged file hash (or
    # the load Result carrying it). This is the CONSUMER view only — the
    # Settings domain keeps its helpers and their public signatures (the
    # merged-hash shape is byte-pinned by settings_test and the I43
    # no-filter pin; Result#settings carries malformed values verbatim).
    #
    # Honesty rule (the flows-through world): pi never filters settings
    # values (settings-manager.ts:126), so strict types appear ONLY where
    # the resolution arithmetic guarantees the class (identity —
    # Identity.resolve validates; thinking_level — the vocabulary-resolved
    # value or the default; context_window — the file-tier contract
    # output; default_tools — the selection list). File-sourced scalars a
    # malformed file can corrupt ride Nominal::Any: the raw staged value
    # lands verbatim, no raise, no filter — exactly the merged hash's
    # content.

    # The present-keys slice of the compaction block (the key set
    # Settings.compaction_kwargs produces today): a key exists only when
    # the merged file carried a non-nil value, so the loop's built-in
    # defaults hold for the rest. Values are nominal — they flow through.
    class CompactionSettings < Dry::Struct
      attribute? :enabled, Types::Nominal::Any
      attribute? :reserve_tokens, Types::Nominal::Any
      attribute? :keep_recent_tokens, Types::Nominal::Any
    end

    class ResolvedSettings < Dry::Struct
      # The resolved identity face (Strict::String — Identity.resolve
      # validated it before this view is built).
      attribute :identity, Types::Strict::String

      # The flows-through scalars: the resolve_setting table's outcomes
      # (env tier via the identity namespace, then the merged file hash,
      # then DEFAULTS). A malformed file value rides verbatim (no filter).
      attribute :default_model, Types::Nominal::Any
      attribute :default_provider, Types::Nominal::Any
      attribute :api_base, Types::Nominal::Any
      attribute :api_key, Types::Nominal::Any

      # Strict where resolution guarantees the class.
      attribute :thinking_level, Types::Strict::String
      attribute :context_window, Types::Strict::Integer.optional
      attribute :default_tools, Types::Strict::Array

      # The compaction slice — always present (possibly empty when the
      # merged file declares no compaction block).
      attribute :compaction, Shapes::CompactionSettings

      class << self
        # Builds the resolved view from a Settings.load Result (or the bare
        # merged hash), running today's exact resolution arithmetic per
        # key — the helpers stay the single source of each table:
        # resolve_setting (env > file > DEFAULTS), resolve_thinking_level
        # (the vocabulary value or the default), the file-tier context
        # window (Schemas::Settings.context_window_value), selected_tools,
        # and the compaction_kwargs key set. The context window here is
        # the FILE tier only — the env tier (<IDENTITY>_CONTEXT_WINDOW)
        # and the model/registry tiers stay in
        # Settings.resolve_context_window, which needs the chat model.
        #
        # @param settings_or_result [Settings::Result, Hash] the load
        #   outcome (or the merged settings hash itself).
        # @param identity [String] the resolved face (Identity.resolve).
        # @param env [Hash] the env tier source (tests inject).
        def from_load(settings_or_result, identity:, env: ENV)
          settings = settings_or_result.respond_to?(:settings) ? settings_or_result.settings : settings_or_result
          new(
            identity:,
            default_model: Settings.resolve_setting("defaultModel", settings, identity:, env:),
            default_provider: Settings.resolve_setting("defaultProvider", settings, identity:, env:),
            api_base: Settings.resolve_setting("apiBase", settings, identity:, env:),
            api_key: Settings.resolve_setting("apiKey", settings, identity:, env:),
            thinking_level: Settings.resolve_thinking_level(settings),
            context_window: Schemas::Settings.context_window_value(settings["contextWindow"]),
            default_tools: Settings.selected_tools(settings),
            compaction: Shapes::CompactionSettings.new(**Settings.compaction_kwargs(settings))
          )
        end
      end
    end
  end
end
