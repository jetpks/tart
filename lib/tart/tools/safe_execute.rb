# frozen_string_literal: true

require_relative "../schemas/tools"

module Tart
  module Tools
    # Shared behavior of the built-in tools: every execution failure comes
    # back to the model as an {error: message} result (pi's agent loop turns
    # tool errors into error tool results), never as a loop crash. Cancellation
    # always propagates.
    module SafeExecute
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        # The name the model calls this tool by; explicit so class renames
        # never change the wire name.
        def pi_name(name = nil)
          @pi_name = name unless name.nil?
          @pi_name
        end
      end

      def name
        self.class.pi_name
      end

      # The compaction estimate's schema reader — the wire's parameters
      # (the gem's verbatim declaration), one reader for the estimate and
      # the tests.
      def parameters_schema
        self.class.parameters
      end

      # The execution seam (the replaced client's Tool#call contract — the
      # batch executor and the ToolGate land here): the provider's parsed
      # arguments speak string keys, the schema speaks symbols; the
      # +tool_call+ duck rides only when #execute declares the keyword
      # (the replaced client's execute_accepts_tool_call? idiom).
      def call(tool_call: nil, **arguments)
        normalized = arguments.transform_keys(&:to_sym)
        normalized[:tool_call] = tool_call if tool_call && execute_accepts_tool_call?
        execute(**normalized)
      rescue ArgumentError => e
        # I96 (jetpks/tart#19): a provider shape that cannot bind — a missing
        # required keyword, or an unknown one — raises HERE, before execute's
        # in-body safe_execute rescue and validate_input ever run, and the
        # escape killed the whole session. Consult the I43 seam first (S2) on
        # the raw symbolized arguments minus the +tool_call+ duck: a failure
        # IS the result — dry's canonical `…: is missing` wrapper with the
        # pinned-rule precedence intact. When validation passes (the pure
        # unknown-keyword class) or the name has no registered contract (the
        # KeyError belted away — memory, subagent, contact_supervisor,
        # architect_loop, architect_compact), ONE minted wrapper speaks the
        # binding error as its single failure line, rendered by the seam's
        # own pretty_arguments (S3). Never re-raises; the green path and the
        # present-invalid path (in-body validation on the BOUND kwargs) stay
        # byte-unchanged — pre-dispatch validation was REJECTED (D1): it
        # would re-route those frozen bytes and leave unknown keys crashing.
        received = normalized.reject { |key, _value| key == :tool_call }
        consulted =
          begin
            Schemas::Tools.validate(self.class.pi_name, received)
          rescue KeyError
            nil # a contract-less name: the belt speaks for the seam
          end
        consulted ||
          {error: "Validation failed for tool \"#{self.class.pi_name}\":\n  - #{e.message}\n\n" \
                  "Received arguments:\n#{Schemas::Tools.pretty_arguments(received)}"}
      end

      private

      def execute_accepts_tool_call?
        method(:execute).parameters.any? { |(_kind, param)| param == :tool_call }
      end

      # The I43 input-validation seam — ONE idiom for all seven built-ins:
      # the tool's contract is looked up by wire name ({Schemas::Tools}),
      # keyed off +pi_name+. nil passes; a failure comes back as the
      # {error:} result — the pinned in-tool strings byte-exact where they
      # exist (bash timeout, edit edits), pi's loop-level wrapper shape for
      # the rest. Every execute opens with this inside its safe_execute
      # block, before the runtime work; runtime raises stay raises.
      def validate_input(**arguments)
        Schemas::Tools.validate(self.class.pi_name, arguments)
      end

      def safe_execute
        yield
      rescue Fast::Completions::CancelledError
        raise
        # I94 E5: ArgumentError stays byte-exact (pi's deliberate
        # contract-raise idiom — every golden error case); every other
        # StandardError is an internal defect and carries the class + first
        # backtrace line, so the model sees WHAT broke and WHERE.
      rescue StandardError => e
        site = e.backtrace&.first
        message = e.is_a?(ArgumentError) ? e.message : "#{e.class}: #{e.message}#{" (at #{site})" if site}"
        {error: message}
      end
    end
  end
end
