# frozen_string_literal: true

require "open3"

module Tart
  module Render
    # The interactive chat surface (BRIEF §7.1) — the I11 fullscreen
    # three-area composition of the I03 agent event surface on the I02
    # kernel.
    #
    # Render model (ported from pi's fullscreen chat viewport,
    # chat-viewport.ts createChatViewport): the surface owns a scrollback
    # buffer and every frame composes a vertical Layout — a transcript area
    # (the buffer's visible tail, with the streaming message's raw source at
    # its end), a bordered editor area whose top border carries the status
    # line (pi custom-editor.ts renderTopBorder), and a two-line footer (pi
    # footer.ts). The ratatui_ruby inline viewport + insert_before path is
    # retired from the interactive surface (it stays in the TUI seam for any
    # other caller); the buffer is redrawn wholesale each frame, which is
    # what makes resize redrawing clobber-proof.
    #
    # Threading: all draws happen on the kernel's frame loop (the renderer
    # proc); agent events mutate state under a mutex from the agent fiber;
    # key events arrive through the kernel's on_event. The agent runs as a
    # kernel task (+kernel.async { agent.run }+, event-only run mode) so a
    # kernel interrupt (Ctrl+C) cancels the in-flight turn. (I14: the
    # approval UI is deleted — pi has no permissions system; the plumbing
    # side lives in the agent lane.)
    class Chat
      SPINNER = %w[⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏].freeze

      # How long one draw re-arms the animation window while the agent works
      # (frame pacing: deadline-paced at the frame rate while busy, purely
      # event-driven when idle — the I02 static-loop property).
      BUSY_FRAME_SECONDS = 0.25

      # Rows the footer always occupies (pi renders a pwd line + a stats
      # line — footer.ts:169-171).
      FOOTER_ROWS = 2

      # Smallest editor area: top border, one input row, bottom border (pi
      # chat-viewport.ts:33 editor minSize 3).
      MIN_EDITOR_ROWS = 3

      # Bounded multi-line tool-result preview: at most this many content
      # lines, then an ellipsis row (pi truncates tool output previews).
      TOOL_PREVIEW_LINES = 3

      # The tool name that dispatches to pi's shell renderers (bash.ts:115
      # createShellRenderers — shared by bash and powershell; the port
      # runs bash only).
      BASH_TOOL = "bash".freeze

      # The file tools that dispatch to pi's per-tool renderers (I18 —
      # write.ts/read.ts renderCall/renderResult); everything else
      # non-bash keeps the generic ⎿ line (I17's ruling).
      WRITE_TOOL = "write".freeze
      READ_TOOL = "read".freeze

      # pi write.ts:113 (formatWriteCall): at most this many content lines
      # render unexpanded, then the expand hint.
      WRITE_PREVIEW_LINES = 10

      # pi read.ts:56 (COMPACT_RESOURCE_FILE_NAMES) — the file names whose
      # read collapses to the compact `read resource` shape.
      COMPACT_RESOURCE_FILE_NAMES = ["AGENTS.override.md", "AGENTS.md", "AGENTS.MD", "CLAUDE.md", "CLAUDE.MD"].freeze

      # History depth (pi: editor.ts addToHistory caps at 100 entries).
      HISTORY_LIMIT = 100

      # Suggestion-list window (pi editor.ts:322 default 5; the 3-20 clamp
      # is settings-backed — cut, itemized deviation: fixed at the default).
      AUTOCOMPLETE_MAX = 5

      # Session-picker window (pi session-selector.ts:302 maxVisible 10).
      PICKER_MAX = 10

      # Wheel scroll (item 6, pi tui-alt-screen.ts): lines per event — the
      # library default (:271, `options.wheelScrollLines ?? 1`; the app-level
      # "auto" accelerator and its fullscreen-wheel-scroll-lines settings
      # knob are cut, itemized) — and the alt+wheel multiplier (:79
      # ALT_WHEEL_SCROLL_MULTIPLIER = 5).
      WHEEL_LINES_PER_EVENT = 1
      ALT_WHEEL_MULTIPLIER = 5

      # Wheel direction → scroll delta (pi parseWheelEvent :705-723: wheel up
      # scrolls up).
      WHEEL_DIRECTION = {"scroll_up" => -1, "scroll_down" => 1}.freeze

      # Double/triple-click window (pi DOUBLE_CLICK_INTERVAL_MS :82 = 500ms;
      # the count cycles 1 → 2 → 3 → 1 on the same row and word range —
      # getClickCount :1247-1267).
      DOUBLE_CLICK_SECONDS = 0.5

      # Word-selection joiners (pi TERMINAL_WORD_SELECTION_JOINERS :85): paths
      # and kebab-case tokens stay whole across a word boundary.
      WORD_JOINERS = "/-".freeze

      # pi status-indicator.ts:85-95 — the compaction-start border labels,
      # minus the cancel hint (deviation: ctrl+c aborts the whole run in the
      # port, not just the compaction — BRIEF §5.1, itemized).
      COMPACTION_LABELS = {
        manual: "Compacting context...",
        threshold: "Auto-compacting...",
        overflow: "Context overflow detected, Auto-compacting..."
      }.freeze

      # A selection endpoint in transcript-buffer coordinates (pi
      # SelectionPoint reduced to content rows: the port's selection is
      # anchored to buffer lines, so it survives scrolling — pi stores
      # scrollView content rows exactly the same way,
      # getScrollSelectionPoint :1133-1155). +boundary+ marks an exclusive
      # end (word/line granularity — pi SelectionPoint.boundary).
      Point = Struct.new(:row, :col, :boundary)

      # The owner's ascii-art collection (tart-mode's mark) — one random
      # piece per MOTD render (boot and /new). pi-mode renders pi's actual
      # half-block mark instead ({pi_mark}).
      LOGOS_DIR = File.expand_path("logos", __dir__)

      # The MOTD hints line — the PORT's real keys only (pi's `!` bash
      # mode, escape-to-clear, ctrl+c-twice and the thinking/model cycles
      # have no port binding; cut, itemized).
      HINTS_LINE = "ctrl+c interrupt/quit · ctrl+d exit (empty) · / commands · pgup/pgdn scroll".freeze

      # pi-mode's built-in header text (pi interactive-mode.ts:1045-1053 —
      # compactInstructions joined with muted " · ", compactOnboarding,
      # onboarding). The keybindings behind escape-to-clear, `!` bash and
      # the ctrl+o expand are cut (itemized) — the hint TEXT renders for
      # byte parity, per the identity contract.
      PI_HINTS_LINE = "escape interrupt · ctrl+c/ctrl+d clear/exit · / commands · ! bash · ctrl+o more".freeze
      PI_NOTICE_LINE = "Press ctrl+o to show full startup help and loaded resources.".freeze
      PI_ONBOARDING_LINE = "Pi can explain its own features and look up its docs. Ask it how to use or extend Pi.".freeze

      # pi's outputPad (interactive-mode.ts:516, default 1): one leading
      # space on every content row of the chat surface — the header's Text
      # paddingX (interactive-mode.ts:1060-1063), the echo's and the
      # assistant's Markdown paddingX (user-message.ts:23,
      # assistant-message.ts:120-127). Blank rows carry no pad (pi's
      # Spacer renders empty rows).
      OUTPUT_PAD = " ".freeze

      # One random art piece's lines (empty collection → no logo lines).
      def motd_logo_lines
        file = Dir[File.join(LOGOS_DIR, "*.txt")].sample
        file ? File.readlines(file, chomp: true) : []
      end

      # The boundary classes of pi's word navigation (word-navigation.ts with
      # utils.ts:1006 PUNCTUATION_REGEX and :1011 isWhitespaceChar). The
      # Intl.Segmenter word-like segment is approximated by word-character
      # runs (recorded simplification); ASCII punctuation stays a boundary
      # either way — pi's PUNCTUATION_REGEX sub-rule.
      PUNCTUATION = /[(){}\[\]<>.,;:'"!?+\-=*\/\\|&%^$#@~`]/.freeze
      WORD_CHAR = /[[:alnum:]_]/.freeze
      WHITESPACE = /\s/.freeze

      # The git branch reader (pi footer-data-provider.ts:52-70, reduced):
      # one +git symbolic-ref+ per turn, nil when not on a branch (detached
      # HEAD or no repo — pi labels detached "detached"; the port omits the
      # segment, recorded). Injected so tests never shell out.
      DEFAULT_BRANCH_READER = lambda do |cwd|
        out, _err, status = Open3.capture3("git", "--no-optional-locks", "symbolic-ref",
          "--quiet", "--short", "HEAD", chdir: cwd)
        status.success? && !out.empty? ? out.strip : nil
      end

      # @param session the TUI session (fullscreen viewport).
      # @param kernel [Core::Loop] the kernel; used to open animation windows
      #   and to submit agent runs as kernel tasks.
      # @param footer_data [Hash, nil] launcher-wired footer facts (AC4):
      #   +:cwd+ (the working directory), +:model+ (the resolved model id),
      #   +:context_window+ (the I10 resolved window — the usage
      #   denominator), +:auto_compact+ (the compaction-enabled indicator),
      #   +:thinking_level+ (the settings-resolved level; the footer
      #   renders +model • <level>+, nil → the model alone). nil renders
      #   the footer from what the surface knows alone.
      # @param branch_reader [Proc] +call(cwd)+ → branch name or nil.
      # @param autocomplete [Object, nil] the completion-source seam (AC1):
      #   answers +items+ with the full {value:, label:, description:}
      #   catalog the surface fuzzy-filters. nil (the default) offers no
      #   suggestions — headless tests stay deterministic; bin/tart wires
      #   the real command/skill sources (see {SlashSource}).
      # @param motd [Boolean] render the startup MOTD block on the first
      #   frame (and on {new_session}); tests that pin plain transcript
      #   content opt out, the launcher's default renders it.
      # @param identity [String] the resolved face (Tart::Identity) the
      #   MOTD renders — pi's header bytes vs the owner's art + tart
      #   header. Structural items (padding, spacers, footer format) are
      #   identity-independent.
      # @param settings_root [String] the user config dir the MOTD's
      #   [Context] section reports (injectable so tests never touch
      #   ~/.tart).
      def initialize(session:, kernel:, footer_data: nil, branch_reader: DEFAULT_BRANCH_READER, autocomplete: nil,
        motd: true, identity: Identity::DEFAULT, settings_root: Agent::Session.default_root)
        @session = session
        @kernel = kernel
        @footer_data = footer_data
        @branch_reader = branch_reader
        @agent = nil
        @autocomplete = autocomplete
        @mutex = Mutex.new
        @input = +""
        @cursor = 0
        @history = []
        @history_index = -1 # -1 = not browsing (pi: editor.ts historyIndex)
        @history_draft = nil
        # Active autocomplete list: the filtered items + the selection index
        # (pi editor.ts autocompleteState/autocompleteList + SelectList).
        @suggestions = nil
        @selected = 0
        # Transcript scroll state (pi ScrollView follow-end semantics): the
        # viewport's top-line offset over the buffer; +@follow+ while pinned
        # to the end (the default — the tail is what's visible).
        @scroll_offset = 0
        @follow = true
        # Mouse selection state (item 10, pi tui-alt-screen.ts:83-107):
        # anchor/focus points, granularity (:character/:word/:line), the
        # initial word/line range a drag extends, and the multi-click
        # bookkeeping. Reactor-side only (the kernel's event sink and the
        # renderer share the frame loop's thread).
        @selection = nil
        @last_click = nil
        # The running compaction's reason (the border-status label's key).
        @compaction_reason = nil
        # The /resume session picker (item 2, pi SessionSelectorComponent
        # reduced): nil = closed; open it holds {items:, selected:} with
        # items the launcher-built [{path:, label:}] list (newest first).
        @picker = nil
        @live = +""
        # The in-flight message's reasoning (pi's live thinking block): the
        # joined chunk.thinking deltas, rendered dim while it grows and
        # flushed as the completed thinking block at :message_end (the loop
        # strips Message#thinking before the surface sees the event —
        # loop.rb strip_thinking_replay).
        @reasoning = +""
        @busy = false
        @tool = nil
        @frames = 0
        # Completed lines awaiting the transcript buffer on the next frame
        # (thread-safe: agent fiber produces, frame loop consumes).
        @scrollback = Queue.new
        # The surface-owned scrollback buffer (final display Lines) — the
        # transcript area draws its visible tail every frame.
        @transcript = []
        # Footer usage state: session-cumulative token totals accumulated at
        # each assistant completion, the latest assistant usage (the context
        # numerator), and the staleness flag pi's post-compaction "?" comes
        # from (footer.ts getSessionStats / contextUsage).
        @usage_totals = {input: 0, output: 0, cache_read: 0, cache_write: 0}
        @last_usage = nil
        @usage_stale = false
        @branch = nil
        @branch_fetched = false
        @settings_root = settings_root
        @identity = identity
        @motd_pending = motd # rendered on the first frame, once wired
        # pi's chat container is a separate component from the header
        # (interactive-mode.ts:633-639); its leading-spacer gate (children
        # non-empty, :3930-3931) reads this — any chat region since the
        # boot/new/resume reset, header excluded.
        @chat_started = false
      end

      # The agent loop this surface drives (wired after construction: the
      # agent's on_event/approval procs reference this chat).
      attr_accessor :agent

      # The slash-command handler (Commands::Handler, bin-wired): leading-
      # "/" submit text routes through it before any agent call. nil (the
      # default; e.g. tests) sends every text to the agent — pre-I10 shape.
      attr_accessor :commands

      # The resume seam (bin/tart-wired): the session picker's enter key
      # calls +call(path)+ with the selected session file; the launcher
      # swaps in the fresh agent (start_session) and replays the transcript
      # ({resume_session}).
      attr_accessor :on_resume

      # The launcher-wired footer facts (see #initialize).
      attr_writer :footer_data

      # @return [Boolean] whether an agent run is in flight.
      def busy?
        @mutex.synchronize { @busy }
      end

      # @return [String] the input line buffer.
      attr_reader :input

      # @return [Array<String>] the transcript buffer's display lines (test
      #   readback for kernel-driven tests, where the drawn widget tree is
      #   the only observable).
      def transcript_lines
        @mutex.synchronize { @transcript.map { |line| line.spans.map(&:content).join } }
      end

      # @return [Array<Hash>, nil] the active suggestion items (test
      #   readback — the list is otherwise visible only in the drawn tree).
      def suggestions
        @mutex.synchronize { @suggestions }
      end

      # @return [Integer] the active list's selection index (test readback).
      def suggestions_index
        @mutex.synchronize { @selected }
      end

      # @return [Array<Hash>, nil] the open session picker's items (test
      #   readback; nil = closed).
      def picker_items
        @mutex.synchronize { @picker&.fetch(:items) }
      end

      # @return [Integer] the picker's selection index (test readback).
      def picker_index
        @mutex.synchronize { @picker ? @picker[:selected] : 0 }
      end

      # @return [Integer] the transcript viewport's top-line offset (test
      #   readback; maintained at render time).
      def scroll_offset
        @mutex.synchronize { @scroll_offset }
      end

      # The kernel renderer proc: builds the fullscreen three-area widget.
      # A String result would be wrapped in TUI.status_panel by the kernel;
      # this returns the widget itself.
      def renderer
        @renderer_proc ||= -> { render_frame }
      end

      def render_frame
        widget = nil
        @mutex.synchronize do
          enqueue_motd if @motd_pending
          @motd_pending = false
          flush_scrollback
          @frames += 1
          widget = build_widget
        end
        # Keep frames deadline-paced while the agent works (spinner, live
        # region); idle goes event-driven again on agent_end.
        @kernel.animate(duration: BUSY_FRAME_SECONDS) if busy?
        widget
      end

      # Kernel event sink (every dispatched event, native or synthetic).
      # Ctrl+C never reaches here — the kernel owns it (interrupt). Mouse
      # events route to the surface's wheel-scroll/selection machinery;
      # resize is ignored (the kernel marks the frame dirty either way and
      # the next frame recomposes from the session's fresh viewport).
      def on_event(event, _source = nil)
        return handle_mouse(event) if event.respond_to?(:mouse?) && event.mouse?
        return unless event.key? || event.paste?

        edit_input(event)
      end

      # Agent event sink (I03 event surface). Runs on the agent fiber.
      def on_agent_event(event)
        handled = nil
        @mutex.synchronize do
          case event[:type]
          when :agent_start
            @busy = true
            @branch = nil # per-turn branch invalidation (pi's provider cache, reduced)
            @branch_fetched = false
          when :message_start
            @live = +""
            @reasoning = +""
          when :message_update
            chunk = event[:chunk]
            @live << chunk.content if chunk.content.is_a?(String) && !chunk.content.empty?
            reasoning = chunk.thinking&.text
            @reasoning << reasoning if reasoning.is_a?(String) && !reasoning.empty?
          when :message_end
            message = event[:message]
            if message.role == :assistant
              accumulate_usage(message)
              handled = complete(message.content)
              enqueue_message(handled)
            end
          when :tool_execution_start
            @tool = event[:tool_call].name
          when :tool_execution_end
            @tool = nil
            call = event[:tool_call]
            # The per-tool block dispatch (pi's per-tool renderers): bash
            # owns the shell shapes (I17 — the frozen :tool_execution_end
            # contract carries `duration:`), write/read their file-tool
            # shapes (I18), the rest the generic ⎿ line.
            enqueue_tool_block(call.name, call.arguments, event[:result], event[:duration])
          when :compaction_start
            # The frozen I12 contract (Agent::Loop#run_compaction, after
            # prepare succeeds): the border shows pi's per-reason label
            # (status-indicator.ts:85-95 minus the cancel hint) until the
            # result (+:compaction+) or the run end clears it.
            @compaction_reason = event[:reason]
          when :compaction
            # pi: after compaction, context tokens are unknown until the
            # next LLM response (footer "?"); the event itself renders a
            # post-hoc compaction line (the compaction-start border status
            # came from :compaction_start — the frozen I12 contract).
            @compaction_reason = nil
            @usage_stale = true
            @scrollback << [blank_line] # the compaction line is a region too (pi :3903-3904)
            enqueue_scrollback(
              "✻ compacted (#{event[:reason]}, #{event[:tokens_before]} tokens)", fg: Theme[:dim]
            )
          when :agent_end
            @busy = false
            @compaction_reason = nil
            if event[:interrupted] == true
              handled = "interrupted"
              enqueue_scrollback(handled, fg: Theme[:warning])
            elsif event[:error]
              handled = "error: #{event[:error].message}"
              enqueue_scrollback(handled, fg: Theme[:error])
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

      # The /new surface (bin/tart's reset seam): pi handleClearCommand →
      # newSession → renderCurrentSessionState — the chat container clears,
      # initial state re-renders, then the accent "✓ New session started"
      # line (interactive-mode.ts:6926-6936, 2209-2216). The port's flat
      # transcript analog: drop the buffer and stream state, re-render the
      # MOTD block, then the accent line (deviation, itemized: pi's header
      # lives in a separate container and never re-renders). Cross-lane
      # contract: bin/tart's reset lambda calls this after swapping in the
      # fresh agent (start_session + surface.new_session).
      def new_session
        @mutex.synchronize do
          clear_transcript
          enqueue_motd
          enqueue_scrollback("✓ New session started", fg: Theme[:accent])
        end
      end

      # The resume surface (item 3, pi handleResumeSession → switchSession
      # → renderCurrentSessionState + showStatus, interactive-mode.ts
      # :5741-5780, :2210-2218): the transcript clears — NO MOTD re-render
      # (pi's chat container gets the session's entries only; the port's
      # header/MOTD would be a fresh-boot shape — itemized cut) — the
      # recorded entries replay through the live-turn shapes, then the
      # compaction count (:4226-4232) and "Resumed session". bin/tart wires
      # both CLI --resume and the picker's enter through this one method
      # after swapping in the fresh agent.
      def resume_session(path)
        @mutex.synchronize do
          clear_transcript
          entries = Agent::Session.load_entries(path)
          replay_entries(entries)
          compactions = entries.count { |entry| entry.is_a?(Hash) && entry["type"] == "compaction" }
          if compactions.positive?
            times = compactions == 1 ? "1 time" : "#{compactions} times"
            enqueue_scrollback("Session compacted #{times}", fg: Theme[:dim])
          end
          enqueue_scrollback("Resumed session", fg: Theme[:accent])
        end
      end

      # The /resume picker (item 2, pi showSessionSelector →
      # SessionSelectorComponent, interactive-mode.ts:3335-3338, :5708-5735,
      # reduced — see the picker methods at the bottom): +items+ is the
      # launcher-built [{path:, label:}] list, newest first; keys route
      # through {picker_input} while open, enter fires {on_resume}.
      def open_session_picker(items)
        @mutex.synchronize { @picker = {items:, selected: 0} }
      end

      # Slash-command output (pi's chat-line status UX): a muted line in
      # the transcript buffer. Thread-safe — the kernel task calls this
      # off-frame. Public placement is load-bearing: bin/tart wires the
      # Commands::Handler with +output: ->(text) { surface.command_line(text) }+
      # (the I13 /skills NoMethodError).
      def command_line(text)
        @mutex.synchronize { enqueue_scrollback(text, fg: Theme[:muted]) }
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

        # Hard cell-wise clip (pi truncateToWidth with an empty tail).
        def clip_text(text, width)
          out = []
          budget = width
          text.chars.each do |char|
            w = TUI.text_width(char)
            break if w > budget

            out << char
            budget -= w
          end
          out.join
        end

        # pi fuzzyMatch (fuzzy.ts:12-72): every query char in order (not
        # necessarily consecutive) in the lowercased text; the score is ≤ 0,
        # lower is better — consecutive matches −5·n, gaps +2·gap, word
        # boundaries −10, position +0.1·i, an exact match −100. nil = no
        # match. The alnum/num-alpha swap ("ab12" ⇄ "12ab") retries with a
        # +5 penalty (fuzzy.ts:68-93).
        def fuzzy_match(query, text)
          query = query.downcase
          text = text.downcase
          score = fuzzy_subsequence_score(query, text)
          return score if score

          swapped = query.match(/\A(?<letters>[a-z]+)(?<digits>[0-9]+)\z/) { |m| "#{m[:digits]}#{m[:letters]}" } ||
            query.match(/\A(?<digits>[0-9]+)(?<letters>[a-z]+)\z/) { |m| "#{m[:letters]}#{m[:digits]}" }
          swapped && (swapped_score = fuzzy_subsequence_score(swapped, text)) ? swapped_score + 5 : nil
        end

        def fuzzy_subsequence_score(query, text)
          return nil if query.length > text.length
          return 0 if query.empty?

          score = 0.0
          last = -1
          consecutive = 0
          query.chars.each do |char|
            i = text.index(char, last + 1)
            return nil unless i

            if last == i - 1
              consecutive += 1
              score -= consecutive * 5
            else
              consecutive = 0
              score += (i - last - 1) * 2 if last >= 0
            end
            score -= 10 if i.zero? || /[\s\-_.\/:]/.match?(text[i - 1])
            score += i * 0.1
            last = i
          end
          score -= 100 if query == text
          score
        end

        # pi fuzzyFilter (fuzzy.ts:75-106): whitespace/slash-separated query
        # tokens must ALL match the search text; matches sort best-first.
        # pi's Array#sort is stable (ties keep the pre-sort catalog order —
        # item 4); Ruby's sort_by is not, so the pre-sort index is the
        # tie-break (item 4 fix: /ar's architect-family ties land where
        # pi's do).
        def fuzzy_filter(items, query)
          return items if query.strip.empty?

          tokens = query.strip.split(/[\s\/]+/).reject(&:empty?)
          return items if tokens.empty?

          items.each_with_index.filter_map do |item, i|
            text = yield(item)
            scores = tokens.map { |token| fuzzy_match(token, text) }
            scores.all? ? [item, scores.sum, i] : nil
          end.sort_by { |_, score, i| [score, i] }.map(&:first)
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

        # pi formatTokens (footer.ts:23-30): compact token counts.
        def format_tokens(count)
          if count < 1000 then count.to_s
          elsif count < 10_000 then format("%.1fk", count / 1000.0)
          elsif count < 1_000_000 then "#{(count / 1000.0).round}k"
          elsif count < 10_000_000 then format("%.1fM", count / 1_000_000.0)
          else "#{(count / 1_000_000.0).round}M"
          end
        end

        # pi formatCwdForFooter (footer.ts:33-43): the cwd with the home
        # prefix contracted to "~"; paths outside home render absolute.
        def format_cwd(cwd, home = Dir.home)
          return cwd if home.nil? || home.empty?

          resolved = File.expand_path(cwd)
          resolved_home = File.expand_path(home)
          return resolved unless resolved == resolved_home || resolved.start_with?(resolved_home + File::SEPARATOR)

          resolved == resolved_home ? "~" : "~#{File::SEPARATOR}#{resolved[(resolved_home.length + 1)..]}"
        end
      end

      # The real completion source (bin/tart-wired): the builtin slash
      # commands plus /skill:<name> entries — pi's command list
      # (CombinedAutocompleteProvider; skills registered as "skill:<name>"
      # at coding-agent interactive-mode.ts:809-818, plain descriptions —
      # pi's [sourceTag] prefixes are extension/path-source metadata the
      # port has no equivalent of, recorded). Items-only: the surface owns
      # the fuzzy filter (mapping judgment — the port's provider seam is
      # static, no async).
      class SlashSource
        def initialize(commands:, skills:)
          @commands = commands
          @skills = skills
        end

        def items
          @commands.map { |name, meta| {value: name, label: name, description: meta[:description]} } +
            @skills.map { |skill| {value: "skill:#{skill.name}", label: "skill:#{skill.name}", description: skill.description} }
        end
      end

      private

      # Completed content: queued for the transcript buffer.
      # Mutex context (called from on_agent_event); returns the final text
      # (nil when nothing to show).
      def complete(text)
        @live = +""
        return nil if !text.is_a?(String) || text.empty?

        text
      end

      # A completed assistant message as transcript rows (pi
      # assistant-message.ts updateContent): the leading blank every
      # message with visible content opens with (:103-105 — the
      # between-item rule), the joined reasoning block, the blank after a
      # thinking run when content follows (:172-174), then the content.
      # A reasoning-only message gets no trailing blank.
      def enqueue_message(content)
        has_reasoning = !@reasoning.empty?
        has_content = !content.nil?
        return unless has_reasoning || has_content

        @chat_started = true
        @scrollback << [blank_line]
        # The joined thinking renders as a dim block BEFORE the content
        # (pi assistant-message.ts:99-175 render order). The live
        # reasoning buffer is the text source, not Message#thinking —
        # the loop strips the latter before this event (itemized
        # deviation from the spec's message.thinking.text letter).
        flush_reasoning
        if has_content
          # Assistant completions render as markdown (AC5).
          @scrollback << [blank_line] if has_reasoning
          enqueue_markdown(content)
        end
      end

      def blank_line
        TUI.line("")
      end

      # The startup MOTD block: the header-container shape (pi
      # interactive-mode.ts:1075-1077 — Spacer(1), the header, Spacer(1))
      # around the identity's header content. In tart-mode the content is
      # the owner's art, the version line, the hints line, then the
      # [Context] and [Skills] resource sections (pi's showLoadedResources
      # :1778-1860; the [Prompts]/[Extensions]/[Themes] sections and
      # package-update notices are cut — the port loads none of them,
      # itemized). pi-mode renders pi's actual built-in header bytes.
      def enqueue_motd
        lines = [blank_line]
        lines.concat(@identity == Identity::PI ? pi_header_lines : tart_header_lines(viewport_width))
        lines << blank_line
        @scrollback << lines
      end

      # tart-mode's header: the owner's art collection, the tart version
      # line, the port's hints line, the resource sections — every content
      # row through the {OUTPUT_PAD} rule.
      def tart_header_lines(width)
        content_width = width - OUTPUT_PAD.length * 2
        lines = motd_logo_lines.map { |line| TUI.line("#{OUTPUT_PAD}#{line}") }
        lines << TUI.line([TUI.span(OUTPUT_PAD), TUI.span("tart"), TUI.span(" v#{Tart::VERSION}", fg: Theme[:dim])])
        lines.concat(Chat.wrap(HINTS_LINE, content_width).map { |row| TUI.line("#{OUTPUT_PAD}#{row}", fg: Theme[:dim]) })
        motd_sections(content_width).each do |header, rows|
          lines << blank_line << TUI.line("#{OUTPUT_PAD}#{header}", fg: Theme[:md_heading])
          lines.concat(rows)
        end
        lines
      end

      # pi-mode's built-in header (interactive-mode.ts:1028-1063 +
      # pi-logo.ts): the 2-line half-block mark with the version on the
      # mark's first line and the hints on its second, the ctrl+o notice,
      # a blank (the header text's "\\n\\n"), the onboarding line. The
      # mark's brand colors are fixed (pi-logo.ts:9); Apple Terminal gets
      # the wordmark fallback (supportsPiLogo — it misrenders half
      # blocks). The expand machinery behind the notice is cut, itemized.
      def pi_header_lines
        top, bottom = pi_mark
        hints = TUI.span(bottom.empty? ? PI_HINTS_LINE : " #{PI_HINTS_LINE}", fg: Theme[:dim])
        [
          TUI.line([TUI.span(OUTPUT_PAD), *top, TUI.span(" v#{Identity::ORACLE_VERSION}", fg: Theme[:dim])]),
          TUI.line([TUI.span(OUTPUT_PAD), *bottom, hints]),
          TUI.line([TUI.span(OUTPUT_PAD), TUI.span(PI_NOTICE_LINE, fg: Theme[:dim])]),
          blank_line,
          TUI.line([TUI.span(OUTPUT_PAD), TUI.span(PI_ONBOARDING_LINE, fg: Theme[:dim])])
        ]
      end

      # pi piLogoLines (pi-logo.ts:26-30): 4 cells wide, 2 lines tall —
      # the top line coral-on-blue, then coral, then empty; the bottom
      # blue, empty, yellow. Returns [first-line spans, second-line
      # spans]; the wordmark fallback's second line is empty (the hints
      # ride alone).
      def pi_mark
        if apple_terminal?
          [[TUI.span("P", fg: Theme[:logoCoral]), TUI.span("i", fg: Theme[:logoYellow])], []]
        else
          top = [
            TUI.span("▀", fg: Theme[:logoCoral], bg: Theme[:logoBlue]),
            TUI.span("▀█", fg: Theme[:logoCoral]),
            TUI.span(" ")
          ]
          bottom = [TUI.span("█▀", fg: Theme[:logoBlue]), TUI.span(" "), TUI.span("█", fg: Theme[:logoYellow])]
          [top, bottom]
        end
      end

      # pi isAppleTerminalSession (pi-tui terminal.ts:44-45): darwin +
      # TERM_PROGRAM.
      def apple_terminal?
        RUBY_PLATFORM.include?("darwin") && ENV["TERM_PROGRAM"] == "Apple_Terminal"
      end

      # The loaded-resource sections (pi showLoadedResources): [Context] —
      # the config sources the port actually loads, existing files only,
      # registration order (pi's contextCompactList, sort: false);
      # [Skills] — the loaded skill names, sorted, dim, one wrapped
      # compact list (pi formatCompactList :1791-1797). Sections with no
      # entries are omitted, as in pi.
      def motd_sections(width)
        sections = []
        context = context_sources.select { |path| File.file?(path) }
        unless context.empty?
          sections << ["[Context]", dim_compact_list(context, width)]
        end
        skills = motd_skill_names # sorted (pi formatCompactList's localeCompare)
        unless skills.empty?
          sections << ["[Skills]", dim_compact_list(skills, width)]
        end
        sections
      end

      # The config files the port loads for +cwd+ (Settings.load's user +
      # project pair and the MCP config; settings.rb:12-14,
      # mcp/config.rb:16). Paths injectable through +settings_root+ so
      # tests never touch ~/.tart.
      def context_sources
        mcp = ENV["TART_MCP_CONFIG"] || File.join(@settings_root, "mcp.json")
        cwd = @footer_data&.fetch(:cwd, nil) || Dir.pwd
        [
          File.join(@settings_root, Settings::ROOT_KEY),
          File.join(cwd, Settings::CONFIG_DIR, Settings::ROOT_KEY),
          mcp
        ]
      end

      # The MOTD's [Skills] names: the wired completion source's skill
      # entries (SlashSource carries exactly the launcher's loaded skills).
      def motd_skill_names
        return [] unless @autocomplete

        @autocomplete.items.filter_map { |item|
          item[:value].delete_prefix("skill:") if item[:value].start_with?("skill:")
        }.sort
      end

      # pi formatCompactList (:1791-1797): trimmed entries joined ", ",
      # two-space indent, dim — word-wrapped to the content width, every
      # row through the {OUTPUT_PAD} rule. (The sort, when wanted, happens
      # at the call site: pi's [Context] list passes sort: false —
      # registration order.)
      def dim_compact_list(entries, width)
        Chat.wrap("  #{entries.join(", ")}", width).map { |row| TUI.line("#{OUTPUT_PAD}#{row}", fg: Theme[:dim]) }
      end

      # Verbatim completed text (tool output, status): wrapped to
      # the transcript width, one line-level fg. Everything routed here is
      # a chat-container child in pi (tool blocks, chat lines, compaction
      # and status lines), so it arms the leading-spacer gate.
      def enqueue_scrollback(text, fg:)
        return if text.nil? || text.empty?

        @chat_started = true
        @scrollback << Chat.wrap(text, viewport_width).map { |line| TUI.line(line, fg:) }
      end

      # The submitted prompt's echo (item 4, pi UserMessageComponent,
      # user-message.ts:40-51): the "text" token's color on the
      # "userMessageBg" background — pi's echo carries no prompt char
      # (the port's I05 prompt-char invention; gone). pi's shape: a
      # leading blank ONLY when the chat container is non-empty
      # (interactive-mode.ts:3930-3931 — the fresh boot's first echo has
      # none; the port's container flag is {@chat_started}), then the
      # component's Markdown paddingY=1 (user-message.ts:23) — one blank
      # row above and below the content — every content row through the
      # {OUTPUT_PAD} rule. Reduced: bg on the text rows only — pi pads a
      # full-width Markdown block.
      def enqueue_user_echo(text)
        rows = Chat.wrap(text, viewport_width - OUTPUT_PAD.length * 2).map do |row|
          TUI.line([TUI.span(OUTPUT_PAD), TUI.span(row, fg: Theme[:user_message_text], bg: Theme[:user_message_bg])])
        end
        region = []
        region << blank_line if @chat_started # the container's non-empty gate
        region << blank_line # paddingY top (user-message.ts:23)
        region.concat(rows)
        region << blank_line # paddingY bottom
        @chat_started = true
        @scrollback << region
      end

      # The resume replay (item 3, pi renderSessionEntries, interactive-
      # mode.ts :3900-3975): the recorded entries through the live-turn
      # shapes — user echoes, assistant thinking-then-content markdown,
      # tool blocks (the assistant's recorded tool_calls joined to their
      # recorded results), compaction summaries — as the entries carry
      # them. Recorded gaps (itemized, never invented): thinking is
      # stripped before record (agent/loop.rb strip_thinking_replay), so no
      # reasoning block replays; non-string (multimodal) content is
      # skipped; usage only when the provider reported it.
      def replay_entries(entries)
        results = entries.filter_map do |entry|
          next unless entry.is_a?(Hash) && entry["type"] == "message"
          message = entry["message"]
          next unless message.is_a?(Hash) && message["role"] == "tool" && message["tool_call_id"]

          [message["tool_call_id"], message["content"]]
        end.to_h
        entries.each { |entry| replay_entry(entry, results) }
      end

      def replay_entry(entry, results)
        return unless entry.is_a?(Hash)

        case entry["type"]
        when "message"
          message = entry["message"]
          return unless message.is_a?(Hash)

          case message["role"]
          when "user" then replay_user(message)
          when "assistant" then replay_assistant(message, results)
          end
        when "compaction"
          # pi :3903-3904 — a compaction summary is a spaced region,
          # markdown-rendered (CompactionSummaryMessageComponent).
          @scrollback << [blank_line]
          enqueue_markdown(entry["summary"]) if entry["summary"].is_a?(String)
        end
      end

      def replay_user(message)
        content = message["content"]
        return unless content.is_a?(String) && !content.strip.empty?

        enqueue_user_echo(content)
        add_to_history(content) # pi renderInitialMessages populateHistory
      end

      def replay_assistant(message, results)
        content = message["content"]
        has_content = content.is_a?(String) && !content.strip.empty?
        reasoning = message["thinking"]
        has_reasoning = reasoning.is_a?(String) && !reasoning.empty?
        tool_calls = message["tool_calls"].is_a?(Hash) ? message["tool_calls"] : {}
        return unless has_content || has_reasoning || tool_calls.any?

        reseed_usage(message)
        # pi assistant-message.ts:103-105 — the spacer rides VISIBLE
        # content only (a tool-call-only assistant entry renders no blank
        # of its own; its tool block brings one).
        @scrollback << [blank_line] if has_content || has_reasoning
        if has_reasoning
          @scrollback << reasoning_lines(reasoning, viewport_width)
          @scrollback << [blank_line] if has_content # pi :172-174
        end
        enqueue_markdown(content) if has_content
        tool_calls.each_value do |call|
          next unless call.is_a?(Hash) && call["name"].is_a?(String)

          # The replay dispatches through the same per-tool shapes (I18):
          # call lines from the recorded arguments, outputs from the
          # recorded results, NO duration — the recorded entries carry
          # none (the frozen contract's replay gap, never invented).
          enqueue_tool_block(call["name"], call["arguments"], results[call["id"]], nil)
        end
      end

      # Footer usage reseeds from the replayed assistant entry's recorded
      # token counts (Message#to_h merges Tokens#to_h — input_tokens,
      # output_tokens, cache_read_tokens, cache_write_tokens). Entries
      # carry usage only when the provider reported it; interrupted turns
      # may carry none (gap, itemized) — all-nil entries are skipped so
      # the boot state stays intact.
      def reseed_usage(message)
        tokens = RubyLLM::Tokens.new(
          input: message["input_tokens"], output: message["output_tokens"],
          cache_read: message["cache_read_tokens"], cache_write: message["cache_write_tokens"]
        )
        return if [tokens.input, tokens.output, tokens.cache_read, tokens.cache_write].all?(&:nil?)

        accumulate_usage(tokens)
      end

      # The /new + resume shared reset: the buffer and stream state drop
      # (pi renderCurrentSessionState's container clears, :2210-2216; the
      # host drops the selection with the transcript, :4096).
      def clear_transcript
        @transcript = []
        @scrollback.clear
        @scroll_offset = 0
        @follow = true
        @selection = nil
        @last_click = nil
        @live = +""
        @reasoning = +""
        # pi's footer stats re-derive from the fresh (empty) session.
        @usage_totals = {input: 0, output: 0, cache_read: 0, cache_write: 0}
        @last_usage = nil
        @usage_stale = false
        # The chat container emptied with the transcript (pi
        # renderCurrentSessionState, interactive-mode.ts:2210-2216) — the
        # leading-spacer gate restarts.
        @chat_started = false
      end

      # Assistant completions render through the markdown converter (AC5):
      # styled rows wrapped to the transcript width, every span's fg routed
      # through the theme (AC3), then converted row → Line at the TUI seam.
      def enqueue_markdown(text)
        return if text.nil? || text.empty?

        @scrollback << markdown_lines(text, viewport_width)
      end

      # Markdown text as themed display lines (the Render::Markdown
      # converter is read-only — theme colors apply at the span level via
      # {Theme.md_fg}; rows re-wrapped to the content width — pi's
      # Markdown wraps to width minus its paddingX on both sides,
      # markdown.ts:289 — every row through the {OUTPUT_PAD} rule).
      # Shared by the completion path and the live region (item 3: pi
      # re-renders the whole streaming message as markdown on every
      # update — interactive-mode.ts:3519-3535, assistant-message.ts
      # :107-109).
      def markdown_lines(text, width)
        content_width = width - OUTPUT_PAD.length * 2
        rows = Render::Markdown.rows(text, width: content_width).flat_map { |row| Chat.wrap_row(row, content_width) }
        rows.map do |row|
          themed = row.map { |span| Render::Markdown::Span.new(text: span.text, fg: Theme.md_fg(span.fg), modifiers: span.modifiers) }
          padded_row(themed)
        end
      end

      # One content row with the {OUTPUT_PAD} leading the spans (pi's
      # Markdown paddingX — the pad renders unstyled before the row).
      def padded_row(spans)
        TUI.markdown_line([Render::Markdown::Span.new(text: OUTPUT_PAD)] + spans)
      end

      # Session-cumulative usage totals + the latest assistant usage (the
      # context numerator; pi's getSessionStats over session entries,
      # reduced to what the event surface carries: assistant messages).
      # Takes an assistant message (reads its +tokens+) or a bare
      # RubyLLM::Tokens (the replay's reseed from recorded counts).
      def accumulate_usage(message)
        tokens = message.respond_to?(:tokens) ? message.tokens : message
        return if tokens.nil?

        @usage_totals[:input] += tokens.input if tokens.input
        @usage_totals[:output] += tokens.output if tokens.output
        @usage_totals[:cache_read] += tokens.cache_read if tokens.cache_read
        @usage_totals[:cache_write] += tokens.cache_write if tokens.cache_write
        @last_usage = tokens
        @usage_stale = false
      end

      # The result's text (tool-execution.ts getTextOutput shape): a result
      # Hash carries :content or :error, recorded entries carry the string
      # content itself.
      def tool_result_text(result)
        result.is_a?(Hash) ? (result[:error] || result[:content] || "").to_s : result.to_s
      end

      # pi bash.ts:20-28 formatDuration — seconds <60 → %.1fs (toFixed
      # rounds: 59_960ms → "60.0s"); <60m → "Xm Ys"; else "Xh Ym Zs".
      def format_duration(ms)
        seconds = ms / 1000.0
        return format("%.1fs", seconds) if seconds < 60

        total_seconds = seconds.floor
        minutes = total_seconds / 60
        remainder = total_seconds % 60
        return "#{minutes}m #{remainder}s" if minutes < 60

        "#{minutes / 60}h #{minutes % 60}m #{remainder}s"
      end

      # The bash tool block (I17 — pi's shell renderer over the tool-turn
      # component): the constructor's Spacer (1 blank, tool-execution.ts:85),
      # the render box's paddingY (1 blank above and below the children,
      # tool-execution.ts:87 Box(1,1)), then the children — the bold
      # bashMode `$ <command>` header (bash.ts:36 theme.bold over
      # formatShellCall; colorKey bashMode — the port carries no
      # context-exclusion state, the dim variant is unreachable, itemized),
      # the output lines blank-separated from the header (bash.ts:78-84 —
      # the Text children's leading "\n"), and the muted `Took <duration>`
      # line (bash.ts:105-109 — a nil/absent duration, the replay path,
      # renders none; the recorded gap is itemized, never invented).
      def enqueue_bash_block(command, output, duration)
        @chat_started = true
        region = [blank_line, blank_line]
        region.concat(padded_fg_rows("$ #{command.to_s.empty? ? "..." : command}",
          fg: Theme[:bashMode], modifiers: [:bold]))
        output_lines = output.strip.lines(chomp: true)
        unless output_lines.empty?
          region << blank_line
          region.concat(padded_fg_rows(output_lines.join("\n"), fg: Theme[:tool_output]))
        end
        if duration
          region << blank_line
          region.concat(padded_fg_rows("Took #{format_duration(duration * 1000.0)}", fg: Theme[:tool_output]))
        end
        region << blank_line
        @scrollback << region
      end

      # Wrapped themed rows through the {OUTPUT_PAD} rule (pi's render-box
      # paddingX, tool-execution.ts:87 — one pad cell, content wrapped to
      # width minus both pads).
      def padded_fg_rows(text, fg:, modifiers: [])
        Chat.wrap(text, viewport_width - OUTPUT_PAD.length * 2).map do |row|
          TUI.line([TUI.span(OUTPUT_PAD), TUI.span(row, fg:, modifiers:)])
        end
      end

      # The per-tool block dispatch (pi's per-tool renderCall/renderResult,
      # I18): bash owns the shell shapes (I17 — carries the duration),
      # write/read their file-tool shapes, everything else the generic ⎿
      # line. Shared by the live and replay paths (I17's shape-sharing
      # ruling); +duration+ is nil on replay (the recorded gap).
      def enqueue_tool_block(name, args, result, duration)
        args = {} unless args.is_a?(Hash)
        case name
        when BASH_TOOL
          enqueue_bash_block(args["command"], tool_result_text(result), duration)
        when WRITE_TOOL
          enqueue_write_block(args, result)
        when READ_TOOL
          enqueue_read_block(args, result)
        else
          # Every tool block opens with a leading blank (pi
          # tool-execution.ts:85 — the constructor's Spacer).
          @scrollback << [blank_line]
          enqueue_scrollback(tool_line(name, result), fg: Theme[:tool_output])
        end
      end

      # The write tool block (I18 — pi write.ts renderers over the
      # tool-turn component): the constructor's Spacer + render-box
      # paddingY (tool-execution.ts:85,87 — the bash block's shape), the
      # bold toolTitle `write` header + the renderToolPath display
      # (write.ts:99-100), blank, the content as toolOutput rows
      # (write.ts:108-122), box pad. The SUCCESS result renders NOTHING
      # (formatWriteResult is undefined unless error, write.ts:128-143);
      # an error renders its text in the error token after a blank (the
      # leading "\n", write.ts:143). Cuts, itemized: the syntax
      # highlighting (highlightCode — the port has no highlighter;
      # invisible to text files) and the ctrl+o expand binding (backlog
      # C) — the hint's TEXT renders for byte parity.
      def enqueue_write_block(args, result)
        @chat_started = true
        region = [blank_line, blank_line]
        region.concat(write_call_rows(args))
        content_rows = write_content_rows(args)
        unless content_rows.empty?
          region << blank_line
          region.concat(content_rows)
        end
        error = result.is_a?(Hash) ? result[:error] : nil
        if error
          region << blank_line
          region.concat(padded_fg_rows(error.to_s, fg: Theme[:error]))
        end
        region << blank_line
        @scrollback << region
      end

      # The read tool block (I18 — pi read.ts renderers): the Spacer + box
      # padding (tool-execution.ts:85,87), then the call line alone —
      # formatReadCall's bold toolTitle `read` + renderToolPath + the
      # warning :start-end range (read.ts:35-42), or the compact resource
      # shape (getCompactReadClassification, read.ts:63-88). The result
      # renders NOTHING unless error or expanded (read.ts:68-70 — the
      # expand binding is cut, itemized); an error renders its text as
      # toolOutput rows (formatReadResult's isError path).
      def enqueue_read_block(args, result)
        @chat_started = true
        region = [blank_line, blank_line]
        region.concat(read_call_rows(args))
        error = result.is_a?(Hash) ? result[:error] : nil
        if error
          region << blank_line
          region.concat(padded_fg_rows(error.to_s, fg: Theme[:tool_output]))
        end
        region << blank_line
        @scrollback << region
      end

      # pi write.ts:99-100 — the bold toolTitle `write` header + the
      # renderToolPath display (accent token). Mixed spans, so the row
      # bypasses {padded_fg_rows} for a hand-built span line (recorded
      # gap: pi's Text wraps the header to the viewport; a call line
      # wider than the width overflows here).
      def write_call_rows(args)
        [TUI.line([TUI.span(OUTPUT_PAD), tool_title_span("write"), TUI.span(" "),
                   TUI.span(tool_path_display(args), fg: Theme[:accent])])]
      end

      # pi write.ts:108-122 — the content preview: \r stripped
      # (normalizeDisplayText), trailing empty lines trimmed
      # (trimTrailingEmptyLines), at most 10 lines, then the expand hint
      # row (keyHint app.tools.expand — the dim key + muted text bytes;
      # the ctrl+o binding is cut, the bytes are the contract).
      def write_content_rows(args)
        lines = args["content"].to_s.gsub("\r", "").split("\n", -1)
        lines.pop while !lines.empty? && lines.last.empty?
        return [] if lines.empty?

        display = lines.first(WRITE_PREVIEW_LINES)
        rows = padded_fg_rows(display.join("\n"), fg: Theme[:tool_output])
        remaining = lines.length - display.length
        if remaining.positive?
          rows << TUI.line([TUI.span(OUTPUT_PAD),
                            TUI.span("... (#{remaining} more lines, #{lines.length} total,", fg: Theme[:muted]),
                            TUI.span(" "),
                            TUI.span("ctrl+o", fg: Theme[:dim]),
                            TUI.span(" to expand)", fg: Theme[:muted])])
        end
        rows
      end

      # pi read.ts:35-42 formatReadCall vs :79-90 formatCompactReadCall —
      # the plain call line, or the compact resource shape with the dim
      # expand hint (the [skill] label rides customMessageLabel violet —
      # the port's accent analog — over customMessageText muted).
      def read_call_rows(args)
        classification = compact_read_classification(args)
        if classification
          label_spans = if classification[:kind] == :skill
            [TUI.span("[skill] ", fg: Theme[:accent], modifiers: [:bold]),
             TUI.span(classification[:label], fg: Theme[:muted])]
          else
            [tool_title_span("read resource"), TUI.span(" "),
             TUI.span(classification[:label], fg: Theme[:accent])]
          end
          [TUI.line([TUI.span(OUTPUT_PAD), *label_spans, *line_range_spans(args),
                     TUI.span(" (ctrl+o to expand)", fg: Theme[:dim])])]
        else
          [TUI.line([TUI.span(OUTPUT_PAD), tool_title_span("read"), TUI.span(" "),
                     TUI.span(tool_path_display(args), fg: Theme[:accent]), *line_range_spans(args)])]
        end
      end

      # pi write.ts:99 theme.fg("toolTitle", theme.bold(...)) — the tool
      # call header token (dark.json:40 toolTitle = text, the truecolor
      # prose value).
      def tool_title_span(title)
        TUI.span(title, fg: Theme[:toolTitle], modifiers: [:bold])
      end

      # pi render-utils.ts:102-110 renderToolPath over :10-18 shortenPath
      # — the display path: the ~ contraction under home, verbatim
      # otherwise; the empty/absent path renders the toolOutput "..."
      # (write.ts:105 / read.ts:104 fallback). linkPath's OSC8 hyperlink
      # is capability-gated — the port's TUI carries none (recorded).
      def tool_path_display(args)
        raw_path = args["file_path"] || args["path"]
        return "..." if raw_path.nil? || raw_path.empty?

        home = Dir.home
        raw_path.start_with?(home) ? "~#{raw_path[home.length..]}" : raw_path
      end

      # pi read.ts:35-42 formatReadLineRange — the warning-colored
      # :start-end suffix when offset/limit narrow the read (start
      # defaults to 1; a limit without offset still ranges from 1).
      def line_range_spans(args)
        offset = args["offset"]
        limit = args["limit"]
        return [] if offset.nil? && limit.nil?

        start_line = offset || 1
        end_line = limit ? start_line + limit - 1 : ""
        [TUI.span(":#{start_line}-#{end_line}", fg: Theme[:warning])]
      end

      # pi read.ts:63-88 getCompactReadClassification — the compact shape
      # for resource-like reads: SKILL.md → the [skill] shape (label =
      # the skill directory), the AGENTS.md/CLAUDE.md resource names →
      # the `read resource` shape (label = the cwd-relative or absolute
      # path, formatPathRelativeToCwdOrAbsolute). pi's own-package docs
      # class (getPiDocsClassification) is cut, itemized: the port has no
      # pi package root.
      def compact_read_classification(args)
        raw_path = tool_path_display(args)
        return if raw_path == "..."

        absolute_path = File.expand_path(raw_path)
        name = File.basename(absolute_path)
        return {kind: :skill, label: File.basename(File.dirname(absolute_path))} if name == "SKILL.md"
        return {kind: :resource, label: cwd_relative_path(absolute_path)} if COMPACT_RESOURCE_FILE_NAMES.include?(name)

        nil
      end

      # pi utils/paths.ts:120-123 formatPathRelativeToCwdOrAbsolute —
      # cwd-relative when under the cwd, absolute otherwise.
      def cwd_relative_path(absolute_path)
        cwd = "#{Dir.pwd}/"
        absolute_path.start_with?(cwd) ? absolute_path[cwd.length..] : absolute_path
      end

      # Bounded multi-line preview (pi truncates tool output): the first
      # TOOL_PREVIEW_LINES non-empty lines, then an ellipsis row. The
      # generic non-bash shape (I17's ruling, kept for edit/grep/ls/find
      # — write/read dispatch to their own shapes, I18).
      def tool_line(name, result)
        text = tool_result_text(result)
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
          cancel_autocomplete # pi editor.ts:1261 — paste cancels the list
          return
        end

        # The picker owns every key while open (pi: the selector takes
        # focus — showSelector { focus: selector }).
        return picker_input(event) if @picker

        ctrl = event.modifiers.include?("ctrl")
        alt = event.modifiers.include?("alt")
        printable = event.text? && !(event.modifiers & %w[ctrl alt]).any?
        case event.code
        # Enter applies the selection and submits it (pi editor.ts:790-816
        # tui.select.confirm: a "/"-prefix completion falls through to
        # submit). Escape is the editor's onEscape (item 5, pi
        # custom-editor.ts:103-111: the list consumes it first for
        # cancellation; else interactive-mode.ts:3070-3090 — a streaming
        # run aborts through the kernel's interrupt path (the ctrl+c
        # mechanism, Task#stop — no second path), idle escape is a no-op;
        # pi's double-escape /tree//fork is cut — no session branching).
        when "enter"
          apply_suggestion if @suggestions
          submit
        when "escape"
          if @suggestions
            cancel_autocomplete
          elsif busy?
            @kernel.interrupt_work!
          end
        # While the list is active up/down navigate the LIST (history
        # yields — pi custom-editor.ts:127-131 → editor.ts:766-771).
        when "up" then @suggestions ? navigate_suggestions(-1) : history_previous
        when "down" then @suggestions ? navigate_suggestions(1) : history_next
        when "tab"
          if @suggestions then apply_suggestion
          else update_autocomplete # explicit trigger (pi handleTabCompletion)
          end
        # Transcript paging (pi keybindings.ts:114-115 tui.editor.pageUp/
        # pageDown, defaultKeys pageUp/ctrl+pageUp, pageDown/ctrl+pageDown;
        # the gem spells the codes "page_up"/"page_down") — the port maps
        # the action onto the transcript viewport (the port's editor is
        # single-line; mapping judgment, itemized). The list wins while
        # active (pi's precedence: the list owns the vertical keys).
        when "page_up" then scroll_page(-1) unless @suggestions
        when "page_down" then scroll_page(1) unless @suggestions
        when "backspace"
          alt ? delete_word_backward : delete_backward
          update_autocomplete # pi editor.ts:1449-1463 — re-filter/re-trigger
        when "delete" then alt ? delete_word_forward : delete_forward
        when "left" then (alt || ctrl) ? move_word_backward : move_left
        when "right" then (alt || ctrl) ? move_word_forward : move_right
        when "home" then move_start
        when "end" then move_end
        when "a" then ctrl ? move_start : insert_printable(event)
        when "e" then ctrl ? move_end : insert_printable(event)
        when "b" then alt ? move_word_backward : (ctrl ? move_left : insert_printable(event))
        when "f" then alt ? move_word_forward : (ctrl ? move_right : insert_printable(event))
        when "d"
          # app.exit (pi custom-editor.ts:118-125, keybindings.ts:28 —
          # default ctrl+d): on an empty editor the run exits (the /quit
          # path); non-empty falls through to delete-char-forward.
          if ctrl && @input.empty?
            @kernel.stop!
          elsif alt
            delete_word_forward
          elsif ctrl
            delete_forward
          else
            insert_printable(event)
          end
        when "w" then ctrl ? delete_word_backward : insert_printable(event)
        else insert_printable(event)
        end
        # pi editor.ts:1228-1251 — the list re-filters on every printable
        # while active; typing triggers when in slash context (pi gates the
        # trigger to word chars/"/"; with a slash-only source the context
        # check alone decides, so one re-query covers both — CJK trigger
        # chars cut, itemized). Movement keys leave the list (pi literal).
        update_autocomplete if printable
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
        text = @input.dup.strip # pi onSubmit trims (interactive-mode.ts:3201)
        cancel_autocomplete
        return if text.empty?

        add_to_history(text)
        @input.clear
        @cursor = 0
        exit_history_browsing
        @branch = nil # per-turn branch invalidation
        @branch_fetched = false
        enqueue_user_echo(text)
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

      # The completed thinking block (pi assistant-message.ts:99-175 order —
      # thinking before the content): the live reasoning buffer flushed as
      # dim italic transcript rows, then cleared.
      def flush_reasoning
        text = @reasoning
        @reasoning = +""
        return if text.empty?

        @scrollback << reasoning_lines(text, viewport_width)
      end

      # Reasoning text as dim italic display lines (pi assistant-message.ts
      # :140-150: thinkingText fg, italic; markdown-of-reasoning is cut,
      # plain dim text — itemized reduction).
      def reasoning_lines(text, width)
        self.class.wrap(text, width - OUTPUT_PAD.length * 2).map { |line| TUI.line([TUI.span(OUTPUT_PAD), TUI.span(line, fg: Theme[:thinkingText], modifiers: [:italic])]) }
      end

      # pi's editor history (components/editor.ts addToHistory): trimmed,
      # no consecutive duplicates, capped, most recent first.
      def add_to_history(text)
        trimmed = text.strip
        return if trimmed.empty? || @history.first == trimmed

        @history.unshift(trimmed)
        @history.pop if @history.size > HISTORY_LIMIT
      end

      # --- autocomplete (AC1, pi editor.ts autocomplete block + SelectList) ---

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

      # Re-query the completion source from the current input/cursor (pi
      # editor.ts:1228-1251 update-on-typing + applyAutocompleteSuggestions
      # :2432-2442): in slash context, fuzzy-filter the catalog on the
      # command text (pi CombinedAutocompleteProvider.getSuggestions
      # tui/autocomplete.ts:336-365 — bare skill names first, then full
      # "skill:" names); no context or no matches cancels the list.
      def update_autocomplete
        token = slash_token
        items = token && @autocomplete ? filter_suggestions(token[1..]) : nil
        @suggestions = items&.any? ? items : nil
        return unless @suggestions

        @selected = best_match_index(items, token[1..])
      end

      def filter_suggestions(query)
        bare = Chat.fuzzy_filter(@autocomplete.items, query) { |item| item[:value].delete_prefix("skill:") }
        bare + Chat.fuzzy_filter(@autocomplete.items - bare, query) { |item| item[:value] }
      end

      # pi getBestAutocompleteMatchIndex (editor.ts:2207-2232): the exact
      # match always wins, else the first value with the prefix — else the
      # default (first) item.
      def best_match_index(items, prefix)
        return 0 if prefix.empty?

        first_prefix = nil
        items.each_with_index do |item, i|
          return i if item[:value] == prefix

          first_prefix ||= i if item[:value].start_with?(prefix)
        end
        first_prefix || 0
      end

      def cancel_autocomplete
        @suggestions = nil
        @selected = 0
      end

      # pi SelectList.handleInput (select-list.ts:146-155): up/down WRAP.
      def navigate_suggestions(direction)
        size = @suggestions.size
        @selected = direction == -1 ? (@selected.zero? ? size - 1 : @selected - 1) : (@selected == size - 1 ? 0 : @selected + 1)
      end

      # pi applyCompletion's slash branch (tui/autocomplete.ts:419-436):
      # the token (before the cursor) is replaced with "/<value> " — the
      # trailing space included — and the cursor lands after it.
      def apply_suggestion
        item = @suggestions[@selected]
        cancel_autocomplete
        return unless item

        lead = @input.index(/\S/) || 0
        tail = @input[@cursor..] || ""
        @input = "#{@input[0, lead]}/#{item[:value]} #{tail}"
        @cursor = lead + item[:value].length + 2 # +2 for "/" and the space
      end

      # --- transcript scroll state (pi scroll-view.ts follow-end) ---

      # One page of transcript rows (pi keybindings.ts:114-115). A page
      # away from the end detaches (+@follow+ false — pi scrollBy sets
      # followingEnd = followEnd && next === maxScrollTop); the render
      # ({transcript_widget}) re-follows whenever the offset lands at the
      # end, and keeps a detached offset put as new output arrives.
      def scroll_page(direction)
        scroll_by(direction * transcript_area_rows)
      end

      # Scrolls the transcript by +lines+ rows (pi ScrollView.scrollBy,
      # scroll-view.ts:127-135): any move away from the end detaches; the
      # render re-arms follow whenever the offset lands at the end (wheel
      # back down = re-arm; a wheel down while following clamps and stays
      # armed — pi's next === maxScrollTop rule). While following,
      # +@scroll_offset+ tracks the last rendered end, so the wheel moves
      # relative to it.
      def scroll_by(lines)
        @follow = false
        @scroll_offset = [@scroll_offset + lines, 0].max
      end

      # The transcript area's row budget — the page size and the mouse
      # mapping's viewport bound (pi chat-viewport geometry, shared with
      # {build_widget}).
      def transcript_area_rows
        area = @session.viewport_area
        height = area ? area.height : 24
        [height - editor_area_rows(height) - FOOTER_ROWS, 1].max
      end

      # --- mouse: wheel scroll + transcript selection (items 6/10, pi
      # tui-alt-screen.ts) ---

      # The gem's mouse events (scroll_up/down, down/drag/up, moved — shape
      # verified live on the synthetic seam) drive the transcript: wheel
      # scrolls it, the left button owns selection (pi
      # handleSelectionMouseEvent :1322 — button&3 == 0; right-click paste
      # is Windows-only in pi — cut, itemized), bare motion is ignored.
      def handle_mouse(event)
        return wheel(event) if event.scroll?
        return unless event.left?

        case event.kind
        when "down" then selection_press(event.y, event.x)
        when "drag" then selection_drag(event.y, event.x)
        when "up" then selection_release(event.y, event.x)
        end
      end

      # One wheel event: lines-per-event (alt+wheel 5×, pi :710) in the
      # event's direction.
      def wheel(event)
        lines = WHEEL_LINES_PER_EVENT * (event.modifiers.include?("alt") ? ALT_WHEEL_MULTIPLIER : 1)
        scroll_by(WHEEL_DIRECTION.fetch(event.kind) * lines)
      end

      # Press: anchor at the pointer (pi :1397-1416). A double click takes
      # the pointer's word, a triple the whole line (granularity + initial
      # range — a following drag extends word-/line-wise, pi
      # updateSelectionFocus :1226-1244). A press outside the transcript
      # area drops the selection (pi: the press lands on another component).
      def selection_press(y, x)
        point = content_point(y, x)
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

      # Drag: extend the focus (pi :1370-1380). pi's edge auto-scroll while
      # dragging past the viewport (updateSelectionAutoScroll :1270-1320,
      # 50ms timer) is cut — itemized.
      def selection_drag(y, x)
        return unless @selection

        point = content_point(y, x)
        update_selection_focus(point) if point
      end

      # Release: a press without a move (anchor == focus) collapses to no
      # selection; otherwise copy-on-select (pi :1332-1366, default on —
      # :269) via the seam's OSC 52 write.
      def selection_release(y, x)
        return unless @selection

        point = content_point(y, x)
        update_selection_focus(point) if point
        text = selection_text
        @selection = nil if text.nil?
        TUI.osc52_copy(text) if text
      end

      # Focus extension (pi updateSelectionFocus :1226-1244): character
      # granularity moves the focus point; word/line re-selects at the
      # pointer and flips the anchor to the opposite end of the initial
      # range (dragging backwards grows the head end).
      def update_selection_focus(point)
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
      def selection_bounds
        return nil unless @selection

        a, b = @selection[:anchor], @selection[:focus]
        return nil if a == b

        before?(a, b) ? [a, b] : [b, a]
      end

      def before?(a, b)
        a.row < b.row || (a.row == b.row && a.col < b.col)
      end

      # The selected text (pi getActiveSelectionText :1414-1437): each
      # covered buffer row's cell slice, trailing whitespace trimmed,
      # joined with newlines. nil when nothing (or only whitespace) is
      # selected.
      def selection_text
        bounds = selection_bounds
        return nil unless bounds

        start, focus = bounds
        text = (start.row..focus.row).map do |row|
          source = plain_content_line(row)
          width = TUI.text_width(source)
          from = start.row == row ? start.col : 0
          to = focus.row == row ? (focus.boundary ? focus.col : focus.col + 1) : width
          from = from.clamp(0, width)
          to = to.clamp(from, width)
          slice_cells(source, from, to - from).rstrip
        end.join("\n")
        text.empty? ? nil : text
      end

      # Maps a terminal cell to a selection point in buffer coordinates (pi
      # getScrollSelectionPoint :1133-1155): the transcript area starts at
      # row 0 (the fullscreen composition's first child); the column
      # clamps to the area's width (the scrollbar gutter excluded while
      # overflowing — pi clamps to the scrollview box). nil below the
      # transcript area.
      def content_point(y, x)
        rows = transcript_area_rows
        return nil unless y < rows

        lines = display_lines
        return nil if lines.empty?

        row = (@scroll_offset + y).clamp(0, lines.size - 1)
        transcript_width = lines.size > rows ? viewport_width - 1 : viewport_width
        Point.new(row, x.clamp(0, transcript_width - 1))
      end

      # The word selection at +point+ (pi getWordSelection :1167-1212): the
      # maximal run of word characters joined by "/"/"-" (paths and
      # kebab-case stay whole); any other single character selects itself
      # (pi: a non-word segment is its own selection). nil beyond the
      # line's cells.
      def word_range(point)
        text = plain_content_line(point.row)
        return nil if point.col >= TUI.text_width(text)

        idx = char_index_at_cell(text, point.col)
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
        width = TUI.text_width(plain_content_line(point.row))
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

      # The buffer row's plain text (the display Line's span contents).
      def plain_content_line(row)
        display_lines[row].spans.map(&:content).join
      end

      # The character covering cell +col+ of +text+.
      def char_index_at_cell(text, col)
        cell = 0
        text.each_char.with_index do |ch, i|
          cell += TUI.text_width(ch)
          return i if cell > col
        end
        text.length - 1
      end

      # The leading text fitting +width+ cells (whole characters; a wide
      # character that would straddle the bound moves whole to the
      # remainder — widths stay additive).
      def take_cells(text, width)
        out = +""
        text.each_char do |ch|
          break if TUI.text_width(out) + TUI.text_width(ch) > width

          out << ch
        end
        out
      end

      # The +width+-cell substring of +text+ starting at cell +start+.
      def slice_cells(text, start, width)
        rest = take_cells(text, start)
        take_cells(text[rest.length..] || "", width)
      end

      def editor_area_rows(height)
        return [picker_widget_rows + 2, height - 1].min if @picker # + borders

        [MIN_EDITOR_ROWS + autocomplete_rows, height - 1].min
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

      # The fullscreen three-area composition (AC1, pi chat-viewport.ts):
      # a transcript area on top (Min 1 — takes the rest), the bordered
      # editor area and the footer docked at the bottom (Length — pi's
      # shrink:1 fixed-height dock). All heights derive from the session's
      # viewport every frame, so a resize recomposes cleanly.
      def build_widget
        area = @session.viewport_area
        height = area ? area.height : 24
        editor_rows = editor_area_rows(height)
        transcript_rows = [height - editor_rows - FOOTER_ROWS, 1].max
        TUI.layout(
          children: [
            transcript_widget(transcript_rows),
            @picker ? picker_widget : editor_widget,
            footer_widget,
          ],
          constraints: [
            TUI.constraint_min(transcript_rows),
            TUI.constraint_length(editor_rows),
            TUI.constraint_length(FOOTER_ROWS),
          ]
        )
      end

      # The transcript area: the scroll buffer's viewport — pi ScrollView
      # follow-end semantics (scroll-view.ts:127-135): while following, the
      # visible tail tracks the content end; a scrolled-up offset stays put
      # as new output arrives; any landing at the end re-follows
      # (followingEnd = followEnd && next === maxScrollTop). A right-gutter
      # scrollbar renders when the content overflows (pi "auto" —
      # settings-defaults.ts:63; hidden when the view fits).
      def transcript_widget(rows)
        width = viewport_width
        lines = display_lines
        max_offset = [lines.size - rows, 0].max
        @scroll_offset = @follow ? max_offset : @scroll_offset.clamp(0, max_offset)
        @follow = true if @scroll_offset == max_offset
        window = (lines[@scroll_offset, rows] || []).map.with_index do |line, i|
          highlight_row(line, @scroll_offset + i)
        end
        return TUI.paragraph(text: window, wrap: false) if lines.size <= rows

        TUI.layout(
          direction: :horizontal,
          children: [
            TUI.paragraph(text: window, wrap: false),
            # pi paints onto the last column (replaceScrollbarCell); the
            # port carves a dedicated 1-cell column instead (mapping
            # judgment — same visible result, content clips one cell early).
            TUI.paragraph(text: scrollbar_glyphs(lines.size, rows), wrap: false),
          ],
          constraints: [TUI.constraint_min(1), TUI.constraint_length(1)]
        )
      end

      # The right-gutter scrollbar (pi layout.ts:307-330 paintScrollbar:
      # track "│" / thumb "┃"). pi's actual scrollbarTrack/scrollbarThumb
      # tokens (dark.json:28-29, blue-tinted) — promoted in the theme table
      # (I12 ruling 2 carry-in; the interim dim/muted routing retired).
      def scrollbar_glyphs(total, rows)
        TUI.scrollbar_lines(content_length: total, position: @scroll_offset, viewport: rows,
          track_fg: Theme[:scrollbarTrack], thumb_fg: Theme[:scrollbarThumb])
      end

      # The edit box (pi CustomEditor, item 5): full-width from column 0,
      # horizontal borders ONLY (the top border carries the status line —
      # custom-editor.ts renderTopBorder :36-77; renderBottomBorder
      # editor.ts:516), no east/west borders, no prompt char (pi's editor
      # renders the bare text; the "❯" prompt was an I11 invention),
      # paddingX 0 (pi's editorPaddingX default, settings-defaults.ts:46)
      # with pi's one reserved cursor column (editor.ts:518-521: without
      # padding the layout width is width − 1). The suggestion list renders
      # below the input row, inside the editor area (pi editor.ts:618-634
      # — the area height grows by the list height; the port's standing
      # I12 placement).
      def editor_widget
        inner = [viewport_width - 1, 1].max
        content = [TUI.line(clip_spans(input_spans, inner))] + autocomplete_lines(inner)
        TUI.block(
          title: status_title,
          borders: [:top, :bottom],
          border_style: TUI.style(fg: Theme[:border]),
          title_style: TUI.style(fg: Theme[:dim]),
          children: [TUI.paragraph(text: content, wrap: false)]
        )
      end

      def status_title
        # pi shows the compaction indicator regardless of the streaming
        # state (a manual /compact runs outside a turn in the port).
        return nil unless @busy || @compaction_reason

        " #{status_line} "
      end

      def status_line
        # The running compaction displaces the working/tool detail (pi
        # status-indicator.ts:85-95 via interactive-mode.ts:3672-3681).
        return "#{SPINNER[@frames % SPINNER.size]} #{COMPACTION_LABELS.fetch(@compaction_reason, "Compacting context...")}" if @compaction_reason

        detail = @tool ? "tool: #{@tool}" : (@live.empty? ? "thinking" : "…")
        "#{SPINNER[@frames % SPINNER.size]} #{detail}"
      end

      # The footer (AC4, pi footer.ts): line 1 the ~-contracted cwd with the
      # git branch; line 2 the token stats left and the model (plus the
      # thinking level — footer.ts:226-244) right-aligned. pi's whole
      # footer renders dim (:280-288 — the parts dimmed independently so
      # the colored context segment survives): every span is dim except
      # the context segment when it crosses the warning/error thresholds.
      def footer_widget
        data = @footer_data || {}
        width = viewport_width
        pwd = Chat.format_cwd(data[:cwd] || Dir.pwd)
        pwd = "#{pwd} (#{read_branch(data[:cwd])})" if read_branch(data[:cwd])
        TUI.paragraph(text: [
          TUI.line(clip_spans([TUI.span(pwd)], width), fg: Theme[:dim]),
          footer_stats(data, width),
        ], wrap: false)
      end

      # The branch, cached until the next turn invalidates it (pi's provider
      # cache, reduced to per-turn invalidation — recorded). The fetched
      # flag makes a nil result (no repo / detached HEAD) cached too.
      def read_branch(cwd)
        return nil if @branch_reader.nil? || cwd.nil?

        unless @branch_fetched
          @branch = @branch_reader.call(cwd)
          @branch_fetched = true
        end
        @branch
      end

      # The stats line as spans (footer.ts:113-153): ↑input ↓output
      # R(ead) W(rite) CH% when present, the context segment, then the
      # model right-aligned (min 2 spaces padding, stats truncated with
      # "..." when they would crowd it out). The thinking level rides the
      # right side as +model • <level>+ ONLY when the model is
      # reasoning-capable (pi footer.ts:233-244 reads
      # state.model?.reasoning; otherwise the model alone), and the
      # provider label prefixes the segment (pi :246-258 — the
      # launcher-resolved model metadata; pi's own >1-available-provider
      # gate is unimplementable without a catalog, itemized). pi's
      # "thinking off" state is unreachable through the port's level
      # resolution, itemized.
      def footer_stats(data, width)
        totals = @usage_totals
        parts = []
        parts << "↑#{Chat.format_tokens(totals[:input])}" if totals[:input].positive?
        parts << "↓#{Chat.format_tokens(totals[:output])}" if totals[:output].positive?
        parts << "R#{Chat.format_tokens(totals[:cache_read])}" if totals[:cache_read].positive?
        parts << "W#{Chat.format_tokens(totals[:cache_write])}" if totals[:cache_write].positive?
        parts << "CH#{format("%.1f%%", cache_hit_rate)}" if cache_hit_rate

        model = data[:model] || "no-model"
        right = data[:reasoning] ? "#{model} • #{data[:thinking_level]}" : model
        right = "(#{data[:provider]}) #{right}" if data[:provider]
        left = parts.map { |part| TUI.span("#{part} ", fg: Theme[:dim]) }
        left << TUI.span(context_segment(data), fg: context_fg)
        pad = width - left.sum { |span| TUI.text_width(span.content) } - TUI.text_width(right)
        spans = if pad >= 2
          left + [TUI.span(" " * pad + right, fg: Theme[:dim])]
        else
          # Too wide: the stats clip (with their colors) and the model keeps
          # a two-cell margin (pi truncates statsLeft with "...").
          clip_spans(left, [width - TUI.text_width(right) - 2, 0].max) + [TUI.span("… #{right}", fg: Theme[:dim])]
        end
        TUI.line(spans)
      end

      # The context numerator (pi getContextUsage, agent-session.ts
      # :4237-4271): provider-reported context tokens of the latest
      # assistant usage — 0 at boot (pi's estimate 0 → the 0.0% boot
      # state), nil after a compaction until the next LLM response (pi's
      # post-compaction "?").
      def context_used
        return nil if @usage_stale
        return 0 if @last_usage.nil?

        Compaction.calculate_context_tokens(@last_usage)
      end

      # The context segment (footer.ts:134-143): "0.0%/window (auto)" at
      # boot, "pct%/window (auto)" after usage, "?/window (auto)" after a
      # compaction (pi's post-compaction "?"). Nil window renders "?"
      # alone.
      def context_segment(data)
        window = data[:context_window]
        auto = data[:auto_compact] ? " (auto)" : ""
        return "?" if window.nil?

        used = context_used
        return "?/#{Chat.format_tokens(window)}#{auto}" if used.nil?

        "#{(used * 100.0 / window).round(1)}%/#{Chat.format_tokens(window)}#{auto}"
      end

      def context_fg
        used = context_used
        window = @footer_data&.fetch(:context_window, nil)
        return Theme[:dim] if used.nil? || !window.is_a?(Integer) || !window.positive?

        percent = used * 100.0 / window
        if percent > 90 then Theme[:error] # footer.ts:194-213
        elsif percent > 70 then Theme[:warning]
        else Theme[:dim]
        end
      end

      # pi's latestCacheHitRate (footer.ts:98-103): the latest assistant
      # usage's cacheRead share of the prompt tokens.
      def cache_hit_rate
        return nil if @last_usage.nil? || @usage_totals[:cache_read].zero? && @usage_totals[:cache_write].zero?

        prompt = [@last_usage.input, @last_usage.cache_read, @last_usage.cache_write].compact.sum
        prompt.positive? ? @last_usage.cache_read * 100.0 / prompt : nil
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
      # the editor's inner width (pre-existing; pi scrolls horizontally).
      def input_spans
        at = @input[@cursor]
        spans = [TUI.span(@input[0, @cursor] || "")]
        return spans << TUI.span(" ", modifiers: [:reversed]) unless at

        spans << TUI.span(at, modifiers: [:reversed]) << TUI.span(@input[(@cursor + 1)..])
      end

      # Clips styled spans to +width+ visible columns (the editor's inner
      # width); the trailing partial span is trimmed cell-wise.
      def clip_spans(spans, width)
        out = []
        budget = width
        spans.each do |span|
          break if budget <= 0

          text = span.content
          if TUI.text_width(text) <= budget
            out << span
            budget -= TUI.text_width(text)
          else
            head, = self.class.fit(text, budget)
            out << TUI.span(head, fg: span.style&.fg, modifiers: span.style&.modifiers.to_a)
            budget -= TUI.text_width(head)
          end
        end
        out
      end

      # The transcript buffer's display lines — completed content plus the
      # live region. The transcript area windows this ({transcript_widget})
      # and the mouse machinery addresses it (selection points are buffer
      # rows).
      def display_lines
        @transcript + live_lines(viewport_width)
      end

      # One transcript row re-styled with the selection's inverse highlight
      # (pi applySelection :1589-1638 + applySelectionHighlight :1572-1584:
      # SGR 7 over the covered cells — the port's [:reversed] modifier on
      # the covered spans, fg kept). Rows outside the selection pass
      # through untouched.
      def highlight_row(line, row)
        bounds = selection_bounds
        return line unless bounds
        return line if row < bounds.first.row || row > bounds.last.row

        from, to = selection_columns(row, TUI.text_width(line.spans.map(&:content).join))
        return line if to <= from

        reverse_cells(line, from, to)
      end

      # The selection's cell range on +row+ (pi getSelectionColumns
      # :1429-1447): the start/end columns only bite on their own rows;
      # the char-granularity end is inclusive (+1), a word/line end is
      # exclusive (boundary).
      def selection_columns(row, width)
        start, focus = selection_bounds
        from = start.row == row ? start.col : 0
        to = focus.row == row ? (focus.boundary ? focus.col : focus.col + 1) : width
        [from.clamp(0, width), to.clamp(0, width)]
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

          piece = slice_cells(span.content, a - cell, b - a)
          reversed = a >= from && b <= to
          TUI.span(piece, fg:, modifiers: reversed ? modifiers + [:reversed] : modifiers)
        end
      end

      # The streaming region (item 3, pi interactive-mode.ts:3519-3535 +
      # assistant-message.ts:107-109): the reasoning block stays plain dim
      # italic (the I13 standing ruling — markdown-of-reasoning is cut,
      # itemized) and the CONTENT re-renders as markdown on every delta —
      # pi re-renders the whole streaming message each update, no
      # incremental cleverness. The transcript area's tail clip bounds it
      # (deltas append; the window slides).
      def live_lines(width)
        return [] if @live.empty? && @reasoning.empty?

        reasoning_lines(@reasoning, width) + (@live.empty? ? [] : markdown_lines(@live, width))
      end

      # The editor area's extra rows while the suggestion list is active:
      # the visible window plus the (i/N) scroll-info line (select-list.ts
      # render).
      def autocomplete_rows
        return 0 unless @suggestions

        [@suggestions.size, AUTOCOMPLETE_MAX + (@suggestions.size > AUTOCOMPLETE_MAX ? 1 : 0)].min
      end

      # The list's display lines (pi select-list.ts renderItem +
      # getVisibleRange, two-column with descriptions): the visible window
      # centered on the selection (startIndex = max(0, min(selected −
      # maxVisible/2, size − maxVisible))), "→ " marking the selection —
      # accent-styled whole-line (theme.ts:1061-1068 selectedText) —
      # unselected labels default with the description muted. Descriptions
      # only fit when the editor's inner width affords them (width > 40,
      # select-list.ts:189); the command column clamps to 12-32
      # (SLASH_COMMAND_SELECT_LIST_LAYOUT, editor.ts:248-251, gap 2).
      def autocomplete_lines(width)
        return [] unless @suggestions

        items = @suggestions
        start = [[@selected - AUTOCOMPLETE_MAX / 2, items.size - AUTOCOMPLETE_MAX].min, 0].max
        column = autocomplete_column_width(items)
        column = [column, width - 2 - 4].min # pi: effectivePrimaryColumnWidth (select-list.ts:191)
        rows = items[start, AUTOCOMPLETE_MAX].map.with_index do |item, i|
          autocomplete_row(item, start + i == @selected, column, width)
        end
        rows << TUI.line("  (#{@selected + 1}/#{items.size})", fg: Theme[:muted]) if items.size > AUTOCOMPLETE_MAX
        rows
      end

      # clamp(widest label + gap, 12, 32) over the whole filtered list (pi
      # select-list.ts getPrimaryColumnWidth, gap 2, slash layout 12/32).
      def autocomplete_column_width(items)
        widest = items.map { |item| TUI.text_width(item[:label]) + 2 }.max || 0
        [[widest, 12].max, 32].min
      end

      def autocomplete_row(item, selected, column, width)
        label = Chat.clip_text(item[:label], column - 2)
        spacing = " " * [1, column - TUI.text_width(label)].max
        desc = autocomplete_description(item[:description], width, label, spacing)
        return TUI.line("→ #{label}#{spacing}#{desc}", fg: Theme[:accent]) if selected

        TUI.line([TUI.span("  #{label}"), TUI.span("#{spacing}#{desc}", fg: Theme[:muted])])
      end

      # The description column (select-list.ts:189-210): only when the width
      # affords it (> 40) and at least MIN_DESCRIPTION_WIDTH (10) columns
      # remain after prefix + label + spacing − a two-cell safety margin;
      # hard-clipped (truncateToWidth with an empty tail).
      def autocomplete_description(desc, width, label, spacing)
        return "" unless desc && width > 40

        remaining = width - (2 + TUI.text_width(label) + spacing.length) - 2
        remaining >= 10 ? Chat.clip_text(desc, remaining) : ""
      end

      # --- /resume session picker (item 2, pi SessionSelectorComponent,
      # reduced): the editor area is REPLACED by the picker while open (pi
      # showSelector swaps the container and moves focus). Reductions,
      # itemized: no search input (fuzzy/regex/exact), no all-sessions
      # scope toggle, no threaded/name sort modes, no rename, no delete,
      # no path/cwd toggles, no cwd-mismatch prompt, no hint rows — a flat
      # newest-first list with pi's key shape (up/down navigate, enter
      # selects — onSelect —, escape cancels — onCancel).
      def picker_input(event)
        case event.code
        when "up" then navigate_picker(-1)
        when "down" then navigate_picker(1)
        when "enter"
          item = @picker[:items][@picker[:selected]]
          @picker = nil
          @on_resume&.call(item[:path]) if item
        when "escape" then @picker = nil
        end
      end

      # pi SelectList.handleInput (select-list.ts:146-155): up/down WRAP.
      def navigate_picker(direction)
        size = @picker[:items].size
        return if size.zero?

        selected = @picker[:selected]
        @picker[:selected] = direction == -1 ? (selected.zero? ? size - 1 : selected - 1) : (selected == size - 1 ? 0 : selected + 1)
      end

      def picker_widget
        TUI.block(
          title: " Resume Session (Current Folder) ", # pi SessionSelectorHeader.render :147
          borders: [:top, :bottom],
          border_style: TUI.style(fg: Theme[:border]),
          title_style: TUI.style(fg: Theme[:dim]),
          children: [TUI.paragraph(text: picker_lines, wrap: false)]
        )
      end

      # The picker's content rows: one line per session (pi renders one
      # line each with tree structure :459-460), "→ " marking the selection
      # (accent, pi selectedText — the autocomplete row's shape), labels
      # hard-clipped to the width.
      def picker_lines
        items = @picker[:items]
        return [TUI.line("  No sessions found", fg: Theme[:muted])] if items.empty?

        start = [[@picker[:selected] - PICKER_MAX / 2, items.size - PICKER_MAX].min, 0].max
        rows = items[start, PICKER_MAX].map.with_index do |item, i|
          label = Chat.clip_text(item[:label], viewport_width - 3)
          (start + i) == @picker[:selected] ? TUI.line("→ #{label}", fg: Theme[:accent]) : TUI.line("  #{label}")
        end
        rows << TUI.line("  (#{@picker[:selected] + 1}/#{items.size})", fg: Theme[:muted]) if items.size > PICKER_MAX
        rows
      end

      # The picker's row budget (the editor-area height calc; +2 borders).
      def picker_widget_rows
        items = @picker[:items]
        count = [items.size, PICKER_MAX].min
        items.size > PICKER_MAX ? count + 1 : count
      end

      # Completed lines move into the transcript buffer (pi: completed
      # content into scrollback). Entries are final display Lines. The
      # inline insert_before path is retired from the interactive surface —
      # the buffer is drawn wholesale every frame.
      def flush_scrollback
        until @scrollback.empty?
          @transcript.concat(@scrollback.pop)
        end
      end
    end
  end
end
