# frozen_string_literal: true

require_relative "../test_helper"

module Tart
  # The undo stack (I39): pi undo-stack.ts 1:1 — clone-on-push, detached
  # pops, clear, length; no cap, no redo. Direct-class (the
  # kill_ring_test.rb precedent).
  class UndoStackTest < Test
    def test_lifo_push_pop_and_length
      stack = Render::UndoStack.new
      assert_equal 0, stack.length
      assert_nil stack.pop, "an empty stack pops nil (pi returns undefined)"
      stack.push("first")
      stack.push("second")
      assert_equal 2, stack.length
      assert_equal "second", stack.pop, "the most recent push pops first"
      assert_equal "first", stack.pop
      assert_equal 0, stack.length
    end

    def test_clear_empties_the_stack
      stack = Render::UndoStack.new
      stack.push("a")
      stack.push("b")
      stack.clear
      assert_equal 0, stack.length
      assert_nil stack.pop
    end

    def test_push_deep_copies_so_later_source_mutations_are_invisible
      stack = Render::UndoStack.new
      lines = ["hello".dup, "world".dup] # unfrozen — the test mutates them in place after the push
      snapshot = Render::Editor::Snapshot.new(lines: lines, cursor_line: 1, cursor_col: 3)
      stack.push(snapshot)

      lines << "mutated"        # array grows after the push
      lines[0] << "!"           # in-place string mutation after the push
      snapshot.cursor_line = 99 # struct member mutated after the push

      popped = stack.pop
      assert_equal ["hello", "world"], popped.lines, "the pop returns the pre-mutation deep copy (pi structuredClone)"
      assert_equal 1, popped.cursor_line
      assert_equal 3, popped.cursor_col
    end

    def test_deep_copy_covers_nested_arrays_hashes_strings_and_structs
      original = {
        lines: ["a", ["b", "c"]],
        row: Render::Editor::LayoutRow.new(text: "d", has_cursor: true, cursor_pos: 1),
        count: 3,
        flag: nil,
      }
      copy = Render::UndoStack.deep_copy(original)
      assert_equal original, copy, "the deep copy equals the original"
      refute_same original, copy
      copy[:lines][1] << "mutated"
      copy[:row].text << "!"
      assert_equal ["b", "c"], original[:lines][1], "nested arrays copy"
      assert_equal "d", original[:row].text, "struct members copy (keyword_init structs included)"
    end

    def test_scalars_pass_through_unchanged
      [nil, true, false, 42, 3.14, :sym].each do |scalar|
        assert_same scalar, Render::UndoStack.deep_copy(scalar), "immutable scalars return as-is"
      end
      copy = Render::UndoStack.deep_copy("str")
      assert_equal "str", copy
      refute_same "str", copy, "strings dup"
    end

    def test_pop_returns_a_detached_snapshot
      stack = Render::UndoStack.new
      lines = ["x"]
      stack.push(Render::Editor::Snapshot.new(lines: lines, cursor_line: 0, cursor_col: 0))
      popped = stack.pop
      popped.lines << "y"
      assert_equal ["x"], lines, "mutating the popped snapshot never reaches the source (no re-clone, already detached)"
    end
  end
end
