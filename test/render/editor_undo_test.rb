# frozen_string_literal: true

require_relative "../test_helper"

module Tart
  # The editor undo op (I39): pi editor.test.ts's describe("Undo") block
  # (editor.test.ts:1597+) adapted to the port's op names, plus the
  # clear-semantics split (setText("")-undoable vs submitValue-clears)
  # and the kill-ring interactions. Drives the Editor directly; cursors
  # assert on cursor_line/cursor_col.
  class EditorUndoTest < Test
    def test_undo_on_an_empty_stack_is_a_no_op
      editor = Render::Editor.new
      editor.undo
      assert_equal "", editor.input
      assert_equal [0, 0], [editor.cursor_line, editor.cursor_col]
    end

    def test_undo_past_the_first_snapshot_is_a_no_op
      editor = Render::Editor.new
      editor.insert("hi")
      editor.undo
      editor.undo
      assert_equal "", editor.input, "popping an empty stack after the first undo changes nothing"
    end

    # pi editor.test.ts:1605-1621 — "hello world" → undo → "hello" → undo → "".
    def test_consecutive_word_chars_coalesce_into_one_undo_unit
      editor = Render::Editor.new
      "hello world".each_char { |char| editor.insert(char) }
      assert_equal "hello world", editor.input
      editor.undo
      assert_equal "hello", editor.input, "the space captured the pre-space state — ' world' goes as one unit"
      editor.undo
      assert_equal "", editor.input, "'hello' is one typing unit"
    end

    def test_spaces_undo_one_at_a_time
      editor = Render::Editor.new
      "hello  ".each_char { |char| editor.insert(char) }
      assert_equal "hello  ", editor.input
      editor.undo
      assert_equal "hello ", editor.input
      editor.undo
      assert_equal "hello", editor.input
      editor.undo
      assert_equal "", editor.input
    end

    def test_newlines_undo_and_the_next_word_is_its_own_unit
      editor = Render::Editor.new
      "hello".each_char { |char| editor.insert(char) }
      editor.add_new_line
      "world".each_char { |char| editor.insert(char) }
      assert_equal "hello\nworld", editor.input
      editor.undo
      assert_equal "hello\n", editor.input, "'world' coalesces as its own unit (the newline reset the window)"
      editor.undo
      assert_equal "hello", editor.input, "the newline unit restores the pre-split line"
      editor.undo
      assert_equal "", editor.input
    end

    def test_backspace_undoes
      editor = Render::Editor.new
      "hello".each_char { |char| editor.insert(char) }
      editor.delete_backward
      assert_equal "hell", editor.input
      editor.undo
      assert_equal "hello", editor.input
      assert_equal [0, 5], [editor.cursor_line, editor.cursor_col], "the cursor restores with the text"
    end

    def test_backspace_at_a_line_start_merges_and_undoes
      editor = Render::Editor.new
      editor.insert("a")
      editor.add_new_line # cursor (1,0)
      editor.delete_backward # the col-0 branch merges upward
      assert_equal "a", editor.input
      editor.undo
      assert_equal "a\n", editor.input
      assert_equal [1, 0], [editor.cursor_line, editor.cursor_col], "the multi-line cursor restores"
    end

    def test_forward_delete_undoes
      editor = Render::Editor.new
      "hello".each_char { |char| editor.insert(char) }
      editor.move_start
      editor.move_right
      editor.delete_forward
      assert_equal "hllo", editor.input
      editor.undo
      assert_equal "hello", editor.input
      assert_equal [0, 1], [editor.cursor_line, editor.cursor_col]
    end

    def test_delete_word_backward_undoes
      editor = editor_with("hello world")
      editor.delete_word_backward
      assert_equal "hello ", editor.input, "the separator space stays (the kill boundary)"
      editor.undo
      assert_equal "hello world", editor.input
    end

    def test_delete_word_forward_undoes
      editor = editor_with("hello world")
      editor.move_start
      editor.delete_word_forward
      assert_equal " world", editor.input, "the leading separator stays (the kill boundary — pi's mirror of ctrl+w)"
      editor.undo
      assert_equal "hello world", editor.input
      assert_equal [0, 0], [editor.cursor_line, editor.cursor_col]
    end

    # pi editor.test.ts:1740-1760 — the ctrl+k undo with the post-undo
    # mid-line typing assertion; the port pins the cursor directly too.
    def test_delete_to_line_end_undo_restores_text_and_cursor
      editor = editor_with("hello world")
      editor.move_start
      6.times { editor.move_right }
      editor.delete_to_line_end
      assert_equal "hello ", editor.input
      editor.undo
      assert_equal "hello world", editor.input
      assert_equal [0, 6], [editor.cursor_line, editor.cursor_col], "the cursor restores to the kill position"
      editor.insert("|")
      assert_equal "hello |world", editor.input, "pi's post-undo mid-line typing assertion"
    end

    def test_delete_to_line_start_undo_restores_text_and_cursor
      editor = editor_with("hello world")
      editor.move_start
      6.times { editor.move_right }
      editor.delete_to_line_start
      assert_equal "world", editor.input
      editor.undo
      assert_equal "hello world", editor.input
      assert_equal [0, 6], [editor.cursor_line, editor.cursor_col]
    end

    def test_delete_to_line_end_newline_merge_undoes
      editor = Render::Editor.new
      editor.insert("a")
      editor.add_new_line
      editor.insert("b") # two logical lines, cursor (1,1)
      2.times { editor.move_left } # (1,0) → wrapping up to (0,1) — the end of "a"
      editor.delete_to_line_end # the end-of-line branch kills the "\n", merging downward
      assert_equal "ab", editor.input
      editor.undo
      assert_equal "a\nb", editor.input
      assert_equal [0, 1], [editor.cursor_line, editor.cursor_col]
    end

    def test_yank_undoes
      editor = Render::Editor.new
      "hello ".each_char { |char| editor.insert(char) }
      editor.delete_word_backward # kills "hello "
      editor.yank
      assert_equal "hello ", editor.input
      editor.undo
      assert_equal "", editor.input, "the yanked span is removed — one undo per yank"
    end

    def test_yank_pop_undoes
      editor = Render::Editor.new
      editor.insert("first")
      editor.delete_to_line_start
      editor.insert("x") # typing re-opens the windows — a fresh ring entry
      editor.delete_to_line_start
      editor.yank
      assert_equal "x", editor.input
      editor.yank_pop
      assert_equal "first", editor.input
      editor.undo
      assert_equal "x", editor.input, "the yank-pop pushed its own snapshot — one undo removes the popped span"
    end

    def test_single_line_paste_undoes_atomically
      editor = editor_with("hello world")
      editor.move_start
      5.times { editor.move_right }
      editor.insert_paste("beep boop")
      assert_equal "hellobeep boop world", editor.input
      editor.undo
      assert_equal "hello world", editor.input, "ONE undo restores the whole pre-paste state"
      assert_equal [0, 5], [editor.cursor_line, editor.cursor_col], "the cursor restores too"
      editor.insert("|")
      assert_equal "hello| world", editor.input
    end

    def test_multi_line_paste_undoes_atomically
      editor = editor_with("hello world")
      editor.move_start
      5.times { editor.move_right }
      editor.insert_paste("line1\nline2\nline3")
      assert_equal "helloline1\nline2\nline3 world", editor.input
      editor.undo
      assert_equal "hello world", editor.input, "a multi-line paste is ONE undo unit"
      assert_equal [0, 5], [editor.cursor_line, editor.cursor_col], "the multi-line cursor restores (line AND col)"
      editor.insert("|")
      assert_equal "hello| world", editor.input
    end

    def test_undo_restores_the_cursor_across_wrapped_rows
      editor = Render::Editor.new
      long_line = "one two three four five six seven eight nine ten" # wraps at narrow widths
      long_line.each_char { |char| editor.insert(char) }
      editor.add_new_line
      editor.insert("second")
      editor.undo # removes "second"
      assert_equal [1, 0], [editor.cursor_line, editor.cursor_col]
      editor.undo # removes the newline — back to the long wrapped line's end
      assert_equal long_line, editor.input
      assert_equal [0, long_line.length], [editor.cursor_line, editor.cursor_col], "the logical cursor restores across the wrap"
    end

    # --- the kill-ring interactions (the INTERACTION CONTRACT): undo
    # restores text, never ring contents; undo closes both windows. ---

    def test_undo_never_touches_the_ring
      editor = editor_with("abc")
      editor.move_start
      editor.delete_to_line_end # ring: ["abc"], text ""
      editor.yank
      assert_equal "abc", editor.input
      editor.undo # back to "" — the ring is NOT part of the snapshot
      editor.yank
      assert_equal "abc", editor.input, "kill → yank → undo → yank: the ring survived the undo untouched"
    end

    def test_undo_breaks_the_kill_accumulate_window
      editor = editor_with("one two three")
      editor.delete_word_backward # kills "three"
      editor.delete_word_backward # accumulates: still ONE ring entry (" two"+"three")
      assert_equal "one ", editor.input, "the separator space stays (the kill boundary)"
      editor.undo # restores the second kill's pre-state ("one two ") and nils last_action
      editor.delete_word_backward # a FRESH entry — the window is broken
      editor.yank
      assert_equal "one two ", editor.input,
        "yank gets the third kill ALONE — had the window held, the kill would have merged and yanked ' two three'"
    end

    def test_undo_breaks_the_yank_pop_window
      editor = Render::Editor.new
      editor.insert("first")
      editor.delete_to_line_start
      editor.insert("x")
      editor.delete_to_line_start
      editor.yank
      assert_equal "x", editor.input
      editor.undo
      editor.yank_pop
      assert_equal "", editor.input, "yank_pop after undo is a no-op — last_action was niled, not :yank"
    end

    # pi pushes at every applyCompletion site — a tab-applied completion
    # is undoable (the port's replace_token is the apply write surface).
    def test_replace_token_undo_restores_the_pre_apply_text_and_cursor
      editor = editor_with("/new")
      editor.replace_token(1, "architect ", 11) # the autocomplete's apply surgery
      assert_equal "/architect ", editor.input
      editor.undo
      assert_equal "/new", editor.input
      assert_equal [0, 4], [editor.cursor_line, editor.cursor_col], "the pre-apply cursor restores"
    end

    # pi navigateHistory :465 pushes when browsing starts — the pre-browse
    # draft is one undo away.
    def test_entering_history_browsing_pushes_so_undo_restores_the_draft
      editor = Render::Editor.new
      editor.insert("draft text")
      editor.add_to_history("older entry")
      editor.history_previous
      assert_equal "older entry", editor.input
      editor.undo
      assert_equal "draft text", editor.input
      assert_equal [0, 10], [editor.cursor_line, editor.cursor_col]
    end

    # --- the two clear semantics (D2): clear is pi's setText("") analog
    # (undoable); the submit surface clears the stack. ---

    def test_clear_is_undoable
      editor = editor_with("hello world")
      editor.move_start
      5.times { editor.move_right }
      editor.clear # the escape bash-mode / ctrl+c surface
      assert_equal "", editor.input
      editor.undo
      assert_equal "hello world", editor.input, "pi editor.ts:1120-1124 — the clear is UNDOABLE"
      assert_equal [0, 5], [editor.cursor_line, editor.cursor_col], "text AND cursor restore"
    end

    def test_clear_on_an_empty_buffer_pushes_nothing
      editor = Render::Editor.new
      editor.clear
      editor.undo
      assert_equal "", editor.input, "a following undo is a no-op — clearing an empty buffer pushed nothing"
    end

    def test_submit_clears_the_stack
      editor = editor_with("hello world")
      editor.clear             # chat.rb submit's sequence (pi submitValue)
      editor.clear_undo_stack
      editor.undo
      assert_equal "", editor.input, "pi submitValue :1373 — after submit, undo is a no-op"
    end

    # --- the registry rides the snapshot (I55, pi :2116-2134). Name
    # filter /marker/ is the AC gate contract (D8). ---

    def test_marker_delete_then_undo_restores_text_and_registry
      editor = Render::Editor.new
      content = (1..11).map { |i| "a#{i}" }.join("\n")
      editor.insert_paste(content) # [paste #1 +11 lines], cursor at its end
      editor.delete_backward # the marker arm: whole span + registry drop
      assert_equal "", editor.input
      assert_empty editor.pastes
      editor.undo
      assert_equal "[paste #1 +11 lines]", editor.input, "the marker text restores"
      assert_equal content, editor.pastes[1], "the registry restores with the state triple (pi :2130-2131)"
      assert_equal 1, editor.paste_counter
      assert_equal content, editor.expanded_text, "the round-trip is byte-exact"
    end

    def test_paste_over_marker_is_one_undo_unit
      editor = Render::Editor.new
      content = (1..11).map { |i| "a#{i}" }.join("\n")
      editor.insert_paste(content)
      editor.insert_paste(content) # the paste-over arm + the new marker
      editor.undo
      assert_equal "[paste #1 +11 lines]", editor.input, "ONE undo restores the marker"
      assert_equal content, editor.pastes[1], "the registry restores — the owner arm is part of the ONE paste unit"
      assert_equal 1, editor.paste_counter
    end

    def test_set_text_clears_the_marker_registry_and_undo_restores_it
      editor = Render::Editor.new
      content = (1..11).map { |i| "a#{i}" }.join("\n")
      editor.insert_paste(content)
      editor.set_text("fresh")
      assert_equal "fresh", editor.input
      assert_empty editor.pastes, "pi setText :1124-1125 — the registry clears"
      assert_equal 0, editor.paste_counter
      assert_equal "fresh", editor.expanded_text
      editor.undo
      assert_equal "[paste #1 +11 lines]", editor.input, "the clear was ONE undo away"
      assert_equal content, editor.pastes[1], "the snapshot carried the OLD registry (the push precedes the clear)"
    end

    def test_paste_marker_clear_also_clears_the_registry_and_undo_restores
      editor = Render::Editor.new
      content = (1..11).map { |i| "a#{i}" }.join("\n")
      editor.insert_paste(content)
      editor.clear # the clearEditor → setText("") realization
      assert_empty editor.pastes
      assert_equal 0, editor.paste_counter
      editor.undo
      assert_equal "[paste #1 +11 lines]", editor.input
      assert_equal content, editor.pastes[1], "the clear is undoable WITH the registry"
    end

    private

    def editor_with(text)
      editor = Render::Editor.new
      editor.insert(text)
      editor.move_end
      editor
    end
  end
end
