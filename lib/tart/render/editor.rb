# frozen_string_literal: true

module Tart
  module Render
    # The input-line editor (pi's Input, components/input.ts): a cursor
    # into the buffer, mid-line editing, in-memory history, and word-wise
    # operations (word-navigation.ts boundary semantics). The key surface
    # is exactly the events the kernel forwards (code + ctrl/alt/shift
    # modifiers), bound per pi's keybindings.ts defaults — the binding
    # itself is the Chat coordinator's dispatch; the Editor owns the
    # state and the operations. Editing and movement keys leave history
    # browsing (pi: exitHistoryBrowsing); edit units are chars where pi
    # uses graphemes (single-line input, recorded simplification).
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

      # @return [String] the input line buffer.
      # @return [Integer] the cursor — a char offset into {input} (the
      #   test readback for the cursor-moving operations).
      attr_reader :input, :cursor

      def initialize
        @input = +""
        @cursor = 0
        @history = []
        @history_index = -1 # -1 = not browsing (pi: editor.ts historyIndex)
        @history_draft = nil
        @kill_ring = KillRing.new
        @last_action = nil
      end

      # The clear op (the escape bash-mode clear and the ctrl+c app.clear —
      # both Chat branches ran exactly these two lines at base).
      def clear
        @input.clear
        @cursor = 0
        @last_action = nil
      end

      # The completion-apply write surface (pi applyCompletion): the token
      # region [lead, cursor) is replaced whole — text and cursor land
      # together (no grapheme-wise edit, no history-browsing exit —
      # verbatim base behavior).
      def replace_token(lead, text, cursor)
        @input = "#{@input[0, lead]}#{text}"
        @cursor = cursor
        @last_action = nil
      end

      # --- input-line editing primitives (each leaves history browsing) ---

      # pi insertCharacter (editor.ts:1201-1213) tags typing "type-word";
      # the port's paste path shares this insert (pi's handlePaste leaves
      # the slot nil) — observation-free: the slot is only ever tested
      # against :kill/:yank, and both values sit outside those windows.
      def insert(text)
        exit_history_browsing
        @input.insert(@cursor, text)
        @cursor += text.length
        @last_action = :type_word
      end

      def delete_backward
        exit_history_browsing
        @last_action = nil # pi handleBackspace editor.ts:1374
        return if @cursor.zero?

        @input = @input[0, @cursor - 1] + @input[@cursor..]
        @cursor -= 1
      end

      def delete_forward
        exit_history_browsing
        @last_action = nil # pi handleForwardDelete editor.ts:1781
        return if @cursor >= @input.length

        @input = @input[0, @cursor] + @input[(@cursor + 1)..]
      end

      def move_left
        exit_history_browsing
        @last_action = nil # pi moveCursor editor.ts:1892
        @cursor -= 1 if @cursor.positive?
      end

      def move_right
        exit_history_browsing
        @last_action = nil
        @cursor += 1 if @cursor < @input.length
      end

      def move_start
        exit_history_browsing
        @last_action = nil # pi moveToLineStart editor.ts:1613
        @cursor = 0
      end

      def move_end
        exit_history_browsing
        @last_action = nil # pi moveToLineEnd editor.ts:1618
        @cursor = @input.length
      end

      def move_word_backward
        exit_history_browsing
        @last_action = nil # pi moveWordBackwards editor.ts:1961
        @cursor = self.class.find_word_backward(@input, @cursor)
      end

      def move_word_forward
        exit_history_browsing
        @last_action = nil # pi moveWordForwards
        @cursor = self.class.find_word_forward(@input, @cursor)
      end

      # --- the emacs kill ring (I26): pi's kill/yank slice — every kill
      # op exits history browsing first (editor.ts:1627) and pushes the cut
      # span (backward = prepend, forward = append), accumulating iff the
      # previous action was itself a kill (the lastAction window,
      # editor.ts:352). The single-line editor's at-column-0/end-of-line
      # line-merge branches (editor.ts:1641-1655, 1673-1686) are N/A —
      # itemized cuts, never silent.

      # pi deleteToStartOfLine (editor.ts:1626-1655).
      def delete_to_line_start
        exit_history_browsing
        return if @cursor.zero?

        @kill_ring.push(@input[0, @cursor], prepend: true, accumulate: @last_action == :kill)
        @last_action = :kill
        @input = @input[@cursor..]
        @cursor = 0
      end

      # pi deleteToEndOfLine (editor.ts:1657-1687).
      def delete_to_line_end
        exit_history_browsing
        return if @cursor >= @input.length

        @kill_ring.push(@input[@cursor..], prepend: false, accumulate: @last_action == :kill)
        @last_action = :kill
        @input = @input[0, @cursor]
      end

      # pi yank (editor.ts:1998-2007): paste the most recent entry at the
      # cursor; the insert leaves history browsing (pi insertYankedText).
      def yank
        return if @kill_ring.length.zero?

        text = @kill_ring.peek
        exit_history_browsing
        @input = "#{@input[0, @cursor]}#{text}#{@input[@cursor..]}"
        @cursor += text.length
        @last_action = :yank
      end

      # pi yankPop (editor.ts:2013-2031): only immediately after a yank
      # and with more than one entry; the previously yanked span (the peek
      # before rotation) is deleted, the ring rotates, the new peek is
      # inserted.
      def yank_pop
        return unless @last_action == :yank && @kill_ring.length > 1

        yanked = @kill_ring.peek
        exit_history_browsing
        @input = @input[0, @cursor - yanked.length] + @input[@cursor..]
        @cursor -= yanked.length
        @kill_ring.rotate
        text = @kill_ring.peek
        @input = "#{@input[0, @cursor]}#{text}#{@input[@cursor..]}"
        @cursor += text.length
        @last_action = :yank
      end

      # pi deleteWordBackwards (editor.ts:1692-1735) is a kill op: the
      # crossed span enters the ring, accumulating per the lastAction
      # window captured BEFORE the movement resets it (input.ts:309 shape).
      def delete_word_backward
        return if @cursor.zero?

        exit_history_browsing
        was_kill = @last_action == :kill
        target = self.class.find_word_backward(@input, @cursor)
        @kill_ring.push(@input[target...@cursor], prepend: true, accumulate: was_kill)
        @last_action = :kill
        @input = @input[0, target] + @input[@cursor..]
        @cursor = target
      end

      # pi deleteWordForward (editor.ts:1737-1775), the mirror kill op.
      def delete_word_forward
        return if @cursor >= @input.length

        exit_history_browsing
        was_kill = @last_action == :kill
        target = self.class.find_word_forward(@input, @cursor)
        @kill_ring.push(@input[@cursor...target], prepend: false, accumulate: was_kill)
        @last_action = :kill
        @input = @input[0, @cursor] + @input[target..]
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

      # --- history ---

      # pi's editor history (components/editor.ts addToHistory): trimmed,
      # no consecutive duplicates, capped, most recent first.
      def add_to_history(text)
        trimmed = text.strip
        return if trimmed.empty? || @history.first == trimmed

        @history.unshift(trimmed)
        @history.pop if @history.size > HISTORY_LIMIT
      end

      # pi's navigateHistory (editor.ts:454-484): -1 is the live draft; up
      # walks toward older entries (index 0 = most recent), down back toward
      # the draft. The draft is captured when browsing starts and restored
      # at -1. Up places the cursor at line start, down at line end
      # (cursorPlacement "start"/"end"). The port is single-line, so up/down
      # always navigate (pi: only from the first/last visual line).
      def history_previous = navigate_history(-1)

      def history_next = navigate_history(1)

      def navigate_history(direction)
        @last_action = nil # pi navigateHistory editor.ts:454
        return if @history.empty?

        new_index = @history_index - direction
        return if new_index < -1 || new_index >= @history.size

        @history_draft = [@input.dup, @cursor] if @history_index == -1 && new_index >= 0
        @history_index = new_index
        if @history_index == -1
          @input, @cursor = @history_draft || ["", 0]
          @history_draft = nil
        else
          @input = @history[@history_index].dup
          @cursor = direction == -1 ? 0 : @input.length
        end
      end

      # --- queries ---

      # pi isBashMode (interactive-mode.ts:3125): the trimmed input starts
      # with "!" — the editor's border announces the whole-line bash.
      def bash_mode?
        @input.start_with?("!")
      end

      # The slash token before the cursor, or nil: an optional-whitespace-led
      # "/" first token with no space before the cursor (pi
      # isInSlashCommandContext custom-editor.ts:2202-2204 + the provider's
      # no-space rule tui/autocomplete.ts:340-341 — a space means argument
      # completion, which the port has none of).
      def slash_token
        lead = @input.index(/\S/)
        return nil if lead.nil? || @input[lead] != "/" || lead >= @cursor

        token = @input[lead...@cursor]
        token unless token.match?(/\s/)
      end

      # The input row as spans with pi's fake cursor (tui.ts:205
      # renderFakeCursor via editor.ts:583-597): the grapheme at the
      # insertion point renders inverse-video; at end-of-input a highlighted
      # trailing space. The port's readback-provable analog carries the
      # reversed modifier (the hardware cursor is unreachable through the
      # tree-draw seam and not cell-readable). Input beyond one row clips at
      # the editor's inner width (pre-existing; pi scrolls horizontally).
      def input_spans
        at = @input[@cursor]
        spans = [TUI.span(@input[0, @cursor] || "")]
        return spans << TUI.span(" ", modifiers: [:reversed]) unless at

        spans << TUI.span(at, modifiers: [:reversed]) << TUI.span(@input[(@cursor + 1)..])
      end

      class << self

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

      end
    end
  end
end
