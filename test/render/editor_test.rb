# frozen_string_literal: true

require_relative "../test_helper"

module Tart
  # The input-line editor's state behavior (I22 wave 2): the moved
  # editor-state tests — input edits, cursor readback, history recall,
  # word boundaries, word jumps, insert-printable — driving Editor
  # directly. The Chat coordinator's key dispatch stays covered in
  # test/chat_test.rb.
  class EditorTest < Test
    def test_printable_characters_insert_at_the_cursor
      editor = Render::Editor.new
      editor.insert_printable(TUI.key_event("h"))
      editor.insert_printable(TUI.key_event("i"))
      editor.move_left
      editor.insert_printable(TUI.key_event("X"))
      assert_equal "hXi", editor.input, "a printable character inserts at the cursor"
      editor.move_left
      editor.move_left
      editor.insert_printable(TUI.key_event("!"))
      assert_equal "!hXi", editor.input, "inserting at the start of the line"
    end

    def test_backspace_deletes_before_and_forward_delete_after_the_cursor
      editor = Render::Editor.new
      editor.insert("hi")
      editor.move_left
      editor.delete_backward
      assert_equal "i", editor.input, "backspace deletes before the cursor"
      editor.delete_forward
      assert_equal "", editor.input, "forward-delete removes the character after the cursor"
      editor.delete_forward
      assert_equal "", editor.input, "forward-delete at end-of-input is a no-op"
      editor.insert("ab")
      editor.move_start
      editor.delete_forward
      assert_equal "b", editor.input, "forward-delete at line start removes the first character"
    end

    def test_home_end_and_ctrl_b_f_move_the_cursor
      editor = Render::Editor.new
      editor.insert("abcd")
      editor.move_start
      assert_equal 0, editor.cursor, "home jumps to line start"
      editor.insert_printable(TUI.key_event("X"))
      assert_equal "Xabcd", editor.input, "home jumps to line start"
      editor.move_right # over 'a'
      editor.move_right # over 'b'
      editor.insert_printable(TUI.key_event("Y"))
      assert_equal "XabYcd", editor.input, "ctrl+f steps right one character"
      editor.move_left
      editor.insert_printable(TUI.key_event("Z"))
      assert_equal "XabZYcd", editor.input, "ctrl+b steps left one character"
      editor.move_end
      assert_equal 7, editor.cursor, "ctrl+e jumps to line end"
      editor.insert_printable(TUI.key_event("!"))
      assert_equal "XabZYcd!", editor.input, "ctrl+e jumps to line end"
    end

    # --- history (I06/AC3): pi's editor.ts addToHistory/navigateHistory —
    # most recent first, draft restored, recalled entries editable. ---

    def test_history_recalls_entries_in_order
      editor = Render::Editor.new
      editor.add_to_history("A")
      editor.add_to_history("B")
      editor.history_previous
      assert_equal "B", editor.input, "up recalls the most recent entry"
      editor.history_previous
      assert_equal "A", editor.input, "up again walks to older entries"
      editor.history_next
      assert_equal "B", editor.input, "down returns toward the draft"
      editor.history_next
      assert_equal "", editor.input, "down past the newest entry restores the live draft"
    end

    def test_history_skips_consecutive_duplicates
      editor = Render::Editor.new
      editor.add_to_history("A")
      editor.add_to_history("A")
      editor.history_previous
      assert_equal "A", editor.input, "a duplicate submission enters history once"
      editor.history_next
      assert_equal "", editor.input, "down past the newest entry restores the empty draft"
      editor.history_previous
      editor.history_previous
      assert_equal "A", editor.input, "history holds a single entry — walking past it is a no-op"
    end

    # --- word-wise operations (I06/AC3): pi's word-navigation.ts boundary
    # semantics — skip trailing whitespace, then one word/punctuation run. ---

    def test_find_word_backward_boundaries
      assert_equal 6, Render::Editor.find_word_backward("hello world", 11),
        "deletes 'world' but keeps the separator space (pi segment semantics)"
      assert_equal 0, Render::Editor.find_word_backward("hello ", 6), "trailing whitespace goes with the word"
      assert_equal 4, Render::Editor.find_word_backward("foo.bar", 7), "ASCII punctuation stays a boundary"
      assert_equal 3, Render::Editor.find_word_backward("foo.", 4), "a punctuation run goes as one unit"
      assert_equal 0, Render::Editor.find_word_backward("hi", 0)
      assert_equal 0, Render::Editor.find_word_backward("", 0)
    end

    def test_find_word_forward_boundaries
      assert_equal 5, Render::Editor.find_word_forward("hello world", 0)
      assert_equal 11, Render::Editor.find_word_forward("hello world", 5), "whitespace skipped to the next word"
      assert_equal 2, Render::Editor.find_word_forward("hi.", 0), "a word stops at the punctuation"
      assert_equal 3, Render::Editor.find_word_forward("hi.", 2), "a punctuation run is one unit"
      assert_equal 2, Render::Editor.find_word_forward("hi", 3), "at end-of-line the cursor stays put"
    end

    def test_alt_b_alt_f_jump_words
      editor = Render::Editor.new
      editor.insert("hello world")
      editor.move_word_backward
      assert_equal 6, editor.cursor, "alt+b jumps one word backward"
      editor.insert_printable(TUI.key_event("X"))
      assert_equal "hello Xworld", editor.input, "alt+b jumps one word backward"
      editor.move_word_backward
      editor.insert_printable(TUI.key_event("Y"))
      assert_equal "hello YXworld", editor.input, "alt+b from the last word jumps to its start"
      editor.move_word_forward
      editor.insert_printable(TUI.key_event("Z"))
      assert_equal "hello YXworldZ", editor.input, "alt+f jumps one word forward"
    end
  end
end
