# frozen_string_literal: true

module Tart
  module Render
    # The interactive chat surface (BRIEF §7.1) — the I04 consumer of the I03
    # agent event surface on the I02 kernel.
    #
    # Render model (ported from pi's tui-main-screen.ts): completed content
    # lands as scrollback *above* the live region, the live region at the
    # bottom carries status/spinner, the pending-approval prompt, and the
    # input line. Mechanism is §5.1-sanctioned foundation mechanics: pi
    # diff-redraws the main screen itself; here the ratatui_ruby inline
    # viewport is the live region and {TUI} scrollback insertion
    # (+insert_before+) is how completed content lands above it. Observable
    # contract is parity: completed messages readable above a live bottom
    # region, streaming visible while it happens, terminal restored on
    # exit/interrupt. Assistant completions render through the markdown
    # converter at completion; the live region streams the raw source
    # verbatim (pi renders markdown while streaming — the recorded
    # deviation).
    #
    # Threading: all draws and scrollback insertions happen on the kernel's
    # frame loop (the renderer proc); agent events mutate state under a mutex
    # from the agent fiber; key events arrive through the kernel's on_event.
    # The agent runs as a kernel task (+kernel.async { agent.run }+, event-only
    # run mode) so a kernel interrupt (Ctrl+C) cancels the in-flight turn.
    #
    # Approval: the approval callback runs on the kernel fiber and waits on an
    # +Async::Queue#pop+ — interruptible at the suspension point by
    # Task#stop. The decision is pushed cross-thread (the I03 lost-wakeup
    # cure: a fiber-to-fiber +Async::Queue+ push on the same thread can fail
    # to wake a blocked pop; a cross-thread push is the proven path).
    class Chat
      SPINNER = %w[⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏].freeze

      # How long one draw re-arms the animation window while the agent works
      # (frame pacing: deadline-paced at the frame rate while busy, purely
      # event-driven when idle — the I02 static-loop property).
      BUSY_FRAME_SECONDS = 0.25

      # Rows the pending-approval block occupies in the live region.
      APPROVAL_ROWS = 3

      # Bounded multi-line tool-result preview: at most this many content
      # lines, then an ellipsis row (pi truncates tool output previews).
      TOOL_PREVIEW_LINES = 3

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

      # The style vocabulary — fg colors behind the TUI seam, porting pi's
      # observable distinctions (dark theme): the user echo carries the blue
      # distinction (pi: userMessageBg blue background; fg is the closest
      # analog on a plain span), assistant completions carry their styles
      # per-span through the markdown converter (plain prose stays the
      # terminal default, pi: userMessageText/text), tool output is muted
      # (pi: toolOutput), status is dim (pi: spinner/thinking), interrupts
      # yellow and errors red (pi: warning/error).
      FG = {
        user: :light_blue,
        tool: :gray,
        status: :dark_gray,
        interrupted: :yellow,
        error: :red,
      }.freeze

      # @param session the TUI session (inline viewport).
      # @param kernel [Core::Loop] the kernel; used to open animation windows
      #   and to submit agent runs as kernel tasks.
      def initialize(session:, kernel:)
        @session = session
        @kernel = kernel
        @agent = nil
        @mutex = Mutex.new
        @input = +""
        @cursor = 0
        @history = []
        @history_index = -1 # -1 = not browsing (pi: editor.ts historyIndex)
        @history_draft = nil
        @live = +""
        @busy = false
        @tool = nil
        @pending = nil
        @frames = 0
        @decisions = Async::Queue.new
        # Completed lines awaiting scrollback insertion on the next frame
        # (thread-safe: agent fiber produces, frame loop consumes).
        @scrollback = Queue.new
      end

      # The agent loop this surface drives (wired after construction: the
      # agent's on_event/approval procs reference this chat).
      attr_accessor :agent

      # The slash-command handler (Commands::Handler, bin-wired): leading-
      # "/" submit text routes through it before any agent call. nil (the
      # default; e.g. tests) sends every text to the agent — pre-I10 shape.
      attr_accessor :commands

      # @return [Object, nil] the tool call awaiting an approval decision.
      def pending_approval
        @mutex.synchronize { @pending }
      end

      # @return [Boolean] whether an agent run is in flight.
      def busy?
        @mutex.synchronize { @busy }
      end

      # @return [String] the input line buffer (input is not rendered while
      #   an approval prompt is pending; keys are consumed by the prompt).
      attr_reader :input

      # The kernel renderer proc: drains queued scrollback above the viewport,
      # then builds the live-region widget. A String result would be wrapped
      # in TUI.status_panel by the kernel; this returns the widget itself.
      def renderer
        @renderer_proc ||= -> { render_frame }
      end

      def render_frame
        flush_scrollback
        widget = nil
        @mutex.synchronize do
          @frames += 1
          widget = build_widget
        end
        # Keep frames deadline-paced while the agent works (spinner, live
        # region); idle goes event-driven again on agent_end.
        @kernel.animate(duration: BUSY_FRAME_SECONDS) if busy?
        widget
      end

      # Kernel event sink (every dispatched event, native or synthetic).
      # Ctrl+C never reaches here — the kernel owns it (interrupt).
      def on_event(event, _source = nil)
        return unless event.key? || event.paste?

        decided = nil
        @mutex.synchronize { decided = @pending }
        if decided
          decide(event)
        else
          edit_input(event)
        end
      end

      # Agent event sink (I03 event surface). Runs on the agent fiber.
      def on_agent_event(event)
        handled = nil
        @mutex.synchronize do
          case event[:type]
          when :agent_start
            @busy = true
          when :message_start
            @live = +""
          when :message_update
            chunk = event[:chunk]
            @live << chunk.content if chunk.content.is_a?(String) && !chunk.content.empty?
          when :message_end
            message = event[:message]
            if message.role == :assistant
              handled = complete(message.content)
              # Assistant completions render as markdown (AC5) — at
              # completion only: the live region streamed the raw source.
              enqueue_markdown(handled) if handled
            end
          when :tool_execution_start
            @tool = event[:tool_call].name
          when :tool_execution_end
            @tool = nil
            handled = tool_line(event[:tool_call].name, event[:result])
            enqueue_scrollback(handled, fg: FG[:tool])
          when :agent_end
            @busy = false
            if event[:interrupted] == true
              handled = "interrupted"
              enqueue_scrollback(handled, fg: FG[:interrupted])
            elsif event[:error]
              handled = "error: #{event[:error].message}"
              enqueue_scrollback(handled, fg: FG[:error])
            end
            # A message submitted in the wind-down window (after the agent's
            # final steering check, before agent_end) sits queued with no run
            # in flight — continue the run (pi's queued-message semantics:
            # pi polls the queue at loop start, agent-loop.ts:175).
            if handled.nil? && @agent&.queued_messages?
              @kernel.async { @agent.run }
            end
          end
        end
        @kernel.animate(duration: BUSY_FRAME_SECONDS)
      end

      # The agent loop's approval callback (runs on the kernel fiber).
      # Waits interruptibly for the key-driven decision; +false+ (deny) is
      # the default outcome, pi's permission-dialog semantics.
      def approval(tool_call)
        @mutex.synchronize { @pending = tool_call }
        decision = false
        begin
          @kernel.animate(duration: BUSY_FRAME_SECONDS)
          decision = @decisions.pop # interruptible: Task#stop raises here
        ensure
          @mutex.synchronize { @pending = nil }
          # A raced decision must not pre-approve a later call.
          @decisions.pop until @decisions.empty?
        end
        decision
      end

      class << self
        # Greedy word wrap to +width+ visible columns; over-long words hard-split.
        # pi wraps with ANSI/grapheme awareness (utils.ts); plain text is this
        # iteration's recorded scope.
        def wrap(text, width)
          return [""] if text.empty?

          text.lines(chomp: true).flat_map { |line| wrap_line(line, width) }
        end

        def wrap_line(line, width)
          out = []
          while TUI.text_width(line) > width
            head, consumed = fit(line, width)
            out << head
            line = line[consumed..]
          end
          out << line
          out
        end

        # Word-wrap one styled markdown row to +width+ visible columns: the
        # {fit} word-wrap over the row's visible text, spans re-grouped per
        # wrapped line (pi wraps rendered markdown to the terminal width).
        # Rows that fit — and blank rows — pass through unchanged.
        def wrap_row(row, width)
          return [row] if row.empty? || TUI.text_width(row.map(&:text).join) <= width

          cells = row.flat_map { |span| span.text.chars.product([span]) }
          out = []
          until cells.empty?
            head, consumed = fit(cells.map(&:first).join, width)
            out << styled_row(cells[0, head.length])
            cells = cells[consumed..] || []
          end
          out
        end

        # Wrapped cells re-grouped into spans (consecutive chars of one
        # source span coalesce back into a single run).
        def styled_row(cells)
          cells.chunk_while { |(_, a), (_, b)| a.equal?(b) }.map do |group|
            span = group.first[1]
            Render::Markdown::Span.new(text: group.map(&:first).join, fg: span.fg, modifiers: span.modifiers)
          end
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

        # Longest prefix of +line+ fitting +width+, preferring a word break.
        # Returns [head, chars_consumed].
        def fit(line, width)
          w = 0
          line.chars.each_with_index do |char, i|
            char_width = TUI.text_width(char)
            break if w + char_width > width

            w += char_width
          end
          return [line, w] if w == line.length

          if line[w] == " "
            [line[0, w], w + 1] # word boundary at the width edge; consume the space
          elsif (space_break = line[0, w].rindex(" "))
            [line[0, space_break], space_break + 1] # break before the last word; consume the space
          elsif w.positive?
            [line[0, w], w] # hard split
          else
            [line.chars.first, 1] # over-wide first grapheme; force progress
          end
        end
      end

      private

      # Completed content: queued for insertion above the live region.
      # Mutex context (called from on_agent_event); returns the final text
      # (nil when nothing to show).
      def complete(text)
        @live = +""
        return nil if !text.is_a?(String) || text.empty?

        text
      end

      # Verbatim completed text (user echo, tool output, status): wrapped to
      # the viewport width, one line-level fg.
      def enqueue_scrollback(text, fg:)
        return if text.nil? || text.empty?

        @scrollback << Chat.wrap(text, viewport_width).map { |line| TUI.line(line, fg:) }
      end

      # Assistant completions render through the markdown converter (AC5):
      # styled rows wrapped to the viewport width, span styling intact, then
      # converted row → Line at the TUI seam. The live region streamed the
      # raw source verbatim — markdown renders at completion only (the
      # recorded deviation from pi's streaming markdown rendering).
      def enqueue_markdown(text)
        return if text.nil? || text.empty?

        width = viewport_width
        rows = Render::Markdown.rows(text, width:).flat_map { |row| Chat.wrap_row(row, width) }
        @scrollback << rows.map { |row| TUI.markdown_line(row) }
      end

      # Bounded multi-line preview (pi truncates tool output): the first
      # TOOL_PREVIEW_LINES non-empty lines, then an ellipsis row.
      def tool_line(name, result)
        text = result.is_a?(Hash) ? (result[:error] || result[:content] || "").to_s : result.to_s
        lines = text.lines(chomp: true).map(&:rstrip).reject(&:empty?)
        return "  ⎿ #{name}" if lines.empty?

        preview = lines.first(TOOL_PREVIEW_LINES)
        preview << "…" if lines.size > TOOL_PREVIEW_LINES
        rest = preview[1..].map { |line| "    #{line}" }
        (["  ⎿ #{name}: #{preview.first}"] + rest).join("\n")
      end

      def viewport_width
        area = @session.viewport_area
        area ? area.width : 80
      end

      # Pending-approval keys: y/Y approve, n/N deny, everything else is
      # consumed by the prompt (never reaches the chat input line).
      def decide(event)
        return unless event.key?

        case event.code
        when "y", "Y" then resolve(true)
        when "n", "N" then resolve(false)
        end
      end

      # Cross-thread push (the I03 lost-wakeup cure): the waiting fiber is on
      # the reactor thread; a fiber-to-fiber Async::Queue push can fail to
      # wake it, a cross-thread push is the proven path.
      def resolve(value)
        Thread.new { @decisions << value }.join
      end

      # The input-line editor (pi's Input, components/input.ts): a cursor
      # into the buffer, mid-line editing, in-memory history, and word-wise
      # operations (word-navigation.ts boundary semantics). The key surface
      # is exactly the events the kernel forwards (code + ctrl/alt/shift
      # modifiers), bound per pi's keybindings.ts defaults. Editing and
      # movement keys leave history browsing (pi: exitHistoryBrowsing);
      # edit units are chars where pi uses graphemes (single-line input,
      # recorded simplification).
      def edit_input(event)
        if event.paste?
          insert(event.content)
          return
        end

        ctrl = event.modifiers.include?("ctrl")
        alt = event.modifiers.include?("alt")
        case event.code
        when "enter" then submit
        when "backspace" then alt ? delete_word_backward : delete_backward
        when "delete" then alt ? delete_word_forward : delete_forward
        when "left" then (alt || ctrl) ? move_word_backward : move_left
        when "right" then (alt || ctrl) ? move_word_forward : move_right
        when "up" then history_previous
        when "down" then history_next
        when "home" then move_start
        when "end" then move_end
        when "a" then ctrl ? move_start : insert_printable(event)
        when "e" then ctrl ? move_end : insert_printable(event)
        when "b" then alt ? move_word_backward : (ctrl ? move_left : insert_printable(event))
        when "f" then alt ? move_word_forward : (ctrl ? move_right : insert_printable(event))
        when "d" then alt ? delete_word_forward : (ctrl ? delete_forward : insert_printable(event))
        when "w" then ctrl ? delete_word_backward : insert_printable(event)
        else insert_printable(event)
        end
      end

      # pi's submit path (interactive-mode.ts:3200-3442): a leading "/"
      # routes through the commands module before any agent call —
      # /skill:<name> expands (unknown skill passes through as plain text),
      # builtins dispatch when idle, and text matching nothing falls through
      # to the agent as a plain message. Deviation (itemized): pi's builtin
      # if-chain precedes its streaming branch, so pi dispatches builtins
      # mid-turn (/compact aborts the turn first) — the port routes ALL
      # slash text through the steer path while a turn runs.
      def submit
        text = @input.dup
        return if text.strip.empty?

        add_to_history(text)
        @input.clear
        @cursor = 0
        exit_history_browsing
        enqueue_scrollback("❯ #{text}", fg: FG[:user])
        if @commands && text.start_with?("/")
          text = @commands.expand_skill(text)
          return if !busy? && @commands.dispatch(text)
        end
        if busy?
          @agent.push_message(text) # steering: consumed at the next turn boundary
        else
          @kernel.async { @agent.run(text) }
        end
      end

      # Slash-command output (pi's chat-line status UX): a muted line in
      # scrollback. Thread-safe — the kernel task calls this off-frame.
      def command_line(text)
        @mutex.synchronize { enqueue_scrollback(text, fg: FG[:tool]) }
      end

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

      # pi's live region: the bottom viewport shows status, the streaming
      # message tail, and the input line — as many rows as the viewport
      # affords, everything beyond clipped at the top. During an approval
      # prompt the input line is displaced (pi: the dialog replaces the
      # editor in the editor container) and its keys are consumed.
      def build_widget
        lines = []
        lines << TUI.line(status_line, fg: FG[:status]) if @busy
        lines.concat(live_lines.map { |line| TUI.line(line) }) # assistant: terminal default
        if @pending
          lines.concat(approval_lines.map { |line| TUI.line(line, fg: FG[:interrupted]) })
        else
          lines << TUI.line(input_spans)
        end
        lines = lines.last(viewport_height) if viewport_height
        TUI.paragraph(text: lines, wrap: false)
      end

      def status_line
        detail = @tool ? "tool: #{@tool}" : (@live.empty? ? "thinking" : "…")
        "#{SPINNER[@frames % SPINNER.size]} #{detail}"
      end

      # --- input-line editing primitives (each leaves history browsing) ---

      def insert(text)
        exit_history_browsing
        @input.insert(@cursor, text)
        @cursor += text.length
      end

      def delete_backward
        exit_history_browsing
        return if @cursor.zero?

        @input = @input[0, @cursor - 1] + @input[@cursor..]
        @cursor -= 1
      end

      def delete_forward
        exit_history_browsing
        return if @cursor >= @input.length

        @input = @input[0, @cursor] + @input[(@cursor + 1)..]
      end

      def move_left
        exit_history_browsing
        @cursor -= 1 if @cursor.positive?
      end

      def move_right
        exit_history_browsing
        @cursor += 1 if @cursor < @input.length
      end

      def move_start
        exit_history_browsing
        @cursor = 0
      end

      def move_end
        exit_history_browsing
        @cursor = @input.length
      end

      def move_word_backward
        exit_history_browsing
        @cursor = self.class.find_word_backward(@input, @cursor)
      end

      def move_word_forward
        exit_history_browsing
        @cursor = self.class.find_word_forward(@input, @cursor)
      end

      # pi's deleteWordBackwards (input.ts:309): move one word backward,
      # delete what the move crossed.
      def delete_word_backward
        return if @cursor.zero?

        exit_history_browsing
        target = self.class.find_word_backward(@input, @cursor)
        @input = @input[0, target] + @input[@cursor..]
        @cursor = target
      end

      def delete_word_forward
        return if @cursor >= @input.length

        exit_history_browsing
        target = self.class.find_word_forward(@input, @cursor)
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

      # The input row as spans with pi's fake cursor (tui.ts:205
      # renderFakeCursor via editor.ts:583-597): the grapheme at the
      # insertion point renders inverse-video; at end-of-input a highlighted
      # trailing space. The port's readback-provable analog carries the
      # reversed modifier (the hardware cursor is unreachable through the
      # tree-draw seam and not cell-readable). Input beyond one row clips at
      # the viewport edge (pre-existing; pi scrolls horizontally).
      def input_spans
        at = @input[@cursor]
        spans = [TUI.span("❯ "), TUI.span(@input[0, @cursor] || "")]
        return spans << TUI.span(" ", modifiers: [:reversed]) unless at

        spans << TUI.span(at, modifiers: [:reversed]) << TUI.span(@input[(@cursor + 1)..])
      end

      # The streaming text, wrapped to the viewport width, as many tail
      # lines as fit above the other live-region rows (deltas append; the
      # window slides): the status line while busy, then the approval block
      # (APPROVAL_ROWS rows) or the input line. (The final clip in
      # build_widget stays authoritative; this estimate is what keeps a
      # full live tail from pushing those rows out from under it.)
      def live_lines
        return [] if @live.empty?

        wrapped = self.class.wrap(@live, viewport_width)
        fixed = (@busy ? 1 : 0) + (@pending ? APPROVAL_ROWS : 1)
        budget = viewport_height ? viewport_height - fixed : wrapped.size
        wrapped.last([budget, 0].max)
      end

      def viewport_height
        area = @session.viewport_area
        area ? area.height : nil
      end

      def approval_lines
        args = JSON.generate(@pending.arguments) rescue @pending.arguments.to_s
        [
          "approve #{@pending.name}?",
          args.length > viewport_width ? args[0, viewport_width] : args,
          "y = yes, n = no"
        ]
      end

      # Insert queued lines above the live viewport (pi: completed content
      # into scrollback). Entries are final display lines (plain text at a
      # line-level fg, or markdown-vocabulary rows converted at the seam).
      # Must never run inside a draw — the kernel calls the renderer before
      # drawing, and insert_before itself raises during draw.
      def flush_scrollback
        until @scrollback.empty?
          lines = @scrollback.pop
          @session.insert_before(lines.size, TUI.paragraph(text: lines))
        end
      end
    end
  end
end
