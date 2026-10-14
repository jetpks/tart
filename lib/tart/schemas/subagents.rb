# frozen_string_literal: true

require "dry-validation"

module Tart
  module Schemas
    module Subagents
      # The agent-profile contract (I49 Spec §2 — the I43 discipline):
      # validates the SHAPE of one `agents/**/*.md` frontmatter; the
      # defaults (name → file stem, description → "", tools → the builtin
      # seven, context → fresh) are the CALLER's (Profiles builds the spec
      # Hash); a boundary never raises — the caller maps failures to
      # warning diagnostics and skips the file.
      #
      # The field set is pi's agent frontmatter subset the port consumes;
      # everything else in pi's vocabulary (aliases, acceptanceRole,
      # defaultReads, defaultProgress, systemPromptMode (replace is the
      # port's only mode), inheritProjectContext / inheritSkills (the
      # fresh/fork context covers it), allowNestedSubagents (children never
      # nest — I48 OQ-7), machine, extensions, permission rules) is
      # tolerated and ignored (OQ-6, Spec §2 — `validate_keys = false`).
      module ProfileFields
        # pi profiles.js SAFE_PATH_TOKEN (/^[A-Za-z0-9][A-Za-z0-9._-]*$/);
        # the failure is pi normalizePathToken's message.
        SAFE_NAME_TOKEN = /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/.freeze
        NAME_MESSAGE = "must be a safe file name using only letters, numbers, dots, underscores, and hyphens.".freeze

        # The tool universe (Spec §2): the seven builtins + the intercom
        # tool. The pinned unknown-tool failure names this set sorted.
        TOOLS_UNIVERSE = %w[read edit write bash find grep ls contact_supervisor].freeze

        # pi's comma form (a string splits on ","; an array passes through).
        TOOLS_SHAPE_MESSAGE = "tools must be a comma-separated string or an array of strings"

        def self.unknown_tool_message(name)
          "unknown tool #{name} (valid tools: #{TOOLS_UNIVERSE.sort.join(", ")})"
        end

        def self.thinking_message
          "must be one of #{Tart::Settings::THINKING_LEVELS.join(", ")}"
        end

        def self.context_message
          'must be "fresh" or "fork"'
        end
      end

      class ProfileContract < Dry::Validation::Contract
        json do
          config.validate_keys = false
          optional(:name).maybe(:string)
          optional(:description).maybe(:string)
          optional(:tools)
          optional(:model).maybe(:string)
          optional(:thinking).maybe(:string)
          optional(:context).maybe(:string)
        end

        rule(:name) do
          next if value.nil?

          key.failure(ProfileFields::NAME_MESSAGE) unless value.match?(ProfileFields::SAFE_NAME_TOKEN)
        end

        rule(:tools) do
          next if value.nil?

          list = value.is_a?(String) ? value.split(",") : value
          unless list.is_a?(Array) && list.all? { |item| item.is_a?(String) }
            key.failure(ProfileFields::TOOLS_SHAPE_MESSAGE)
            next
          end

          list.map(&:strip).reject(&:empty?).each do |name|
            next if ProfileFields::TOOLS_UNIVERSE.include?(name)

            key.failure(ProfileFields.unknown_tool_message(name))
          end
        end

        # The model spec rides Subagents.resolve_model's semantics; its
        # error texts pass through VERBATIM (Spec §2 — the pinned texts are
        # resolve_model's, so the profile diagnostic names the same ladder
        # the spawn path would). Referenced at rule time, not load time —
        # the schemas family loads before the Subagents module.
        rule(:model) do
          next if value.nil?

          Tart::Subagents.resolve_model(value, catalog: nil, fallback: nil)
        rescue ArgumentError => e
          key.failure(e.message)
        end

        rule(:thinking) do
          next if value.nil?

          key.failure(ProfileFields.thinking_message) unless Tart::Settings::THINKING_LEVELS.include?(value)
        end

        rule(:context) do
          next if value.nil?

          key.failure(ProfileFields.context_message) unless %w[fresh fork].include?(value)
        end
      end

      # Instantiated once at module load (the Schemas::Tools pattern).
      PROFILE_CONTRACT = ProfileContract.new
    end
  end
end
