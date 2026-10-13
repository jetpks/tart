# frozen_string_literal: true

module Tart
  module Render
    # Generic undo stack with clone-on-push semantics (1:1 port of pi
    # undo-stack.ts). Stores deep copies of state snapshots; popped
    # snapshots are returned directly (no re-clone) since they are
    # already detached. Dumb by design: no cap, no redo, no knowledge of
    # the Editor. Ruby has no structuredClone — {deep_copy} is the
    # equivalent over the value shapes an Editor snapshot can hold
    # (Array / Hash / String / Struct members); every other value is
    # immutable in Ruby and passes through as-is.
    class UndoStack
      def initialize
        @stack = []
      end

      # Push a deep copy of +state+ (pi push — the clone happens at push
      # time, so the caller's later mutations stay invisible).
      def push(state)
        @stack.push(self.class.deep_copy(state))
      end

      # Pop and return the most recent snapshot, nil when empty (pi pop
      # — the snapshot is already detached).
      def pop
        @stack.pop
      end

      # Remove all snapshots (pi clear — `stack.length = 0`).
      def clear
        @stack = []
      end

      def length = @stack.size

      # The structuredClone equivalent: a fresh deep copy over Array /
      # Hash / String / Struct members. Structs rebuild member-wise —
      # keyword_init structs reject positional new, and member-wise
      # construction fits every Struct shape.
      def self.deep_copy(value)
        case value
        when Array then value.map { |item| deep_copy(item) }
        when Hash then value.each_with_object({}) { |(key, item), copy| copy[deep_copy(key)] = deep_copy(item) }
        when String then value.dup
        when Struct
          value.class.new.tap do |copy|
            value.members.each { |member| copy[member] = deep_copy(value[member]) }
          end
        else value
        end
      end
    end
  end
end
