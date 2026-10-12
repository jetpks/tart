# frozen_string_literal: true

module Tart
  module Render
    # Ring buffer for emacs-style kill/yank operations (1:1 port of pi
    # kill-ring.ts). Tracks killed (deleted) text entries; consecutive
    # kills can accumulate into a single entry, and yank-pop cycles
    # oldest-ward through the ring.
    class KillRing
      def initialize
        @ring = []
      end

      # pi push (kill-ring.ts:24): a nil/empty text is a no-op; accumulate
      # merges into the most recent entry — prepend for a backward
      # deletion, append for a forward one.
      def push(text, prepend:, accumulate: false)
        return if text.nil? || text.empty?

        if accumulate && !@ring.empty?
          last = @ring.pop
          @ring << (prepend ? text + last : last + text)
        else
          @ring << text
        end
      end

      # Most recent entry without modifying the ring (nil when empty).
      def peek = @ring.last

      # Move the newest entry oldest-ward (pi kill-ring.ts:46 — the
      # yank-pop cycle).
      def rotate
        @ring.unshift(@ring.pop) if @ring.size > 1
      end

      def length = @ring.size
    end
  end
end
