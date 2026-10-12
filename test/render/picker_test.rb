# frozen_string_literal: true

require_relative "../test_helper"

module Tart
  # The /resume session picker's state behavior (I22 wave 2): navigation
  # wrap, enter → on_select, esc-cancel, and the rows budget — driving
  # Picker directly. The Chat wiring (open_session_picker + on_resume)
  # and the in-place rendering stay in test/chat_test.rb.
  class PickerTest < Test
    def test_picker_navigates_and_escapes_cancel
      selected = []
      picker = Render::Picker.new(items: [{path: "/a", label: "first"}, {path: "/b", label: "second"}],
        on_select: ->(item) { selected << item[:path] })
      assert_equal 0, picker.selected
      assert picker.handle(TUI.key_event("down"))
      assert_equal 1, picker.selected
      assert picker.handle(TUI.key_event("up"))
      assert picker.handle(TUI.key_event("up"))
      assert_equal 1, picker.selected, "up wraps to the last item (pi select-list wrap)"
      refute picker.handle(TUI.key_event("esc")), "escape cancels (pi onCancel)"
      assert_empty selected
      refute picker.handle(TUI.key_event("enter")), "a cancelled picker never resumes"
      assert_empty selected
    end

    def test_picker_enter_fires_on_select
      selected = []
      picker = Render::Picker.new(items: [{path: "/a", label: "first"}, {path: "/b", label: "second"}],
        on_select: ->(item) { selected << item })
      picker.handle(TUI.key_event("down"))
      refute picker.handle(TUI.key_event("enter")), "the picker closes on enter"
      assert_equal [{path: "/b", label: "second"}], selected, "enter fires onSelect with the item (pi onSelect)"
    end

    def test_lines_and_widget_rows_budget
      picker = Render::Picker.new(items: 12.times.map { |i| {path: "/s#{i}", label: "session #{i}"} })
      assert_equal 11, picker.widget_rows, "the visible window (maxVisible 10) plus the (i/N) info line"
      3.times { picker.handle(TUI.key_event("down")) }
      rows = picker.lines(50).map { |line| line.spans.map(&:content).join }
      assert_equal 11, rows.size
      assert_match(/\A  session 2\z/, rows[2])
      assert_match(/\A→ session 3\z/, rows[3], "the selection marker (pi selectedText)")
      assert_match(/\(4\/12\)/, rows[10], "the (i/N) scroll-info line renders (select-list.ts:107-110)")
    end
  end
end
