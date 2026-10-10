# frozen_string_literal: true

require_relative "test_helper"

module Tart
  class TUITest < Test
    def test_status_panel_draws_paragraph_in_block_headless
      TUI.run(headless: true) do |session|
        session.draw(TUI.status_panel("hello"))
        assert_equal "h", session.cell_symbol(1, 1)
        assert_equal "┌", session.cell_symbol(0, 0) # block border corner
      end
    end

    def test_style_and_line_vocabulary_render_styled_cells
      TUI.run(headless: true, width: 20, screen_height: 4) do |session|
        session.draw(TUI.paragraph(text: [TUI.line("user", fg: :light_blue), TUI.line("plain")]))
        assert_equal :light_blue, session.cell_fg(0, 0), "styled span's fg reads back"
        assert_nil session.cell_fg(0, 1), "unstyled span carries the terminal default"
        assert_equal :light_blue, TUI.style(fg: :light_blue).fg
      end
    end

    def test_span_and_multispan_line_vocabulary_render_and_read_back
      TUI.run(headless: true, width: 20, screen_height: 4) do |session|
        line = TUI.line([
          TUI.span("ab ", fg: :red),
          TUI.span("cd", modifiers: [:reversed]),
          TUI.span("ef"),
        ])
        session.draw(TUI.paragraph(text: [line]))
        assert_equal :red, session.cell_fg(0, 0), "fg per span"
        assert_equal [:reversed], session.cell_modifiers(3, 0), "modifier per span"
        assert_equal "e", session.cell_symbol(5, 0), "unstyled trailing span renders"
        assert_empty session.cell_modifiers(5, 0)
        assert_empty TUI.span("x").style.to_a.compact, "an unstyled span carries no Style"
      end
    end

    # The markdown seam's conversion (AC5): markdown-vocabulary rows
    # (duck-typed spans: text/fg/modifiers) → styled Lines; an empty row is
    # a blank line.
    def test_markdown_line_converts_vocabulary_rows_and_read_back
      TUI.run(headless: true, width: 20, screen_height: 4) do |session|
        span = Render::Markdown::Span
        session.draw(TUI.paragraph(text: [
          TUI.markdown_line([span.new(text: "ab", fg: :yellow, modifiers: [:bold])]),
          TUI.markdown_line([]),
          TUI.markdown_line([span.new(text: "cd")]),
        ]))
        assert_equal :yellow, session.cell_fg(0, 0), "fg converts to the span's Style"
        assert_equal [:bold], session.cell_modifiers(0, 0), "modifiers convert to the span's Style"
        assert_equal " ", session.cell_symbol(0, 1), "an empty row renders a blank line"
        assert_nil session.cell_fg(0, 2), "an unstyled span carries the terminal default"
      end
    end

    # --- fullscreen seam surface (AC1): layout splits, bordered blocks,
    # widget-tree readback, resize — all on the headless test terminal. ---

    def test_layout_splits_children_into_constraint_rects
      TUI.run(headless: true, width: 20, screen_height: 6) do |session|
        session.draw(TUI.layout(
          children: [TUI.paragraph(text: "top"), TUI.paragraph(text: "bottom")],
          constraints: [TUI.constraint_min(1), TUI.constraint_length(2)]
        ))
        assert_equal "t", session.cell_symbol(0, 0), "the Min child takes the top"
        assert_equal "b", session.cell_symbol(0, 4), "the Length child docks at the bottom"
      end
    end

    def test_block_renders_title_and_borders_with_styles
      TUI.run(headless: true, width: 20, screen_height: 5) do |session|
        session.draw(TUI.block(
          title: " status ",
          border_style: TUI.style(fg: :dark_gray),
          title_style: TUI.style(fg: :dark_gray),
          children: [TUI.paragraph(text: "input")]
        ))
        assert_equal "┌", session.cell_symbol(0, 0)
        assert_equal "s", session.cell_symbol(2, 0), "the title renders on the top border"
        assert_equal :dark_gray, session.cell_fg(2, 0), "the title carries its style"
        assert_equal "i", session.cell_symbol(1, 1), "children render inside the borders"
      end
    end

    def test_widget_lines_reads_back_a_composed_tree
      TUI.run(headless: true, width: 20, screen_height: 6) do |session|
        widget = TUI.layout(
          children: [
            TUI.paragraph(text: [TUI.line("echo"), TUI.line("rows")]),
            TUI.block(children: [TUI.paragraph(text: "input")]),
          ],
          constraints: [TUI.constraint_min(1), TUI.constraint_length(3)]
        )
        assert_equal ["echo", "rows", "input"], TUI.widget_lines(widget),
          "layout children read back in order; a block's title row is not display content"
        session.draw(widget)
      end
    end

    def test_resize_reshapes_the_test_terminal_and_the_next_frame_recomposes
      TUI.run(headless: true, width: 20, screen_height: 6) do |session|
        session.draw(TUI.paragraph(text: "x"))
        session.resize(30, 8)
        area = session.viewport_area
        assert_equal [30, 8], [area.width, area.height], "the viewport reports the new geometry"
        session.draw(TUI.paragraph(text: [TUI.line("y" * 25)]))
        assert_equal 8, session.buffer_content.size, "the buffer reshaped"
        assert_equal 30, session.buffer_content.first.length
      end
    end

    def test_terminal_restored_after_normal_run
      TUI.run(headless: true) { |session| session.draw(TUI.status_panel("x")) }
      refute TUI::Session.active?
    end

    def test_terminal_restored_on_raise
      error = assert_raises(RuntimeError) do
        TUI.run(headless: true) { raise "boom" }
      end
      assert_equal "boom", error.message
      refute TUI::Session.active?, "terminal must be restored even on raise (ISIG safety net)"
    end

    def test_refuses_nested_session
      TUI.run(headless: true) do
        assert_raises(TUI::SessionError) { TUI.run(headless: true) { } }
      end
    end

    def test_synthetic_push_and_drain_round_trip
      TUI.run(headless: true) do |session|
        Thread.new { session.push_event(TUI.sync_event) }
        received = nil
        100.times do
          session.drain_synthetic { |event| received = event }
          break if received
          sleep 0.005
        end
        assert received&.sync?, "synthetic event must round-trip through SyntheticEvents"
        refute session.synthetic_pending?
      end
    end

    def test_ctrl_c_predicate
      assert TUI.ctrl_c?(TUI.key_event("c", modifiers: ["ctrl"])), "raw-mode 0x03 arrives as key c + ctrl"
      refute TUI.ctrl_c?(TUI.key_event("c"))
      refute TUI.ctrl_c?(TUI.key_event("q", modifiers: ["ctrl"]))
      refute TUI.ctrl_c?(TUI.sync_event)
    end
  end
end
