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
      rescue StandardError => e
        {error: e.message}
      end
    end
  end
end
