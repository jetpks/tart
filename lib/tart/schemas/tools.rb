# frozen_string_literal: true

require "json"
require "dry-validation"

module Tart
  module Schemas
    # B4 — tool inputs: one input contract per built-in tool, mirroring each
    # tool's JSON-Schema declaration shapes (the wire declarations
    # themselves stay byte-identical — the contracts validate internally,
    # after the executor's argument hand-off, before the runtime work). Validation is
    # NO-COERCION: pi's Value.Convert string→number coercion is not ported
    # (today's port rejects wrong-typed numbers; the pi-coercion gap is
    # itemized in the iteration record).
    #
    # Error vocabulary: a PINNED in-tool message (bash timeout, edit edits)
    # comes back byte-exactly as the whole {error:} value — the tool's own
    # voice, exactly the raise it replaces. Every other shape failure speaks
    # pi's agent-loop wrapper (pi packages/ai/src/utils/validation.ts:317):
    # `Validation failed for tool "<name>":\n  - <path>: <detail>\n\n
    # Received arguments:\n<pretty JSON>` — dry's detail text is accepted
    # (the TypeBox prose is not cloned). Pinned rule failures WIN over
    # schema failures on the same input, matching today's raise order (the
    # in-tool checks ran before any runtime use of the other args).
    module Tools
      # pi bash.ts:29-37 resolveTimeoutMs / edit.ts:138 — the two pinned
      # in-tool strings (byte-exact, pi's own).
      PINNED_TIMEOUT_MESSAGE = "Invalid timeout: must be a finite number of seconds"
      PINNED_EDITS_MESSAGE = "Edit tool input is invalid. edits must contain at least one replacement."
      PINNED_TEXTS = [PINNED_TIMEOUT_MESSAGE, PINNED_EDITS_MESSAGE].freeze

      # pi's edit items speak camelCase on the wire (string keys arrive
      # untouched inside the array — the executor seam symbolizes top-level keys
      # only); direct callers may use the snake aliases
      # (Edit.normalize_edit_shapes accepts all three flavors).
      OLD_TEXT_KEYS = [:old_text, :oldText, "oldText"].freeze
      NEW_TEXT_KEYS = [:new_text, :newText, "newText"].freeze

      class Read < Dry::Validation::Contract
        json do
          config.validate_keys = false
          required(:path).value(:string)
          optional(:offset).maybe([:integer, :float])
          optional(:limit).maybe([:integer, :float])
        end
      end

      class Bash < Dry::Validation::Contract
        json do
          config.validate_keys = false
          required(:command).value(:string)
          optional(:timeout).maybe([:integer, :float])
        end

        # The pinned timeout rule (replaces bash resolve_timeout's raise):
        # finite and positive, or the exact pi string. pi's
        # >2147483.647s second tier stays cut, as today.
        rule(:timeout) do
          next unless value

          key.failure(PINNED_TIMEOUT_MESSAGE) unless value.is_a?(Numeric) && value.finite? && value.positive?
        end
      end

      class Edit < Dry::Validation::Contract
        json do
          config.validate_keys = false
          required(:path).value(:string)
          # Presence only: every shape check is the rule below, so the
          # not-an-array and empty cases carry the pinned string instead of
          # dry's prose (a schema type error would skip the rule).
          required(:edits)
        end

        rule(:edits) do
          unless value.is_a?(Array) && !value.empty?
            key.failure(PINNED_EDITS_MESSAGE)
            next
          end

          value.each_with_index do |item, index|
            unless item.is_a?(Hash)
              key([:edits, index]).failure("must be a hash")
              next
            end

            # Each item's texts must be a string WHEN PRESENT; empty strings
            # and nil-shapes flow to EditDiff exactly as today (the
            # `oldText must not be empty in …` golden is EditDiff's, not the
            # schema's).
            {oldText: OLD_TEXT_KEYS, newText: NEW_TEXT_KEYS}.each do |field, keys|
              text = keys.filter_map { |key| item[key] if item.key?(key) }.first
              next if text.nil? || text.is_a?(String)

              key([:edits, index, field]).failure("must be a string")
            end
          end
        end
      end

      class Write < Dry::Validation::Contract
        json do
          config.validate_keys = false
          required(:path).value(:string)
          required(:content).value(:string)
        end
      end

      class Ls < Dry::Validation::Contract
        json do
          config.validate_keys = false
          optional(:path).maybe(:string)
          optional(:limit).maybe([:integer, :float])
        end
      end

      class Grep < Dry::Validation::Contract
        json do
          config.validate_keys = false
          required(:pattern).value(:string)
          optional(:path).maybe(:string)
          optional(:glob).maybe(:string)
          optional(:ignore_case).maybe(:bool)
          optional(:literal).maybe(:bool)
          optional(:context).maybe([:integer, :float])
          optional(:limit).maybe([:integer, :float])
        end
      end

      class Find < Dry::Validation::Contract
        json do
          config.validate_keys = false
          required(:pattern).value(:string)
          optional(:path).maybe(:string)
          optional(:limit).maybe([:integer, :float])
        end
      end

      # Instantiated once at module load (the pattern contract), keyed by
      # the wire name the tools report through pi_name.
      CONTRACTS = {
        "read" => Read.new,
        "bash" => Bash.new,
        "edit" => Edit.new,
        "write" => Write.new,
        "ls" => Ls.new,
        "grep" => Grep.new,
        "find" => Find.new
      }.freeze

      module_function

      # nil = valid; {error: message} = rejected (the tool's result).
      # +arguments+ is the tool's execute kwargs Hash — the root-object
      # guard is the kwarg construction itself (Contract#call raises on
      # non-Hash input).
      def validate(pi_name, arguments)
        contract = CONTRACTS.fetch(pi_name) do
          raise KeyError, "no input contract registered for tool #{pi_name.inspect}"
        end
        result = contract.call(arguments)
        return nil if result.success?

        pinned = result.errors.to_a.find { |message| PINNED_TEXTS.include?(message_text(message)) }
        return {error: message_text(pinned)} if pinned

        {error: wrapper(pi_name, result, arguments)}
      end

      # pi validation.ts:317 — `Validation failed for tool "<name>":` + one
      # "  - <path>: <message>" line per failure + the received arguments
      # pretty-printed (pi JSON.stringify(args, null, 2)).
      def wrapper(pi_name, result, arguments)
        lines = result.errors.to_a.map { |message| "  - #{format_path(message.path)}: #{message_text(message)}" }
        "Validation failed for tool \"#{pi_name}\":\n#{lines.join("\n")}\n\n" \
          "Received arguments:\n#{pretty_arguments(arguments)}"
      end

      # pi formatValidationPath (validation.ts:243-254): the instance path
      # joined with dots — edits.0.oldText (the dotted-index style; the
      # models.json bracket style is that boundary's own).
      def format_path(path)
        path.map.with_index { |part, index| index.zero? ? part.to_s : ".#{part}" }.join
      end

      def pretty_arguments(arguments)
        JSON.pretty_generate(arguments)
      rescue JSON::GeneratorError
        arguments.inspect
      end

      # Rule failures carry the exact string as text; dry's sum-type
      # messages (integer-or-float) answer to_s instead.
      def message_text(message)
        message.respond_to?(:text) ? message.text : message.to_s
      end
    end
  end
end
