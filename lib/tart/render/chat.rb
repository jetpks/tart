# frozen_string_literal: true

require "open3"

require_relative "text"
require_relative "panel"
require_relative "bash_block"
require_relative "file_blocks"
require_relative "tool_block"
require_relative "editor"
require_relative "autocomplete"
require_relative "picker"
require_relative "slash_source"

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

      # pi chat-viewport.ts:22-45 — the dock's widgets-above container
      # renders a default Spacer(1) when no extension widgets exist
      # (interactive-mode.ts:966-968 renderWidgetContainer,
      # spacerWhenEmpty: true): a blank dock row between the transcript
      # and the editor. The port's fixed analog (no extension
      # widgets/pending/status containers — itemized cuts, as ever):
      # transcript + spacer(1) + editor + footer.
      DOCK_SPACER_ROWS = 1

      # The auto scrollbar's transient hide delay (pi scroll-view.ts:55
      # scrollbarHideDelayMs, default 1000 — AC2). Injectable so tests
      # never sleep real seconds.
      SCROLLBAR_HIDE_DELAY_MS = 1000

      # Smallest editor area: top border, one input row, bottom border (pi
      # chat-viewport.ts:33 editor minSize 3).
      MIN_EDITOR_ROWS = 3

      # The tool name that dispatches to pi's shell renderers (bash.ts:115
      # createShellRenderers — shared by bash and powershell; the port
      # runs bash only).
      BASH_TOOL = "bash".freeze

      # The file tools that dispatch to pi's per-tool renderers (I18 —
      # write.ts/read.ts renderCall/renderResult); everything else
      # non-bash keeps the generic ⎿ line (I17's ruling).
      WRITE_TOOL = "write".freeze
      READ_TOOL = "read".freeze

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
      # The compact hint row as (key, description) pairs — pi keyHint's
      # shape (keybinding-hints.ts:42-44): the key in dim, the description
      # in muted with the " · " separator riding its run (the -e capture's
      # byte proof; the system-theme-era whole-line dim was the artifact).
      PI_HINTS = [
        ["escape", "interrupt"],
        ["ctrl+c/ctrl+d", "clear/exit"],
        ["/", "commands"],
        ["!", "bash"],
        ["ctrl+o", "more"],
      ].freeze
      PI_NOTICE_LINE = "Press ctrl+o to show full startup help and loaded resources.".freeze
      PI_ONBOARDING_LINE = "Pi can explain its own features and look up its docs. Ask it how to use or extend Pi.".freeze

      # pi keyHint (keybinding-hints.ts:42-44) over {PI_HINTS}: dim key +
      # muted description, the separator inside every description run but
      # the last.
      def pi_hint_spans
        PI_HINTS.flat_map.with_index do |(key, description), index|
          tail = index == PI_HINTS.length - 1 ? " #{description}" : " #{description} · "
          [TUI.span(key, fg: Theme[:dim]), TUI.span(tail, fg: Theme[:muted])]
        end
      end

      # pi's outputPad (interactive-mode.ts:516, default 1): one leading
      # space on every content row of the chat surface — the header's Text
      # paddingX (interactive-mode.ts:1060-1063), the echo's and the
      # assistant's Markdown paddingX (user-message.ts:23,

      # An expandable block riding the scrollback queue: the rows built at
      # the CURRENT toggle state + the builder (re-invoked with the new
      # state at the ctrl+o toggle; the drain records the transcript
      # range). pi's expandable tool children.
      MarkedRegion = Struct.new(:rows, :builder)

      # One random art piece's lines (empty collection → no logo lines).
      def motd_logo_lines
        file = Dir[File.join(LOGOS_DIR, "*.txt")].sample
        file ? File.readlines(file, chomp: true) : []
      end

      # The selection granularity's word-char class (the editor's full
      # boundary-class set lives on {Editor} — word-navigation.ts).
      WORD_CHAR = Editor::WORD_CHAR

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
      #   catalog the list fuzzy-filters. nil (the default) offers no
      #   suggestions — headless tests stay deterministic; bin/tart wires
      #   the real command/skill sources (see {SlashSource}).
      # @param motd [Boolean] render the startup MOTD block on the first
      #   frame (and on {new_session}); tests that pin plain transcript
      #   content opt out, the launcher's default renders it.
      # @param identity [String] the resolved face (Tart::Identity) the
      #   MOTD renders — pi's header bytes vs the owner's art + tart
      #   header. Structural items (padding, spacers, footer format) are
      #   identity-independent.
      # @param prompts [Array<Prompts::Template>] the loaded prompt
      #   templates — the MOTD's [Prompts] section (injectable so tests
      #   never touch the filesystem; the empty default renders no
      #   section, as in pi).
      # @param extensions [Array<String>] the loaded MCP server names —
      #   the MOTD's [Extensions] section (the port's loaded
      #   external-resource analog; empty renders none).
      # @param settings_root [String] the user config dir the MOTD's
      #   [Context] section reports (injectable so tests never touch
      #   ~/.tart).
      def initialize(session:, kernel:, footer_data: nil, branch_reader: DEFAULT_BRANCH_READER, autocomplete: nil,
        motd: true, identity: Identity::DEFAULT, settings_root: Agent::Session.default_root,
        prompts: [], extensions: [])
        @session = session
        @kernel = kernel
        @footer_data = footer_data
        @branch_reader = branch_reader
        @agent = nil
        @mutex = Mutex.new
        # The input-line editor (pi's Input — the editor state and
        # operations) and its suggestion list over the injected completion
        # source (pi editor.ts autocompleteState/autocompleteList +
        # SelectList). Both unsynchronized — see the class comment.
        @editor = Editor.new
        @autocomplete = Autocomplete.new(source: autocomplete)
        # Transcript scroll state (pi ScrollView follow-end semantics): the
        # viewport's top-line offset over the buffer; +@follow+ while pinned
        # to the end (the default — the tail is what's visible).
        @scroll_offset = 0
        @follow = true
        # The auto scrollbar's transient state (pi scroll-view.ts:74-123):
        # the activity timestamp a user scroll marks (transientScrollbarVisible
        # — fresh while younger than the hide delay) and the epoch that
        # retires stale one-shot hide timers (pi clearTimeout). Reactor-
        # thread-only state, like the scroll state.
        @scrollbar_activity_at = nil
        @scrollbar_timer_epoch = 0
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
        # reduced): nil = closed; open it holds the {Picker} over the
        # launcher-built [{path:, label:}] list (newest first).
        @picker = nil
        # The ctrl+o global tool-output toggle (pi toolOutputExpanded,
        # setToolsExpanded — interactive-mode.ts:6810-6826): every
        # expandable block rebuilds in place; the border status reports.
        # The expandable registry tracks each block's transcript row range
        # + row builder (recorded at drain time — the scrollback is a
        # cross-thread queue, the transcript is flat).
        @tool_output_expanded = false
        @expandable_blocks = []
        @border_status = nil
        # The !-prefix bash execution (backlog C, pi handleBashCommand):
        # the in-flight task (single-flight — pi's isBashRunning gate),
        # the escape-cancel handshake state, and the last ctrl+c timestamp
        # (pi's lastSigintTime — the double-press exit window,
        # handleCtrlC :6840).
        @user_bash_task = nil
        @user_bash_cancel_flag = false
        @user_bash_slot = {}
        @user_bash_command = nil
        @user_bash_excluded = false
        @last_ctrl_c = nil
        # The bashExecution records deferred while a turn runs (pi's
        # _pendingBashMessages, flushed on agent_end).
        @pending_bash_records = []
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
        @prompts = prompts
        @extensions = extensions
        # The runtime thinking level (nil = the settings default shows;
        # /thinking sets it — pi agent.state.thinkingLevel).
        @thinking_level = nil
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

      # The auto scrollbar's hide delay in ms (pi scrollbarHideDelayMs,
      # scroll-view.ts:55) — a test seam: tests inject a short delay
      # instead of sleeping real seconds.
      attr_writer :scrollbar_hide_delay_ms

      # @return [Boolean] whether an agent run is in flight.
      def busy?
        @mutex.synchronize { @busy }
      end

      # @return [String] the input line buffer (the editor's).
      def input
        @mutex.synchronize { @editor.input }
      end

      # The kernel handle (the escape-cancel path stops the user-bash task
      # through it; tests read it too).
      attr_reader :kernel

      # @return [Array<String>] the transcript buffer's display lines (test
      #   readback for kernel-driven tests, where the drawn widget tree is
      #   the only observable).
      def transcript_lines
        # Trailing PRESENTATION fill is not text: the bg panels' fill
        # spans (all-space content, bg-only style — the trailing pad and
        # the full-width blank rows) drop off the readback; content spans
        # keep their bytes verbatim (art trailing spaces, markdown
        # spacing rows). The -e capture remains the style gate.
        @mutex.synchronize do
          @transcript.map do |line|
            spans = line.spans.dup
            spans.pop while !spans.empty? && panel_fill_span?(spans.last)
            spans.empty? ? "" : spans.map(&:content).join
          end
        end
      end

      # A trailing bg-panel fill span: all-space content styled bg-only.
      def panel_fill_span?(span)
        style = span.style
        return false unless style && span.content.match?(/\A *\z/)

        style.bg && !style.fg && (style.modifiers || []).empty?
      end

      # @return [Array<Hash>, nil] the active suggestion items (test
      #   readback — the list is otherwise visible only in the drawn tree).
      def suggestions
        @mutex.synchronize { @autocomplete.suggestions }
      end

      # @return [Integer] the active list's selection index (test readback).
      def suggestions_index
        @mutex.synchronize { @autocomplete.selected }
      end

      # @return [Array<Hash>, nil] the open session picker's items (test
      #   readback; nil = closed).
      def picker_items
        @mutex.synchronize { @picker&.items }
      end

      # @return [Integer] the picker's selection index (test readback).
      def picker_index
        @mutex.synchronize { @picker ? @picker.selected : 0 }
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
            @border_status = nil # pi's status indicators clear on agent events
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
            @scrollback << [Panel.blank_line] # the compaction line is a region too (pi :3903-3904)
            enqueue_scrollback(
              "✻ compacted (#{event[:reason]}, #{event[:tokens_before]} tokens)", fg: Theme[:dim]
            )
          when :agent_end
            @busy = false
            @compaction_reason = nil
            # The deferred bashExecution records flush at agent end (pi's
            # _pendingBashMessages flush) — never mid-tool-sequence.
            flush_pending_bash_records
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
      # reduced): +items+ is the launcher-built [{path:, label:}] list,
      # newest first; keys route into the picker's +handle+ while open,
      # enter fires {on_resume} through the picker's on_select wiring.
      def open_session_picker(items)
        @mutex.synchronize { @picker = Picker.new(items:, on_select: ->(item) { @on_resume&.call(item[:path]) }) }
      end

      # Slash-command output (pi's chat-line status UX): a muted line in
      # the transcript buffer. Thread-safe — the kernel task calls this
      # off-frame. Public placement is load-bearing: bin/tart wires the
      # Commands::Handler with +output: ->(text) { surface.command_line(text) }+
      # (the I13 /skills NoMethodError).
      def command_line(text)
        @mutex.synchronize { enqueue_scrollback(text, fg: Theme[:muted]) }
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
        @scrollback << [Panel.blank_line]
        # The joined thinking renders as a dim block BEFORE the content
        # (pi assistant-message.ts:99-175 render order). The live
        # reasoning buffer is the text source, not Message#thinking —
        # the loop strips the latter before this event (itemized
        # deviation from the spec's message.thinking.text letter).
        flush_reasoning
        if has_content
          # Assistant completions render as markdown (AC5).
          @scrollback << [Panel.blank_line] if has_reasoning
          enqueue_markdown(content)
        end
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
        lines = [Panel.blank_line]
        lines.concat(@identity == Identity::PI ? pi_header_lines : tart_header_lines(viewport_width))
        # The loaded-resource sections ride BOTH identities (pi
        # showLoadedResources renders for any theme/identity — the owner's
        # missing [Context]/[Skills]/[Prompts]/[Extensions] block; each
        # section opens with its blank, the enqueue's trailing blank is
        # the header container's closing Spacer). Wrapped at the content
        # width, as the sections always have.
        motd_sections(viewport_width - Panel::OUTPUT_PAD.length * 2).each do |header, rows|
          lines << Panel.blank_line << TUI.line("#{Panel::OUTPUT_PAD}#{header}", fg: Theme[:md_heading])
          lines.concat(rows)
        end
        lines << Panel.blank_line
        @scrollback << lines
      end

      # tart-mode's header: the owner's art collection, the tart version
      # line, the port's hints line — every content row through the
      # {OUTPUT_PAD} rule. The resource sections render below for both
      # identities ({enqueue_motd}).
      def tart_header_lines(width)
        content_width = width - Panel::OUTPUT_PAD.length * 2
        lines = motd_logo_lines.map { |line| TUI.line("#{Panel::OUTPUT_PAD}#{line}") }
        lines << TUI.line([TUI.span(Panel::OUTPUT_PAD), TUI.span("tart"), TUI.span(" v#{Tart::VERSION}", fg: Theme[:dim])])
        lines.concat(Text.wrap(HINTS_LINE, content_width).map { |row| TUI.line("#{Panel::OUTPUT_PAD}#{row}", fg: Theme[:dim]) })
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
        # The separating space renders PLAIN (pi: the mark's spans, a
        # plain space, THEN the dim hints span — the -e capture's byte
        # proof: the port dimmed the space).
        hints = pi_hint_spans
        [
          TUI.line([TUI.span(Panel::OUTPUT_PAD), *top, TUI.span(" "), TUI.span("v#{Identity::ORACLE_VERSION}", fg: Theme[:dim])]),
          TUI.line([TUI.span(Panel::OUTPUT_PAD), *bottom, TUI.span(" "), *hints]),
          TUI.line([TUI.span(Panel::OUTPUT_PAD), TUI.span(PI_NOTICE_LINE, fg: Theme[:dim])]),
          Panel.blank_line,
          TUI.line([TUI.span(Panel::OUTPUT_PAD), TUI.span(PI_ONBOARDING_LINE, fg: Theme[:dim])])
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
      # [Skills] — the loaded skill names, sorted; [Prompts] — the loaded
      # prompt templates as /name, sorted (pi promptCompactList :1896);
      # [Extensions] — the loaded MCP server names, sorted. One wrapped
      # dim compact list each (pi formatCompactList :1791-1797). Sections
      # with no entries are omitted, as in pi.
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
        prompts = @prompts.map { |template| "/#{template.name}" }.sort
        unless prompts.empty?
          sections << ["[Prompts]", dim_compact_list(prompts, width)]
        end
        extensions = @extensions.sort
        unless extensions.empty?
          sections << ["[Extensions]", dim_compact_list(extensions, width)]
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
        return [] unless @autocomplete.source

        @autocomplete.source.items.filter_map { |item|
          item[:value].delete_prefix("skill:") if item[:value].start_with?("skill:")
        }.sort
      end

      # pi formatCompactList (:1791-1797): trimmed entries joined ", ",
      # two-space indent, dim — word-wrapped to the content width, every
      # row through the {OUTPUT_PAD} rule. (The sort, when wanted, happens
      # at the call site: pi's [Context] list passes sort: false —
      # registration order.)
      def dim_compact_list(entries, width)
        Text.wrap("  #{entries.join(", ")}", width).map { |row| TUI.line("#{Panel::OUTPUT_PAD}#{row}", fg: Theme[:dim]) }
      end

      # Verbatim completed text (tool output, status): wrapped to
      # the transcript width, one line-level fg. Everything routed here is
      # a chat-container child in pi (tool blocks, chat lines, compaction
      # and status lines), so it arms the leading-spacer gate.
      def enqueue_scrollback(text, fg:)
        return if text.nil? || text.empty?

        @chat_started = true
        @scrollback << Text.wrap(text, viewport_width).map { |line| TUI.line(line, fg:) }
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
      # {OUTPUT_PAD} rule, the bg riding the FULL row width (pi markdown.ts
      # :352 applyBackgroundToLine — pad spans + trailing fill + the
      # paddingY blanks all carry the panel bg).
      def enqueue_user_echo(text)
        bg = Theme[:user_message_bg]
        rows = Text.wrap(text, viewport_width - Panel::OUTPUT_PAD.length * 2).map do |row|
          TUI.line([TUI.span(Panel::OUTPUT_PAD, bg: bg),
                    TUI.span(row, fg: Theme[:user_message_text], bg: bg),
                    Panel.panel_tail(TUI.text_width(row), viewport_width, bg)])
        end
        region = []
        region << Panel.blank_line if @chat_started # the container's non-empty gate
        region << Panel.panel_blank_line(viewport_width, bg) # paddingY top (user-message.ts:23)
        region.concat(rows)
        region << Panel.panel_blank_line(viewport_width, bg) # paddingY bottom
        @chat_started = true
        @scrollback << region
      end

      # The submitted prompt's display dispatcher (the skill half of pi's
      # user-message rendering, interactive-mode.ts:3930-3948): the skill
      # block parses back out of the expanded text and renders as its OWN
      # collapsible panel (SkillInvocationMessageComponent, collapsed by
      # default — the owner's "[skill] architect (ctrl+o to expand)"
      # container), the trailing user message echoes below it as a normal
      # echo (pi's unconditional Spacer(1) between). The plain submission
      # is the echo alone. The MODEL receives and the session records the
      # full expanded text either way — the split is display-only, as in
      # pi.
      def enqueue_user_submission(text)
        block = Text.parse_skill_block(text)
        return enqueue_user_echo(text) unless block

        @scrollback << [Panel.blank_line] if @chat_started # the container's non-empty gate (once)
        @chat_started = true
        push_expandable(->(expanded) { skill_panel_rows(block, expanded:) })
        enqueue_user_echo(block.user_message) if block.user_message
      end

      # The skill-invocation panel (pi skill-invocation-message.ts:
      # Box(outputPad, 1, customMessageBg), collapsed by default, the
      # ctrl+o toggle sweeps it via the expandable registry — pi
      # component.setExpanded(this.toolOutputExpanded)). Collapsed: one
      # content row — the bold customMessageLabel [skill], the
      # customMessageText name, the dim " (ctrl+o to expand)" hint
      # (keyText app.tools.expand). Expanded: the label row, then the
      # bold-markdown name header + the content as markdown over
      # customMessageText prose (pi's color override — token colors
      # still apply, the prose callback doesn't). paddingY 1 both ways;
      # every row through the {OUTPUT_PAD} rule + the full-width bg.
      # pi's click-to-toggle MouseRegion is cut — the port's mouse owns
      # selection (itemized).
      def skill_panel_rows(block, expanded:)
        bg = Theme[:custom_message_bg]
        # pi: theme.fg("customMessageLabel", `\x1b[1m[skill]\x1b[22m `) —
        # the trailing space rides the LABEL's run. Every span carries the
        # panel bg itself — the bg is per-SPAN in the gem's emission, and
        # a span without one resets it (^[[49m — the transparent-text
        # defect).
        label = TUI.span("[skill] ", fg: Theme[:custom_message_label], modifiers: [:bold], bg: bg)
        unless expanded
          line = Panel.padded_spans_row(
            [label, TUI.span(block.name, fg: Theme[:custom_message_text], bg: bg),
             TUI.span(" (ctrl+o to expand)", fg: Theme[:dim], bg: bg)], viewport_width, bg
          )
          return [Panel.panel_blank_line(viewport_width, bg), line, Panel.panel_blank_line(viewport_width, bg)]
        end

        rows = [Panel.panel_blank_line(viewport_width, bg), Panel.padded_spans_row([label], viewport_width, bg)]
        rows.concat(markdown_lines("**#{block.name}**\n\n#{block.content}", viewport_width,
          prose_fg: Theme[:custom_message_text], bg: bg))
        rows << Panel.panel_blank_line(viewport_width, bg)
        rows
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
          when "bashExecution" then replay_user_bash(message)
          end
        when "compaction"
          # pi :3903-3904 — a compaction summary is a spaced region,
          # markdown-rendered (CompactionSummaryMessageComponent).
          @scrollback << [Panel.blank_line]
          enqueue_markdown(entry["summary"]) if entry["summary"].is_a?(String)
        end
      end

      def replay_user(message)
        content = message["content"]
        return unless content.is_a?(String) && !content.strip.empty?

        enqueue_user_submission(content)
        @editor.add_to_history(content) # pi renderInitialMessages populateHistory
      end

      # The replayed !-prefix bash execution (pi addMessageToChat's
      # bashExecution case :3870-3887): the block rebuilt from the
      # recorded fields — the recorded output is the executor's
      # tail-truncated content, the exact display input.
      def replay_user_bash(message)
        return unless message.is_a?(Hash)

        enqueue_user_bash_block(
          message["command"].to_s,
          content: message["output"].is_a?(String) ? message["output"] : "",
          exit_code: message["exitCode"],
          cancelled: message["cancelled"] == true,
          truncated: message["truncated"] == true,
          full_output_path: message["fullOutputPath"],
          excluded: message["excludeFromContext"] == true
        )
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
        @scrollback << [Panel.blank_line] if has_content || has_reasoning
        if has_reasoning
          @scrollback << reasoning_lines(reasoning, viewport_width)
          @scrollback << [Panel.blank_line] if has_content # pi :172-174
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
        @expandable_blocks.clear
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
      def markdown_lines(text, width, prose_fg: nil, bg: nil)
        content_width = width - Panel::OUTPUT_PAD.length * 2
        rows = Render::Markdown.rows(text, width: content_width).flat_map { |row| Text.wrap_row(row, content_width) }
        rows.map do |row|
          themed = row.map do |span|
            fg = Theme.md_fg(span.fg)
            fg = prose_fg if fg.nil? && prose_fg # the panel's prose-color override
            Render::Markdown::Span.new(text: span.text, fg:, modifiers: span.modifiers)
          end
          bg ? panel_markdown_row(themed, bg) : Panel.padded_row(themed)
        end
      end

      # One markdown row through the {OUTPUT_PAD} rule with the panel bg
      # + tail (the expanded skill panel's content rows —
      # applyBackgroundToLine over the Markdown component).
      def panel_markdown_row(spans, bg)
        width = spans.sum { |span| TUI.text_width(span.text) }
        content = spans.map { |span| TUI.span(span.text, fg: span.fg, modifiers: span.modifiers, bg: bg) }
        TUI.line([TUI.span(Panel::OUTPUT_PAD, bg: bg), *content, Panel.panel_tail(width, viewport_width, bg)])
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

      # The bash tool block (I17 — pi's shell renderer over the tool-turn
      # component): the constructor's Spacer (1 blank, tool-execution.ts:85),
      # the render box's paddingY (1 blank above and below the children,
      # tool-execution.ts:87 Box(1,1)), then the children — the bold
      # bashMode `$ <command>` header (bash.ts:36 theme.bold over
      # formatShellCall; colorKey bashMode — the port carries no
      # context-exclusion state, the dim variant is unreachable, itemized),
      # the output lines blank-separated from the header (bash.ts:78-84 —
      # the Text children's leading "\n") collapsed to the preview's last
      # rows plus the earlier-lines hint (I19 — {BashBlock.collapse_bash_preview};
      # the truncation notice rides after, {BashBlock.split_truncation_notice}), and
      # the muted `Took <duration>` line (bash.ts:105-109 — a nil/absent
      # duration, the replay path, renders none; the recorded gap is
      # itemized, never invented).
      def enqueue_bash_block(command, output, duration, error: false)
        @chat_started = true
        push_expandable(->(expanded) { BashBlock.bash_block_rows(command, output, duration, viewport_width, expanded:, error:) })
      end

      # The expandable-block enqueue: the block rides the scrollback as a
      # {MarkedRegion} (the drain records its transcript range for the
      # ctrl+o toggle's in-place rebuild).
      def push_expandable(builder)
        @scrollback << MarkedRegion.new(builder.(@tool_output_expanded), builder)
      end

      # The !-prefix bash block (pi BashExecutionComponent, backlog C): a
      # BORERED block — Spacer, DynamicBorder in the colorKey ("dim" for
      # the !!-excluded, bashMode otherwise), then the content: the bold
      # `$ command` header, the muted output (tail-truncated to pi's
      # context limits by the executor; collapsed to the last 20 VISUAL
      # rows of the last 20 LOGICAL lines — PREVIEW_LINES 20, keep "end",
      # visual-truncate.ts), the status rows (each its own row,
      # statusParts.join("\n")): the "... N more lines (ctrl+o to expand)"
      # hint (N = hidden LOGICAL lines), "(cancelled)" warning,
      # "(exit N)" error, "Output truncated. Full output: <path>"
      # warning — then the bottom border. The ctrl+o global toggle is the
      # next slice (the hint's TEXT renders for byte parity); streaming
      # loader frames are execution-transient (itemized).
      def enqueue_user_bash_block(command, content:, exit_code:, cancelled:, truncated:,
                                  full_output_path:, excluded:)
        push_expandable(->(expanded) do
          BashBlock.user_bash_block_rows(command, viewport_width, content:, exit_code:, cancelled:, truncated:,
                                         full_output_path:, excluded:, expanded:)
        end)
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
          # pi's bash tool marks a nonzero exit an isError result (the
          # s4 capture: the failed `ls` block renders toolErrorBg) — the
          # port's Tools::Bash gates identically (bash.rb:126); carry the
          # flag so the panel picks the error bg.
          error = result.is_a?(Hash) && result[:error]
          enqueue_bash_block(args["command"], ToolBlock.tool_result_text(result), duration, error:)
        when WRITE_TOOL
          enqueue_write_block(args, result)
        when READ_TOOL
          enqueue_read_block(args, result)
        else
          # Every tool block opens with a leading blank (pi
          # tool-execution.ts:85 — the constructor's Spacer), then the
          # bg'd contentText panel (the Box shape over ToolBlock.tool_line).
          @chat_started = true
          @scrollback << [Panel.blank_line, *ToolBlock.generic_panel_rows(name, result, viewport_width)]
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
        push_expandable(->(expanded) { FileBlocks.write_block_rows(args, result, viewport_width, expanded:) })
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
        push_expandable(->(expanded) { FileBlocks.read_block_rows(args, result, viewport_width, expanded:) })
      end

      def viewport_width
        area = @session.viewport_area
        area ? area.width : 80
      end

      # The key dispatch (pi interactive-mode.ts's component wiring): every
      # key routes into the editor, the suggestion list, or the picker —
      # the coordinator owns the routing, the objects own the state.
      def edit_input(event)
        if event.paste?
          @editor.insert(event.content)
          @autocomplete.cancel # pi editor.ts:1261 — paste cancels the list
          return
        end

        # The picker owns every key while open (pi: the selector takes
        # focus — showSelector { focus: selector }); it closes itself on
        # enter/esc and the holder drops.
        if @picker
          @picker = nil unless @picker.handle(event)
          return
        end

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
          @autocomplete.apply(@editor) if @autocomplete.suggestions
          submit
        when "esc"
          # pi onEscape (interactive-mode.ts:3069-3092): a streaming run
          # aborts through the kernel's interrupt path; a running user
          # bash cancels (abortBash); bash mode clears the input; idle
          # no-op (the double-escape /tree//fork is cut — no session
          # branching). The gem's canonical code is "esc"
          # (event/key/system.rb:36) — "escape" never matched a real tty
          # (the live-smoke find: I15's escape interrupt was silently
          # dead on real terminals).
          if @autocomplete.suggestions
            @autocomplete.cancel
          elsif busy?
            @kernel.interrupt_work!
          elsif @user_bash_task
            cancel_user_bash
          elsif @editor.bash_mode?
            @editor.clear
          end
        when "c"
          # app.clear (pi handleCtrlC :6840-6848): clear the editor; a
          # second press within 500 ms exits. The loop's in-band ctrl+c
          # intercept is REMOVED (loop.rb) — pi's escape is the interrupt,
          # ctrl+c is clear/exit (keybindings.ts:27).
          if ctrl
            now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            if @last_ctrl_c && now - @last_ctrl_c < 0.5
              @kernel.stop!
            else
              @editor.clear
              @last_ctrl_c = now
            end
          else
            @editor.insert_printable(event)
          end
        when "o"
          # app.tools.expand (pi keybindings.ts:50, default ctrl+o — the
          # GLOBAL tool-output toggle, setToolsExpanded).
          ctrl ? set_tool_output_expanded(!@tool_output_expanded) : @editor.insert_printable(event)
        # While the list is active up/down navigate the LIST (history
        # yields — pi custom-editor.ts:127-131 → editor.ts:766-771).
        when "up" then @autocomplete.suggestions ? @autocomplete.navigate(-1) : @editor.history_previous
        when "down" then @autocomplete.suggestions ? @autocomplete.navigate(1) : @editor.history_next
        when "tab"
          if @autocomplete.suggestions then @autocomplete.apply(@editor)
          else @autocomplete.update(@editor) # explicit trigger (pi handleTabCompletion)
          end
        # Transcript paging (pi keybindings.ts:114-115 tui.editor.pageUp/
        # pageDown, defaultKeys pageUp/ctrl+pageUp, pageDown/ctrl+pageDown;
        # the gem spells the codes "page_up"/"page_down") — the port maps
        # the action onto the transcript viewport (the port's editor is
        # single-line; mapping judgment, itemized). The list wins while
        # active (pi's precedence: the list owns the vertical keys).
        when "page_up" then scroll_page(-1) unless @autocomplete.suggestions
        when "page_down" then scroll_page(1) unless @autocomplete.suggestions
        when "backspace"
          alt ? @editor.delete_word_backward : @editor.delete_backward
          @autocomplete.update(@editor) # pi editor.ts:1449-1463 — re-filter/re-trigger
        when "delete" then alt ? @editor.delete_word_forward : @editor.delete_forward
        when "left" then (alt || ctrl) ? @editor.move_word_backward : @editor.move_left
        when "right" then (alt || ctrl) ? @editor.move_word_forward : @editor.move_right
        when "home" then @editor.move_start
        when "end" then @editor.move_end
        when "a" then ctrl ? @editor.move_start : @editor.insert_printable(event)
        when "e" then ctrl ? @editor.move_end : @editor.insert_printable(event)
        when "b" then alt ? @editor.move_word_backward : (ctrl ? @editor.move_left : @editor.insert_printable(event))
        when "f" then alt ? @editor.move_word_forward : (ctrl ? @editor.move_right : @editor.insert_printable(event))
        when "d"
          # app.exit (pi custom-editor.ts:118-125, keybindings.ts:28 —
          # default ctrl+d): on an empty editor the run exits (the /quit
          # path); non-empty falls through to delete-char-forward.
          if ctrl && @editor.input.empty?
            @kernel.stop!
          elsif alt
            @editor.delete_word_forward
          elsif ctrl
            @editor.delete_forward
          else
            @editor.insert_printable(event)
          end
        when "w" then ctrl ? @editor.delete_word_backward : @editor.insert_printable(event)
        else @editor.insert_printable(event)
        end
        # pi editor.ts:1228-1251 — the list re-filters on every printable
        # while active; typing triggers when in slash context (pi gates the
        # trigger to word chars/"/"; with a slash-only source the context
        # check alone decides, so one re-query covers both — CJK trigger
        # chars cut, itemized). Movement keys leave the list (pi literal).
        @autocomplete.update(@editor) if printable
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
        text = @editor.input.dup.strip # pi onSubmit trims (interactive-mode.ts:3201)
        @autocomplete.cancel
        return if text.empty?

        @editor.add_to_history(text)
        @editor.clear
        @editor.exit_history_browsing
        @branch = nil # per-turn branch invalidation
        @branch_fetched = false
        if @commands && text.start_with?("/")
          text = @commands.expand_skill(text)
          return if !busy? && @commands.dispatch(text)
        end
        # The !-prefix bash intercepts BEFORE the user echo (pi handleSubmit
        # :3347-3360 — the BashExecutionComponent is the display, no user
        # echo; the bare prefix falls through as plain text).
        parsed = user_bash_command(text)
        return user_bash(*parsed) if parsed

        enqueue_user_submission(text)
        if busy?
          @agent.push_message(text) # steering: consumed at the next turn boundary
        else
          @kernel.async { @agent.run(text) }
        end
      end

      # pi handleSubmit :3347-3356 — "!" runs whole-line bash, "!!" runs it
      # excluded from the model context; the bare prefix (no command) is
      # plain text. Returns [command, excluded] or nil.
      def user_bash_command(text)
        return unless text.start_with?("!")

        excluded = text.start_with?("!!")
        command = text[(excluded ? 2 : 1)..].to_s.strip
        return if command.empty?

        [command, excluded]
      end

      # The user-bash execution (pi handleBashCommand :6987): one at a time
      # (pi's isBashRunning gate — the warning is pi's showWarning text).
      # The tool run BRIDGES to a worker thread (Agent::Bridge — the tool's
      # pop-loop blocks its thread; the reactor must keep drawing), and the
      # block renders on completion; the RECORD defers to agent_end while
      # a turn runs (pi's _pendingBashMessages — the entry must not
      # interleave a tool sequence in the record). Streaming chunks are
      # execution-transient in pi's Loader frames — the port renders the
      # completed block (itemized).
      def user_bash(command, excluded)
        if @user_bash_task
          enqueue_scrollback("A bash command is already running. Press Esc to cancel it first.",
            fg: Theme[:warning])
          return
        end
        tool = Tools::Bash.new(cwd: Dir.pwd)
        # The escape-cancel handshake: the flag flips the worker's
        # cancellation checkpoint (the tool aborts at its next 50 ms
        # check — the group kill + partial-output outcome are the tool's
        # own {Tools::Bash#run_user} rescue), the task stop kills the
        # reactor-side wait, and the handler renders from the slot the
        # worker filled (read after the bridge's bounded join).
        @user_bash_command = command
        @user_bash_excluded = excluded
        @user_bash_cancel_flag = false
        @user_bash_slot = {}
        @user_bash_task = @kernel.async do
          terminal = Agent::Bridge.new
            .on_cancel { @user_bash_cancel_flag = true }
            .run(lambda do |sink|
              RubyLLM::Support::Cancellation.watch(
                -> { raise RubyLLM::CancelledError if @user_bash_cancel_flag }
              ) do
                outcome = tool.run_user(command)
                @user_bash_slot[:outcome] = outcome
                sink.call({})
              end
            end) { |_item| }
          finish_user_bash(terminal)
        end
      end

      # The worker's terminal: the outcome rendered + recorded; a worker
      # error surfaces as an error line (the ENOENT class — no block).
      def finish_user_bash(terminal)
        @user_bash_task = nil
        if (outcome = @user_bash_slot[:outcome])
          enqueue_user_bash_block(@user_bash_command, **user_bash_fields(outcome),
            excluded: @user_bash_excluded)
          record_user_bash(user_bash_record(@user_bash_command, outcome, excluded: @user_bash_excluded))
        elsif terminal&.dig(:type) == :error
          enqueue_scrollback("bash: #{terminal[:error].message}", fg: Theme[:error])
        end
        @kernel.request_draw
      end

      # The record defers while a turn runs (pi's _pendingBashMessages);
      # idle executions record immediately.
      def record_user_bash(message)
        if busy?
          @pending_bash_records << message
        else
          @agent&.record_bash_execution(message)
        end
      end

      # The escape-cancel (pi abortBash): flip the worker's checkpoint
      # flag, stop the reactor-side wait (the bridge joins the worker
      # bounded — its cancelled outcome, partial output included, lands
      # in the slot), then render from the slot after a bounded yield
      # loop (this handler runs in the frame-loop fiber — sleep yields).
      def cancel_user_bash
        @user_bash_cancel_flag = true
        @user_bash_task.stop
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
        sleep 0.05 while @user_bash_slot.empty? && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        outcome = @user_bash_slot[:outcome]
        @user_bash_task = nil
        enqueue_user_bash_block(@user_bash_command,
          **(outcome ? user_bash_fields(outcome) : {content: "", exit_code: nil, cancelled: true,
                                                    truncated: false, full_output_path: nil}),
          excluded: @user_bash_excluded)
        record_user_bash(user_bash_record(@user_bash_command,
          outcome || Tools::Bash::BashOutcome.new(content: "", exit_code: nil, cancelled: true,
                                                  truncation: nil, full_output_path: nil),
          excluded: @user_bash_excluded))
        @kernel.request_draw
      end

      # The block's primitive fields off the executor's outcome (the live
      # and replay compositions share them — pi's setComplete arguments,
      # bash-execution.ts:108-121).
      def user_bash_fields(outcome)
        {content: outcome.content, exit_code: outcome.exit_code, cancelled: outcome.cancelled,
         truncated: outcome.truncation&.truncated == true,
         full_output_path: outcome.truncation&.truncated == true ? outcome.full_output_path : nil}
      end

      def user_bash_record(command, outcome, excluded:)
        fields = user_bash_fields(outcome)
        Agent::Session.bash_execution_message(
          command:, output: fields[:content], exit_code: fields[:exit_code],
          cancelled: fields[:cancelled], truncated: outcome.truncation&.truncated == true,
          full_output_path: outcome.full_output_path,
          exclude_from_context: excluded
        )
      end

      # The agent_end flush (pi's agent-end _pendingBashMessages flush).
      def flush_pending_bash_records
        @pending_bash_records.each { |message| @agent&.record_bash_execution(message) }
        @pending_bash_records.clear
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
        Text.wrap(text, width - Panel::OUTPUT_PAD.length * 2).map { |line| TUI.line([TUI.span(Panel::OUTPUT_PAD), TUI.span(line, fg: Theme[:thinkingText], modifiers: [:italic])]) }
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
      # relative to it. A scroll that MOVED marks scrollbar activity (pi
      # scrollBy: `if (moved !== 0) markScrollbarActivity()` — a clamped
      # no-op marks nothing).
      def scroll_by(lines)
        max_offset = [display_lines.size - transcript_area_rows, 0].max
        start = @follow ? max_offset : @scroll_offset # pi: followingEnd ? maxScrollTop : scrollTop
        previous = @scroll_offset
        @scroll_offset = [[start + lines, max_offset].min, 0].max
        @follow = false
        mark_scrollbar_activity if @scroll_offset != previous
      end

      # The auto rail's transient show (pi ScrollView.markScrollbarActivity,
      # scroll-view.ts:97-110): a moved user scroll marks the activity
      # timestamp and arms a one-shot hide timer on the reactor; a re-mark
      # bumps the epoch so the stale timer no-ops (pi clearTimeout +
      # re-set). The timer clears the timestamp and requests exactly one
      # redraw — the hide frame (kernel.request_draw). Movement already
      # implies overflow (a fitting view's max_offset is 0 — nothing can
      # move), matching pi's contentHeight > viewportHeight guard.
      def mark_scrollbar_activity
        @scrollbar_activity_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        epoch = (@scrollbar_timer_epoch += 1)
        @kernel.async do
          sleep(scrollbar_hide_delay_ms / 1000.0)
          next if @scrollbar_timer_epoch != epoch

          @scrollbar_activity_at = nil
          @kernel.request_draw
        end
      end

      def scrollbar_hide_delay_ms
        @scrollbar_hide_delay_ms || SCROLLBAR_HIDE_DELAY_MS
      end

      # The transcript area's row budget — the page size and the mouse
      # mapping's viewport bound (pi chat-viewport geometry, shared with
      # {build_widget}): the viewport minus the dock — spacer 1 + editor +
      # footer (pi chat-viewport.ts:22-45, the widgets-above default
      # Spacer(1); AC2).
      def transcript_area_rows(height = nil)
        unless height
          area = @session.viewport_area
          height = area ? area.height : 24
        end
        [height - editor_area_rows(height) - FOOTER_ROWS - dock_spacer_rows(height), 1].max
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
        # pi clamps to the scrollview box — full width for "auto" (the
        # rail overlays the last column, no reserved gutter to exclude;
        # scroll-view.ts:80-82 getContentWidth).
        Point.new(row, x.clamp(0, viewport_width - 1))
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
        return [@picker.widget_rows + 2, height - 1].min if @picker # + borders

        [MIN_EDITOR_ROWS + @autocomplete.rows, height - 1].min
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
        transcript_rows = transcript_area_rows(height)
        spacer_rows = dock_spacer_rows(height)
        TUI.layout(
          children: [
            transcript_widget(transcript_rows),
            dock_spacer_widget,
            @picker ? @picker.widget(viewport_width) : editor_widget,
            footer_widget,
          ],
          constraints: [
            TUI.constraint_min(transcript_rows),
            TUI.constraint_length(spacer_rows),
            TUI.constraint_length(editor_rows),
            TUI.constraint_length(FOOTER_ROWS),
          ]
        )
      end

      # The dock spacer's rendered rows (pi widgetsAbove shrink 1, minSize 0
      # — chat-viewport.ts:29): one blank dock row when the screen affords
      # it; under pressure (a cramped screen whose editor area grew — the
      # suggestion list) it is the row that yields, keeping the
      # transcript's min 1 and the editor's full height.
      def dock_spacer_rows(height)
        [[height - editor_area_rows(height) - FOOTER_ROWS - 1, 0].max, DOCK_SPACER_ROWS].min
      end

      # The dock's widgets-above default (pi interactive-mode.ts:966-968
      # renderWidgetContainer spacerWhenEmpty: true — a Spacer(1) when no
      # extension widgets exist): a blank row between the transcript and
      # the editor (AC2).
      def dock_spacer_widget
        TUI.paragraph(text: [Panel.blank_line], wrap: false)
      end

      # The transcript area: the scroll buffer's viewport — pi ScrollView
      # follow-end semantics (scroll-view.ts:127-135): while following, the
      # visible tail tracks the content end; a scrolled-up offset stays put
      # as new output arrives; any landing at the end re-follows
      # (followingEnd = followEnd && next === maxScrollTop). The follow-end
      # adjustment NEVER marks scrollbar activity (pi updateLayout :180-192
      # — only the user-scroll seams mark). Content wraps the FULL width
      # for "auto" (scroll-view.ts:80-82 getContentWidth — only "always"
      # reserves a column); the rail overlays the last column while fresh
      # and the settled screen shows none (AC2).
      def transcript_widget(rows)
        width = viewport_width
        lines = display_lines
        max_offset = [lines.size - rows, 0].max
        @scroll_offset = @follow ? max_offset : @scroll_offset.clamp(0, max_offset)
        @follow = true if @scroll_offset == max_offset
        # pi updateLayout force-hide (scroll-view.ts:200): content fits →
        # the transient rail hides immediately.
        @scrollbar_activity_at = nil if lines.size <= rows
        window = (lines[@scroll_offset, rows] || []).map.with_index do |line, i|
          highlight_row(line, @scroll_offset + i)
        end
        return TUI.paragraph(text: window, wrap: false) unless scrollbar_visible?(lines, rows)

        glyphs = scrollbar_glyphs(lines.size, rows)
        TUI.paragraph(text: window.map.with_index { |line, i| overlay_rail_cell(line, glyphs[i], width) }, wrap: false)
      end

      # pi scroll-view.ts isScrollbarVisible (:74-78): the auto rail paints
      # only while the content overflows AND scroll activity is fresh
      # (transientScrollbarVisible, younger than scrollbarHideDelayMs) — a
      # settled screen never shows it (AC2).
      def scrollbar_visible?(lines, rows)
        stamp = @scrollbar_activity_at
        return false if stamp.nil? || lines.size <= rows

        Process.clock_gettime(Process::CLOCK_MONOTONIC) - stamp < scrollbar_hide_delay_ms / 1000.0
      end

      # One rail row (pi paintScrollbar layout.ts:307-330 via
      # replaceScrollbarCell): the glyph REPLACES the last column's cell —
      # content clips at width−1, plain padding spaces carry it to the
      # rail column, the glyph keeps its theme fg (grafted from
      # {scrollbar_glyphs}' own span — scrollbarTrack/scrollbarThumb).
      # pi's hover-driven active thumb `█` (setScrollbarActive,
      # tui-alt-screen.ts:1057-1065) has no port seam and is unreachable
      # in the rig — cut, itemized; the at-rest `┃` is the reachable
      # subset.
      def overlay_rail_cell(line, glyph, width)
        head = Text.clip_spans(line.spans, width - 1)
        pad = width - 1 - head.sum { |span| TUI.text_width(span.content) }
        spans = pad.positive? ? [*head, TUI.span(" " * pad)] : head
        TUI.line([*spans, glyph.spans.first])
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
        content = [TUI.line(Text.clip_spans(@editor.input_spans, inner))] + @autocomplete.lines(inner)
        TUI.block(
          title: status_title,
          borders: [:top, :bottom],
          # pi updateEditorBorderColor (interactive-mode.ts:4514-4522):
          # the border follows the input — bash mode (a leading "!")
          # renders the bashMode token; otherwise the session's thinking
          # level (getThinkingBorderColor — {editor_border_color}).
          border_style: TUI.style(fg: editor_border_color),
          title_style: TUI.style(fg: Theme[:dim]),
          children: [TUI.paragraph(text: content, wrap: false)]
        )
      end

      # pi getThinkingBorderColor (theme.ts:348) over the session's level
      # || "off" — reasoning-gated like the footer's `model • level`
      # segment (a non-reasoning model carries no level → thinking_off
      # #6c767b, the rig mock's settled border; the owner's reasoning
      # model at level high renders #9776e5). The level is the RUNTIME
      # session level when set (/thinking), else the settings-resolved
      # one (pi session.thinkingLevel over the settings default).
      def editor_border_color
        return Theme[:bashMode] if @editor.bash_mode?

        level = thinking_level if @footer_data&.fetch(:reasoning, nil)
        token = "thinking_#{level || :off}".to_sym
        Theme::TOKENS.key?(token) ? Theme[token] : Theme[:thinking_off]
      end

      # The session's thinking level (pi agent.state.thinkingLevel): nil
      # = not set this session — the settings-resolved default shows.
      def thinking_level
        @thinking_level || @footer_data&.fetch(:thinking_level, nil)
      end

      def status_title
        # pi shows the compaction indicator regardless of the streaming
        # state (a manual /compact runs outside a turn in the port); the
        # toggle status rides the same slot until the next agent event.
        # Direct ivars — this runs inside render_frame's synchronize.
        return " #{@border_status} " if @border_status && !@busy
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
        pwd = Text.format_cwd(data[:cwd] || Dir.pwd)
        pwd = "#{pwd} (#{read_branch(data[:cwd])})" if read_branch(data[:cwd])
        # The pwd span carries the dim token ITSELF (pi footer.ts:282 —
        # theme.fg("dim", pwd)); TUI.line's array form ignores the line
        # fg, so the line-level fg: was silently dropping the color (the
        # default-fg pwd/branch defect).
        TUI.paragraph(text: [
          TUI.line(Text.clip_spans([TUI.span(pwd, fg: Theme[:dim])], width)),
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
        parts << "↑#{Text.format_tokens(totals[:input])}" if totals[:input].positive?
        parts << "↓#{Text.format_tokens(totals[:output])}" if totals[:output].positive?
        parts << "R#{Text.format_tokens(totals[:cache_read])}" if totals[:cache_read].positive?
        parts << "W#{Text.format_tokens(totals[:cache_write])}" if totals[:cache_write].positive?
        parts << "CH#{format("%.1f%%", cache_hit_rate)}" if cache_hit_rate

        # The model segment (pi footer.ts:233-244): +model • <level>+
        # when reasoning-capable — level "off" renders the spelled-out
        # "thinking off" (pi's literal). The provider prefix is pi's
        # >1-available-provider gate (:246-258) — the port resolves one
        # static provider, so it NEVER renders (the owner's live
        # "(openai) " finding). The level is the runtime session level
        # (/thinking), else the settings-resolved one.
        model = data[:model] || "no-model"
        right = if data[:reasoning]
          thinking_level == "off" ? "#{model} • thinking off" : "#{model} • #{thinking_level}"
        else
          model
        end
        left = parts.map { |part| TUI.span("#{part} ", fg: Theme[:dim]) }
        left << TUI.span(context_segment(data), fg: context_fg)
        pad = width - left.sum { |span| TUI.text_width(span.content) } - TUI.text_width(right)
        spans = if pad >= 2
          left + [TUI.span(" " * pad + right, fg: Theme[:dim])]
        else
          # Too wide: the stats clip (with their colors) and the model keeps
          # a two-cell margin (pi truncates statsLeft with "...").
          Text.clip_spans(left, [width - TUI.text_width(right) - 2, 0].max) + [TUI.span("… #{right}", fg: Theme[:dim])]
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
        return "?/#{Text.format_tokens(window)}#{auto}" if used.nil?

        "#{(used * 100.0 / window).round(1)}%/#{Text.format_tokens(window)}#{auto}"
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
      #
      # The region renders the assistant message's SETTLED shape from the
      # first delta (pi updateContent runs while streaming — the leading
      # Spacer(1) :103-105 and the between-runs Spacer :172-174 are
      # component children, not post-hoc inserts): leading blank, the
      # reasoning rows, a blank when content follows the reasoning, the
      # content. The blank appearing only at completion was the 2nd-pass
      # shift (the row insert moved streaming content down a line).
      def live_lines(width)
        return [] if @live.empty? && @reasoning.empty?

        lines = [Panel.blank_line]
        lines.concat(reasoning_lines(@reasoning, width)) unless @reasoning.empty?
        lines << Panel.blank_line if !@reasoning.empty? && !@live.empty?
        lines.concat(markdown_lines(@live, width)) unless @live.empty?
        lines
      end

      # Completed lines move into the transcript buffer (pi: completed
      # content into scrollback). Entries are final display Lines — or a
      # {MarkedRegion}: an expandable block, whose transcript range is
      # recorded at drain time so the ctrl+o toggle can rebuild it in
      # place (pi setToolsExpanded's child sweep). The inline
      # insert_before path is retired from the interactive surface — the
      # buffer is drawn wholesale every frame.
      def flush_scrollback
        until @scrollback.empty?
          item = @scrollback.pop
          if item.is_a?(MarkedRegion)
            @expandable_blocks << {start: @transcript.size, size: item.rows.length,
                                   builder: item.builder}
            @transcript.concat(item.rows)
          else
            @transcript.concat(item)
          end
        end
      end

      # /thinking's seam (pi selectThinkingLevel :5165-5177): the session
      # level changes, the border reports "Thinking level: <level>"
      # (pi showStatus) until the next agent event clears it. The level
      # drives the footer's `model • <level>` segment and the editor
      # border color ({editor_border_color}) — pi footer.invalidate +
      # updateEditorBorderColor. (Public — the dispatcher's callable.)
      def set_thinking_level(level)
        @mutex.synchronize do
          @thinking_level = level
          @border_status = "Thinking level: #{level}"
        end
        @kernel.request_draw
      end

      # pi cycleThinkingLevel (agent-session.ts:2641-2653): the next
      # level in THINKING_LEVEL_OPTIONS order, wrapping — the port's
      # analog for the bare /thinking command (pi opens its selector
      # there; the port has no selector UI, the cycle is the keybinding's
      # behavior — itemized deviation). (Public — the dispatcher's
      # callable.)
      def cycle_thinking_level
        current = @mutex.synchronize { thinking_level || Settings::DEFAULTS.fetch("thinkingLevel") }
        levels = Settings::THINKING_LEVELS
        next_level = levels[(levels.index(current) + 1) % levels.size]
        set_thinking_level(next_level)
        next_level
      end

      public :set_thinking_level, :cycle_thinking_level

      # app.tools.expand (pi setToolsExpanded :6810-6826): the GLOBAL
      # toggle — every expandable block rebuilds collapsed↔expanded in
      # place; the border status reports (pi showStatus). Cuts, itemized:
      # the header's startup-help flip (the expanded header's full hint
      # list + loaded-resources sections are unported) — the block sweep
      # is the feature.
      def set_tool_output_expanded(expanded)
        return if expanded == @tool_output_expanded

        @tool_output_expanded = expanded
        @expandable_blocks.each do |registered|
          rows = registered[:builder].call(expanded)
          @transcript[registered[:start], registered[:size]] = rows
          registered[:size] = rows.length
        end
        @border_status = "Tool output: #{expanded ? "expanded" : "collapsed"}"
        @kernel.request_draw
      end
    end
  end
end
