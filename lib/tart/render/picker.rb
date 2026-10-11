# frozen_string_literal: true

require_relative "text"

module Tart
  module Render
    # The /resume session picker (item 2, pi SessionSelectorComponent,
    # reduced): a flat newest-first list with pi's key shape (up/down
    # navigate, enter selects — onSelect —, escape cancels — onCancel).
    # The select callback is wired at construction (pi onSelect): the Chat
    # coordinator builds the Picker with a lambda into its {Chat#on_resume}
    # seam and drops its holder once +handle+ reports the picker closed.
    # Reductions, itemized: no search input (fuzzy/regex/exact), no
    # all-sessions scope toggle, no threaded/name sort modes, no rename,
    # no delete, no path/cwd toggles, no cwd-mismatch prompt, no hint rows.
    # Unsynchronized by design (I22 shape rule a): the Chat surface owns
    # the mutex.
    class Picker
      # Session-picker window (pi session-selector.ts:302 maxVisible 10).
      PICKER_MAX = 10

      # @return the launcher-built [{path:, label:}] list (newest first)
      #   and the selection index (the Chat readbacks' targets).
      attr_reader :items, :selected

      # +on_select+ fires with the selected item hash on enter (pi onSelect).
      def initialize(items:, on_select: nil)
        @items = items
        @selected = 0
        @on_select = on_select
        @closed = false
      end

      # The picker owns every key while open (pi: the selector takes focus
      # — showSelector { focus: selector }). Returns true while open;
      # enter/esc close it (pi onSelect/onCancel) — false from then on
      # (a closed picker handles nothing), and the Chat coordinator drops
      # its holder.
      def handle(event)
        return false if @closed

        case event.code
        when "up" then navigate(-1)
        when "down" then navigate(1)
        when "enter"
          item = @items[@selected]
          close
          @on_select&.call(item) if item
        when "esc" then close
        end
        !@closed
      end

      # The picker's content rows: one line per session (pi renders one
      # line each with tree structure :459-460), "→ " marking the selection
      # (accent, pi selectedText — the autocomplete row's shape), labels
      # hard-clipped to the width.
      def lines(width)
        return [TUI.line("  No sessions found", fg: Theme[:muted])] if @items.empty?

        start = [[@selected - PICKER_MAX / 2, @items.size - PICKER_MAX].min, 0].max
        rows = @items[start, PICKER_MAX].map.with_index do |item, i|
          label = Text.clip_text(item[:label], width - 3)
          (start + i) == @selected ? TUI.line("→ #{label}", fg: Theme[:accent]) : TUI.line("  #{label}")
        end
        rows << TUI.line("  (#{@selected + 1}/#{@items.size})", fg: Theme[:muted]) if @items.size > PICKER_MAX
        rows
      end

      # The picker's widget — the editor area is REPLACED by the picker
      # while open (pi showSelector swaps the container and moves focus).
      def widget(width)
        TUI.block(
          title: " Resume Session (Current Folder) ", # pi SessionSelectorHeader.render :147
          borders: [:top, :bottom],
          border_style: TUI.style(fg: Theme[:border]),
          title_style: TUI.style(fg: Theme[:dim]),
          children: [TUI.paragraph(text: lines(width), wrap: false)]
        )
      end

      # The picker's row budget (the editor-area height calc; +2 borders).
      def widget_rows
        count = [@items.size, PICKER_MAX].min
        @items.size > PICKER_MAX ? count + 1 : count
      end

      private

      # pi SelectList.handleInput (select-list.ts:146-155): up/down WRAP.
      def navigate(direction)
        size = @items.size
        return if size.zero?

        @selected = direction == -1 ? (@selected.zero? ? size - 1 : @selected - 1) : (@selected == size - 1 ? 0 : @selected + 1)
      end

      def close
        @closed = true
      end
    end
  end
end
