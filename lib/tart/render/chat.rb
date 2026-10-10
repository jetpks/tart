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
    # kernel interrupt (Ctrl+C) cancels the in-flight turn.
    #
    # Approval: the approval callback runs on the kernel fiber and waits on
    # an +Async::Queue#pop+ — interruptible at the suspension point by
    # Task#stop. The decision is pushed cross-thread (the I03 lost-wakeup
    # cure: a fiber-to-fiber +Async::Queue+ push on the same thread can fail
    # to wake a blocked pop; a cross-thread push is the proven path).
    class Chat
      SPINNER = %w[⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏].freeze

      # How long one draw re-arms the animation window while the agent works
      # (frame pacing: deadline-paced at the frame rate while busy, purely
      # event-driven when idle — the I02 static-loop property).
      BUSY_FRAME_SECONDS = 0.25

      # Rows the pending-approval block occupies in the editor area.
      APPROVAL_ROWS = 3

      # Rows the footer always occupies (pi renders a pwd line + a stats
      # line — footer.ts:169-171).
      FOOTER_ROWS = 2

      # Smallest editor area: top border, one input row, bottom border (pi
      # chat-viewport.ts:33 editor minSize 3).
      MIN_EDITOR_ROWS = 3

      # Bounded multi-line tool-result preview: at most this many content
      # lines, then an ellipsis row (pi truncates tool output previews).
      TOOL_PREVIEW_LINES = 3

      # History depth (pi: editor.ts addToHistory caps at 100 entries).
      HISTORY_LIMIT = 100

      # Suggestion-list window (pi editor.ts:322 default 5; the 3-20 clamp
      # is settings-backed — cut, itemized deviation: fixed at the default).
      AUTOCOMPLETE_MAX = 5

      # pi status-indicator.ts:85-95 — the compaction-start border labels,
      # minus the cancel hint (deviation: ctrl+c aborts the whole run in the
      # port, not just the compaction — BRIEF §5.1, itemized).
      COMPACTION_LABELS = {
        manual: "Compacting context...",
        threshold: "Auto-compacting...",
        overflow: "Context overflow detected, Auto-compacting..."
      }.freeze

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
      #   denominator), +:auto_compact+ (the compaction-enabled indicator).
      #   nil renders the footer from what the surface knows alone.
      # @param branch_reader [Proc] +call(cwd)+ → branch name or nil.
      # @param autocomplete [Object, nil] the completion-source seam (AC1):
      #   answers +items+ with the full {value:, label:, description:}
      #   catalog the surface fuzzy-filters. nil (the default) offers no
      #   suggestions — headless tests stay deterministic; bin/tart wires
      #   the real command/skill sources (see {SlashSource}).
      def initialize(session:, kernel:, footer_data: nil, branch_reader: DEFAULT_BRANCH_READER, autocomplete: nil)
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
        # The running compaction's reason (the border-status label's key).
        @compaction_reason = nil
        @live = +""
        @busy = false
        @tool = nil
        @pending = nil
        @frames = 0
        @decisions = Async::Queue.new
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
      end

      # The agent loop this surface drives (wired after construction: the
      # agent's on_event/approval procs reference this chat).
      attr_accessor :agent

      # The slash-command handler (Commands::Handler, bin-wired): leading-
      # "/" submit text routes through it before any agent call. nil (the
      # default; e.g. tests) sends every text to the agent — pre-I10 shape.
      attr_accessor :commands

      # The launcher-wired footer facts (see #initialize).
      attr_writer :footer_data

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
      # Ctrl+C never reaches here — the kernel owns it (interrupt). Resize
      # events are ignored here; the kernel marks the frame dirty either way
      # and the next frame recomposes from the session's fresh viewport.
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
            @branch = nil # per-turn branch invalidation (pi's provider cache, reduced)
            @branch_fetched = false
          when :message_start
            @live = +""
          when :message_update
            chunk = event[:chunk]
            @live << chunk.content if chunk.content.is_a?(String) && !chunk.content.empty?
          when :message_end
            message = event[:message]
            if message.role == :assistant
              accumulate_usage(message)
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
            enqueue_scrollback(handled, fg: Theme[:tool_output])
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
        def fuzzy_filter(items, query)
          return items if query.strip.empty?

          tokens = query.strip.split(/[\s\/]+/).reject(&:empty?)
          return items if tokens.empty?

          items.filter_map do |item|
            text = yield(item)
            scores = tokens.map { |token| fuzzy_match(token, text) }
            scores.all? ? [item, scores.sum] : nil
          end.sort_by { |_, score| score }.map(&:first)
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

      # Verbatim completed text (user echo, tool output, status): wrapped to
      # the transcript width, one line-level fg.
      def enqueue_scrollback(text, fg:)
        return if text.nil? || text.empty?

        @scrollback << Chat.wrap(text, viewport_width).map { |line| TUI.line(line, fg:) }
      end

      # Assistant completions render through the markdown converter (AC5):
      # styled rows wrapped to the transcript width, every span's fg routed
      # through the theme (AC3), then converted row → Line at the TUI seam.
      # The live region streamed the raw source verbatim — markdown renders
      # at completion only (the recorded deviation from pi's streaming
      # markdown rendering).
      def enqueue_markdown(text)
        return if text.nil? || text.empty?

        width = viewport_width
        rows = Render::Markdown.rows(text, width:).flat_map { |row| Chat.wrap_row(row, width) }
        @scrollback << rows.map do |row|
          themed = row.map { |span| Render::Markdown::Span.new(text: span.text, fg: Theme.md_fg(span.fg), modifiers: span.modifiers) }
          TUI.markdown_line(themed)
        end
      end

      # Session-cumulative usage totals + the latest assistant usage (the
      # context numerator; pi's getSessionStats over session entries,
      # reduced to what the event surface carries: assistant messages).
      def accumulate_usage(message)
        tokens = message.tokens if message.respond_to?(:tokens)
        return if tokens.nil?

        @usage_totals[:input] += tokens.input if tokens.input
        @usage_totals[:output] += tokens.output if tokens.output
        @usage_totals[:cache_read] += tokens.cache_read if tokens.cache_read
        @usage_totals[:cache_write] += tokens.cache_write if tokens.cache_write
        @last_usage = tokens
        @usage_stale = false
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
          cancel_autocomplete # pi editor.ts:1261 — paste cancels the list
          return
        end

        ctrl = event.modifiers.include?("ctrl")
        alt = event.modifiers.include?("alt")
        printable = event.text? && !(event.modifiers & %w[ctrl alt]).any?
        case event.code
        # Enter applies the selection and submits it (pi editor.ts:790-816
        # tui.select.confirm: a "/"-prefix completion falls through to
        # submit). Escape cancels the list WITHOUT interrupting (pi
        # custom-editor.ts:103-111 — interrupt only when no list is shown).
        when "enter"
          apply_suggestion if @suggestions
          submit
        when "escape" then cancel_autocomplete if @suggestions
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
        when "d" then alt ? delete_word_forward : (ctrl ? delete_forward : insert_printable(event))
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
        enqueue_scrollback("❯ #{text}", fg: Theme[:user_message_text])
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
      # the transcript buffer. Thread-safe — the kernel task calls this
      # off-frame.
      def command_line(text)
        @mutex.synchronize { enqueue_scrollback(text, fg: Theme[:muted]) }
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
        @follow = false
        @scroll_offset = [@scroll_offset + direction * transcript_page_rows, 0].max
      end

      # The transcript area's row budget — the page size (pi chat-viewport
      # geometry, shared with {build_widget}).
      def transcript_page_rows
        area = @session.viewport_area
        height = area ? area.height : 24
        [height - editor_area_rows(height) - FOOTER_ROWS, 1].max
      end

      def editor_area_rows(height)
        [MIN_EDITOR_ROWS + (@pending ? APPROVAL_ROWS - 1 : 0) + autocomplete_rows, height - 1].min
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
            editor_widget,
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
        lines = @transcript + live_lines(width)
        max_offset = [lines.size - rows, 0].max
        @scroll_offset = @follow ? max_offset : @scroll_offset.clamp(0, max_offset)
        @follow = true if @scroll_offset == max_offset
        window = lines[@scroll_offset, rows] || []
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
      # track "│" / thumb "┃"). Theme routing: the port's token table has
      # no scrollbarTrack/scrollbarThumb (RAISED in PHASE 0 — theme.rb
      # read-only this iteration); the nearest analogs carry it (track →
      # dim, thumb → muted) until the tokens are promoted.
      def scrollbar_glyphs(total, rows)
        TUI.scrollbar_lines(content_length: total, position: @scroll_offset, viewport: rows,
          track_fg: Theme[:dim], thumb_fg: Theme[:muted])
      end

      # The bordered editor area (pi CustomEditor): the input line inside
      # the borders; while an approval prompt holds the editor, its prompt
      # displaces the input row (pi: the dialog replaces the editor in the
      # editor container). The top border's title is the status line (pi
      # renderTopBorder via custom-editor.ts:18-22) — absent when idle (pi
      # IdleStatus renders empty).
      def editor_widget
        inner = [viewport_width - 2, 1].max
        content = if @pending
          approval_lines(inner).map { |text| TUI.line(text, fg: Theme[:warning]) }
        else
          # The suggestion list renders below the input row, inside the
          # editor area (pi editor.ts:618-634 — the area height grows by
          # the list height).
          [TUI.line(clip_spans(input_spans, inner))] + autocomplete_lines(inner)
        end
        TUI.block(
          title: status_title,
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
      # git branch; line 2 the token stats left and the model id
      # right-aligned, all dim except the context segment (warning >70%,
      # error >90% — footer.ts:132-139).
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
      # model id right-aligned (min 2 spaces padding, stats truncated with
      # "..." when they would crowd it out).
      def footer_stats(data, width)
        totals = @usage_totals
        parts = []
        parts << "↑#{Chat.format_tokens(totals[:input])}" if totals[:input].positive?
        parts << "↓#{Chat.format_tokens(totals[:output])}" if totals[:output].positive?
        parts << "R#{Chat.format_tokens(totals[:cache_read])}" if totals[:cache_read].positive?
        parts << "W#{Chat.format_tokens(totals[:cache_write])}" if totals[:cache_write].positive?
        parts << "CH#{format("%.1f%%", cache_hit_rate)}" if cache_hit_rate

        model = data[:model] || "no-model"
        left = parts.map { |part| TUI.span("#{part} ") }
        left << TUI.span(context_segment(data), fg: context_fg)
        pad = width - left.sum { |span| TUI.text_width(span.content) } - TUI.text_width(model)
        spans = if pad >= 2
          left + [TUI.span(" " * pad + model)]
        else
          # Too wide: the stats clip (with their colors) and the model keeps
          # a two-cell margin (pi truncates statsLeft with "...").
          clip_spans(left, [width - TUI.text_width(model) - 2, 0].max) + [TUI.span("… #{model}")]
        end
        TUI.line(spans)
      end

      # The context numerator: provider-reported context tokens of the
      # latest assistant usage — nil before the first usage and after a
      # compaction (pi's post-compaction "?").
      def context_used
        return nil if @usage_stale || @last_usage.nil?

        Compaction.calculate_context_tokens(@last_usage)
      end

      # The context segment (footer.ts:134-143): "?/window (auto)" until
      # usage arrives (and after compaction, pi's post-compaction "?"),
      # then "pct%/window (auto)". Nil window renders "?" alone.
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
        if percent > 90 then Theme[:error]
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
        spans = [TUI.span("❯ "), TUI.span(@input[0, @cursor] || "")]
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

      # The streaming text, wrapped to the transcript width — the
      # transcript area's tail clip bounds it (deltas append; the window
      # slides).
      def live_lines(width)
        return [] if @live.empty?

        self.class.wrap(@live, width).map { |line| TUI.line(line) }
      end

      def approval_lines(width)
        args = JSON.generate(@pending.arguments) rescue @pending.arguments.to_s
        [
          "approve #{@pending.name}?",
          args.length > width ? args[0, width] : args,
          "y = yes, n = no"
        ]
      end

      # The editor area's extra rows while the suggestion list is active:
      # the visible window plus the (i/N) scroll-info line (select-list.ts
      # render). An approval prompt consumes the keys — no list alongside
      # it.
      def autocomplete_rows
        return 0 unless @suggestions && !@pending

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
        return [] unless @suggestions && !@pending

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
