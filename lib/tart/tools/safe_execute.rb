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

      private

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
      rescue RubyLLM::CancelledError
        raise
      rescue StandardError => e
        {error: e.message}
      end
    end
  end
end
