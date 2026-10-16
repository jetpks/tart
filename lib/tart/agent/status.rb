# frozen_string_literal: true

module Tart
  module Agent
    # The minimal status surface for streaming agent content (BRIEF §4, no
    # new TUI): accumulates streamed text deltas and the tool-call lifecycle
    # into a one-line status string, callable directly as a Core::Loop
    # renderer proc. No mutex (de-bridged I50): on_event and to_s both run
    # on fibers of the ONE reactor thread — plain instance state suffices.
    class Status
      def initialize
        @text = +""
        @tool = nil
        @interrupted = false
      end

      # Event sink: pass as the agent loop's on_event alongside your own.
      def on_event(event)
        case event[:type]
        when :message_update
          chunk = event[:chunk]
          @text << chunk.content if chunk.content.is_a?(String) && !chunk.content.empty?
        when :tool_execution_start
          @tool = event[:tool_call].name
        when :tool_execution_end
          @tool = nil
        when :agent_end
          @interrupted = event[:interrupted] == true
        end
      end

      # @return [String] the status line (renderer-compatible: #call).
      def to_s
        return "interrupted" if @interrupted
        return "tool: #{@tool}" if @tool

        tail = @text[-120..]
        tail&.empty? ? "" : (tail || "")
      end

      def call
        to_s
      end

      # Reset the accumulated text at the start of a new turn.
      def reset!
        @text = +""
        self
      end
    end
  end
end
