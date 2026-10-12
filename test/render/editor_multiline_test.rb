# frozen_string_literal: true

require_relative "../test_helper"

module Tart
  # The multi-line editor's visual-line model (I35): the wrap chunker and
  # the visual map, cross-line motions through pi's sticky-column table,
  # real newlines + paste, the boundary kill arms, multi-line history,
  # the render window, and the scroll-border label composition — driving
  # Editor directly (pi editor.ts 1.1.0). The Chat coordinator's key
  # dispatch and the drawn box stay covered in test/chat_test.rb.
  class EditorMultilineTest < Test
    def reversed?(span)
      span.style&.modifiers&.to_a&.include?(:reversed)
    end

    def row_text(row)
      row.spans.map(&:content).join
    end

    # --- test list (1): the wrap chunker + the visual map + the render
    # rows — chunk-faithful offsets, the reserved cursor column. ---

    def test_word_wrap_line_chunks_carry_original_line_offsets
      chunks = Render::Editor.word_wrap_line("aaaa bbbb cccc", 9)
      assert_equal [["aaaa ", 0, 5], ["bbbb cccc", 5, 14]],
        chunks.map { |chunk| [chunk[:text], chunk[:start], chunk[:end_]] },
        "the break lands after the last space and the chunk keeps its offsets (pi wordWrapLine)"
    end

    def test_word_wrap_line_forces_breaks_without_an_opportunity
      assert_equal ["aaaa", "aaaa", "aa"], Render::Editor.word_wrap_line("aaaaaaaaaa", 4).map { |c| c[:text] },
        "no whitespace, no backtrack: hard breaks at the width"
    end

    def test_word_wrap_line_is_width_aware_per_char
      assert_equal ["a", "漢", "字"], Render::Editor.word_wrap_line("a漢字", 2).map { |c| c[:text] },
        "CJK cells stay honest (2 cells each; the CJK break-opportunity rule is cut)"
      assert_equal ["漢字", "漢"], Render::Editor.word_wrap_line("漢字漢", 5).map { |c| c[:text] },
        "two 2-cell chars fit width 5; the third forces the break"
    end

    def test_the_visual_line_maps_wrapped_rows_to_logical_positions
      editor = Render::Editor.new
      editor.insert("aaaa bbbb cccc")
      map = editor.build_visual_line_map(9)
      assert_equal [{line: 0, start_col: 0, length: 5}, {line: 0, start_col: 5, length: 9}], map
      assert_equal 0, editor.find_visual_line_at(map, 0, 4), "a col inside the first segment"
      assert_equal 1, editor.find_visual_line_at(map, 0, 14),
        "the cursor at length belongs to the LAST segment of its logical line (pi findVisualLineAt)"
    end

    def test_typing_past_the_row_renders_on_visual_row_two_with_the_fake_cursor
      editor = Render::Editor.new
      editor.insert("aaaa bbbb cccc") # cursor at the end (col 14)
      rows = editor.input_rows(9)
      assert_equal "aaaa ", row_text(rows[0])
      refute rows[0].spans.any? { |span| reversed?(span) }, "row 1 has no cursor"
      tail = rows[1].spans.last
      assert_equal ["bbbb cccc", " "], rows[1].spans.map(&:content),
        "the end-of-input cursor is a highlighted trailing space appended to the row…"
      assert reversed?(tail), "…reversed (it may occupy the reserved last column)"
      assert_equal 2, editor.rendered_rows
    end

    def test_the_cursor_on_a_character_reverses_that_character
      editor = Render::Editor.new
      editor.insert("aaaa bbbb cccc")
      editor.move_start
      editor.move_right # cursor over the second 'a'
      rows = editor.input_rows(9)
      assert reversed?(rows[0].spans[1]), "the grapheme at the insertion point renders inverse-video"
      assert_equal ["a", "a", "aa "], rows[0].spans.map(&:content), "the row splits around the cursor"
    end

    # --- test list (2): up/down across wrapped rows through the
    # P/S/T/U sticky-column table (pi computeVerticalMoveColumn
    # editor.ts:1583-1611; non-last segments clamp to length−1). ---

    def test_cursor_up_clamps_to_the_segment_then_down_restores_the_column
      editor = Render::Editor.new
      editor.insert("aaaa bbbb cccc")
      editor.input_rows(9) # pin the wrap width (pi lastWidth)
      # Cursor at the end (visual row 2, its segment's end): up clamps to
      # row 1's length−1 (a non-last segment) and sets the preferred col.
      editor.cursor_up
      assert_equal [0, 4], [editor.cursor_line, editor.cursor_col],
        "up from a clamped position lands at the non-last segment's length−1 (table row 2)"
      editor.cursor_down
      assert_equal [0, 14], [editor.cursor_line, editor.cursor_col],
        "down restores the preferred column (table row 3: target fits preferred)"
    end

    def test_cursor_up_down_walk_the_visual_rows_with_a_sticky_column
      editor = Render::Editor.new
      editor.insert("aaaa bbbb cccc")
      editor.add_new_line
      editor.insert("abcdefghij")
      editor.input_rows(9)
      assert_equal [1, 10], [editor.cursor_line, editor.cursor_col] # on the wrapped "j" row

      editor.cursor_up # row 3 → row 2: cursor mid-segment (S) keeps the visual col
      assert_equal [1, 1], [editor.cursor_line, editor.cursor_col]
      editor.cursor_up # row 2 → row 1 (line 0's tail segment): S keeps the visual col 1
      assert_equal [0, 6], [editor.cursor_line, editor.cursor_col]
      editor.cursor_up # row 1 → row 0: S keeps the visual col 1
      assert_equal [0, 1], [editor.cursor_line, editor.cursor_col]
      editor.cursor_up # first visual row, col > 0, not browsing: home (pi editor.ts:925-937)
      assert_equal [0, 0], [editor.cursor_line, editor.cursor_col]

      3.times { editor.cursor_down } # walk back down at column 0 (S branch each row)
      assert_equal [1, 9], [editor.cursor_line, editor.cursor_col], "down lands on the last visual row"
    end

    # --- test list (3): home/end go to the LOGICAL line's start/end
    # (pi moveToLineStart/moveToLineEnd, editor.ts:1613-1620 — the
    # entry's "per-visual-row" shorthand is corrected against source). ---

    def test_home_and_end_reach_the_logical_line_across_wrapped_rows
      editor = Render::Editor.new
      editor.insert("aaaa bbbb cccc")
      editor.input_rows(9) # the line wraps: visual row 2 holds cols 5..13
      4.times { editor.move_left } # cursor to col 10 — visual row 2
      editor.move_end
      assert_equal 14, editor.cursor_col, "end is the LOGICAL line's end, not the visual row's"
      editor.move_start
      assert_equal 0, editor.cursor_col, "start is the LOGICAL line's start"
    end

    def test_horizontal_and_word_motions_wrap_across_logical_lines
      editor = Render::Editor.new
      editor.insert("ab")
      editor.add_new_line
      editor.insert("cd")
      3.times { editor.move_left }
      assert_equal [0, 2], [editor.cursor_line, editor.cursor_col], "left wraps to the previous line's end"
      editor.move_right
      assert_equal [1, 0], [editor.cursor_line, editor.cursor_col], "right wraps to the next line's start"

      editor.move_end
      editor.move_word_backward
      assert_equal [1, 0], [editor.cursor_line, editor.cursor_col],
        "word-backward scans to the line start (pi crosses only at col 0)"
      editor.move_word_backward
      assert_equal [0, 2], [editor.cursor_line, editor.cursor_col], "word-backward crosses the boundary at col 0"
      editor.move_word_forward
      assert_equal [1, 0], [editor.cursor_line, editor.cursor_col], "word-forward crosses at the line end"
    end

    # --- test list (4): the kill arms on wrapped rows + the boundary
    # "\n" kills/merges (pi editor.ts:1625-1775), yank/yank_pop across
    # lines (:2028-2112). ---

    def test_kill_to_line_start_and_end_take_the_logical_line_not_the_visual_row
      editor = Render::Editor.new
      editor.insert("aaaa bbbb cccc")
      editor.input_rows(9)
      4.times { editor.move_left } # cursor col 10 — visual row 2's first char
      editor.delete_to_line_start
      assert_equal "cccc", editor.input, "the kill takes the LOGICAL prefix (cols 0..9), not the visual row"
      assert_equal 0, editor.cursor_col

      editor2 = Render::Editor.new
      editor2.insert("aaaa bbbb cccc")
      editor2.move_start
      6.times { editor2.move_right } # col 6 — visual row 1's tail
      editor2.delete_to_line_end
      assert_equal "aaaa b", editor2.input, "the kill takes the LOGICAL suffix"
    end

    def test_kill_ops_merge_lines_with_the_newline_as_the_killed_text
      editor = Render::Editor.new
      editor.insert("ab")
      3.times { editor.add_new_line } # ["ab", "", "", ""]
      editor.insert("x")
      editor.move_start # (3,0)
      editor.delete_to_line_start
      assert_equal ["ab", "", "x"], editor.lines, "ctrl+u at col 0 kills the \\n and merges upward"
      assert_equal [2, 0], [editor.cursor_line, editor.cursor_col]
      editor.delete_to_line_start
      assert_equal ["ab", "x"], editor.lines, "the empty previous line keeps the cursor at col 0"
      editor.delete_to_line_start
      assert_equal ["abx"], editor.lines, "three consecutive boundary kills accumulate in the ring"

      editor2 = Render::Editor.new
      editor2.insert("ab")
      editor2.add_new_line
      editor2.insert("cd")
      editor2.move_start
      editor2.move_left # wraps to (0,2) — line 0's end, the boundary
      editor2.delete_to_line_end
      assert_equal ["abcd"], editor2.lines, "ctrl+e at the line end kills the \\n and merges downward"
      assert_equal [0, 2], [editor2.cursor_line, editor2.cursor_col]

      # Plain backspace / forward-delete at a boundary merge WITHOUT the
      # ring (pi handleBackspace :1432-1443, handleForwardDelete :1806-1815).
      editor3 = Render::Editor.new
      editor3.insert("ab")
      editor3.add_new_line
      editor3.insert("cd")
      editor3.add_new_line
      editor3.insert("ef")
      editor3.move_start # (2,0)
      editor3.delete_backward
      assert_equal ["ab", "cdef"], editor3.lines
      assert_equal [1, 2], [editor3.cursor_line, editor3.cursor_col]
      editor3.move_end # (1,4) — line 1's end, line 2 gone
      editor3.delete_forward
      editor3.move_start
      editor3.move_left # wraps to (0,2) — line 0's end, a boundary
      editor3.delete_forward
      assert_equal ["abcdef"], editor3.lines, "forward-delete at the line end merges downward"
      editor3.yank
      assert_equal "abcdef", editor3.input, "the plain merges pushed nothing into the ring"
    end

    def test_word_deletes_kill_the_newline_at_line_boundaries
      editor = Render::Editor.new
      editor.insert("ab cd")
      editor.add_new_line
      editor.insert("ef")
      editor.move_start
      editor.delete_word_backward
      assert_equal ["ab cdef"], editor.lines, "alt+backspace at col 0 kills the \\n (backward: prepend)"
      assert_equal [0, 5], [editor.cursor_line, editor.cursor_col]

      editor2 = Render::Editor.new
      editor2.insert("ab")
      editor2.add_new_line
      editor2.insert("cd ef")
      editor2.move_start
      editor2.move_left # wraps to (0,2) — line 0's end, a boundary
      editor2.delete_word_forward
      assert_equal ["abcd ef"], editor2.lines, "alt+d at the line end kills the \\n (forward: append)"
      assert_equal [0, 2], [editor2.cursor_line, editor2.cursor_col], "the merge leaves the cursor in place"
    end

    def test_yank_splices_the_accumulated_multi_line_ring_text
      yank = Render::Editor.new
      yank.insert("ab")
      3.times { yank.add_new_line } # ["ab", "", "", ""] cursor (3,0)
      yank.insert("x")
      yank.move_start # (3,0)
      yank.delete_to_line_start             # ring ["\\n"]
      yank.delete_to_line_start             # ACCUMULATES: ring ["\\n\\n"]
      yank.delete_to_line_start             # ring ["\\n\\n\\n"]; lines ["abx"] cursor (0,2)
      assert_equal ["abx"], yank.lines
      yank.yank
      assert_equal ["ab", "", "", "x"], yank.lines,
        "yank splices the multi-line ring text (the suffix rides the last inserted line)"
      assert_equal [3, 0], [yank.cursor_line, yank.cursor_col], "cursor at the inserted tail's end"
    end

    def test_yank_and_yank_pop_splice_across_lines
      editor = Render::Editor.new
      editor.insert("one")
      editor.move_start
      editor.delete_to_line_end            # ring ["one"]
      editor.insert("ab")                  # typing re-arms the window
      editor.add_new_line
      editor.insert("cd")
      editor.move_start                    # (1,0)
      editor.delete_to_line_start          # a fresh \\n kill: merge → ["abcd"], ring ["one", "\\n"]
      assert_equal ["abcd"], editor.lines
      editor.yank                          # the \\n back: the two lines split again
      assert_equal ["ab", "cd"], editor.lines
      assert_equal [1, 0], [editor.cursor_line, editor.cursor_col]
      editor.yank_pop                      # the yanked \\n deletes across lines, the ring rotates
      assert_equal ["abonecd"], editor.lines
      assert_equal [0, 5], [editor.cursor_line, editor.cursor_col]
    end

    # --- test list (6): multi-line history recall. ---

    def test_multi_line_history_recalls_all_rows_with_pis_cursor_placement
      editor = Render::Editor.new
      editor.add_to_history("four")
      editor.add_to_history("one\ntwo\nthree") # most recent first
      editor.insert("d1")
      editor.add_new_line
      editor.insert("d2") # the live draft: ["d1", "d2"], cursor (1,2)

      editor.history_previous
      assert_equal ["one", "two", "three"], editor.lines, "a multi-line entry recalls all rows"
      assert_equal [0, 0], [editor.cursor_line, editor.cursor_col], "up places the cursor at the start"
      editor.history_previous
      assert_equal ["four"], editor.lines, "up walks to the older entry"
      editor.history_next
      assert_equal [2, 5], [editor.cursor_line, editor.cursor_col],
        "down places the cursor at the recalled entry's end"

      editor.history_next
      assert_equal ["d1", "d2"], editor.lines, "the draft restores with its lines and cursor"
      assert_equal [1, 2], [editor.cursor_line, editor.cursor_col]

      editor.history_previous
      editor.move_end
      editor.insert("X")
      assert_equal ["oneX", "two", "three"], editor.lines, "a recalled entry is editable"
    end

    # --- test list (7): newline insertion + paste. ---

    def test_add_new_line_splits_at_the_cursor
      editor = Render::Editor.new
      editor.insert("abcd")
      2.times { editor.move_left }
      editor.add_new_line
      assert_equal ["ab", "cd"], editor.lines, "the line splits at the cursor"
      assert_equal [1, 0], [editor.cursor_line, editor.cursor_col]
    end

    def test_insert_paste_normalizes_and_filters_like_pi
      editor = Render::Editor.new
      editor.insert_paste("a\r\nb\tc")
      assert_equal ["a", "b    c"], editor.lines, "\\r\\n → \\n and tabs → 4 spaces (pi normalizeText)"
      assert_equal [1, 6], [editor.cursor_line, editor.cursor_col], "cursor at the inserted tail"

      editor2 = Render::Editor.new
      editor2.insert_paste("x\x01y\n")
      assert_equal ["xy", ""], editor2.lines, "non-printables drop; \\n is kept (pi handlePaste filter)"

      editor3 = Render::Editor.new
      editor3.insert("ab")
      editor3.move_left
      editor3.insert_paste("X\nY")
      assert_equal ["aX", "Yb"], editor3.lines, "the splice joins the prefix and the suffix"
      assert_equal [1, 1], [editor3.cursor_line, editor3.cursor_col]
    end

    def test_insert_paste_is_not_typing_and_leaves_history_browsing
      editor = Render::Editor.new
      editor.add_to_history("old")
      editor.history_previous
      editor.insert_paste("x")
      editor.history_next
      assert_equal "xold", editor.input,
        "paste left history browsing: down does not walk to the draft (pi handlePaste editor.ts:1263)"

      editor2 = Render::Editor.new
      editor2.insert("a")
      editor2.insert_paste("b")
      assert_nil editor2.instance_variable_get(:@last_action), "paste is not a type-word (pi: lastAction nil)"
    end

    # --- test list (5, editor half): the render window. ---

    def test_max_visible_lines_comes_from_the_rows_reader
      assert_equal 5, Render::Editor.new(rows_reader: -> { 10 }).max_visible_lines,
        "max(5, floor(rows * 0.3)) — the floor holds"
      assert_equal 7, Render::Editor.new.max_visible_lines,
        "the default rows_reader (24) — the same value Chat's screen_height feeds"
    end

    def test_the_window_slides_with_the_cursor_and_pages_back
      editor = Render::Editor.new(rows_reader: -> { 10 }) # 5 visible rows
      5.times { |i| editor.insert("r#{i + 1}"); editor.add_new_line unless i == 4 }
      assert_equal 5, editor.lines.length
      editor.input_rows(80)
      assert_equal 5, editor.rendered_rows, "5 rows fit the 5-row window exactly"
      3.times { editor.add_new_line } # 8 lines now; the cursor is on row 7
      rows = editor.input_rows(80)
      assert_equal 5, editor.rendered_rows, "the window caps at maxVisibleLines"
      assert_equal 3, editor.scroll_offset, "the cursor row stays visible (7 − 5 + 1)"
      assert_equal ["r4", "r5", "", "", " "], rows.map { |row| row_text(row) },
        "the window slides to the cursor (the trailing cell is the reversed cursor space)"
      assert_equal 0, editor.hidden_below

      editor.page_scroll(-1) # the cursor pages to visual row 2
      rows = editor.input_rows(80)
      assert_equal 2, editor.scroll_offset, "the window slides up just enough to show the cursor row"
      assert_equal ["r3", "r4", "r5", "", ""], rows.map { |row| row_text(row) }
      assert_equal 1, editor.hidden_below, "rows hidden below the window feed the ↓ border"
    end

    def test_page_scroll_moves_the_sticky_column_page_and_clamps
      editor = Render::Editor.new
      10.times { |i| editor.insert(("a".ord + i).chr); editor.add_new_line unless i == 9 }
      editor.move_start # (9,0) — move_start is the LOGICAL line's start
      editor.page_scroll(-1)
      assert_equal [2, 0], [editor.cursor_line, editor.cursor_col], "one page = maxVisibleLines rows"
      editor.page_scroll(-1)
      assert_equal [0, 0], [editor.cursor_line, editor.cursor_col], "paging clamps at the first visual row"
      editor.page_scroll(1)
      assert_equal [7, 0], [editor.cursor_line, editor.cursor_col]
      editor.page_scroll(1)
      assert_equal [9, 0], [editor.cursor_line, editor.cursor_col], "paging clamps at the last visual row"
    end

    def test_page_scroll_resets_the_kill_accumulation_window
      editor = Render::Editor.new
      editor.insert("one two")
      editor.move_word_backward # col 4
      editor.delete_to_line_start # ring: "one "
      editor.page_scroll(1) # lastAction = nil (pi pageScroll :1963)
      editor.move_end
      editor.delete_to_line_start # NOT accumulated: a fresh ring entry
      editor.yank
      assert_equal "two", editor.input,
        "the page move broke the kill window (I26 discipline): a fresh entry yanks only the latest kill"
    end

    # --- the scroll-border label composition (createScrollBorder,
    # editor.ts:279-296, unit-pinned). ---

    def test_scroll_border_composes_the_centered_label_over_dashes
      assert_equal "───── ↑ 3 more ─────", Render::Editor.scroll_border("↑", 3, 20)
      assert_equal "─── ↑...", Render::Editor.scroll_border("↑", 3, 8), "the narrow fallback anchors left"
      assert_equal "─── ↓ 1...", Render::Editor.scroll_border("↓", 12, 10), "the indicator truncates cell-wise"
      assert_equal "..", Render::Editor.scroll_border("↑", 3, 2), "the floor is a bare ellipsis"
    end

    # --- test list (9, editor half): the readbacks and the gates. ---

    def test_the_readbacks_across_the_multi_line_shape
      editor = Render::Editor.new
      editor.insert("ab")
      editor.add_new_line
      editor.insert("cd")
      assert_equal "ab\ncd", editor.input, "input joins the lines"
      assert_equal "ab\ncd", editor.text, "text is pi getText's join"
      assert_equal 5, editor.cursor, "cursor reads back as the FLAT offset over the join"
      assert_equal [1, 2], [editor.cursor_line, editor.cursor_col]
      editor.clear
      assert_equal [""], editor.lines, "clear resets to the one-empty-line shape"
      assert_equal [0, 0, 0], [editor.cursor_line, editor.cursor_col, editor.cursor]
    end

    def test_slash_context_is_line_zero_only
      editor = Render::Editor.new
      editor.insert("/cmd")
      assert_equal "/cmd", editor.slash_token
      editor.add_new_line
      assert_nil editor.slash_token, "the token gates to cursor_line.zero? (pi isSlashMenuAllowed)"
      editor.move_left # wraps to line 0's end
      assert_equal "/cmd", editor.slash_token, "back on line 0 the context returns"
    end

    def test_bash_mode_reads_line_zero
      editor = Render::Editor.new
      editor.insert("!echo")
      editor.add_new_line
      editor.insert("ls")
      assert editor.bash_mode?, "the ! prefix on LINE 0 announces bash mode"
      assert_equal ["!echo", "ls"], editor.lines
    end

    def test_backslash_before_cursor_query
      editor = Render::Editor.new
      editor.insert("hi\\")
      assert editor.backslash_before_cursor?, "the no-shift+enter idiom's guard (pi :878-887)"
      editor.move_start
      refute editor.backslash_before_cursor?
    end
  end
end
