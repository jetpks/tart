# frozen_string_literal: true

require_relative "text"
require_relative "editor"

module Tart
  module Render
    # The mouse-selection state machine (item 10, pi tui-alt-screen.ts
    # :83-107): anchor/focus points, granularity (:character/:word/:line),
    # the initial word/line range a drag extends, and the multi-click
    # bookkeeping — plus the render-side highlight query (pi
    # applySelection :1589-1638, getSelectionColumns :1429-1447) and the
    # copy-on-select seam (pi :1332-1366, default on — :269, via
    # TUI.osc52_copy inside the release op). Points address
    # transcript-buffer rows (pi SelectionPoint reduced — the selection
    # is anchored to buffer lines, so it survives scrolling; whole-screen
    # selection (I28) extends the space: rows below the transcript area
    # arrive as NEGATIVE synthetic rows (terminal row − screen height,
    # the coordinator's {Chat#content_point}) and the injected reader
    # answers them from the composed dock — the machine itself stays
    # area-agnostic. The buffer's content lines reach the machine
    # through the
    # construction-injected reader over the Chat coordinator's live
    # transcript, the pointer points are threaded per call from it (the
    # content_point composition needs the viewport state + geometry).
    # Unsynchronized by design (I22 shape rule a): the Chat surface owns
    # the mutex.
    class Selection
      # Double/triple-click window (pi DOUBLE_CLICK_INTERVAL_MS :82 =
      # 500ms; the count cycles 1 → 2 → 3 → 1 on the same row and word
      # range — getClickCount :1247-1267).
      DOUBLE_CLICK_SECONDS = 0.5

      # Word-selection joiners (pi TERMINAL_WORD_SELECTION_JOINERS :85):
      # paths and kebab-case tokens stay whole across a word boundary.
      WORD_JOINERS = "/-".freeze

      # The selection granularity's word-char class (the editor's full
      # boundary-class set lives on {Editor} — word-navigation.ts).
      WORD_CHAR = Editor::WORD_CHAR

      # A selection endpoint in transcript-buffer coordinates (pi
      # SelectionPoint reduced to content rows: the port's selection is
      # anchored to buffer lines, so it survives scrolling — pi stores
      # scrollView content rows exactly the same way,
      # getScrollSelectionPoint :1133-1155). +boundary+ marks an
      # exclusive end (word/line granularity — pi SelectionPoint.boundary).
      Point = Struct.new(:row, :col, :boundary)

      # +line_reader+ answers one buffer row's plain text (the display
      # Line's span contents — the coordinator's live transcript seam,
      # read at event time: rows addressed by {Point#row}).
      def initialize(line_reader:)
        @line_reader = line_reader
        @selection = nil
        @last_click = nil
      end

      # Press: anchor at the pointer (pi :1397-1416). A double click
      # takes the pointer's word, a triple the whole line (granularity +
      # initial range — a following drag extends word-/line-wise, pi
      # updateSelectionFocus :1226-1244). A nil point (a press outside
      # the transcript area — pi: the press lands on another component)
      # drops the selection.
      def press(point)
        return @selection = nil unless point

        word = word_range(point)
        count = next_click_count(point, word)
        range = count == 2 ? word : (count == 3 ? line_range(point) : nil)
        @selection = {
          anchor: range ? range.first : point,
          focus: range ? range.last : point,
          granularity: range ? (count == 2 ? :word : :line) : :character,
          initial: range
        }
      end

      # Drag: extend the focus (pi :1370-1380). pi's edge auto-scroll
      # while dragging past the viewport (updateSelectionAutoScroll
      # :1270-1320, 50ms timer) is cut — itemized.
      def drag(point)
        return unless @selection

        update_focus(point) if point
      end

      # The selected text (pi getActiveSelectionText :1414-1437): each
      # covered row's cell slice, trailing whitespace trimmed, joined
      # with newlines. nil when nothing (or only whitespace) is selected.
      # Public — pi's app.message.copy reads it for the preferSelection
      # branch (interactive-mode.ts:6641-6648); the rows are the
      # coordinator's whole-screen point space ({Point#row}): transcript
      # buffer rows at 0+, the dock's synthetic rows below (negative —
      # the coordinator's reader answers them).
      def selection_text
        start, focus = bounds
        return nil unless start

        text = (start.row..focus.row).map do |row|
          source = line(row)
          width = TUI.text_width(source)
          from = start.row == row ? start.col : 0
          to = focus.row == row ? (focus.boundary ? focus.col : focus.col + 1) : width
          from = from.clamp(0, width)
          to = to.clamp(from, width)
          Text.slice_cells(source, from, to - from).rstrip
        end.join("\n")
        text.empty? ? nil : text
      end

      # Release: a press without a move (anchor == focus) collapses to no
      # selection; otherwise copy-on-select (pi :1332-1366, default on —
      # :269) via the seam's OSC 52 write.
      def release(point)
        return unless @selection

        update_focus(point) if point
        text = selection_text
        @selection = nil if text.nil?
        TUI.osc52_copy(text) if text
      end

      # One transcript row re-styled with the selection's inverse
      # highlight (pi applySelection :1589-1638 +
      # applySelectionHighlight :1572-1584: SGR 7 over the covered cells
      # — the port's [:reversed] modifier on the covered spans, fg kept).
      # Rows outside the selection pass through untouched.
      def highlight_row(line, row)
        selected = bounds
        return line unless selected
        return line if row < selected.first.row || row > selected.last.row

        from, to = columns(row, TUI.text_width(line.spans.map(&:content).join))
        return line if to <= from

        reverse_cells(line, from, to)
      end

      # The /new + resume reset (pi renderCurrentSessionState — the host
      # drops the selection with the transcript, interactive-mode.ts
      # :4096).
      def reset
        @selection = nil
        @last_click = nil
      end

      private

      # The buffer row's plain text (the display Line's span contents).
      def line(row)
        @line_reader.call(row)
      end

      # Focus extension (pi updateSelectionFocus :1226-1244): character
      # granularity moves the focus point; word/line re-selects at the
      # pointer and flips the anchor to the opposite end of the initial
      # range (dragging backwards grows the head end).
      def update_focus(point)
        s = @selection
        if s[:granularity] == :character || !s[:initial]
          s[:focus] = point
        else
          range = s[:granularity] == :word ? word_range(point) : line_range(point)
          return unless range

          if before?(range.first, s[:initial].first)
            s[:anchor], s[:focus] = s[:initial].last, range.first
          else
            s[:anchor], s[:focus] = s[:initial].first, range.last
          end
        end
      end

      # @return the ordered [start, focus] selection bounds, or nil when
      #   there is no selection (the endpoints coincide — pi
      #   getSelectionBounds :1403-1426).
      def bounds
        return nil unless @selection

        a, b = @selection[:anchor], @selection[:focus]
        return nil if a == b

        before?(a, b) ? [a, b] : [b, a]
      end

      # The selection's cell range on +row+ (pi getSelectionColumns
      # :1429-1447): the start/end columns only bite on their own rows;
      # the char-granularity end is inclusive (+1), a word/line end is
      # exclusive (boundary).
      def columns(row, width)
        start, focus = bounds
        from = start.row == row ? start.col : 0
        to = focus.row == row ? (focus.boundary ? focus.col : focus.col + 1) : width
        [from.clamp(0, width), to.clamp(0, width)]
      end

      # The word selection at +point+ (pi getWordSelection :1167-1212): the
      # maximal run of word characters joined by "/"/"-" (paths and
      # kebab-case stay whole); any other single character selects itself
      # (pi: a non-word segment is its own selection). nil beyond the
      # line's cells.
      def word_range(point)
        text = line(point.row)
        return nil if point.col >= TUI.text_width(text)

        idx = Text.char_index_at_cell(text, point.col)
        if text[idx].match?(WORD_CHAR) || WORD_JOINERS.include?(text[idx])
          from = idx
          from -= 1 while from > 0 && word_char?(text[from - 1])
          upto = idx
          upto += 1 while upto < text.length - 1 && word_char?(text[upto + 1])
        else
          from = upto = idx
        end
        [Point.new(point.row, TUI.text_width(text[0, from])),
         Point.new(point.row, TUI.text_width(text[0, upto + 1]), true)]
      end

      def word_char?(ch)
        ch.match?(WORD_CHAR) || WORD_JOINERS.include?(ch)
      end

      # The line selection at +point+ (pi getLineSelection :1214-1219): the
      # whole row, exclusive end at its width.
      def line_range(point)
        width = TUI.text_width(line(point.row))
        [Point.new(point.row, 0), Point.new(point.row, width, true)]
      end

      # pi getClickCount :1247-1267: clicks within the double-click window
      # on the same row and word range cycle 1 → 2 → 3 → 1.
      def next_click_count(point, word)
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        last = @last_click
        count = if word && last && now - last[:at] <= DOUBLE_CLICK_SECONDS &&
          last[:row] == point.row && last[:start] == word.first.col && last[:end] == word.last.col
          (last[:count] % 3) + 1
        else
          1
        end
        @last_click = word && {row: point.row, start: word.first.col, end: word.last.col, count:, at: now}
        count
      end

      def before?(a, b)
        a.row < b.row || (a.row == b.row && a.col < b.col)
      end

      # Rebuilds one display line with the cell range [from, to) inverse-
      # highlighted: spans are split at the range's bounds, covered pieces
      # carry [:reversed] (fg kept — pi's SGR 7 composes over SGR).
      def reverse_cells(line, from, to)
        cell = 0
        spans = line.spans.flat_map do |span|
          pieces = span_pieces(span, cell, from, to)
          cell += TUI.text_width(span.content)
          pieces
        end
        TUI.line(spans)
      end

      # One span split at the selection bounds (cuts strictly inside the
      # span); pieces inside [from, to) are reversed.
      def span_pieces(span, cell, from, to)
        width = TUI.text_width(span.content)
        cuts = [from, to].select { |c| cell < c && c < cell + width }.uniq.sort
        fg = span.style&.fg
        modifiers = span.style&.modifiers || []
        [cell, *cuts, cell + width].each_cons(2).filter_map do |a, b|
          next if a == b

          piece = Text.slice_cells(span.content, a - cell, b - a)
          reversed = a >= from && b <= to
          TUI.span(piece, fg:, modifiers: reversed ? modifiers + [:reversed] : modifiers)
        end
      end
    end
  end
end
