# frozen_string_literal: true

require_relative "text"
require_relative "motd"
require_relative "footer"
require_relative "user_bash"
require_relative "panel"
require_relative "bash_block"
require_relative "file_blocks"
require_relative "tool_block"
require_relative "editor"
require_relative "autocomplete"
require_relative "picker"
require_relative "selection"
require_relative "viewport"
require_relative "slash_source"
require_relative "transcript"

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

      # pi status-indicator.ts:85-95 — the compaction-start border labels,
      # minus the cancel hint (deviation: ctrl+c aborts the whole run in the
      # port, not just the compaction — BRIEF §5.1, itemized).
      COMPACTION_LABELS = {
        manual: "Compacting context...",
        threshold: "Auto-compacting...",
        overflow: "Context overflow detected, Auto-compacting..."
      }.freeze

      # pi's outputPad (interactive-mode.ts:516, default 1): one leading
      # space on every content row of the chat surface — the header's Text
      # paddingX (interactive-mode.ts:1060-1063), the echo's and the
      # assistant's Markdown paddingX (user-message.ts:23,

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
      def initialize(session:, kernel:, footer_data: nil, branch_reader: Footer::DEFAULT_BRANCH_READER, autocomplete: nil,
        motd: true, identity: Identity::DEFAULT, settings_root: Agent::Session.default_root,
        prompts: [], extensions: [])
        @session = session
        @kernel = kernel
        @footer_data = footer_data
        @agent = nil
        @mutex = Mutex.new
        # The input-line editor (pi's Input — the editor state and
        # operations) and its suggestion list over the injected completion
        # source (pi editor.ts autocompleteState/autocompleteList +
        # SelectList). Both unsynchronized — see the class comment.
        @editor = Editor.new
        @autocomplete = Autocomplete.new(source: autocomplete)
        # The viewport state machines (I23 wave 3): the transcript scroll
        # state — the offset over the buffer, the follow-end pin and the
        # auto scrollbar's transient rail (pi ScrollView) — and the mouse
        # selection state (item 10, pi tui-alt-screen.ts:83-107). Both
        # unsynchronized — see the class comments; the selection reads
        # this surface's live transcript through its content seam.
        @viewport = Viewport.new
        @selection_state = Selection.new(line_reader: ->(row) { plain_content_line(row) })
        # The running compaction's reason (the border-status label's key).
        @compaction_reason = nil
        # The /resume session picker (item 2, pi SessionSelectorComponent
        # reduced): nil = closed; open it holds the {Picker} over the
        # launcher-built [{path:, label:}] list (newest first).
        @picker = nil
        # The transcript/scrollback assembly (I25 wave 5): the scrollback
        # queue, the flat transcript buffer, the ctrl+o expandable
        # registry (pi toolOutputExpanded/setToolsExpanded —
        # interactive-mode.ts:6810-6826) and the resume replay, extracted
        # stateful (the wave-2/4 idiom). Seams: the width reader (the
        # enqueue family wraps to the viewport width) and the late-bound
        # completion sinks — the editor-history record on replay and the
        # footer usage reseed. Unsynchronized: this surface owns the
        # mutex, and the component is called from exactly the fibers that
        # touched the state at base.
        @transcript_state = Transcript.new(
          width_reader: -> { viewport_width },
          history_sink: ->(text) { @editor.add_to_history(text) },
          reseed_sink: ->(message) { @footer.reseed_usage(message) }
        )
        @border_status = nil
        # The !-prefix bash execution state machine (backlog C, pi
        # handleBashCommand): the coordinator routes into it — submit's
        # parse, escape's cancel, agent_end's deferred-record flush. The
        # last ctrl+c timestamp stays here (pi's lastSigintTime — the
        # double-press exit window, handleCtrlC :6840).
        @user_bash = UserBash.new(
          kernel: kernel,
          busy_reader: -> { busy? },
          block_sink: ->(command, fields, excluded) { @transcript_state.enqueue_user_bash_block(command, **fields, excluded:) },
          record_sink: ->(message) { @agent&.record_bash_execution(message) },
          line_sink: ->(text, fg:) { @transcript_state.enqueue_scrollback(text, fg:) }
        )
        @last_ctrl_c = nil
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
        # The footer state machine (I24 wave 4): the branch cache and the
        # usage accounting (pi footer-data-provider.ts + footer.ts), fed
        # the launcher facts per frame from {@footer_data}.
        @footer = Footer.new(branch_reader:)
        @settings_root = settings_root
        @identity = identity
        @prompts = prompts
        @extensions = extensions
        # The runtime thinking level (nil = the settings default shows;
        # /thinking sets it — pi agent.state.thinkingLevel).
        @thinking_level = nil
        @motd_pending = motd # rendered on the first frame, once wired
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
      # instead of sleeping real seconds. The state lives on the viewport;
      # the seam stays on the Chat surface (the readbacks' shape).
      def scrollbar_hide_delay_ms=(ms)
        @viewport.hide_delay_ms = ms
      end

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
          @transcript_state.lines.map do |line|
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
        @mutex.synchronize { @viewport.offset }
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
          @transcript_state.flush_scrollback
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
            @footer.invalidate_branch # per-turn branch invalidation (pi's provider cache, reduced)
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
              @footer.accumulate_usage(message)
              handled = complete(message.content)
              # The reasoning buffer threads in as data and clears after
              # the render (the flush lived inside enqueue_message at
              # base — same row order, buffer reset with the completion).
              @transcript_state.enqueue_message(handled, reasoning: @reasoning)
              @reasoning = +""
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
            @transcript_state.enqueue_tool_block(call.name, call.arguments, event[:result], event[:duration])
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
            @footer.mark_usage_stale
            # the compaction line is a region too (pi :3903-3904)
            @transcript_state.enqueue_region([Panel.blank_line])
            @transcript_state.enqueue_scrollback(
              "✻ compacted (#{event[:reason]}, #{event[:tokens_before]} tokens)", fg: Theme[:dim]
            )
          when :agent_end
            @busy = false
            @compaction_reason = nil
            # The deferred bashExecution records flush at agent end (pi's
            # _pendingBashMessages flush) — never mid-tool-sequence.
            @user_bash.flush_pending
            if event[:interrupted] == true
              handled = "interrupted"
              @transcript_state.enqueue_scrollback(handled, fg: Theme[:warning])
            elsif event[:error]
              handled = "error: #{event[:error].message}"
              @transcript_state.enqueue_scrollback(handled, fg: Theme[:error])
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
          @transcript_state.enqueue_scrollback("✓ New session started", fg: Theme[:accent])
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
          @transcript_state.replay_entries(entries)
          compactions = entries.count { |entry| entry.is_a?(Hash) && entry["type"] == "compaction" }
          if compactions.positive?
            times = compactions == 1 ? "1 time" : "#{compactions} times"
            @transcript_state.enqueue_scrollback("Session compacted #{times}", fg: Theme[:dim])
          end
          @transcript_state.enqueue_scrollback("Resumed session", fg: Theme[:accent])
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
        @mutex.synchronize { @transcript_state.enqueue_scrollback(text, fg: Theme[:muted]) }
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
        lines.concat(@identity == Identity::PI ? Motd.pi_header_lines : Motd.tart_header_lines(viewport_width))
        # The loaded-resource sections ride BOTH identities (pi
        # showLoadedResources renders for any theme/identity — the owner's
        # missing [Context]/[Skills]/[Prompts]/[Extensions] block; each
        # section opens with its blank, the enqueue's trailing blank is
        # the header container's closing Spacer). Wrapped at the content
        # width, as the sections always have. The section inputs gather
        # from this surface's constructor state (Motd is stateless —
        # everything threads).
        Motd.sections(viewport_width - Panel::OUTPUT_PAD.length * 2,
          context: Motd.context_sources(@settings_root, @footer_data&.fetch(:cwd, nil) || Dir.pwd),
          skills: Motd.motd_skill_names(@autocomplete.source),
          prompts: @prompts, extensions: @extensions).each do |header, rows|
          lines << Panel.blank_line << TUI.line("#{Panel::OUTPUT_PAD}#{header}", fg: Theme[:md_heading])
          lines.concat(rows)
        end
        lines << Panel.blank_line
        @transcript_state.enqueue_region(lines)
      end

      # The /new + resume shared reset: the buffer and stream state drop
      # (pi renderCurrentSessionState's container clears, :2210-2216; the
      # host drops the selection with the transcript, :4096). The
      # transcript state resets through its component (the I24
      # {@footer.reset_usage} precedent).
      def clear_transcript
        @transcript_state.reset
        @viewport.reset
        @selection_state.reset
        @live = +""
        @reasoning = +""
        # pi's footer stats re-derive from the fresh (empty) session.
        @footer.reset_usage
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
          elsif @user_bash.running?
            @user_bash.cancel
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
          ctrl ? set_tool_output_expanded(!@transcript_state.tool_output_expanded) : @editor.insert_printable(event)
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
        when "page_up"
          unless @autocomplete.suggestions
            mark_scrollbar_activity(@viewport.scroll_page(-1, display_lines.size, transcript_area_rows))
          end
        when "page_down"
          unless @autocomplete.suggestions
            mark_scrollbar_activity(@viewport.scroll_page(1, display_lines.size, transcript_area_rows))
          end
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
        @footer.invalidate_branch # per-turn branch invalidation
        if @commands && text.start_with?("/")
          text = @commands.expand_skill(text)
          return if !busy? && @commands.dispatch(text)
        end
        # The !-prefix bash intercepts BEFORE the user echo (pi handleSubmit
        # :3347-3360 — the BashExecutionComponent is the display, no user
        # echo; the bare prefix falls through as plain text).
        parsed = UserBash.parse(text)
        return @user_bash.run(*parsed) if parsed

        @transcript_state.enqueue_user_submission(text)
        if busy?
          @agent.push_message(text) # steering: consumed at the next turn boundary
        else
          @kernel.async { @agent.run(text) }
        end
      end

      # The completed thinking block (pi assistant-message.ts:99-175 order —
      # thinking before the content): the live reasoning buffer flushed as
      # dim italic transcript rows, then cleared. Retained on the
      # coordinator for the live region; the completion path's flush
      # happens inside {Transcript#enqueue_message} (the reasoning text
      # threads in at the :message_end event — I25).
      def flush_reasoning
        text = @reasoning
        @reasoning = +""
        return if text.empty?

        @transcript_state.enqueue_region(Transcript.reasoning_lines(text, viewport_width))
      end

      # --- transcript scroll state (pi scroll-view.ts follow-end) ---

      # The scrollbar hide timer's kernel arm (pi scroll-view.ts:97-110
      # markScrollbarActivity — the timer lives on the host reactor; the
      # port's host is the kernel). The viewport owns the stamp+epoch
      # state machine ({Viewport#mark}, whose epoch the user-scroll seams
      # thread back): this arm sleeps the hide delay, no-ops on a stale
      # epoch (pi clearTimeout + re-set) and hides the rail + requests
      # exactly one redraw — the hide frame ({kernel.request_draw}).
      # Movement already implies overflow (a fitting view's max_offset is
      # 0 — nothing can move), matching pi's contentHeight >
      # viewportHeight guard.
      def mark_scrollbar_activity(epoch)
        return unless epoch

        @kernel.async do
          sleep(@viewport.hide_delay_ms / 1000.0)
          next if @viewport.stale?(epoch)

          @viewport.hide_scrollbar
          @kernel.request_draw
        end
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
      # The pointer's buffer point is composed here ({content_point} —
      # viewport state + geometry) and threaded into the selection.
      def handle_mouse(event)
        return wheel(event) if event.scroll?
        return unless event.left?

        case event.kind
        when "down" then @selection_state.press(content_point(event.y, event.x))
        when "drag" then @selection_state.drag(content_point(event.y, event.x))
        when "up" then @selection_state.release(content_point(event.y, event.x))
        end
      end

      # One wheel event: the lines-per-event math and the wheel constants
      # live on the viewport ({Viewport#wheel} — pi tui-alt-screen.ts wheel
      # → scrollView.scrollBy); this is the routing + the hide timer's
      # arm.
      def wheel(event)
        mark_scrollbar_activity(@viewport.wheel(event, display_lines.size, transcript_area_rows))
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

        row = (@viewport.offset + y).clamp(0, lines.size - 1)
        # pi clamps to the scrollview box — full width for "auto" (the
        # rail overlays the last column, no reserved gutter to exclude;
        # scroll-view.ts:80-82 getContentWidth).
        Selection::Point.new(row, x.clamp(0, viewport_width - 1))
      end

      # The buffer row's plain text (the display Line's span contents) —
      # the selection's content seam (the {Selection} machine reads it
      # through its injected reader).
      def plain_content_line(row)
        display_lines[row].spans.map(&:content).join
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
            @footer.widget(footer_data, viewport_width),
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
      # and the settled screen shows none (AC2). The offset maintenance
      # and the rail paint are Viewport ops; the highlight is the
      # selection's render query ({Selection#highlight_row}).
      def transcript_widget(rows)
        width = viewport_width
        lines = display_lines
        window = @viewport.window(lines, rows).map.with_index do |line, i|
          @selection_state.highlight_row(line, @viewport.offset + i)
        end
        return TUI.paragraph(text: window, wrap: false) unless @viewport.scrollbar_visible?(lines, rows)

        glyphs = @viewport.scrollbar_glyphs(lines.size, rows)
        TUI.paragraph(text: window.map.with_index { |line, i| @viewport.overlay_rail_cell(line, glyphs[i], width) }, wrap: false)
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

      # The footer's per-frame data view: the launcher facts with the
      # runtime thinking level overlaid when set ({thinking_level} — pi
      # footer.ts:226-244 reads the live session level over the
      # settings-resolved one). nil footer_data renders from what the
      # surface knows alone, as at base.
      def footer_data
        data = @footer_data || {}
        @thinking_level ? data.merge(thinking_level: @thinking_level) : data
      end

      # The transcript buffer's display lines — completed content plus the
      # live region. The transcript area windows this ({transcript_widget})
      # and the mouse machinery addresses it (selection points are buffer
      # rows).
      def display_lines
        @transcript_state.lines + live_lines(viewport_width)
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
        lines.concat(Transcript.reasoning_lines(@reasoning, width)) unless @reasoning.empty?
        lines << Panel.blank_line if !@reasoning.empty? && !@live.empty?
        lines.concat(Transcript.markdown_lines(@live, width)) unless @live.empty?
        lines
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
      # place; the border status reports (pi showStatus). The registry
      # sweep is the component's state half; the report + draw stay here
      # (the frozen public op — I25 extraction). Cuts, itemized: the
      # header's startup-help flip (the expanded header's full hint
      # list + loaded-resources sections are unported) — the block sweep
      # is the feature.
      def set_tool_output_expanded(expanded)
        return unless @transcript_state.set_tool_output_expanded(expanded)

        @border_status = "Tool output: #{expanded ? "expanded" : "collapsed"}"
        @kernel.request_draw
      end
    end
  end
end
