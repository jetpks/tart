# frozen_string_literal: true

require_relative "undo_stack"

module Tart
  module Render
    # The input editor (pi's Editor, components/editor.ts 1.1.0): a
    # multi-LOGICAL-line buffer with a visual-line model — logical lines
    # wrap into visual rows at the render width, the cursor is a logical
    # {cursor_line, cursor_col} position navigated through pi's visual-row
    # semantics (sticky column, page scroll), plus in-memory history, the
    # emacs kill ring (I26), and word-wise operations
    # (word-navigation.ts boundary semantics). The key surface is exactly
    # the events the kernel forwards (code + ctrl/alt/shift modifiers),
    # bound per pi's keybindings.ts defaults — the binding itself is the
    # Chat coordinator's dispatch; the Editor owns the state and the
    # operations. Editing keys leave history browsing (pi:
    # exitHistoryBrowsing) while pure motions keep it (pi's dispatch —
    # moveCursor/moveToVisualLine never exit); edit units are chars where
    # pi uses graphemes (the recorded simplification — paste markers, the
    # other multi-grapheme unit, are cut with the large-paste
    # compaction).
    #
    # Rendering (I35): {input_rows} lays the buffer out as visual rows
    # (pi layoutText) through the {word_wrap_line} chunker, windows them
    # to max(5, floor(rows * 0.3)) ({max_visible_lines}, pi editor.ts:538
    # — one source with {page_scroll}'s page size via the rows_reader
    # seam), and keeps the cursor row visible (pi :543-556). The wrap and
    # border-label math are pure class functions so tests pin them
    # directly.
    #
    # Unsynchronized by design (I22 shape rule a): the Chat surface owns
    # the mutex; editor operations run on the kernel task exactly as they
    # did when they lived on Chat.
    class Editor
      # History depth (pi: editor.ts addToHistory caps at 100 entries).
      HISTORY_LIMIT = 100

      # The boundary classes of pi's word navigation (word-navigation.ts with
      # utils.ts:1006 PUNCTUATION_REGEX and :1011 isWhitespaceChar). The
      # Intl.Segmenter word-like segment is approximated by word-character
      # runs (recorded simplification); ASCII punctuation stays a boundary
      # either way — pi's PUNCTUATION_REGEX sub-rule.
      PUNCTUATION = /[(){}\[\]<>.,;:'"!?+\-=*\/\\|&%^$#@~`]/.freeze
      WORD_CHAR = /[[:alnum:]_]/.freeze
      WHITESPACE = /\s/.freeze

      # One laid-out visual row (pi LayoutLine, editor.ts:298-303): the
      # row's text, whether the cursor sits on it, and the cursor's
      # column within the row text.
      LayoutRow = Struct.new(:text, :has_cursor, :cursor_pos, keyword_init: true)

      # The undo snapshot (pi EditorSnapshot, editor.ts:225-229, minus
      # its pastes/pasteCounter halves — the large-paste marker registry
      # is a recorded I35 cut, itemized; the port's snapshot is exactly
      # pi's EditorState triple). {UndoStack#push} deep-copies, so a
      # snapshot is detached from the live buffer the moment it stacks.
      Snapshot = Struct.new(:lines, :cursor_line, :cursor_col, keyword_init: true)

      # @return [Array<String>] the logical lines (always ≥ 1; pi
      #   EditorState.lines).
      # @return [Integer] the cursor's logical line / column (pi
      #   getCursor's shape).
      # @return [Integer] the visible window's top over the visual rows
      #   (pi scrollOffset — updated at render, :543-556).
      # @return [Integer] the last window's visible row count (pi
      #   renderedVisibleLineCount) and the rows hidden below it (pi
      #   renderBottomBorder's linesBelow) — the Chat area-height and
      #   border readbacks.
      attr_reader :lines, :cursor_line, :cursor_col, :scroll_offset, :rendered_rows, :hidden_below

      # +rows_reader+ feeds max(5, floor(rows * 0.3)) (pi
      # editor.ts:538/1966 both read terminal.rows); Chat wires
      # -> { screen_height } so the render window and the page size share
      # one source. The 24 default matches the headless fallbacks' shape.
      def initialize(rows_reader: -> { 24 })
        @lines = [""]
        @cursor_line = 0
        @cursor_col = 0
        @preferred_visual_col = nil # pi preferredVisualCol (sticky column; nil = unset)
        @scroll_offset = 0
        @rendered_rows = 1
        @hidden_below = 0
        @last_width = 80 # pi lastWidth — the wrap width between renders
        @rows_reader = rows_reader
        @history = []
        @history_index = -1 # -1 = not browsing (pi: editor.ts historyIndex)
        @history_draft = nil
        @kill_ring = KillRing.new
        @last_action = nil
        @undo_stack = UndoStack.new # pi undoStack field, editor.ts:368
      end

      # The joined buffer (pi getText, editor.ts:1088) — the
      # chat/autocomplete/submit callers' readback.
      def input
        @lines.join("\n")
      end

      # pi getText's name for the join.
      def text = input

      # The cursor as a FLAT char offset over the joined text — the
      # pre-multiline readback shape the cursor-moving operations' tests
      # pin (line 0 col c == c, exactly the base values).
      def cursor
        @lines[0, @cursor_line].sum { |line| line.length + 1 } + @cursor_col
      end

      # The clear op (the escape bash-mode clear and the ctrl+c app.clear —
      # both Chat branches ran exactly these lines at base; the window
      # reset is pi submitValue's scrollOffset = 0, editor.ts:921). pi
      # setText's push-if-content-differs (editor.ts:1120-1124) makes
      # these clears UNDOABLE — only the submit surface clears the stack
      # (Chat#submit → clear_undo_stack, pi submitValue :1373).
      def clear
        push_undo_snapshot unless input.empty?
        @lines = [""]
        @cursor_line = 0
        set_cursor_col(0)
        @last_action = nil
        @scroll_offset = 0
      end

      # The completion-apply write surface (pi applyCompletion): the token
      # region [lead, cursor) is replaced whole — text and cursor land
      # together (no grapheme-wise edit, no history-browsing exit —
      # verbatim base behavior). Flat-string line-0 contract: the slash
      # token only ever lives on line 0 ({slash_token} gates to it).
      def replace_token(lead, text, cursor)
        push_undo_snapshot # pi pushes at every applyCompletion site (editor.ts:772/793/2244/2395) — undoable
        @lines[0] = "#{@lines[0][0, lead]}#{text}"
        @cursor_line = 0
        set_cursor_col(cursor)
        @last_action = nil
      end

      # --- input editing primitives (each leaves history browsing) ---

      # pi insertCharacter (editor.ts:1201-1213) tags typing "type-word";
      # the port's typing op inserts into the CURRENT line at the column.
      # Observation-free slot note as at base: the slot is only ever
      # tested against :kill/:yank, and both values sit outside those
      # windows.
      def insert(text)
        exit_history_browsing
        # pi's fish-style coalescing (:1209-1212): push iff the char is
        # whitespace or the previous action wasn't typing — consecutive
        # word-chars are ONE undo unit, each space its own (captured
        # pre-space). The port's insert is single-char through
        # insert_printable; multi-char text (test setups) follows the
        # same whitespace rule.
        push_undo_snapshot if text.match?(WHITESPACE) || @last_action != :type_word
        line = @lines[@cursor_line]
        @lines[@cursor_line] = "#{line[0, @cursor_col]}#{text}#{line[@cursor_col..]}"
        set_cursor_col(@cursor_col + text.length)
        @last_action = :type_word
      end

      # pi handlePaste's insert path (editor.ts:1260-1298 +
      # insertTextAtCursorInternal :1156-1200), minus the CSI-u control
      # decode (the gem's paste events carry decoded content), the
      # path-prefix space, and the large-paste "[paste #N]" markers (CUT,
      # itemized — never silent): normalize line endings + tabs, filter
      # non-printables keeping \n, splice multi-line, cursor at the
      # inserted tail.
      def insert_paste(text)
        exit_history_browsing
        @last_action = nil # pi handlePaste editor.ts:1263
        push_undo_snapshot # pi handlePaste editor.ts:1265 — unconditional, before the filters
        filtered = self.class.normalize_text(text).each_char.select do |char|
          char == "\n" || char.ord >= 32
        end.join
        insert_multiline(filtered) unless filtered.empty?
      end

      # pi addNewLine (editor.ts:1329-1348): split the current line at
      # the cursor, cursor to the new line's start.
      def add_new_line
        exit_history_browsing
        @last_action = nil
        push_undo_snapshot # pi addNewLine editor.ts:1333
        line = @lines[@cursor_line]
        @lines[@cursor_line] = line[0, @cursor_col]
        @lines.insert(@cursor_line + 1, line[@cursor_col..])
        @cursor_line += 1
        set_cursor_col(0)
      end

      # pi handleBackspace (editor.ts:1374-1445): delete the char before
      # the cursor; at a line start, merge with the previous line (the
      # plain backspace is not a kill op — no ring push).
      def delete_backward
        exit_history_browsing
        @last_action = nil
        if @cursor_col.positive?
          push_undo_snapshot # pi handleBackspace editor.ts:1384
          line = @lines[@cursor_line]
          @lines[@cursor_line] = line[0, @cursor_col - 1] + line[@cursor_col..]
          set_cursor_col(@cursor_col - 1)
        elsif @cursor_line.positive?
          push_undo_snapshot # pi handleBackspace editor.ts:1430
          merge_with_previous_line
        end
      end

      # pi handleForwardDelete (editor.ts:1781-1815): delete the char at
      # the cursor; at a line end, merge with the next line.
      def delete_forward
        exit_history_browsing
        @last_action = nil
        line = @lines[@cursor_line]
        if @cursor_col < line.length
          push_undo_snapshot # pi handleForwardDelete editor.ts:1786
          @lines[@cursor_line] = line[0, @cursor_col] + line[(@cursor_col + 1)..]
        elsif @cursor_line < @lines.length - 1
          push_undo_snapshot # pi handleForwardDelete editor.ts:1800
          @lines[@cursor_line] = line + @lines.delete_at(@cursor_line + 1)
        end
      end

      # --- cursor motion ---

      # pi moveCursor's left arm (editor.ts:1936-1945): one char
      # backward, wrapping to the previous line's end.
      def move_left
        exit_history_browsing
        @last_action = nil # pi moveCursor editor.ts:1892
        if @cursor_col.positive?
          set_cursor_col(@cursor_col - 1)
        elsif @cursor_line.positive?
          @cursor_line -= 1
          set_cursor_col(@lines[@cursor_line].length)
        end
      end

      # pi moveCursor's right arm (editor.ts:1907-1923): one char
      # forward, wrapping to the next line's start; at the very end the
      # cursor stays but the visual column seeds the sticky column for a
      # following vertical move (pi :1917-1923).
      def move_right
        exit_history_browsing
        @last_action = nil
        line = @lines[@cursor_line]
        if @cursor_col < line.length
          set_cursor_col(@cursor_col + 1)
        elsif @cursor_line < @lines.length - 1
          @cursor_line += 1
          set_cursor_col(0)
        else
          map = build_visual_line_map(@last_width)
          vl = map[find_visual_line_at(map, @cursor_line, @cursor_col)]
          @preferred_visual_col = vl ? @cursor_col - vl[:start_col] : nil
        end
      end

      # pi moveToLineStart (editor.ts:1613-1616) — the LOGICAL line's
      # start, not the visual row's.
      def move_start
        exit_history_browsing
        @last_action = nil
        set_cursor_col(0)
      end

      # pi moveToLineEnd (editor.ts:1617-1620) — the LOGICAL line's end.
      def move_end
        exit_history_browsing
        @last_action = nil
        set_cursor_col(@lines[@cursor_line].length)
      end

      # pi moveWordBackwards (editor.ts:1977-1995): the word scan on the
      # current line; at a line start, jump to the previous line's end.
      def move_word_backward
        exit_history_browsing
        @last_action = nil
        if @cursor_col.zero?
          if @cursor_line.positive?
            @cursor_line -= 1
            set_cursor_col(@lines[@cursor_line].length)
          end
          return
        end
        set_cursor_col(self.class.find_word_backward(@lines[@cursor_line], @cursor_col))
      end

      # pi moveWordForwards (editor.ts:2172-2190), the mirror.
      def move_word_forward
        exit_history_browsing
        @last_action = nil
        line = @lines[@cursor_line]
        if @cursor_col >= line.length
          if @cursor_line < @lines.length - 1
            @cursor_line += 1
            set_cursor_col(0)
          end
          return
        end
        set_cursor_col(self.class.find_word_forward(line, @cursor_col))
      end

      # pi cursorUp's dispatch (editor.ts:925-937): on the FIRST visual
      # row, history iff the editor is empty, browsing is live, or the
      # logical col is 0 — else the logical line start; off the first
      # row, one visual row up through the sticky-column move (the
      # motion arm keeps history browsing, pi moveCursor).
      def cursor_up
        map = build_visual_line_map(@last_width)
        current = find_visual_line_at(map, @cursor_line, @cursor_col)
        if current.zero?
          if empty_editor? || browsing? || @cursor_col.zero?
            history_previous
          else
            move_start
          end
        else
          move_visual_row(map, current, current - 1)
        end
      end

      # pi cursorDown's dispatch (editor.ts:938-950): on the LAST visual
      # row, history iff browsing — else the logical line end; off the
      # last row, one visual row down.
      def cursor_down
        map = build_visual_line_map(@last_width)
        current = find_visual_line_at(map, @cursor_line, @cursor_col)
        if current == map.length - 1
          browsing? ? history_next : move_end
        else
          move_visual_row(map, current, current + 1)
        end
      end

      # pi pageScroll (editor.ts:1961-1973): the cursor paged by
      # max(5, floor(rows * 0.3)) visual rows through the sticky-column
      # move, clamped to the map — one page size with the render window
      # ({max_visible_lines}). The motion keeps history browsing (pi).
      def page_scroll(direction)
        @last_action = nil
        map = build_visual_line_map(@last_width)
        current = find_visual_line_at(map, @cursor_line, @cursor_col)
        target = (current + direction * max_visible_lines).clamp(0, map.length - 1)
        move_visual_row(map, current, target)
      end

      # --- the emacs kill ring (I26): pi's kill/yank slice — every kill
      # op exits history browsing first (editor.ts:1627) and pushes the
      # cut span (backward = prepend, forward = append), accumulating iff
      # the previous action was itself a kill (the lastAction window,
      # editor.ts:352). At a line boundary the killed text is the "\n"
      # itself and the lines merge (editor.ts:1641-1655, 1673-1686).

      # pi deleteToStartOfLine (editor.ts:1625-1655): the logical
      # prefix; at a column-0 boundary, the "\n" merging upward.
      def delete_to_line_start
        exit_history_browsing
        if @cursor_col.positive?
          push_undo_snapshot # pi deleteToStartOfLine editor.ts:1631 — before the ring push
          line = @lines[@cursor_line]
          @kill_ring.push(line[0, @cursor_col], prepend: true, accumulate: @last_action == :kill)
          @last_action = :kill
          @lines[@cursor_line] = line[@cursor_col..]
          set_cursor_col(0)
        elsif @cursor_line.positive?
          push_undo_snapshot # pi deleteToStartOfLine editor.ts:1642
          kill_newline_merge_previous
        end
      end

      # pi deleteToEndOfLine (editor.ts:1657-1687): the logical suffix;
      # at an end-of-line boundary, the "\n" merging downward.
      def delete_to_line_end
        exit_history_browsing
        line = @lines[@cursor_line]
        if @cursor_col < line.length
          push_undo_snapshot # pi deleteToEndOfLine editor.ts:1666 — before the ring push
          @kill_ring.push(line[@cursor_col..], prepend: false, accumulate: @last_action == :kill)
          @last_action = :kill
          @lines[@cursor_line] = line[0, @cursor_col]
        elsif @cursor_line < @lines.length - 1
          push_undo_snapshot # pi deleteToEndOfLine editor.ts:1676
          @kill_ring.push("\n", prepend: false, accumulate: @last_action == :kill)
          @last_action = :kill
          @lines[@cursor_line] = line + @lines.delete_at(@cursor_line + 1)
        end
      end

      # pi yank (editor.ts:2028-2038): paste the most recent entry at the
      # cursor — multi-line ring text splices across lines
      # (insertYankedText :2040-2076). The insert leaves history
      # browsing.
      def yank
        return if @kill_ring.length.zero?

        push_undo_snapshot # pi yank editor.ts:2001 — right after the empty-ring guard
        text = @kill_ring.peek
        exit_history_browsing
        insert_multiline(text)
        @last_action = :yank
      end

      # pi yankPop (editor.ts:2040-2055): only immediately after a yank
      # and with more than one entry; the previously yanked span (the
      # peek before rotation) is deleted across lines (deleteYankedText
      # :2085-2112), the ring rotates, the new peek is inserted.
      def yank_pop
        return unless @last_action == :yank && @kill_ring.length > 1

        push_undo_snapshot # pi yankPop editor.ts:2017 — right after the guard
        yanked = @kill_ring.peek
        exit_history_browsing
        delete_yanked_text(yanked)
        @kill_ring.rotate
        insert_multiline(@kill_ring.peek)
        @last_action = :yank
      end

      # pi deleteWordBackwards (editor.ts:1692-1735) is a kill op: the
      # crossed span enters the ring, accumulating per the lastAction
      # window captured BEFORE the movement resets it (input.ts:309
      # shape); at a column-0 boundary the "\n" is the killed text and
      # the lines merge upward.
      def delete_word_backward
        exit_history_browsing
        line = @lines[@cursor_line]
        if @cursor_col.zero?
          if @cursor_line.positive?
            push_undo_snapshot # pi deleteWordBackwards editor.ts:1700
            kill_newline_merge_previous
          end
          return
        end

        push_undo_snapshot # pi deleteWordBackwards editor.ts:1713 — before the ring push
        was_kill = @last_action == :kill
        target = self.class.find_word_backward(line, @cursor_col)
        @kill_ring.push(line[target...@cursor_col], prepend: true, accumulate: was_kill)
        @last_action = :kill
        @lines[@cursor_line] = line[0, target] + line[@cursor_col..]
        set_cursor_col(target)
      end

      # pi deleteWordForward (editor.ts:1737-1775), the mirror kill op
      # with the end-of-line "\n" merge downward.
      def delete_word_forward
        exit_history_browsing
        line = @lines[@cursor_line]
        if @cursor_col >= line.length
          if @cursor_line < @lines.length - 1
            push_undo_snapshot # pi deleteWordForward editor.ts:1745
            @kill_ring.push("\n", prepend: false, accumulate: @last_action == :kill)
            @last_action = :kill
            @lines[@cursor_line] = line + @lines.delete_at(@cursor_line + 1)
          end
          return
        end

        push_undo_snapshot # pi deleteWordForward editor.ts:1756 — before the ring push
        was_kill = @last_action == :kill
        target = self.class.find_word_forward(line, @cursor_col)
        @kill_ring.push(line[@cursor_col...target], prepend: false, accumulate: was_kill)
        @last_action = :kill
        @lines[@cursor_line] = line[0, @cursor_col] + line[target..]
      end

      def exit_history_browsing
        @history_index = -1
        @history_draft = nil
      end

      # Printable characters insert at the cursor (pi input.ts:268-277);
      # ctrl/alt-modified keys are never text (the real gem's text? ignores
      # modifiers, so the guard is load-bearing for alt+b/f).
      def insert_printable(event)
        return unless event.text? && !(event.modifiers & %w[ctrl alt]).any?

        insert(event.code)
      end

      # --- undo (pi undoStack + undo(), editor.ts:2116-2134) ---

      # pi undo(): exit history browsing FIRST, pop, empty → no-op, then
      # restore the state triple by DIRECT assignment (pi Object.assign —
      # no set_cursor_col; the sticky column nils explicitly below). The
      # kill-ring windows break (@last_action niled — the accumulate and
      # yank-pop windows close) but the ring itself is never snapshotted
      # and never cleared: undo restores text, never ring contents. The
      # render window stays alone (@scroll_offset/@last_width untouched —
      # pi touches neither; the window re-clamps at the next render).
      def undo
        exit_history_browsing
        snapshot = @undo_stack.pop
        return if snapshot.nil?

        @lines = snapshot.lines
        @cursor_line = snapshot.cursor_line
        @cursor_col = snapshot.cursor_col
        @last_action = nil # pi — undo closes the kill-accumulate and yank-pop windows
        @preferred_visual_col = nil
      end

      # pi submitValue's undoStack.clear() (editor.ts:1373) — the ONLY
      # stack-clear site; Chat#submit calls this right after {clear}.
      def clear_undo_stack
        @undo_stack.clear
      end

      # --- history ---

      # pi's editor history (components/editor.ts addToHistory): trimmed,
      # no consecutive duplicates, capped, most recent first.
      def add_to_history(text)
        trimmed = text.strip
        return if trimmed.empty? || @history.first == trimmed

        @history.unshift(trimmed)
        @history.pop if @history.size > HISTORY_LIMIT
      end

      # pi's navigateHistory (editor.ts:475-503): -1 is the live draft; up
      # walks toward older entries (index 0 = most recent), down back toward
      # the draft. The draft is the cloned state ([lines, cursor_line,
      # cursor_col] — pi structuredClone(this.state)) captured when browsing
      # starts and restored at -1. Recall splits the entry, placing the
      # cursor at line start (up) / line end (down) — pi setTextInternal's
      # cursorPlacement "start"/"end".
      def history_previous = navigate_history(-1)

      def history_next = navigate_history(1)

      # --- queries ---

      # pi isBashMode (interactive-mode.ts:3125): the trimmed input starts
      # with "!" — read from line 0 (the editor's border announces the
      # whole-line bash).
      def bash_mode?
        @lines.first.start_with?("!")
      end

      # pi shouldSubmitOnBackslashEnter's tail (editor.ts:878-887, minus
      # the keybinding lookup the Chat dispatch owns): a "\\" immediately
      # before the cursor — the no-shift+enter terminal's newline-on-enter
      # idiom.
      def backslash_before_cursor?
        @cursor_col.positive? && @lines[@cursor_line][@cursor_col - 1] == "\\"
      end

      # The slash token before the cursor, or nil: an optional-whitespace-led
      # "/" first token with no space before the cursor, gated to line 0
      # (pi isInSlashCommandContext custom-editor.ts:2202-2204 + the
      # provider's no-space rule tui/autocomplete.ts:340-341 — a space
      # means argument completion, which the port has none of).
      def slash_token
        return nil unless @cursor_line.zero?

        line = @lines.first
        lead = line.index(/\S/)
        return nil if lead.nil? || line[lead] != "/" || lead >= @cursor_col

        token = line[lead...@cursor_col]
        token unless token.match?(/\s/)
      end

      # --- rendering ---

      # The visual rows as display lines (pi render's layoutText + window,
      # editor.ts:536-607): wrap each logical line ({layout_rows}), window
      # to {max_visible_lines} keeping the cursor row visible (pi
      # :543-556), and compose each row with the fake cursor as the
      # reversed-span motif (tui.ts:205 renderFakeCursor via
      # editor.ts:583-597 — the grapheme at the insertion point renders
      # inverse-video; at end-of-row a highlighted trailing space, which
      # may occupy the reserved last column). +width+ is the caller's
      # inner width and pins the wrap width between renders (pi lastWidth).
      def input_rows(width)
        window_layout(width).map { |row| row_line(row) }
      end

      # The windowed row count without composing spans — Chat's
      # editor-area height driver (pi measures the editor's rendered
      # height per frame; the port's layout constraints need the count
      # before the children render). Mutates the window state exactly as
      # {input_rows} does, so interleaved calls converge.
      def windowed_rows(width)
        window_layout(width).length
      end

      # pi buildVisualLineMap (editor.ts:1836-1862): each logical line →
      # its visual-row segments [{line:, start_col:, length:}]; an empty
      # line still takes one row.
      def build_visual_line_map(width)
        map = []
        @lines.each_with_index do |line, i|
          if line.empty?
            map << {line: i, start_col: 0, length: 0}
          elsif TUI.text_width(line) <= width
            map << {line: i, start_col: 0, length: line.length}
          else
            self.class.word_wrap_line(line, width).each do |chunk|
              map << {line: i, start_col: chunk[:start], length: chunk[:end_] - chunk[:start]}
            end
          end
        end
        map
      end

      # pi findVisualLineAt (editor.ts:1864-1885): the visual row holding
      # the logical position — the cursor at +length+ belongs to the LAST
      # segment of its logical line.
      def find_visual_line_at(map, line, col)
        map.each_with_index do |vl, i|
          next unless vl[:line] == line

          offset = col - vl[:start_col]
          last_segment = i == map.length - 1 || map[i + 1][:line] != vl[:line]
          return i if offset >= 0 && (offset < vl[:length] || (last_segment && offset == vl[:length]))
        end
        map.length - 1
      end

      # max(5, floor(rows * 0.3)) over the rows_reader (pi editor.ts:538)
      # — the render window's cap AND {page_scroll}'s page size.
      def max_visible_lines
        [5, (@rows_reader.call * 0.3).floor].max
      end

      class << self

        # pi wordWrapLine (editor.ts:131-234) in char units (the recorded
        # grapheme simplification; the CJK break-opportunity rule and the
        # paste-marker atomicity are cut, itemized): wrap-opportunity
        # backtracking — the break lands after the last whitespace before
        # a non-whitespace run (multiple spaces join) — and forced breaks
        # when no opportunity helps. Chunks carry their original-line
        # char offsets [{text:, start:, end_:}]. CJK cell widths stay
        # honest (width-aware per char via TUI.text_width).
        def word_wrap_line(line, width)
          return [{text: "", start: 0, end_: 0}] if line.empty? || width <= 0
          return [{text: line, start: 0, end_: line.length}] if TUI.text_width(line) <= width

          chunks = []
          current_width = 0
          chunk_start = 0
          wrap_opp_index = -1
          wrap_opp_width = 0

          line.chars.each_with_index do |char, i|
            char_width = TUI.text_width(char)
            is_ws = WHITESPACE.match?(char)

            # Overflow check before advancing (pi :155-172): backtrack to
            # the last wrap opportunity when the stranded run still fits,
            # else force-break at the current position.
            if current_width + char_width > width
              if wrap_opp_index >= 0 && current_width - wrap_opp_width + char_width <= width
                chunks << {text: line[chunk_start...wrap_opp_index], start: chunk_start, end_: wrap_opp_index}
                chunk_start = wrap_opp_index
                current_width -= wrap_opp_width
              elsif chunk_start < i
                chunks << {text: line[chunk_start...i], start: chunk_start, end_: i}
                chunk_start = i
                current_width = 0
              end
              wrap_opp_index = -1
            end

            if char_width > width
              # pi's single-atomic-segment arm (:174-190, re-wrap at
              # grapheme granularity): a char-unit segment re-wraps to
              # itself — the char starts its own row (which may overflow
              # visually, exactly as pi's does).
              chunk_start = i
              current_width = char_width
              wrap_opp_index = -1
              next
            end

            current_width += char_width

            # Record the wrap opportunity: whitespace followed by
            # non-whitespace — the break point is after the last space
            # (pi :200-204; the CJK-boundary arm is cut).
            next_char = line[i + 1]
            if is_ws && next_char && !WHITESPACE.match?(next_char)
              wrap_opp_index = i + 1
              wrap_opp_width = current_width
            end
          end

          chunks << {text: line[chunk_start..], start: chunk_start, end_: line.length}
        end

        # pi's normalizeText (editor.ts:1148-1150): \r\n and \r → \n,
        # tabs → 4 spaces.
        def normalize_text(text)
          text.gsub("\r\n", "\n").gsub("\r", "\n").gsub("\t", "    ")
        end

        # pi's findWordBackward (word-navigation.ts:17-70): from the cursor,
        # skip trailing whitespace, then stop at the next word/punctuation
        # boundary — one word run (ASCII punctuation inside it stays a
        # boundary) or one punctuation run. On "hello world" this lands at 6
        # (the separator space is kept); on "hello " it lands at 0 (the
        # whitespace is trailing). Pure function.
        def find_word_backward(text, cursor)
          return 0 if cursor <= 0

          i = cursor
          i -= 1 while i.positive? && WHITESPACE.match?(text[i - 1])
          return i if i.zero?

          if WORD_CHAR.match?(text[i - 1])
            i -= 1 while i.positive? && WORD_CHAR.match?(text[i - 1])
          elsif PUNCTUATION.match?(text[i - 1])
            i -= 1 while i.positive? && PUNCTUATION.match?(text[i - 1])
          else
            i -= 1 # non-word, non-punct (e.g. an emoji): one char
          end
          i
        end

        # pi's findWordForward (word-navigation.ts:73-124): the mirror of
        # {find_word_backward} — skip leading whitespace, then stop at the
        # next word/punctuation boundary. Pure function.
        def find_word_forward(text, cursor)
          return text.length if cursor >= text.length

          i = cursor
          i += 1 while i < text.length && WHITESPACE.match?(text[i])
          return i if i == text.length

          if WORD_CHAR.match?(text[i])
            i += 1 while i < text.length && WORD_CHAR.match?(text[i])
          elsif PUNCTUATION.match?(text[i])
            i += 1 while i < text.length && PUNCTUATION.match?(text[i])
          else
            i += 1
          end
          i
        end

        # pi createScrollBorder (editor.ts:279-296): the centered
        # " ↑ N more " label over dashes, with the narrow fallbacks — the
        # left-anchored "─── ↑ N more " indicator when the centered form
        # can't fit, a "..."-truncated tail at the floor. Pure function
        # (the label composition is unit-pinned; Chat composes the border
        # rows around it).
        def scroll_border(direction, hidden, width)
          available = [width, 0].max
          label = " #{direction} #{hidden} more "
          label_width = TUI.text_width(label)
          if label_width + 2 <= available
            left_width = (available - label_width) / 2
            return "─" * left_width + label + "─" * (available - left_width - label_width)
          end

          indicator = "─── #{direction} #{hidden} more "
          remaining = available - TUI.text_width(indicator)
          return indicator + "─" * remaining if remaining >= 0

          ellipsis = "..."[0, available]
          Text.take_cells(indicator, available - ellipsis.length) + ellipsis
        end

      end

      private

      # pi layoutText (editor.ts:998-1079): every logical line → its
      # LayoutRows — a fitting line is one row; a wrapped line one row
      # per chunk, the cursor belonging to the last chunk from its start
      # and to earlier chunks inside [start, end) (clamped into the
      # chunk's visible text — the trimmed-whitespace case).
      def layout_rows(width)
        return [LayoutRow.new(text: "", has_cursor: true, cursor_pos: 0)] if empty_editor?

        rows = []
        @lines.each_with_index do |line, i|
          if TUI.text_width(line) <= width
            current = i == @cursor_line
            rows << LayoutRow.new(text: line, has_cursor: current, cursor_pos: current ? @cursor_col : nil)
            next
          end

          chunks = self.class.word_wrap_line(line, width)
          chunks.each_with_index do |chunk, ci|
            last_chunk = ci == chunks.length - 1
            in_chunk = i == @cursor_line &&
              (last_chunk ? @cursor_col >= chunk[:start] : @cursor_col >= chunk[:start] && @cursor_col < chunk[:end_])
            unless in_chunk
              rows << LayoutRow.new(text: chunk[:text], has_cursor: false, cursor_pos: nil)
              next
            end

            pos = @cursor_col - chunk[:start]
            pos = chunk[:text].length if pos > chunk[:text].length
            rows << LayoutRow.new(text: chunk[:text], has_cursor: true, cursor_pos: pos)
          end
        end
        rows
      end

      # The visible window over the laid-out rows (pi render :540-558):
      # the cursor row kept inside [scroll_offset, scroll_offset +
      # max_visible), the offset clamped, the readbacks (rendered rows,
      # hidden-below count) refreshed.
      def window_layout(width)
        @last_width = width
        rows = layout_rows(width)
        cursor_row = rows.index(&:has_cursor) || 0
        max_visible = max_visible_lines
        if cursor_row < @scroll_offset
          @scroll_offset = cursor_row
        elsif cursor_row >= @scroll_offset + max_visible
          @scroll_offset = cursor_row - max_visible + 1
        end
        @scroll_offset = @scroll_offset.clamp(0, [rows.length - max_visible, 0].max)
        visible = rows[@scroll_offset, max_visible] || []
        @rendered_rows = visible.length
        @hidden_below = rows.length - (@scroll_offset + visible.length)
        visible
      end

      # One display row (the base input_spans motif carried per row): the
      # grapheme at the insertion point renders reversed; at end-of-row a
      # highlighted trailing space (which may occupy the reserved last
      # column).
      def row_line(row)
        return TUI.line(row.text) unless row.has_cursor

        at = row.text[row.cursor_pos]
        spans = [TUI.span(row.text[0, row.cursor_pos] || "")]
        return TUI.line([*spans, TUI.span(" ", modifiers: [:reversed])]) unless at

        TUI.line([*spans, TUI.span(at, modifiers: [:reversed]), TUI.span(row.text[(row.cursor_pos + 1)..])])
      end

      # The window's sticky-column motion arm (pi moveCursor's vertical
      # half through moveToVisualLine) — the one cursor write that does
      # NOT clear the preferred column ({compute_vertical_move_column}
      # owns it) and does NOT exit history browsing (pure motion).
      def move_visual_row(map, current, target)
        @last_action = nil
        move_to_visual_line(map, current, target)
      end

      # pi moveToVisualLine (editor.ts:1479-1558) WITHOUT the
      # paste-marker snap (snappedFromCursorCol is paste-marker-only —
      # inert in the char-unit port, itemized): the sticky column table
      # picks the target visual column; non-last segments clamp to
      # length-1 so the cursor stays inside the segment.
      def move_to_visual_line(map, current, target)
        current_vl = map[current]
        target_vl = map[target]
        return unless current_vl && target_vl

        current_visual_col = @cursor_col - current_vl[:start_col]
        move_col = compute_vertical_move_column(current_visual_col,
          segment_max_col(map, current), segment_max_col(map, target))

        @cursor_line = target_vl[:line]
        @cursor_col = [target_vl[:start_col] + move_col, @lines[@cursor_line].length].min
      end

      # The segment's reachable visual columns (pi moveToVisualLine
      # :1511-1517): the last segment of a logical line spans
      # [0, length]; earlier ones stop at length-1 (their trailing
      # whitespace belongs to the row's tail, not the cursor).
      def segment_max_col(map, index)
        vl = map[index]
        last_segment = index == map.length - 1 || map[index + 1][:line] != vl[:line]
        last_segment ? vl[:length] : [vl[:length] - 1, 0].max
      end

      # pi computeVerticalMoveColumn (editor.ts:1583-1611) — the sticky
      # column decision table verbatim:
      #
      # | P | S | T | U | Scenario                     | Set Preferred | Move To    |
      # |---|---|---|---|------------------------------|---------------|------------|
      # | 0 | * | 0 | - | Start nav, target fits       | null          | current    |
      # | 0 | * | 1 | - | Start nav, target shorter    | current       | target end |
      # | 1 | 0 | 0 | 0 | Clamped, target fits pref    | null          | preferred  |
      # | 1 | 0 | 0 | 1 | Clamped, still can't fit     | keep          | target end |
      # | 1 | 0 | 1 | - | Clamped, target even shorter | keep          | target end |
      # | 1 | 1 | 0 | - | Rewrapped, target fits       | null          | current    |
      # | 1 | 1 | 1 | - | Rewrapped, target shorter    | current       | target end |
      #
      # P = preferred col set; S = cursor mid-segment (not clamped to
      # end); T = target shorter than the current visual col; U = target
      # shorter than the preferred col.
      def compute_vertical_move_column(current_visual_col, source_max, target_max)
        has_preferred = !@preferred_visual_col.nil? # P
        cursor_in_middle = current_visual_col < source_max # S
        target_too_short = target_max < current_visual_col # T

        if !has_preferred || cursor_in_middle
          if target_too_short
            @preferred_visual_col = current_visual_col
            return target_max
          end

          @preferred_visual_col = nil
          return current_visual_col
        end

        if target_too_short || target_max < @preferred_visual_col # U
          return target_max
        end

        result = @preferred_visual_col
        @preferred_visual_col = nil
        result
      end

      # pi setCursorCol (editor.ts:1469-1473): every non-vertical cursor
      # write clears the sticky column so a later up/down starts fresh.
      def set_cursor_col(col)
        @cursor_col = col
        @preferred_visual_col = nil
      end

      # The col-0 boundary merge shared by the backward kill arms (pi's
      # merge block, editor.ts:1432-1443/1656-1665/1700-1712).
      def kill_newline_merge_previous
        @kill_ring.push("\n", prepend: true, accumulate: @last_action == :kill)
        @last_action = :kill
        previous = @lines[@cursor_line - 1]
        @lines[@cursor_line - 1] = previous + @lines.delete_at(@cursor_line)
        @cursor_line -= 1
        set_cursor_col(previous.length)
      end

      # pi insertYankedText (editor.ts:2040-2076): the text's lines
      # spliced in at the cursor — the first line joins the prefix, the
      # last joins the suffix, middle lines insert whole, and the cursor
      # lands at the end of the inserted tail.
      def insert_multiline(text)
        parts = text.split("\n", -1) # JS-split semantics: trailing empties stay (pi's split)
        line = @lines[@cursor_line]
        before = line[0, @cursor_col]
        after = line[@cursor_col..]
        if parts.length == 1
          @lines[@cursor_line] = "#{before}#{text}#{after}"
          set_cursor_col(@cursor_col + text.length)
        else
          @lines[@cursor_line] = before + parts.first
          @lines.insert(@cursor_line + 1, *parts[1...-1]) if parts.length > 2
          last_index = @cursor_line + parts.length - 1
          @lines.insert(last_index, parts.last + after)
          @cursor_line = last_index
          set_cursor_col(parts.last.length)
        end
      end

      # pi deleteYankedText (editor.ts:2085-2112): the previously yanked
      # span's lines removed — single-line deletes backward from the
      # cursor; multi-line collapses [start_line, cursor_line] into one
      # merged line.
      def delete_yanked_text(yanked)
        parts = yanked.split("\n", -1)
        if parts.length == 1
          line = @lines[@cursor_line]
          @lines[@cursor_line] = line[0, @cursor_col - yanked.length] + line[@cursor_col..]
          set_cursor_col(@cursor_col - yanked.length)
        else
          start_line = @cursor_line - (parts.length - 1)
          start_col = @lines[start_line].length - parts.first.length
          after = @lines[@cursor_line][@cursor_col..]
          before = @lines[start_line][0, start_col]
          @lines[start_line, parts.length] = before + after
          @cursor_line = start_line
          set_cursor_col(start_col)
        end
      end

      # Merge the current line into the previous one (plain backspace at
      # a line start — no kill ring push; pi handleBackspace :1432-1443).
      def merge_with_previous_line
        previous = @lines[@cursor_line - 1]
        @lines[@cursor_line - 1] = previous + @lines.delete_at(@cursor_line)
        @cursor_line -= 1
        set_cursor_col(previous.length)
      end

      # pi pushUndoSnapshot (editor.ts:2116-2119): the LIVE state fields
      # go into the snapshot (lines, cursor_line, cursor_col) and the
      # stack's push deep-copies — the mutation that follows can't reach
      # it. pi's snapshot also carries pastes/pasteCounter (editor.ts
      # :225-229) — cut with the large-paste marker feature, itemized.
      def push_undo_snapshot
        @undo_stack.push(Snapshot.new(lines: @lines, cursor_line: @cursor_line, cursor_col: @cursor_col))
      end

      def navigate_history(direction)
        @last_action = nil # pi navigateHistory editor.ts:475
        return if @history.empty?

        new_index = @history_index - direction
        return if new_index < -1 || new_index >= @history.size

        if @history_index == -1 && new_index >= 0
          push_undo_snapshot # pi navigateHistory editor.ts:465 — before the draft capture
          @history_draft = [@lines.dup, @cursor_line, @cursor_col]
        end
        @history_index = new_index
        if @history_index == -1
          lines, line, col = @history_draft || [[""], 0, 0]
          @history_draft = nil
          @lines = lines
          @cursor_line = line
          @cursor_col = col
          @preferred_visual_col = nil # pi's draft restore (editor.ts:495-497)
          @scroll_offset = 0
        else
          entry = @history[@history_index].split("\n", -1)
          @lines = entry
          @cursor_line = direction == -1 ? 0 : entry.length - 1
          set_cursor_col(direction == -1 ? 0 : entry.last.length)
          @scroll_offset = 0 # pi setTextInternal — the render re-derives
        end
      end

      def browsing?
        @history_index != -1
      end

      def empty_editor?
        @lines.length == 1 && @lines[0].empty?
      end
    end
  end
end
