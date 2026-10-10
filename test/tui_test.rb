# frozen_string_literal: true

require_relative "test_helper"

module RaspberryPi
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
