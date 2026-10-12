# frozen_string_literal: true

require_relative "../test_helper"

module Tart
  # The kill ring + the editor kill/yank ops (I26): the emacs slice, pinned
  # on the public surface (pi kill-ring.ts + editor.test.ts's "Kill ring"
  # describe block, ported to the single-line editor — the multiline
  # line-merge branches are the itemized cut).
  class KillRingTest < Test
    # --- KillRing (pi kill-ring.ts) ---

    def test_push_peek_rotate_and_length
      ring = Render::KillRing.new
      assert_equal 0, ring.length
      assert_nil ring.peek, "an empty ring peeks nil"
      ring.push("a", prepend: false)
      ring.push("b", prepend: false)
      assert_equal "b", ring.peek
      assert_equal 2, ring.length
      ring.rotate
      assert_equal "a", ring.peek, "rotate moves the newest entry oldest-ward"
      ring.rotate
      assert_equal "b", ring.peek, "rotate cycles back"
    end

    def test_nil_and_empty_pushes_are_no_ops
      ring = Render::KillRing.new
      ring.push("", prepend: false)
      ring.push(nil, prepend: false)
      assert_equal 0, ring.length, "kill-ring.ts:24 — `if (!text) return;`"
    end

    def test_accumulate_prepends_or_appends_onto_the_newest_entry
      ring = Render::KillRing.new
      ring.push("hello ", prepend: true)
      ring.push("world", prepend: false, accumulate: true)
      assert_equal "hello world", ring.peek, "a forward kill appends"
      ring.push("x", prepend: true, accumulate: true)
      assert_equal "xhello world", ring.peek, "a backward kill prepends"
    end

    def test_accumulate_onto_an_empty_ring_starts_a_fresh_entry
      ring = Render::KillRing.new
      ring.push("a", prepend: false, accumulate: true)
      assert_equal "a", ring.peek
      assert_equal 1, ring.length
    end

    # --- the editor kill/yank ops (pi editor.test.ts "Kill ring") ---

    def test_consecutive_kills_accumulate_into_one_entry
      editor = editor_with_text("one two three")
      editor.delete_word_backward
      editor.delete_word_backward
      editor.delete_word_backward
      assert_equal "", editor.input
      editor.yank
      assert_equal "one two three", editor.input,
        "kill, kill, kill accumulates into ONE ring entry (editor.test.ts:1311)"
    end

    def test_backward_kills_prepend_and_forward_kills_append
      editor = editor_with_text("hello world")
      editor.move_start
      6.times { editor.move_right }
      editor.delete_to_line_start # backward kill: "hello "
      assert_equal "world", editor.input
      editor.delete_to_line_end # forward kill: "world"
      assert_equal "", editor.input
      editor.yank
      assert_equal "hello world", editor.input,
        "one accumulated entry, ordered 'hello ' + 'world' (prepend/append)"
      assert_equal 11, editor.cursor
    end

    def test_an_intervening_non_kill_breaks_the_accumulate_window
      editor = editor_with_text("foo bar baz")
      editor.delete_word_backward # kills "baz"
      editor.insert("x") # typing closes the window (editor.test.ts:1374)
      assert_equal "foo bar x", editor.input
      editor.delete_word_backward # kills "x" — a separate entry
      assert_equal "foo bar ", editor.input
      editor.yank
      assert_equal "foo bar x", editor.input, "yank gets the newest entry, not the accumulation"
      editor.yank_pop
      assert_equal "foo bar baz", editor.input, "cycling back reaches the older, un-merged entry"
    end

    def test_yank_inserts_the_most_recent_entry_at_the_cursor
      editor = editor_with_text("hello world")
      editor.move_start
      5.times { editor.move_right }
      editor.delete_to_line_end # kills " world"
      editor.move_start
      editor.yank
      assert_equal " worldhello", editor.input, "yank inserts at the cursor (editor.test.ts:1496)"
      assert_equal 6, editor.cursor
    end

    def test_yank_is_a_no_op_on_an_empty_ring
      editor = editor_with_text("test")
      editor.yank
      assert_equal "test", editor.input, "ctrl+y does nothing when the ring is empty"
    end

    def test_yank_pop_without_a_prior_yank_is_a_no_op
      editor = Render::Editor.new
      editor.insert("first")
      editor.delete_to_line_start # kills "first"
      editor.insert("x") # typing closes the yank window (editor.test.ts:1397)
      editor.yank_pop
      assert_equal "x", editor.input
    end

    def test_yank_pop_with_a_one_entry_ring_is_a_no_op
      editor = editor_with_text("only")
      editor.delete_to_line_end
      editor.yank
      editor.yank_pop
      assert_equal "only", editor.input, "a single entry never cycles (editor.test.ts:1298)"
    end

    def test_yank_pop_cycles_oldest_ward
      editor = Render::Editor.new
      %w[first second third].each do |word|
        editor.insert(word)
        editor.delete_to_line_start # the insert re-opens the window — fresh entries
      end
      editor.yank
      assert_equal "third", editor.input, "yank takes the most recent entry"
      editor.yank_pop
      assert_equal "second", editor.input
      editor.yank_pop
      assert_equal "first", editor.input
      editor.yank_pop
      assert_equal "third", editor.input, "the cycle wraps oldest-ward (editor.test.ts:1255)"
    end

    def test_kill_ring_rotation_persists_after_cycling
      editor = Render::Editor.new
      %w[first second third].each do |word|
        editor.insert(word)
        editor.delete_to_line_start
      end
      editor.yank
      editor.yank_pop # ring rotated: the new peek is "second"
      editor.delete_to_line_start # a fresh kill does not disturb the rotation
      editor.yank
      assert_equal "second", editor.input, "the rotation survives past the cycle (editor.test.ts:1416)"
    end

    def test_a_kill_exits_history_browsing
      editor = Render::Editor.new
      editor.insert("live draft")
      editor.add_to_history("older")
      editor.history_previous
      assert_equal "older", editor.input
      editor.delete_to_line_end # pi editor.ts:1627 — the kill leaves browsing first
      assert_equal "", editor.input, "the kill edits the browsed line"
      editor.history_next
      assert_equal "", editor.input, "browsing ended — down does not restore the draft mid-kill-window"
    end

    def test_multi_line_killed_text_yanks_as_one_span
      editor = editor_with_text("a\nb")
      editor.delete_to_line_start
      assert_equal "", editor.input
      editor.yank
      assert_equal "a\nb", editor.input, "the cut is itemized whole — no silent merge"
    end

    private

    def editor_with_text(text)
      editor = Render::Editor.new
      editor.insert(text)
      editor.move_end
      editor
    end
  end
end
