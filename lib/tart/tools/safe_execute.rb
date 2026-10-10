# frozen_string_literal: true

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
