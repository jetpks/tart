# frozen_string_literal: true

require_relative "../test_helper"

module Tart
  # The Selection machine's whole-screen surface (I28 AC1/AC2, direct
  # class): the point space is the coordinator's — transcript buffer rows
  # at 0+, the dock's synthetic rows negative — and the injected
  # line_reader answers both. The machine itself never learns about
  # areas: every mechanic (granularity, drag extension, the text
  # readback) runs unchanged across the row-space boundary.
  class Render::SelectionTest < Test
    LINES = {0 => "hello world", 1 => "second row", -1 => "footer stats", -2 => "footer pwd"}.freeze

    def selection
      @selection ||= Render::Selection.new(line_reader: ->(row) { LINES.fetch(row, "") })
    end

    def press(x, row)
      selection.press(Render::Selection::Point.new(row, x))
    end

    def capture_osc52
      previous = $stdout
      $stdout = StringIO.new
      yield
      $stdout.string[/\e\]52;c;(.*?)\a/, 1]&.unpack1("m")
    ensure
      $stdout = previous
    end

    # The whole-screen text readback (pi getActiveSelectionText :1414 —
    # ctrl+x's preferSelection source).
    def test_selection_text_spans_below_rows_and_buffer_rows
      press(6, 0) # "world" starts at col 6
      selection.drag(Render::Selection::Point.new(-1, 3)) # into the footer's stats row

      assert_equal "ter stats\nhello w", selection.selection_text,
        "the readback walks the point space's two halves in row order"
    end

    def test_double_click_granularity_over_a_below_row
      press(0, -1)
      press(0, -1) # the same word within the window: count 2

      assert_equal "footer", selection.selection_text, "the below row's word"
    end

    def test_a_collapsed_release_leaves_no_text
      press(6, 0)
      copied = capture_osc52 { selection.release(Render::Selection::Point.new(0, 6)) } # no move

      assert_empty copied.to_s, "a press without a move copies nothing"
      assert_nil selection.selection_text, "nothing selected"
    end

    def test_highlight_covers_below_rows
      press(0, -2)
      selection.drag(Render::Selection::Point.new(4, -2))

      blank = TUI.line("footer pwd")
      highlighted = selection.highlight_row(blank, -2)
      assert_equal "footer pwd", highlighted.spans.map(&:content).join, "the row's bytes stand"
      assert highlighted.spans.flat_map { |span| span.style&.modifiers || [] }.include?(:reversed),
        "the below row re-styles with the inverse highlight"

      assert_equal blank.spans, selection.highlight_row(blank, 5).spans, "an untouched row passes through"
    end
  end
end
