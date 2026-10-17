# frozen_string_literal: true

require_relative "text"
require_relative "motd"
require_relative "footer"
require_relative "user_bash"
require_relative "panel"
require_relative "bash_block"
require_relative "file_blocks"
require_relative "tool_block"
require_relative "edit_block"
require_relative "editor"
require_relative "kill_ring"
require_relative "autocomplete"
require_relative "picker"
require_relative "model_menu"
require_relative "selection"
require_relative "viewport"
require_relative "slash_source"
require_relative "transcript"
require_relative "../models"
require_relative "../shapes/model"
require_relative "../shapes/session"

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

      # pi loader.ts:17 DEFAULT_INTERVAL_MS — the spinner's frame dwell: the
      # glyph advances on TIME, never on renders ({spinner_glyph} derives
      # the frame from the monotonic clock at each rendered frame). Since
      # I58 this interval also PACES the renders: the busy spinner tick
      # ({arm_spinner_tick}) requests one draw every dwell — pi's own
      # cadence (the Loader interval advances the frame, then
      # updateDisplay calls requestRender, loader.ts:82-99).
      SPINNER_INTERVAL_SECONDS = 0.08

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

      # pi's alt-screen flash dwell (alt-screen-flash.ts:13
      # DEFAULT_DURATION_MS = 1000) — the copy confirmation's opacity
      # window. A test seam shortens it ({@flash_seconds}).
      FLASH_SECONDS = 1.0

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
      # @param skills [Array<Skills::Skill>] the loaded skill structs —
      #   the MOTD's [Skills] section (file_path feeds the expanded scope
      #   groups; the SlashSource name-only view stays the completion
      #   catalog).
      # @param context_files [Array<{path:, content:}>] the discovered
      #   context files (Agent::ContextFiles.load) — the MOTD's [Context]
      #   input ahead of the config sources (pi's contextFiles = the
      #   system-prompt sources + the agents files, :1843-1853).
      # @param extensions [Array<String>] the loaded MCP server names —
      #   the MOTD's [Extensions] section (the port's loaded
      #   external-resource analog; empty renders none).
      # @param settings_root [String] the user config dir the MOTD's
      #   [Context] section reports (injectable so tests never touch
      #   ~/.tart).
      # @param models [Models::Config, nil] the models.json catalog (the
      #   /model selector's entries, I27); nil (tests) degenerates the
      #   catalog to the boot model (see {model_menu_entries}).
      # @param clock [Proc] +call+ → Float monotonic seconds — the ONLY
      #   time source for the spinner ({spinner_glyph}; the viewport.rb
      #   monotonic precedent, the UserBash constructor-seam idiom).
      #   Tests pin fake time with zero sleeps.
      def initialize(session:, kernel:, footer_data: nil, branch_reader: Footer::DEFAULT_BRANCH_READER, autocomplete: nil,
        motd: true, identity: Identity::DEFAULT, settings_root: Agent::Session.default_root,
        prompts: [], skills: [], context_files: [], extensions: [], models: nil,
        clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        @session = session
        @kernel = kernel
        @footer_data = footer_data
        @agent = nil
        @mutex = Mutex.new
        # The multi-line input editor (pi's Editor — the visual-line state
        # and operations) and its suggestion list over the injected
        # completion source (pi editor.ts autocompleteState/
        # autocompleteList + SelectList). Both unsynchronized — see the
        # class comment. The rows_reader seam shares the screen height
        # with the render window and the editor's page size (pi reads
        # terminal.rows at both sites).
        @editor = Editor.new(rows_reader: -> { screen_height })
        @autocomplete = Autocomplete.new(source: autocomplete)
        # The viewport state machines (I23 wave 3): the transcript scroll
        # state — the offset over the buffer, the follow-end pin and the
        # auto scrollbar's transient rail (pi ScrollView) — and the mouse
        # selection state (item 10, pi tui-alt-screen.ts:83-107). Both
        # unsynchronized — see the class comments; the selection reads
        # this surface's live transcript through its content seam.
        @viewport = Viewport.new
        @selection_state = Selection.new(line_reader: ->(row) { selection_line(row) })
        # The running compaction's reason (the border-status label's key).
        @compaction_reason = nil
        # Whether the boot/new header block is on screen (the compaction
        # rebuild re-enqueues it — pi's headerContainer survives the
        # compaction_end chatContainer clear). Since I33 the header rides
        # the expandable registry ({enqueue_motd_header} — the flip
        # rebuilds it at the CURRENT toggle state). false = no header on
        # screen (motd: false, or the /resume screen) — the rebuild
        # restores none.
        @header_enqueued = false
        # The tart art pick (I56 — the ladder at enqueue/re-pick time; nil
        # until the first header enqueue) and the resize latch (the event
        # dims driving the ONE post-SIGWINCH compose; {render_frame}
        # clears it after {build_widget}).
        @logo_lines = nil
        @resize_dims = nil
        # The /resume session picker (item 2, pi SessionSelectorComponent
        # reduced): nil = closed; open it holds the {Picker} over the
        # launcher-built [{path:, label:}] list (newest first).
        @picker = nil
        # The selector menus (I27, pi showSelector): nil = closed; open
        # it holds the {ModelMenu} — the /thinking level menu or the
        # /model menu — mounted in place of the editor. The runtime
        # model switch ({@runtime_model}, the overlay into the footer
        # view) rides with it.
        @menu = nil
        @runtime_model = nil
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
        # The !-prefix bash execution state machine (backlog C, pi
        # handleBashCommand): the coordinator routes into it — submit's
        # parse, escape's cancel, agent_end's deferred-record flush. The
        # last ctrl+c timestamp stays here (pi's lastSigintTime — the
        # double-press exit window, handleCtrlC :6840). The I38 streaming
        # sinks wire the running block's render state below (pi's
        # BashExecutionComponent lives from before execution,
        # :7000-7062): start before the task spawns, each chunk as the
        # kernel task's drainer delivers it, and the explicit clear at
        # every terminal path.
        @user_bash = UserBash.new(
          kernel: kernel,
          busy_reader: -> { busy? },
          block_sink: ->(command, fields, excluded) { @transcript_state.enqueue_user_bash_block(command, **fields, excluded:) },
          record_sink: ->(message) { @agent&.record_bash_execution(message) },
          line_sink: ->(text, fg:) { @transcript_state.enqueue_scrollback(text, fg:) },
          stream_start_sink: ->(command, excluded) { start_user_bash_stream(command, excluded) },
          stream_chunk_sink: ->(text) { append_user_bash_stream(text) },
          stream_end_sink: -> { end_user_bash_stream }
        )
        @last_ctrl_c = nil
        # The copy confirmation's flash ({flash} — the message token) and
        # its dwell; and the last assistant message's text (pi
        # getLastAssistantText — ctrl+x's fallback copy source), tracked
        # at the assistant completions.
        @flash = nil
        @flash_seconds = FLASH_SECONDS
        @last_assistant_text = nil
        @live = +""
        # The in-flight message's reasoning (pi's live thinking block): the
        # joined chunk.thinking deltas, rendered dim while it grows and
        # flushed as the completed thinking block at :message_end (replay
        # normalization happens at the request seam — Agent::Loop's
        # before_request hook; the message itself keeps its thinking).
        @reasoning = +""
        # The streaming region's conversion cache (I58 D2):
        # {[width, live bytes, reasoning bytes] => rows} from
        # {assistant_live_lines} — the per-frame whole-text markdown/
        # reasoning re-conversion was 95-97% of heavy-frame render CPU
        # (Grounds §2). Cleared at every @live/@reasoning RESET site:
        # within one message generation deltas only append (the bytesize
        # key is monotone), so the reset clearing is what makes size-keyed
        # invalidation exact — without it, a later message colliding on a
        # cached size at the same width would serve the previous message's
        # rows (AC2's reset-cycle exactness pins this).
        @live_region_cache = nil
        @busy = false
        @tool = nil
        # The failure row's double-render guard (I60 D3): set by the
        # :message_end error-row arm, cleared at :agent_start — the
        # agent_end error arm skips its scrollback line when the failure's
        # own row already rendered.
        @error_row_rendered = false
        # The queued-message surface mirror (I54 — pi's _steeringMessages/
        # _followUpMessages, agent-session.ts:2238-2263): appended by the
        # busy submit/follow-up paths, rendered between the dock spacer and
        # the editor (§pending_widget), removed by delivery (first-index
        # text match at :message_start user role — pi :1122-1134) and by
        # alt+up's dequeue.
        @queued = {steer: [], follow_up: []}
        # The abort-first busy command (I54 — pi session.compact/newSession
        # abort first, agent-session.ts:2764-2765 + runtime :167-178): the
        # surface arms kernel.interrupt_work! and re-dispatches the stored
        # command through the idle path at :agent_end.
        @pending_after_interrupt = nil
        # The RUNNING user-bash block's render state (I38 — pi's
        # BashExecutionComponent): the command/excluded, the accumulated
        # chunk text (the appendOutput join IS this string buffer), and
        # the bash loader's OWN time anchor (pi constructs one Loader per
        # component — independent of the border status's anchor). Mutated
        # only by the three sinks, under the surface mutex; nil = no run
        # in flight.
        @user_bash_stream = nil
        # The spinner's time anchor (pi's Loader frame clock): the glyph is
        # derived from the elapsed monotonic seconds at render
        # ({spinner_glyph}), never from the render count. nil until the
        # first status-kind start re-anchors it ({restart_spinner!}).
        @clock = clock
        @spinner_started_at = nil
        # The footer state machine (I24 wave 4): the branch cache and the
        # usage accounting (pi footer-data-provider.ts + footer.ts), fed
        # the launcher facts per frame from {@footer_data}.
        @footer = Footer.new(branch_reader:)
        @settings_root = settings_root
        @models = models
        @identity = identity
        @prompts = prompts
        @skills = skills
        @context_files = context_files
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

      # The flash confirmation's dwell in seconds ({FLASH_SECONDS}) —
      # the same test-seam shape: tests inject 0 instead of sleeping
      # real seconds.
      attr_writer :flash_seconds

      # @return [Boolean] whether an agent run is in flight.
      def busy?
        @mutex.synchronize { @busy }
      end

      # @return [Boolean] whether a user-bash run's live rows are on
      #   screen (the spinner tick's second arm — @busy stays false: a
      #   bash run never lights the border's Working status).
      def user_bash_streaming?
        @mutex.synchronize { !@user_bash_stream.nil? }
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

      # The open selector menu's readbacks (test seams, the picker
      # readbacks' shape): whether a menu is open and its current
      # selection.
      def menu_open?
        @mutex.synchronize { !@menu.nil? }
      end

      def menu_selection
        @mutex.synchronize { @menu&.selection }
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
          widget = build_widget
          # One-frame latch semantics (I56): the resize event's dims drove
          # THIS compose; the draw's autoresize has refreshed the gem area
          # by the next frame (Grounds §2) — subsequent frames compose
          # from the session area again.
          @resize_dims = nil
        end
        # I58 — pi's render discipline (tui.ts requestRender/scheduleRender):
        # nothing renders at a fixed rate here anymore. State changes —
        # agent events (the sink's tail request_draw), user-bash chunks
        # (the I38 sinks), user input (the kernel's per-event dirty mark),
        # the ~80 ms spinner tick ({arm_spinner_tick}) — each request
        # exactly one paint; with nothing pending the loop blocks on the
        # event queue (the I02 static-loop property). The retired
        # re-arm rendered 60 frames/s where pi renders on request ≈ 22/s
        # on the identical stream (Grounds §2 — the burn).
        widget
      end

      # Kernel event sink (every dispatched event, native or synthetic).
      # Ctrl+C never reaches here — the kernel owns it (interrupt). Mouse
      # events route to the surface's wheel-scroll/selection machinery.
      # I56: resize events latch the event's dims and re-compose — the gem's
      # viewport_area answers the LAST DRAWN frame's area outside draw (ext
      # terminal/query.rs:118-124; Grounds §2), so the first post-SIGWINCH
      # frame must compose from the EVENT's own width/height; the kernel's
      # dirty-mark alone would draw at the stale area with no follow-up.
      def on_event(event, _source = nil)
        return handle_mouse(event) if event.respond_to?(:mouse?) && event.mouse?
        return handle_resize(event) if event.respond_to?(:resize?) && event.resize?

        return unless event.key? || event.paste?

        edit_input(event)
      end

      # The SIGWINCH arm (I56): latch the event dims as the compose-time
      # geometry (one frame — {render_frame} clears the latch after
      # {build_widget}; on a real terminal the draw's autoresize refreshes
      # the gem area by then), re-pick the header art at the new width and
      # rebuild the resize-live header block in place, then request the
      # draw. No header enqueued (motd: false — the /resume screens) → no
      # art re-pick, no rebuild; the latch still sets (the editor reflow
      # works headless too). The predicate form mirrors the mouse arm (the
      # base Event answers every ? predicate via method_missing — the
      # respond_to? guard is what separates the classes).
      def handle_resize(event)
        rebuilt = false
        @mutex.synchronize do
          @resize_dims = [event.width, event.height]
          if @header_enqueued
            @logo_lines = Motd.motd_logo_lines(event.width, wordmark: @identity)
            rebuilt = @transcript_state.rebuild_live_expandables
          end
        end
        @kernel.request_draw if rebuilt
      end

      # Agent event sink (I03 event surface). Runs on the agent fiber.
      def on_agent_event(event)
        handled = nil
        @mutex.synchronize do
          case event[:type]
          when :agent_start
            @busy = true
            # The failure row's double-render guard resets per run (D3 —
            # set by the :message_end error-row arm; the agent_end error
            # arm reads it).
            @error_row_rendered = false
            # pi turn_start creates the working indicator (interactive-mode.ts
            # :3427-3433) — the Loader's frame-0 reset.
            restart_spinner!
            arm_spinner_tick
            @footer.invalidate_branch # per-turn branch invalidation (pi's provider cache, reduced)
          when :message_start
            message = event[:message]
            if message.respond_to?(:role) && message.role == :custom
              # The custom-message arm (I47 — pi message_start case custom,
              # interactive-mode.ts:3498-3502: the component is added at
              # message_start, display-gated). The :message_end custom case
              # needs no arm — the assistant guard below already no-ops it
              # (pi renders the block ONCE).
              @transcript_state.enqueue_custom_block(message.custom_type, message.content) if message.display
            else
              # The queued-message delivery arm (I54 — pi agent-session.ts
              # :1122-1134 + interactive-mode.ts:3503-3507): a user-role
              # message_start whose text matches a mirror's FIRST-index
              # entry removes it and renders the user echo AT DELIVERY (the
              # idle submit's opening message never matches — it already
              # echoed at submit). Runs under the surface mutex (the sink
              # holds it) — no re-synchronize.
              deliver_queued_message(message) if message.respond_to?(:role) && message.role == :user
              @live = +""
              @reasoning = +""
              @live_region_cache = nil # the reset invalidates (I58, §live_region_cache)
            end
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
              # pi getLastAssistantText (agent-session.ts:4347): the last
              # assistant message's trimmed text — ctrl+x's fallback.
              @last_assistant_text = handled&.strip
              # The reasoning buffer threads in as data and clears after
              # the render (the flush lived inside enqueue_message at
              # base — same row order, buffer reset with the completion).
              @transcript_state.enqueue_message(handled, reasoning: @reasoning)
              @reasoning = +""
              if message.respond_to?(:finish_reason) && message.finish_reason == "error"
                # pi assistant-message.ts:184-198 — the failure component's
                # row: Spacer(1), then "Error: <errorMessage>" in error fg
                # (after any partial content), outputPad-led and wrapped.
                # The flag arms the agent_end error arm's skip (pi's
                # agent_end renders no error text — the component owns the
                # row; without the guard the failure would double-render).
                # The respond_to? guard is the footer's usage-read idiom:
                # every real loop event carries the Message reader; reader-
                # less display doubles (render_perf's Msg) stay inert.
                @error_row_rendered = true
                @transcript_state.enqueue_region([Panel.blank_line,
                  *Panel.padded_fg_rows("Error: #{message.error_message}", viewport_width,
                    fg: Theme[:error])])
              end
            end
          when :tool_execution_start
            @tool = event[:tool_call].name
            # The PENDING block's enqueue (I34 — pi renders the running
            # call's block immediately under toolPendingBg, the component
            # added to the chat container at :tool_execution_start,
            # interactive-mode.ts:3611-3621): paints on the next frame
            # while the tool runs; the finalize replaces it in place.
            call = event[:tool_call]
            # I65 D2: the registry keys by the call id (pi pendingTools is
            # a Map keyed by toolCallId, interactive-mode.ts:3611-3621).
            # The reader-guard is the details idiom below — reader-less
            # display doubles (render_perf) stay inert, the id threads
            # nil, and the transcript's id-less arms keep today's shape.
            id = call.respond_to?(:id) ? call.id : nil
            @transcript_state.enqueue_pending_tool_block(id, call.name, call.arguments)
          when :tool_execution_end
            @tool = nil
            call = event[:tool_call]
            # The settle (I34): the pending block replaced IN PLACE with
            # the per-tool block dispatch's rows (pi's per-tool renderers
            # — bash owns the shell shapes, I17 — the frozen
            # :tool_execution_end contract carries `duration:`; write/read
            # their file-tool shapes, I18; edit the diff-display family
            # fed the call's details side channel, I57 — the respond_to?
            # guard keeps the recorded ToolCall-shape doubles without the
            # member inert; the rest the generic ⎿ line).
            # No live pending (the replay path) falls back to the append.
            id = call.respond_to?(:id) ? call.id : nil
            @transcript_state.finalize_tool_block(id, call.name, call.arguments, event[:result], event[:duration],
                                                  details: call.respond_to?(:details) ? call.details : nil)
          when :compaction_start
            # The frozen I12 contract (Agent::Loop#run_compaction, after
            # prepare succeeds): the border shows pi's per-reason label
            # (status-indicator.ts:85-95 minus the cancel hint) until the
            # result (+:compaction+) or the run end clears it.
            @compaction_reason = event[:reason]
            # pi constructs CompactionStatusIndicator (:3681) — a new
            # Loader, frame 0.
            restart_spinner!
          when :compaction
            # pi compaction_end's result arm (interactive-mode.ts:3686-3725):
            # the chat container clears and rebuilds from the post-compaction
            # KEPT entries (the payload's `entries` — the frozen lane
            # contract, the same shape the replay consumes) through the
            # replay machinery, then the panel appends LAST (pi
            # addMessageToChat after renderSessionEntries). The footer
            # INVALIDATES — post-compaction the context numerator is
            # unknown until the next LLM response (the "?") — never /new's
            # usage reset. The border status came from :compaction_start
            # (the frozen I12 contract); its clearing here stays — and
            # re-anchors the spinner (pi clearStatusIndicator :3694 → the
            # next working indicator restarts).
            @compaction_reason = nil
            restart_spinner!
            wipe_transcript
            # The header container survives pi's chatContainer clear
            # (interactive-mode.ts:633-639 — sibling containers; the s7
            # capture: art + help + onboarding ride again, no resource
            # listings). Re-enqueued as the EXPANDABLE block — rebuilt at
            # its CURRENT expansion state (pi's live header rides the
            # toggle).
            enqueue_motd_header if @header_enqueued
            entries = event[:entries].is_a?(Array) ? event[:entries] : []
            @transcript_state.replay_entries(entries, update_footer: false, populate_history: false)
            @transcript_state.enqueue_compaction_panel(event[:summary], event[:tokens_before])
            @footer.mark_usage_stale
          when :agent_end
            @busy = false
            @compaction_reason = nil
            # The tick cancels with the run (I58) — unless a user-bash
            # stream keeps it alive. Direct ivar read: this arm HOLDS the
            # surface mutex (user_bash_streaming? would re-synchronize).
            cancel_spinner_tick unless @user_bash_stream
            # The deferred bashExecution records flush at agent end (pi's
            # _pendingBashMessages flush) — never mid-tool-sequence.
            @user_bash.flush_pending
            if event[:interrupted] == true
              # The orphaned pending block's finalize (I34 — pi's abort
              # arm loops pendingTools with the "Operation aborted" error
              # result, interactive-mode.ts:3573-3586); the interrupt
              # scrollback line stays (additive).
              @transcript_state.finalize_pending_as_error("Operation aborted")
              handled = "interrupted"
              @transcript_state.enqueue_scrollback(handled, fg: Theme[:warning])
            elsif event[:error]
              # pi's error arm: the same loop with the error's message. The
              # flag-set case (the failure message's own message_end already
              # rendered the pad-led error row — D3) SKIPS the scrollback
              # line: pi's agent_end renders no error text (the component
              # owns the row). The flag-UNSET case (a failure with no
              # synthesized message_end) renders today's line byte-
              # identically. The finalize stays in BOTH (defense).
              @transcript_state.finalize_pending_as_error(event[:error].message.to_s)
              unless @error_row_rendered
                handled = "error: #{event[:error].message}"
                @transcript_state.enqueue_scrollback(handled, fg: Theme[:error])
              end
            end
            # A message submitted in the wind-down window (after the agent's
            # final steering check, before agent_end) sits queued with no run
            # in flight — continue the run (pi's queued-message semantics:
            # pi polls the queue at loop start, agent-loop.ts:175). The
            # deferred abort-first command (§busy_command_arm) takes THIS
            # agent_end instead: re-dispatch through the EXACT idle paths
            # (kernel.async schedules outside the mutex) and SKIP the
            # wind-down — manual compaction never continues the interrupted
            # turn (pi agent-session.ts:2762-2763).
            if @pending_after_interrupt
              deferred = @pending_after_interrupt
              @pending_after_interrupt = nil
              @kernel.async { @commands&.dispatch(deferred) }
            elsif handled.nil? && @agent&.queued_messages?
              @kernel.async { @agent.run }
            end
          end
        end
        # I58 — the tick discipline: this sink's tail requests ONE paint
        # per event (the delta arm paints on arrival; the retired tail
        # re-opened a 0.25 s animation window here on EVERY event — half
        # the burn). request_draw is the user-bash chunk sink's in-tree
        # precedent (reactor-context legal; this sink runs on the agent
        # fiber of the reactor).
        @kernel.request_draw
      end

      # The /new surface (bin/tart's reset seam): pi handleClearCommand →
      # newSession → renderCurrentSessionState — the chat container clears,
      # initial state re-renders, then the accent "✓ New session started"
      # line (interactive-mode.ts:6926-6936, 2209-2216). pi's shape: the
      # HEADER container untouched (never cleared, never re-rendered — its
      # live state rides the toggle), the loadedResourcesContainer cleared
      # and NEVER re-rendered (sections are boot-once). The port's flat
      # buffer wipes both, so the header block RE-ENQUEUES as the one
      # faithful translation (at the CURRENT toggle state; tart-mode's
      # fresh random art is the sanctioned identity presentation), and the
      # resource sections drop out of the path entirely (the sections-
      # resurrect was a real /new divergence — I33). Cross-lane contract:
      # bin/tart's reset lambda calls this after swapping in the fresh
      # agent (start_session + surface.new_session).
      def new_session
        @mutex.synchronize do
          clear_transcript
          enqueue_motd_header
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
          # The resumed session's last assistant text is ctrl+x's fallback
          # (pi getLastAssistantText reads the loaded messages). The entry
          # gates ride the typed envelopes (the same nil-skip table the
          # loader guards had).
          @last_assistant_text = entries.filter_map { |entry|
            envelope = Shapes::MessageEntry.of(entry)
            next unless envelope && envelope.role == "assistant"

            text = envelope.message["content"]
            next unless text.is_a?(String) && !text.strip.empty?

            text.strip
          }.last
          compactions = entries.count { |entry| Shapes::CompactionEntry.of(entry) }
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
        @live_region_cache = nil # the reset invalidates (I58, §live_region_cache)
        return nil if !text.is_a?(String) || text.empty?

        text
      end

      # The startup MOTD: the header-container block as ONE expandable
      # (pi interactive-mode.ts:1075-1077 — Spacer(1), the header,
      # Spacer(1); BuiltInHeader extends ExpandableText :256-270) plus
      # each loaded-resource section as its own expandable (pi
      # showLoadedResources' per-section ExpandableText children, swept by
      # the same toggle :4568-4572). The ctrl+o flip rebuilds every block
      # collapsed↔expanded in place ({Transcript#set_tool_output_expanded}).
      # Boot-only: /new re-enqueues the header alone ({new_session}), the
      # compaction rebuild ditto (the sections are boot-once, the I31
      # ruling).
      def enqueue_motd
        enqueue_motd_header
        enqueue_motd_sections
      end

      # The header-container block: the identity's header content between
      # its Spacers, built at the CURRENT global toggle state (pi
      # getStartupExpansionState = verbose || toolOutputExpanded; the port
      # has no --verbose, cut, itemized). Registered RESIZE-LIVE (I56 —
      # the SIGWINCH rebuild sweeps only this block). The tart art comes
      # from the LADDER at the current width (I56 — deterministic per
      # width; the random sample is retired): the pick re-runs at boot,
      # /new, and the compaction re-enqueue (all through here, at the
      # then-current {viewport_width} — the latch during a resize), and
      # is re-set ONLY by {handle_resize}; the ctrl+o flip path never
      # re-picks (the I33 byte-restore property — the builder closes over
      # the ivar, not the ladder).
      def enqueue_motd_header
        @header_enqueued = true
        @logo_lines = Motd.motd_logo_lines(viewport_width, wordmark: @identity)
        @transcript_state.push_expandable(->(expanded) { motd_header_rows(expanded) }, resize_live: true)
      end

      def motd_header_rows(expanded)
        header = @identity == Identity::PI ? Motd.pi_header_lines(expanded:, width: viewport_width) : Motd.tart_header_lines(viewport_width, @identity, expanded:, logo_lines: @logo_lines)
        [Panel.blank_line, *header, Panel.blank_line]
      end

      # The loaded-resource sections (boot-once). Each block mirrors pi's
      # container children — paddingX-0 components (addLoadedSection's
      # ExpandableText(..., 0, 0): the header row and the expanded bodies
      # render at column 0; only the COMPACT lists carry the port's pad,
      # the frozen I24 shape).
      # container children: the [Context] branch's LEADING Spacer rides
      # its block (interactive-mode.ts:1852-1853 — the contextFiles branch
      # only), every section carries its TRAILING Spacer (addLoadedSection
      # :1814). The section inputs gather from this surface's constructor
      # state (Motd is stateless — everything threads).
      def enqueue_motd_sections
        cwd = @footer_data&.fetch(:cwd, nil) || Dir.pwd
        Motd.sections(viewport_width,
          context: @context_files.map { |file| file.fetch(:path) } + Motd.context_sources(@settings_root, cwd),
          skills: @skills, prompts: @prompts, extensions: @extensions,
          user_root: @settings_root, project_root: File.join(cwd, Settings::CONFIG_DIR)).each do |section|
          @transcript_state.push_expandable(->(expanded) { motd_section_rows(section, expanded) })
        end
      end

      def motd_section_rows(section, expanded)
        rows = [TUI.line(section.name, fg: Theme[:md_heading])]
        rows.concat(expanded ? section.expanded_rows : section.collapsed_rows)
        rows.unshift(Panel.blank_line) if section.leading_blank
        rows << Panel.blank_line
        rows
      end

      # The /new + resume shared reset: the buffer and stream state drop
      # (pi renderCurrentSessionState's container clears, :2210-2216; the
      # host drops the selection with the transcript, :4096). The
      # transcript state resets through its component (the I24
      # {@footer.reset_usage} precedent).
      def clear_transcript
        wipe_transcript
        # The capture dies with the screen it rode (the /resume screen
        # re-renders no MOTD — the itemized cut; /new re-captures below).
        @header_enqueued = false
        @last_assistant_text = nil # the fresh session has no messages to copy
        # pi's footer stats re-derive from the fresh (empty) session.
        @footer.reset_usage
      end

      # The transcript-side clear WITHOUT the /new halves (pi
      # chatContainer.clear() + renderSessionEntries' resetTextSelection —
      # selection coordinates point into the transcript being replaced,
      # #9311): the compaction rebuild's clear half. The footer usage and
      # the copy source are the /new halves — untouched here.
      def wipe_transcript
        @transcript_state.reset
        @viewport.reset
        @selection_state.reset
        @live = +""
        @reasoning = +""
        @live_region_cache = nil # the reset invalidates (I58, §live_region_cache)
      end

      def viewport_width
        return @resize_dims[0] if @resize_dims

        area = @session.viewport_area
        area ? area.width : 80
      end

      # The key dispatch (pi interactive-mode.ts's component wiring): every
      # key routes into the editor, the suggestion list, the picker, or
      # the selector menu — the coordinator owns the routing, the
      # objects own the state.
      def edit_input(event)
        if event.paste?
          @editor.insert_paste(event.content)
          @autocomplete.cancel # pi editor.ts:1261 — paste cancels the list
          return
        end

        ctrl = event.modifiers.include?("ctrl")

        # The picker owns every key while open (pi: the selector takes
        # focus — showSelector { focus: selector }); it closes itself on
        # enter/esc and the holder drops.
        if @picker
          @picker = nil unless @picker.handle(event)
          return
        end

        # The selector menus (I27) take focus the same way; ctrl+s is
        # the set-as-default (app.models.save / app.thinking.save) —
        # persistence itself stays on this surface (the Settings write
        # + status lines).
        if @menu
          return menu_set_as_default if ctrl && event.code == "s"

          @menu = nil unless @menu.handle(event)
          return
        end

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
          # pi editor.ts:889-919 — the newline keys route to addNewLine
          # BEFORE the submit path (tui.input.newLine = shift+enter/
          # ctrl+j, keybindings.ts:143; alt+enter WAS pi's terminal
          # fallback arm), and plain enter submits — with the
          # no-shift+enter terminal workaround: a "\\" before the cursor
          # is deleted and a newline inserted instead (:906-917). The
          # list keeps pi's select.confirm fall-through: a "/"-prefix
          # completion applies then submits (editor.ts:790-816). I54:
          # alt+enter is app.message.followUp (keybindings.ts:67-70,
          # registered interactive-mode.ts:3116) — checked BEFORE the
          # shift arm (its submit_follow_up carries the cancel);
          # newline keys remain shift+enter/ctrl+j.
          if alt
            submit_follow_up
          elsif event.modifiers.include?("shift")
            @autocomplete.cancel # pi addNewLine editor.ts:1329
            @editor.add_new_line
          elsif @autocomplete.suggestions
            @autocomplete.apply(@editor)
            submit
          elsif @editor.backslash_before_cursor?
            @editor.delete_backward
            @editor.add_new_line
          else
            submit
          end
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
        when "l"
          # app.model.select (pi keybindings.ts:49, default ctrl+l): the
          # model menu.
          ctrl ? open_model_menu : @editor.insert_printable(event)
        when "s"
          # app.models.save / app.thinking.save (pi keybindings.ts:37,
          # :119 — both default ctrl+s): the OPEN menu's set-as-default;
          # inert without one.
          ctrl ? menu_set_as_default : @editor.insert_printable(event)
        when "x"
          # app.message.copy (pi keybindings.ts:63, default ctrl+x →
          # handleCopyCommand {flashConfirmation: true, preferSelection:
          # true}, interactive-mode.ts:3114): the copy seam; bare x types.
          ctrl ? copy_message : @editor.insert_printable(event)
        # While the list is active up/down navigate the LIST (history
        # yields — pi custom-editor.ts:127-131 → editor.ts:766-771);
        # otherwise pi's cursorUp/cursorDown dispatch runs (history at
        # the visual extremes per its gating, else one visual row).
        when "up"
          # I54: alt+up is app.message.dequeue (keybindings.ts:71-74) —
          # restore the queued messages to the editor (pi handleDequeue
          # :4507-4514); the plain/list arms are untouched below it.
          if alt then dequeue_queued_messages
          elsif @autocomplete.suggestions then @autocomplete.navigate(-1)
          else @editor.cursor_up
          end
        when "down" then @autocomplete.suggestions ? @autocomplete.navigate(1) : @editor.cursor_down
        when "tab"
          # app.thinking.cycle (pi keybindings.ts:33-35, default
          # shift+tab): the in-session level cycle — kept when bare
          # /thinking became the menu (I27).
          if event.modifiers.include?("shift")
            cycle_thinking_level
          elsif @autocomplete.suggestions
            @autocomplete.apply(@editor)
          else
            @autocomplete.update(@editor) # explicit trigger (pi handleTabCompletion)
          end
        # Editor paging (pi keybindings.ts:114-115 tui.editor.pageUp/
        # pageDown, defaultKeys pageUp/ctrl+pageUp, pageDown/ctrl+pageDown;
        # the gem spells the codes "page_up"/"page_down") — I35 OPTION A:
        # the page keys page the EDITOR's visual rows (pi pageScroll,
        # editor.ts:1961-1973 — pi's editor pages even with the list
        # open, :960-967 fall-through, so no list guard); the transcript
        # stays wheel-only (the I12 transcript page mapping and its
        # Viewport helper retired with it). The editor paging is silent:
        # pi's pageScroll marks no
        # scrollbar activity (it never touches the transcript).
        when "page_up" then @editor.page_scroll(-1)
        when "page_down" then @editor.page_scroll(1)
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
        when "j"
          # tui.input.newLine's ctrl+j arm (keybindings.ts:143); pi's
          # addNewLine cancels the list (editor.ts:1329).
          if ctrl
            @autocomplete.cancel
            @editor.add_new_line
          else
            @editor.insert_printable(event)
          end
        # The emacs kill/yank slice (I26, pi keybindings.ts:129-135): the
        # kill ops exit history browsing and push the cut span themselves.
        when "u" then ctrl ? @editor.delete_to_line_start : @editor.insert_printable(event)
        when "k" then ctrl ? @editor.delete_to_line_end : @editor.insert_printable(event)
        when "y" then ctrl ? @editor.yank : (alt ? @editor.yank_pop : @editor.insert_printable(event))
        # tui.editor.undo (I39, pi keybindings.ts:142, default ctrl+-):
        # pi matches undo BEFORE the autocomplete-mode block (editor.ts
        # :751-755) — it fires with the list open, neither cancelled nor
        # re-filtered (the printable re-filter below stays off ctrl+-).
        # Bare - types; alt+- is the modifier-guard no-op.
        when "-" then ctrl ? @editor.undo : @editor.insert_printable(event)
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
      # builtins dispatch busy-or-not, and text matching nothing falls
      # through to the agent as a plain message. The text is the editor's
      # EXPANDED read (pi submitValue expands markers before onSubmit,
      # editor.ts:1364-1377 — the marker is display-only; the wire, the
      # session, the history, and the queues all get the full content).
      # I54: the I13-era !busy?
      # gates DROP (pi's builtin if-chain precedes its streaming branch,
      # :3200-3365 — builtins dispatch mid-turn; /compact and /new take
      # the abort-first arm below). The idle submit echoes at submit and
      # runs; a busy submit steers with NO echo — the user message renders
      # AT DELIVERY (pi :3503-3507, the message_start event).
      def submit
        text = @editor.expanded_text.dup.strip # pi submitValue expands BEFORE the trim (editor.ts:1364-1377)
        @autocomplete.cancel
        return if text.empty?

        @editor.add_to_history(text)
        @editor.clear
        @editor.clear_undo_stack # pi submitValue editor.ts:1373 — the submit surface clears the stack
        @editor.exit_history_browsing
        @footer.invalidate_branch # per-turn branch invalidation
        if @commands && text.start_with?("/")
          text = @commands.expand_skill(text) # expansion BEFORE queue (agent-session.ts:2005-2010)
          return if gate_thinking_level(text) # busy-or-not (pi handleThinkingCommand, :5145-5163)
          return if busy_command_arm(text) # §busy_command_arm — false = fall through
          return if @commands.dispatch(text) # busy-or-not
        end
        # The !-prefix bash intercepts BEFORE the user echo (pi handleSubmit
        # :3347-3360 — the BashExecutionComponent is the display, no user
        # echo; the bare prefix falls through as plain text).
        parsed = UserBash.parse(text)
        return @user_bash.run(*parsed) if parsed

        if busy?
          steer_submitted_text(text) # no echo: the delivery arm echoes (pi :3503-3507)
        else
          @transcript_state.enqueue_user_submission(text)
          @kernel.async { @agent.run(text) }
        end
      end

      # The abort-first arm for /compact + /new while a turn runs (I54 —
      # pi session.compact aborts first, agent-session.ts:2764-2765; the
      # runtime's newSession aborts first, agent-session-runtime.ts
      # :167-178). Everything else dispatches immediately (pi's builtin
      # if-chain runs before its streaming branch). The port's realization:
      # interrupt the in-flight run, store the command text, and re-dispatch
      # it through the EXACT idle paths at :agent_end (§on_agent_event).
      # False here = not busy or not one of the two commands — the caller
      # falls through to the immediate dispatch.
      def busy_command_arm(text)
        return false unless busy?
        return false unless text == "/new" || text == "/compact" || text.start_with?("/compact ")

        @pending_after_interrupt = text
        @kernel.interrupt_work!
        @kernel.request_draw
        true
      end

      # app.message.followUp's submit (I54 — pi handleFollowUp,
      # interactive-mode.ts:4475-4505): while streaming the text queues as
      # a FOLLOW-UP (delivered only at full completion); idle alt+enter
      # behaves exactly like plain Enter (:4497-4504). Like pi's prompt()
      # queue branch, skill/prompt-template expansion applies before
      # queueing (agent-session.ts:2005-2010); the builtin dispatch and
      # the thinking gate do NOT run here (pi's handleFollowUp skips the
      # if-chain) and neither does the !-bash intercept — the text queues
      # verbatim (post-expansion). NO submit echo: the delivery arm echoes.
      def submit_follow_up
        text = @editor.expanded_text.dup.strip # pi handleFollowUp reads getExpandedText (interactive-mode.ts:4476)
        return if text.empty?

        return submit unless busy? # pi :4497-4504 — idle alt+enter = Enter

        text = @commands.expand_skill(text) if @commands
        @autocomplete.cancel
        @editor.add_to_history(text)
        @editor.clear
        @editor.clear_undo_stack # the submit surface's discipline, mirrored
        @editor.exit_history_browsing
        @footer.invalidate_branch
        follow_up_submitted_text(text)
      end

      # The shared busy-queue append (the surface mirror + the loop's
      # queue). Compaction-time submits steer too (pi queueCompactionMessage
      # routes non-extension text to a queue with showStatus —
      # interactive-mode.ts:4763-4772; the port's inline compaction makes
      # the separate surface compaction queue unnecessary — the
      # post-compaction drain IS the loop's complete? arm), with pi's
      # flash text.
      def steer_submitted_text(text)
        @mutex.synchronize { @queued[:steer] << text }
        flash("Queued message for after compaction") if @compaction_reason
        @agent.steer(text)
        @kernel.request_draw
      end

      def follow_up_submitted_text(text)
        @mutex.synchronize { @queued[:follow_up] << text }
        flash("Queued message for after compaction") if @compaction_reason
        @agent.follow_up(text)
        @kernel.request_draw
      end

      # The queued-message delivery (I54 — pi agent-session.ts:1122-1134
      # + interactive-mode.ts:3503-3507): the FIRST-index text match across
      # the mirror (steer first, else follow_up) is removed and echoed AT
      # DELIVERY. CALLER HOLDS @mutex (the on_agent_event sink).
      def deliver_queued_message(message)
        text = message.content
        return unless text.is_a?(String)

        %i[steer follow_up].each do |queue|
          index = @queued[queue].index(text)
          next unless index

          @queued[queue].delete_at(index)
          @transcript_state.enqueue_user_submission(text)
          @kernel.request_draw
          return
        end
      end

      # app.message.dequeue (I54 — pi handleDequeue :4507-4514 +
      # restoreQueuedMessagesToEditor :4743-4761): BOTH the surface mirror
      # and the loop's queues clear (pi clearAllQueues); queued-then-current
      # join with blank lines into the editor via {Editor#set_text}; NO
      # abort (the abort-restore arm is pi's extension abortHandler — no
      # extension seam, cut). pi's status texts.
      def dequeue_queued_messages
        steer_texts, follow_texts = @mutex.synchronize { [@queued[:steer], @queued[:follow_up]].map(&:dup) }
        @agent.clear_queues
        all = [*steer_texts, *follow_texts]
        if all.empty?
          flash("No queued messages to restore")
          return
        end

        combined = [all.join("\n\n"), @editor.input].reject { |text| text.strip.empty? }.join("\n\n")
        @editor.set_text(combined)
        n = all.size
        flash("Restored #{n} queued message#{n > 1 ? "s" : ""} to editor")
        @mutex.synchronize do
          @queued[:steer].clear
          @queued[:follow_up].clear
        end
        @kernel.request_draw
      end

      # --- app.message.copy (pi handleCopyCommand :6637-6669) + its flash ---

      # ctrl+x (interactive-mode.ts:3114 — {flashConfirmation: true,
      # preferSelection: true}): the ACTIVE selection's text, else the
      # last assistant message's, each through the seam's OSC 52 write
      # with the flash confirmation; no source is pi's showError
      # (:6651-6653). Deviation, itemized: pi's selection branch is gated
      # on !getCopyOnSelect() (copy-on-select OFF only — when it's on the
      # release already copied); the port's copy-on-select is
      # unconditionally on ({Selection#release}), so keeping the gate
      # literal would make the branch dead — the whole-screen iteration
      # pins selection-else-last-assistant.
      def copy_message
        text = @selection_state.selection_text || @last_assistant_text
        if text
          TUI.osc52_copy(text)
          flash("Copied!")
        else
          error_line("No agent messages to copy yet.")
        end
      end

      # pi's alt-screen flash (alt-screen-flash.ts): a reversed
      # " <message> " composited at the finished screen's top-right for
      # 1000ms, then one redraw. The port composites at render
      # ({transcript_widget}'s row 0) and clears through the kernel timer
      # — the scrollbar-hide arm's shape; a newer flash's token wins
      # (equal? guard — stale clears drop).
      def flash(message)
        token = @flash = {text: message}
        @kernel.request_draw
        @kernel.async do
          sleep(@flash_seconds)
          next unless @flash.equal?(token)

          @flash = nil
          @kernel.request_draw
        end
      end

      # One flash row composited over +line+'s cells at the right edge
      # (pi compositeTuiLine :1667-1687 — the covered cells replace; the
      # gap between the row's content and the flash renders as bare
      # spaces; the message truncates right to the width).
      def flash_row(line, width)
        text = " #{@flash[:text]} "
        flash_width = [TUI.text_width(text), width].min
        text = Text.clip_text(text, flash_width)
        base = Text.clip_spans(line.spans, width - flash_width)
        base_width = base.sum { |span| TUI.text_width(span.content) }
        TUI.line(base + [TUI.span(" " * (width - flash_width - base_width) + text, modifiers: [:reversed])])
      end

      # A surface-initiated error line (pi showError :4623-4627 — a
      # spacer + an error-fg "Error: <message>" chat line).
      def error_line(message)
        @transcript_state.enqueue_region([Panel.blank_line, TUI.line("Error: #{message}", fg: Theme[:error])])
      end

      # /thinking's runtime gate (pi handleThinkingCommand :5143-5157 —
      # the command validates the arg against the RUNTIME model's
      # available levels, not the global ladder): an arg outside the
      # gated set renders pi's showError with the GATED list and
      # dispatches nothing; bare /thinking and available levels fall
      # through to the dispatcher. The surface owns the gate — the
      # frozen Commands::Handler renders the full ladder (:169) and
      # knows nothing of the runtime reasoning capability.
      def gate_thinking_level(text)
        return false unless text.start_with?("/thinking ")

        arg = text.split(/\s+/, 2)[1].to_s.strip
        return false if arg.empty? || available_thinking_levels.include?(arg)

        error_line(%(Unknown thinking level "#{arg}". Available levels: #{available_thinking_levels.join(", ")}.))
        true
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

      # The session viewport's height (the 24 fallback matches
      # {viewport_width}'s 80 — the headless defaults' shape). The resize
      # latch prefers the event's height for the one latched frame (I56).
      def screen_height
        return @resize_dims[1] if @resize_dims

        area = @session.viewport_area
        area ? area.height : 24
      end

      # The transcript area's row budget — the page size and the mouse
      # mapping's viewport bound (pi chat-viewport geometry, shared with
      # {build_widget}): the viewport minus the dock — spacer 1 + pending
      # rows + editor + footer (pi chat-viewport.ts:22-45; I54 adds the
      # pending block — pi's document-area shrink: the TRANSCRIPT yields,
      # the editor/footer never move).
      def transcript_area_rows(height = screen_height)
        [height - editor_area_rows(height) - FOOTER_ROWS - dock_spacer_rows(height) - pending_rows, 1].max
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
        return menu_mouse(event) if @menu
        return wheel(event) if event.scroll?
        return unless event.left?

        case event.kind
        when "down" then @selection_state.press(content_point(event.y, event.x))
        when "drag" then @selection_state.drag(content_point(event.y, event.x))
        when "up" then @selection_state.release(content_point(event.y, event.x))
        end
      end

      # The open menu's click-to-select (pi: mouse events route to the
      # focused component — select-list.ts:109-134 press/release): a left
      # press moves the selection, the release on the same row selects
      # and closes. The terminal cell maps into the list window
      # ({menu_list_top}); wheel keeps scrolling the transcript behind
      # the menu (itemized).
      def menu_mouse(event)
        return unless event.left?

        row = event.y - menu_list_top
        case event.kind
        when "down" then @menu.press(row)
        when "up" then @menu.release(row)
        end
      end

      # The terminal row of the menu's first list item: the menu area
      # docks above the footer (the editor slot), its top border is one
      # row, the list starts {ModelMenu#list_offset} content rows in.
      def menu_list_top
        height = @session.viewport_area&.height || 24
        area_top = height - FOOTER_ROWS - (@menu.widget_rows + 2)
        area_top + 1 + @menu.list_offset
      end

      # One wheel event: the lines-per-event math and the wheel constants
      # live on the viewport ({Viewport#wheel} — pi tui-alt-screen.ts wheel
      # → scrollView.scrollBy); this is the routing + the hide timer's
      # arm.
      def wheel(event)
        mark_scrollbar_activity(@viewport.wheel(event, display_lines.size, transcript_area_rows))
      end

      # Maps a terminal cell to a selection point (pi getSelectionPoint
      # :1145-1152): transcript-area rows map into buffer coordinates (pi
      # getScrollSelectionPoint :1133-1155 — the area starts at row 0, the
      # column clamps to the area's width, the scrollbar gutter excluded
      # while overflowing — pi clamps to the scrollview box); rows BELOW
      # take pi's non-scrollview branch (plain terminal row/col, clamped)
      # re-expressed in the port's row space: a NEGATIVE synthetic row,
      # terminal row − screen height (counted up from the screen's last
      # row — disjoint from the buffer rows, stable under transcript
      # growth, inverted by {selection_line}). A nil point (a press on an
      # empty transcript) drops the selection.
      def content_point(y, x)
        rows = transcript_area_rows
        # pi clamps to the scrollview box — full width for "auto" (the
        # rail overlays the last column, no reserved gutter to exclude;
        # scroll-view.ts:80-82 getContentWidth).
        col = x.clamp(0, viewport_width - 1)
        if y < rows
          lines = display_lines
          return nil if lines.empty?

          return Selection::Point.new((@viewport.offset + y).clamp(0, lines.size - 1), col)
        end
        Selection::Point.new(y - screen_height, col)
      end

      # The selection's line reader (pi getSelectionSourceLine :1165-1171,
      # whole-screen I28): transcript buffer rows answer the display
      # Line's span contents; the dock's synthetic rows answer the
      # composed plain text ({below_line}). pi reads the last-rendered
      # screen buffer (previousScreen); the gem exposes no live
      # screen-buffer readback, so the port composes from the same
      # builders that render the rows — same bytes, different source
      # (itemized).
      def selection_line(row)
        return plain_content_line(row) if row >= 0

        below_line(row + screen_height)
      end

      # The buffer row's plain text (the display Line's span contents) —
      # the transcript rows' content seam.
      def plain_content_line(row)
        display_lines[row].spans.map(&:content).join
      end

      # A below-transcript terminal row's composed plain text: the
      # footer's two rows, the editor slot's borders and content rows,
      # else the dock spacer (a blank). The border bytes mirror the gem
      # Block's render (byte-verified: the title then dashes to width;
      # a titleless/blank border is all dashes).
      def below_line(y)
        footer_top = screen_height - FOOTER_ROWS
        return below_widget_line(y - footer_top) { @footer.lines(footer_data, viewport_width) } if y >= footer_top

        editor_top = footer_top - editor_area_rows
        if y >= editor_top
          offset = y - editor_top
          return editor_top_border_line.spans.map(&:content).join if offset.zero?
          return editor_bottom_border_line.spans.map(&:content).join if offset == editor_area_rows - 1

          line = editor_slot_lines[offset - 1]
          return line ? line.spans.map(&:content).join : ""
        end
        "" # the dock spacer — a blank row
      end

      # The +row+-th line of a dock widget's composed rows (the reader's
      # footer answer; a short composition answers blank).
      def below_widget_line(row)
        line = yield[row]
        line ? line.spans.map(&:content).join : ""
      end

      # pi chat-viewport.ts:33 — the editor dock is shrink 1, minSize 3
      # ({MIN_EDITOR_ROWS}): the two border rows + the windowed input
      # rows (always ≥ 1 — the empty editor lays out one row) + the
      # suggestion list, capped at the screen (the cap is what makes the
      # dock yield under pressure — pi's VStack shrink).
      def editor_area_rows(height = screen_height)
        return [@picker.widget_rows + 2, height - 1].min if @picker # + borders
        return [@menu.widget_rows + 2, height - 1].min if @menu # + borders

        [MIN_EDITOR_ROWS - 1 + @editor.windowed_rows(editor_inner_width) + @autocomplete.rows, height - 1].min
      end

      # The editor slot's top border row (the composition's third child:
      # the transcript/spacer carve the top, the footer the bottom).
      def editor_area_top
        screen_height - FOOTER_ROWS - editor_area_rows
      end

      # The editor slot's content lines (the input row + the suggestion
      # list; a mounted picker/menu renders its own rows in the slot —
      # the same compositions the widget builders wrap).
      def editor_slot_lines
        return @picker.lines(viewport_width) if @picker
        return @menu.lines(viewport_width) if @menu

        editor_content_lines
      end

      # The editor's content lines (the windowed input rows + the
      # suggestion rows) — the edit box's inner rows, shared by
      # {editor_widget}'s build and the selection's dock composition
      # ({below_line}). The editor wraps at the inner width itself (pi
      # layoutText's contentWidth — one column reserved for the cursor,
      # paddingX 0), so rows arrive render-ready; no clip pass.
      def editor_content_lines
        @editor.input_rows(editor_inner_width) + @autocomplete.lines(editor_inner_width)
      end

      # The editor's wrap width (pi render :536-556: layoutWidth =
      # width − 1 — one column reserved for the cursor at paddingX 0).
      def editor_inner_width
        [viewport_width - 1, 1].max
      end

      # The selection highlight over composed dock rows (the transcript's
      # highlight_row pass extended below the transcript area — I28 AC2):
      # each line re-styled at its synthetic row (terminal row − screen
      # height, {content_point}'s below-space).
      def highlight_lines(lines, top)
        lines.map.with_index { |line, i| @selection_state.highlight_row(line, top + i - screen_height) }
      end

      # The fullscreen three-area composition (AC1, pi chat-viewport.ts):
      # a transcript area on top (Min 1 — takes the rest), the bordered
      # editor area and the footer docked at the bottom (Length — pi's
      # shrink:1 fixed-height dock). All heights derive from the session's
      # viewport every frame, so a resize recomposes cleanly. I54: the
      # pending block (pi pendingMessagesContainer) sits between the dock
      # spacer and the editor (createChatViewport :969-976 — document →
      # pendingMessages → status → widgetsAbove → editor).
      def build_widget
        height = screen_height
        editor_rows = editor_area_rows(height)
        transcript_rows = transcript_area_rows(height)
        spacer_rows = dock_spacer_rows(height)
        pending = pending_rows
        TUI.layout(
          children: [
            transcript_widget(transcript_rows),
            dock_spacer_widget,
            pending_widget(pending),
            picker_or_menu_widget || editor_widget,
            footer_widget,
          ],
          constraints: [
            TUI.constraint_min(transcript_rows),
            TUI.constraint_length(spacer_rows),
            TUI.constraint_length(pending),
            TUI.constraint_length(editor_rows),
            TUI.constraint_length(FOOTER_ROWS),
          ]
        )
      end

      # The picker/menu slot: whichever selector is mounted in place of
      # the editor (pi showSelector's container swap), else nil → the
      # editor.
      def picker_or_menu_widget
        return @picker.widget(viewport_width) if @picker
        return @menu.widget(viewport_width) if @menu

        nil
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

      # The pending block's row count (pi updatePendingMessagesDisplay
      # :4724-4740): 0 when both mirror arrays are empty (the widget drops
      # out of the layout entirely); else the blank spacer row + one row
      # per queued message + the dequeue hint row. Lock-free: the render
      # frame holds @mutex, and the unlocked readbacks (the wheel/scroll
      # math) tolerate a one-frame-stale count. Array size/each under MRI's
      # GVL do not interleave with the mutators' single C-level ops.
      def pending_rows
        count = @queued[:steer].size + @queued[:follow_up].size
        count.zero? ? 0 : 2 + count
      end

      # The pending rows (pi updatePendingMessagesDisplay + TruncatedText
      # truncated-text.ts:7-40 — TruncatedText(text, 1, 0): ONE line,
      # clipped, paddingX 1 each side): a blank row (pi Spacer(1)), one
      # dim "Steering: <text>" row per steering message, one dim
      # "Follow-up: <text>" row per follow-up, then the dim dequeue hint
      # (pi's keyDisplayText("app.message.dequeue") = "Alt+Up" — the port
      # has no keybinding registry, the string is the rendered constant).
      def pending_widget(rows)
        return TUI.paragraph(text: [], wrap: false) if rows.zero?

        width = viewport_width
        lines = [Panel.blank_line]
        @queued[:steer].each { |text| lines << pending_row("Steering: ", text, width) }
        @queued[:follow_up].each { |text| lines << pending_row("Follow-up: ", text, width) }
        lines << pending_row("", "↳ Alt+Up to edit all queued messages", width)
        TUI.paragraph(text: lines, wrap: false)
      end

      # One dim pending row: the text's FIRST line only, clipped to the
      # viewport width minus 2, one leading space, right-padded to the
      # width (pi TruncatedText's paddingX 1 discipline).
      def pending_row(label, text, width)
        body = Text.clip_text(text.to_s.lines(chomp: true).first.to_s, [width - 2, 0].max)
        line = " #{label}#{body}"
        TUI.line(line + " " * ([width - TUI.text_width(line), 0].max), fg: Theme[:dim])
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
        if @viewport.scrollbar_visible?(lines, rows)
          glyphs = @viewport.scrollbar_glyphs(lines.size, rows)
          window = window.map.with_index { |line, i| @viewport.overlay_rail_cell(line, glyphs[i], width) }
        end
        # pi's flash composite (compositeFlashes :1664): the flash rows
        # land over the finished screen from row 0, right-aligned —
        # row 0 is the transcript area's first row.
        window[0] = flash_row(window[0], width) if @flash && window[0]
        TUI.paragraph(text: window, wrap: false)
      end

      # The footer's widget with the selection highlight over its rows
      # (I28 AC2 — the composed lines, highlighted at their synthetic
      # rows, wrapped as at base).
      def footer_widget
        lines = highlight_lines(@footer.lines(footer_data, viewport_width), screen_height - FOOTER_ROWS)
        TUI.paragraph(text: lines, wrap: false)
      end

      # The edit box (pi CustomEditor, item 5): full-width from column 0,
      # horizontal borders ONLY (the top border carries the status line —
      # custom-editor.ts renderTopBorder :36-77; renderBottomBorder
      # editor.ts:516), no east/west borders, no prompt char (pi's editor
      # renders the bare text; the "❯" prompt was an I11 invention),
      # paddingX 0 (pi's editorPaddingX default, settings-defaults.ts:46)
      # with pi's one reserved cursor column (editor.ts:518-521: without
      # padding the layout width is width − 1). The suggestion list renders
      # below the input rows, inside the editor area (pi editor.ts:618-634
      # — the area height grows by the list height; the port's standing
      # I12 placement). Since I35 the area composes its own border rows
      # (see {editor_top_border_line}); the content rows carry the
      # selection highlight at their synthetic rows (I28 AC2) and the
      # border rows stay unhighlighted, itemized as at base.
      def editor_widget
        content = highlight_lines(editor_content_lines, editor_area_top + 1)
        TUI.paragraph(text: [editor_top_border_line, *content, editor_bottom_border_line], wrap: false)
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

        level = thinking_level if footer_data[:reasoning]
        token = "thinking_#{level || :off}".to_sym
        Theme::TOKENS.key?(token) ? Theme[token] : Theme[:thinking_off]
      end

      # The editor area's composed border rows (pi renderTopBorder/
      # renderBottomBorder, editor.ts:509-518 + createScrollBorder
      # :279-296): dashes in the border color; when the window hides
      # rows, the centered " ↑/↓ N more " label. Deviation, itemized: pi
      # wraps each border segment in borderColor(...) directly; the gem
      # seam exposes no bottom-title/multi-style border row (tui.rb is
      # shared), so the rows are composed here as span lines inside the
      # editor's paragraph — the BYTES and the segment routing (border
      # color for the border, the embedded status's per-kind colors) are
      # pi's ({Editor.scroll_border} is unit-pinned).
      def editor_top_border_line
        status = status_title
        hidden = @editor.scroll_offset
        unless status || hidden.positive?
          return TUI.line("─" * viewport_width, fg: editor_border_color)
        end
        unless status
          return TUI.line(Editor.scroll_border("↑", hidden, viewport_width), fg: editor_border_color)
        end

        TUI.line(status_border_segments(hidden, status).map do |text, segment|
          TUI.span(text, fg: status_segment_fg(segment))
        end)
      end

      def editor_bottom_border_line
        hidden = @editor.hidden_below
        row = hidden.positive? ? Editor.scroll_border("↓", hidden, viewport_width) : "─" * viewport_width
        TUI.line(row, fg: editor_border_color)
      end

      # The top border's segments with an embedded working status
      # (custom-editor.ts:36-66): "── " + status + " " on the left (pi's
      # single-space shape — the status rides UNFLANKED since I37), the
      # hidden-rows label centered in the border color, and on collision
      # the status degrades to the spinner alone (pi
      # renderSpinnerInBorder) — after which the centered form may fit
      # again (pi re-runs canFitOverflow against the degraded status).
      # Returns [text, :border|:spinner|:message] pairs — the spinner
      # glyph and the message are separate segments so each takes its
      # own color ({status_segment_fg}).
      def status_border_segments(hidden, status)
        width = viewport_width
        label = hidden.positive? ? " ↑ #{hidden} more " : nil
        status = spinner_glyph if label && !status_label_fit?(status, label, width)

        status_width = TUI.text_width(status)
        label_width = label ? TUI.text_width(label) : 0
        overflow_start = (width - label_width) / 2
        left_block = 3 + status_width + 1
        if label && label_width + 2 <= width && overflow_start - left_block >= 1
          tail = " #{"─" * (overflow_start - left_block)}#{label}#{"─" * (width - overflow_start - label_width)}"
          return [["── ", :border], *status_spans(status), [tail, :border]]
        end
        if width >= status_width + 5
          return [["── ", :border], *status_spans(status), [" #{"─" * (width - status_width - 4)}", :border]]
        end

        # pi degrades to the spinner alone here too (custom-editor.ts:66-67
        # re-renders renderSpinnerInBorder before the prefix math).
        status = spinner_glyph
        status_width = TUI.text_width(status)
        prefix = [3, [width - status_width, 0].max].min
        [["─" * prefix, :border], *status_spans(status),
         ["─" * [[width - prefix - status_width, 0].max, 0].max, :border]]
      end

      # custom-editor.ts:44-46 canFitOverflow: the label needs its width
      # plus margins, and the centered label's start must clear the
      # status block ("── " + status + " ") by at least one dash.
      def status_label_fit?(status, label, width)
        label_width = TUI.text_width(label)
        return false unless label_width + 2 <= width

        ((width - label_width) / 2) - (3 + TUI.text_width(status) + 1) >= 1
      end

      # The status block's spans over the composed "<glyph> <message>"
      # (pi renderInBorder's slice — the Loader's `<glyph> <message>`
      # text): the leading glyph and the message are separate segments
      # so each carries its own color ({status_segment_fg}); the
      # degraded bare-glyph form (renderSpinnerInBorder) is the spinner
      # alone. The split is positional — the glyph was composed from ONE
      # clock read in {status_title}; re-deriving it here could race a
      # frame tick.
      def status_spans(status)
        glyph, message = status.split(" ", 2)
        return [[glyph, :spinner]] unless message

        [[glyph, :spinner], [" #{message}", :message]]
      end

      def spinner_frame(anchor)
        # pi loader.ts — the frame displayed at time t is
        # frames[floor((t − anchor)/interval) mod n] whatever the render
        # cadence: pi's setInterval advances the frame on TIME (+
        # requestRender); the port derives the same frame from the
        # monotonic clock at each rendered frame (since I58 the renders
        # themselves ride the spinner tick — {arm_spinner_tick} — the
        # cadence is pi's 12.5 Hz). nil anchor → frame 0 (pi setIndicator
        # resets currentFrame).
        return SPINNER.first unless anchor

        elapsed = @clock.call - anchor
        SPINNER[(elapsed / SPINNER_INTERVAL_SECONDS).floor % SPINNER.size]
      end

      # The border status's glyph — its own anchor ({restart_spinner!}).
      # The bash-run loader shares the MATH, never the anchor (pi: one
      # Loader per component).
      def spinner_glyph
        spinner_frame(@spinner_started_at)
      end

      # pi's per-indicator frame-0 reset (loader.ts setIndicator): every
      # status-kind (re)start re-anchors the spinner — :agent_start
      # creates the working indicator (interactive-mode.ts:3427-3433),
      # :compaction_start constructs CompactionStatusIndicator (:3681),
      # the :compaction result clears it (clearStatusIndicator :3694 —
      # the next working indicator restarts).
      def restart_spinner!
        @spinner_started_at = @clock.call
      end

      # The busy spinner tick (I58 — pi's Loader owns its cadence,
      # loader.ts:82-99): one repeating ~80 ms reactor task requesting a
      # draw for as long as a run is in flight or a user-bash stream
      # renders — the retired burn (a 60 Hz animation window re-armed per
      # frame/event) is pi's 12.5 Hz here. The glyph stays time-derived
      # ({spinner_frame}); the tick only paces the paints. Idempotent (a
      # live tick is kept — :compaction_start re-anchors the glyph, not
      # the pacer). Reactor context only (the sinks that arm run on the
      # reactor; Loop#tick spawns a reactor task). Loop teardown stops the
      # task with the rest of the reactor subtree (Loop#run's ensure).
      def arm_spinner_tick
        return if @spinner_tick

        @spinner_tick = @kernel.tick(SPINNER_INTERVAL_SECONDS)
      end

      # Cancels the spinner tick (the returned task's +stop+ — the same
      # Task#stop mechanism Ctrl+C uses). Idempotent; a dead task's stop
      # is a no-op.
      def cancel_spinner_tick
        task = @spinner_tick
        @spinner_tick = nil
        task&.stop
      end

      # The embedded status's per-segment colors (pi's embedded colorFns):
      # the border dashes ride the editor border color; the WORKING
      # status's spinner AND message ride it too (interactive-mode.ts
      # :2346-2359 — the embedded colorFn overrides both constructor
      # defaults with editor.borderColor — bashMode in bash mode, else
      # the thinking-level ladder — dereferenced lazily per frame, so a
      # mid-turn level change re-colors the status); the COMPACTION
      # indicator has no colorFn — its constructor defaults hold (accent
      # spinner, muted message — status-indicator.ts:80-96).
      def status_segment_fg(segment)
        return editor_border_color if segment == :border
        return Theme[:accent] if segment == :spinner && @compaction_reason
        return Theme[:muted] if segment == :message && @compaction_reason

        editor_border_color
      end

      # The session's thinking level (pi agent.state.thinkingLevel): nil
      # = not set this session — the settings-resolved default shows.
      def thinking_level
        @thinking_level || @footer_data&.fetch(:thinking_level, nil)
      end

      def status_title
        # The transient working/compaction spinner ONLY (pi
        # embedWorkingStatus — unmeasurable at settle, stays): the three
        # persistent statuses are transcript tail rows now
        # ({Transcript::StatusEntry} — pi showStatus :3824-3842). Direct
        # ivars — this runs inside render_frame's synchronize. UNFLANKED
        # since I37: pi's renderInBorder slices the Text pad and the
        # border composition adds its own single spaces
        # (custom-editor.ts:26-29/:60-66) — the I34-era " #{…} " wrapper
        # double-spaced the row.
        return nil unless @busy || @compaction_reason

        "#{spinner_glyph} #{status_message}"
      end

      def status_message
        # The running compaction displaces the working message (pi
        # status-indicator.ts:85-95 via interactive-mode.ts:3672-3681);
        # the working message is pi's constant defaultWorkingMessage
        # (interactive-mode.ts:487) — the I04-era phase-detail vocabulary
        # ("thinking"/"…"/"tool: <name>") retires with I37.
        return COMPACTION_LABELS.fetch(@compaction_reason, "Compacting context...") if @compaction_reason

        "Working"
      end

      # The footer's per-frame data view: the launcher facts with the
      # runtime overlays — the thinking level ({thinking_level}, pi
      # footer.ts:226-244) and the switched model's id, context window,
      # reasoning capability, and thinkingLevelMap (I27 + I36, the footer
      # model segment's + the level ladder's refresh after a /model
      # switch). nil footer_data renders from what the surface knows
      # alone, as at base.
      def footer_data
        data = @footer_data || {}
        data = data.merge(thinking_level: @thinking_level) if @thinking_level
        return data unless @runtime_model

        data = data.merge(model: @runtime_model.id)
        data = data.merge(context_window: @runtime_model.context_window) if @runtime_model.context_window
        # The typed entry always carries the map key (nil when the entry
        # declares none) — the overlay rides on every switch, as the
        # catalog-shaped row always did.
        data = data.merge(thinking_level_map: @runtime_model.thinking_level_map)
        data.merge(reasoning: @runtime_model.reasoning)
      end

      # The transcript buffer's display lines — completed content plus the
      # live region. The transcript area windows this ({transcript_widget})
      # and the mouse machinery addresses it (selection points are buffer
      # rows). Public as the live region's test readback — the
      # {transcript_lines} parallel for kernel-driven tests that pin rows
      # the drawn screen's window may clip.
      def display_lines
        @transcript_state.lines + live_lines(viewport_width)
      end

      # The streaming region (item 3, pi interactive-mode.ts:3519-3535 +
      # assistant-message.ts:107-109): the reasoning block renders as DIM
      # MARKDOWN through the shared converter ({Transcript.reasoning_lines}
      # — the thinkingText+italic prose default over the markdown theme,
      # pi assistant-message.ts:99-176; the I13 markdown-of-reasoning cut
      # retired by the owner's live finding) and the CONTENT re-renders as
      # markdown on every delta — pi re-renders the whole streaming
      # message each update, no incremental cleverness. The transcript
      # area's tail clip bounds it (deltas append; the window slides).
      #
      # The region renders the assistant message's SETTLED shape from the
      # first delta (pi updateContent runs while streaming — the leading
      # Spacer(1) :103-105 and the between-runs Spacer :172-174 are
      # component children, not post-hoc inserts): leading blank, the
      # reasoning rows, a blank when content follows the reasoning, the
      # content. The blank appearing only at completion was the 2nd-pass
      # shift (the row insert moved streaming content down a line).
      def live_lines(width)
        lines = assistant_live_lines(width)
        lines.concat(user_bash_live_rows(width))
        lines
      end

      # The assistant streaming region's rows (item 3, pi
      # interactive-mode.ts:3519-3535 + assistant-message.ts:107-109): the
      # reasoning block renders as DIM MARKDOWN through the shared
      # converter ({Transcript.reasoning_lines} — the thinkingText+italic
      # prose default over the markdown theme, pi assistant-message.ts
      # :99-176; the I13 markdown-of-reasoning cut retired by the owner's
      # live finding) and the CONTENT re-renders as markdown on every
      # delta — pi re-renders the whole streaming message each update, no
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
      #
      # Since I58 the conversion is cached on
      # [viewport_width, @live.bytesize, @reasoning.bytesize] (D2): a
      # cached-window frame (the spinner tick) re-serves the rows, a delta
      # frame (a key change) recomputes. The rows are a pure function of
      # the key's inputs; the reset sites clear the cache so a same-size
      # different-content message can never hit a stale entry (AC2's
      # reset-cycle exactness). Returns a COPY of the cached rows — the
      # caller ({live_lines}) concats into the result.
      def assistant_live_lines(width)
        return [] if @live.empty? && @reasoning.empty?

        key = [width, @live.bytesize, @reasoning.bytesize]
        cached = @live_region_cache
        return cached[1].dup if cached && cached[0] == key

        lines = [Panel.blank_line]
        lines.concat(Transcript.reasoning_lines(@reasoning, width)) unless @reasoning.empty?
        lines << Panel.blank_line if !@reasoning.empty? && !@live.empty?
        lines.concat(Transcript.markdown_lines(@live, width)) unless @live.empty?
        @live_region_cache = [key, lines]
        lines.dup
      end

      # The RUNNING user-bash block's rows (I38 — pi's chat/pending
      # placements, Grounds 6: appended BELOW the transcript content and
      # BELOW any streaming assistant rows). Composed fresh per frame —
      # the toggle state and the glyph read at composition time, pi's
      # updateDisplay discipline (mid-run ctrl+o re-composes, Grounds
      # 6f). Own leading blank (the block head's); an idle run renders
      # nothing here.
      def user_bash_live_rows(width)
        state = @user_bash_stream
        return [] unless state

        BashBlock.running_user_bash_rows(state[:command], width,
          content: state[:content], excluded: state[:excluded],
          spinner_glyph: spinner_frame(state[:spinner_started_at]),
          expanded: @transcript_state.tool_output_expanded)
      end

      # --- the user-bash live stream's sinks (I38 — the UserBash seam;
      # pi handleBashCommand :7000-7062: the component added before
      # execution, appendOutput + ui.requestRender per chunk, setComplete
      # in place) ---

      # Reactor/frame-loop fibers only (the kernel task's drainer delivers
      # chunks on the reactor — the pipe-drain reader threads only push its
      # queue, Grounds §3 probe5); all render-state mutation stays under
      # the surface mutex, exactly the agent-event discipline.
      def start_user_bash_stream(command, excluded)
        @mutex.synchronize do
          @user_bash_stream = {command:, excluded:, content: +"", spinner_started_at: @clock.call}
        end
        # pi adds the component then requestRender (:7033-7034) — the
        # header + loader row paint before the first chunk. The bash
        # loader's glyph must advance between chunks (pi's Loader ticks
        # requestRender on its own 80 ms interval, loader.ts:79-84) — the
        # spinner tick arms with the stream (I58).
        arm_spinner_tick
        @kernel.request_draw
      end

      # The appendOutput join is the string buffer itself: each chunk
      # appends (CR already removed by the seam — Grounds 2), an
      # unterminated trailing line continues on the next chunk's first
      # piece. The draw per chunk is pi's requestRender (:7050-7057).
      def append_user_bash_stream(text)
        appended = false
        @mutex.synchronize do
          # A late chunk after the clear (a cancelled run's partial chunks
          # may still push after the reactor-side wait died) is dropped.
          appended = !@user_bash_stream.nil?
          @user_bash_stream[:content] << text if appended
        end
        @kernel.request_draw if appended
      end

      # The explicit terminal clear (every path — completion, worker
      # error, cancel — notifies exactly once; idempotent). No draw: the
      # caller's own request_draw paints the settled block in the same
      # frame the live rows vanish (AC2). The spinner tick cancels with
      # the stream unless an agent run keeps it (I58).
      def end_user_bash_stream
        @mutex.synchronize { @user_bash_stream = nil }
        cancel_spinner_tick unless busy?
      end

      # /thinking's seam (pi selectThinkingLevel :5165-5177): the session
      # level changes, the border reports "Thinking level: <level>"
      # (pi showStatus) until the next agent event clears it. The level
      # drives the footer's `model • <level>` segment and the editor
      # border color ({editor_border_color}) — pi footer.invalidate +
      # updateEditorBorderColor. (Public — the dispatcher's callable.)
      def set_thinking_level(level)
        apply_thinking_selection(level, persist: false)
      end

      # The runtime model's reasoning capability (pi supportsThinking,
      # agent-session.ts:2665-2668 — model?.reasoning): the boot fact
      # overlaid by the runtime switch ({footer_data}).
      def reasoning_capable?
        !!footer_data[:reasoning]
      end

      # pi getAvailableThinkingLevels (:2657-2662 →
      # getSupportedThinkingLevels, models.ts:1224-1233): a non-reasoning
      # model offers [off] alone; a reasoning model the ladder filtered
      # through the runtime model's thinkingLevelMap (null marks a level
      # unsupported, xhigh/max need a present entry; no map = pi's
      # map-less rule off..high). The runtime switch re-gates (the map
      # rides the per-frame footer view). Retires the I27 deviation
      # ("xhigh/max never filter" — the catalog schema carries the map
      # since I36).
      def available_thinking_levels
        Models.supported_thinking_levels(map: footer_data[:thinking_level_map], reasoning: reasoning_capable?)
      end

      # pi cycleThinkingLevel (agent-session.ts:2641-2653): the next
      # level in THINKING_LEVEL_OPTIONS order, wrapping — app.thinking.cycle
      # (shift+tab), kept in-session when bare /thinking became the menu
      # (I27); no thinking support is a no-op (:2645-2646). A stored
      # level outside the gated set (a switch re-laddered under it)
      # cycles to the FIRST rung — pi's `indexOf → -1` makes
      # `(−1 + 1) % size` land on index 0 (agent-session.ts:2641-2653).
      # (Public — the keybinding's callable.)
      def cycle_thinking_level
        return unless reasoning_capable?

        current = @mutex.synchronize { thinking_level || Settings::DEFAULT_THINKING_LEVEL }
        levels = available_thinking_levels
        index = levels.index(current) || -1
        next_level = levels[(index + 1) % levels.size]
        set_thinking_level(next_level)
        next_level
      end

      # --- the selector menus (I27, pi showSelector family) ---

      # The /thinking selector (pi showThinkingSelector :5168-5183): the
      # session level (the settings default when unset) is the ✓ row;
      # the settings-resolved default carries the · default badge.
      # Selection applies through the same state the command path uses.
      def open_thinking_menu
        @mutex.synchronize do
          @menu = ModelMenu.new(variant: :thinking, items: thinking_menu_items, query_seed: nil,
            search_text: ->(item) { "#{item[:value]} #{item[:description]}" },
            on_select: ->(item) { close_menu; apply_thinking_selection(item[:value], persist: false) },
            on_select_as_default: ->(item) { close_menu; apply_thinking_selection(item[:value], persist: true) })
        end
      end

      # The gated menu's items (ModelMenu.thinking's item shape over
      # {available_thinking_levels}): the sealed family constructor pins
      # the full ladder, so the gate builds here — pi's layering
      # (showThinkingSelector :5176-5183 passes
      # session.getAvailableThinkingLevels into the component).
      def thinking_menu_items
        levels = available_thinking_levels
        # pi marks the ✓ by EXACT equality only (thinking-selector.ts
        # :69-73): a stored level OUTSIDE the gated set marks NO row, and
        # the sealed constructor's preselect falls to index 0
        # (buildSelectList :101-107) — the I27-era display floor is gone
        # with the I40 boot/switch clamps.
        current = thinking_level || Settings::DEFAULT_THINKING_LEVEL
        default = default_thinking_level
        levels.map do |level|
          description = ModelMenu::LEVEL_DESCRIPTIONS.fetch(level)
          description = "#{description} · default" if default == level
          {value: level, label: level, description:, current: current == level, default: false}
        end
      end

      # The /model selector (pi showModelSelector :5342-5361): the
      # catalog is models.json (the static snapshot — the network
      # refresh is cut, itemized); an empty catalog degenerates to the
      # boot model so ctrl+s set-as-default works out of the box
      # (itemized port extension). +seed+ pre-fills the search (/model
      # <unknown-arg>, pi's initialSearchInput).
      def open_model_menu(seed = nil)
        @mutex.synchronize do
          @menu = ModelMenu.model(
            entries: model_menu_entries, current: current_model_ref, default: default_model_ref, seed:,
            on_select: ->(item) { close_menu; apply_model_selection(item.fetch(:entry), persist: false) },
            on_select_as_default: ->(item) { close_menu; apply_model_selection(item.fetch(:entry), persist: true) }
          )
        end
      end

      # The /model <ref> direct switch (pi handleModelCommand's
      # exact-match path — setModel {persist:false} + the "Model: <id>"
      # status). Public — the dispatcher's callable.
      def switch_model(entry)
        apply_model_selection(entry, persist: false)
      end

      public :open_thinking_menu, :open_model_menu, :switch_model

      private

      # ctrl+s (pi app.models.save / app.thinking.save): the OPEN menu's
      # select-and-persist. The menu closes itself through the callback
      # (pi selectLevel → done()); inert without one.
      def menu_set_as_default
        @menu&.select_as_default
      end

      def close_menu
        @menu = nil
      end

      # pi selectThinkingLevel (:5163-5172): the session level, the
      # footer's re-ladder and the editor border's (the overlays flow
      # through {footer_data}), the status (pi showStatus — the transcript
      # tail row, I33); persist:true reports "Default thinking level" and
      # writes the settings default (ctrl+s). The level rides the AGENT
      # seam too ({Agent::Loop#set_thinking_level}) — the next request
      # carries it (pi sets session state the stream options read).
      def apply_thinking_selection(level, persist:)
        @mutex.synchronize do
          @thinking_level = level
          @transcript_state.enqueue_status("#{persist ? "Default thinking level" : "Thinking level"}: #{level}")
        end
        @agent&.set_thinking_level(level)
        Settings.save(@settings_root, "thinkingLevel" => level) if persist
        @kernel.request_draw
      end

      # The switch seam (pi selectModel → session.setModel { persist }):
      # swap the runtime chat model (the loop re-resolves the context
      # window AND the reasoning facts — Loop#switch_model), refresh the
      # footer model segment + the editor border re-ladder (the runtime
      # overlays flow into {footer_data}), report (pi showStatus — the
      # transcript tail row, I33), and persist the default when asked.
      #
      # I40, pi setModel (agent-session.ts:2477-2496): the switch resolves
      # a level FOR THE SWITCH — _getThinkingLevelForModelSwitch
      # (:2670-2679): the FILE-declared default, else the session level
      # (the per-model tier is a cut — no scoped-models surface; no
      # explicit tier — no argument path) — and setThinkingLevel
      # (:2610-2634) re-clamps it through the SWITCHED model's supported
      # set (Models.clamp_thinking_level's exact-pass branch covers pi's
      # includes-then-clamp). The effective level lands on BOTH the
      # surface state and the loop seam, AFTER switch_model (pi swaps the
      # model first, :2484-2494). NO Thinking level status row: pi's
      # thinking_level_changed only invalidates the footer + border
      # (interactive-mode.ts:3495-3498) — the per-frame {footer_data}
      # overlay carries the refresh. persist:true rides the SAME re-clamp
      # (pi setModel {persist} is one path).
      def apply_model_selection(entry, persist:)
        # The menu and /model paths deliver the typed entry; the direct-
        # switch keyword shape (provider:/id:/... — one positional Hash)
        # rides the struct's own type gate before the seam reads it. The
        # map key is supplied explicitly: the declared-optional attribute
        # still requires its key at construction, and the legacy shape
        # may omit it. compat (I46) rides the same explicit-key shape.
        entry = Shapes::Model.new(**entry,
          thinking_level_map: entry.fetch(:thinking_level_map, nil),
          compat: entry.fetch(:compat, nil)) unless entry.is_a?(Shapes::Model)
        status = persist ? "Default model: #{entry.provider}/#{entry.id}" : "Model: #{entry.id}"
        # The provider key rides the switch as METADATA (the wire model's
        # provider attribute — the dialect rides the model by
        # construction); the window + the composed reasoning facts
        # re-resolve in the loop seam (the entry's flag/map, the known
        # tables when the entry declares none — Settings.thinking_facts).
        facts = Settings.thinking_facts(entry, model_id: entry.id)
        # The cwd resolution is the launcher-facts-else-process idiom the
        # MOTD/commands sections already use (@footer_data[:cwd] || Dir.pwd).
        level = Settings.declared_thinking_level(root: @settings_root,
          cwd: @footer_data&.fetch(:cwd, nil) || Dir.pwd) ||
          (@thinking_level || @footer_data&.fetch(:thinking_level, nil))
        effective = Models.clamp_thinking_level(level, map: facts.thinking_level_map,
          reasoning: facts.reasoning)
        @mutex.synchronize do
          @runtime_model = entry
          @thinking_level = effective
          @transcript_state.enqueue_status(status)
        end
        @agent&.switch_model(entry.id, provider: entry.provider,
          context_window: entry.context_window,
          max_tokens: Models.entry_max_tokens(entry),
          model_reasoning: facts.reasoning,
          thinking_level_map: facts.thinking_level_map,
          compat: entry.compat)
        @agent&.set_thinking_level(effective)
        Settings.save(@settings_root, "defaultProvider" => entry.provider, "defaultModel" => entry.id) if persist
        @kernel.request_draw
      end

      # The menu's catalog: models.json's entries; empty/absent → the
      # boot model alone (the degenerate single-entry menu).
      def model_menu_entries
        catalog = @models&.model_entries
        return catalog if catalog && !catalog.empty?

        [boot_model_entry]
      end

      # The boot entry from the launcher facts (footer_data): the
      # resolved model/provider/window/reasoning/level-map, as the typed
      # Shapes::Model. max_tokens carries none (completeness only — the
      # footer facts hold no such value, Grounds OQ-4); reasoning floors
      # a missing fact to false (today's nil read the same everywhere it
      # was consumed). compat carries none (I46 — the footer facts hold
      # no wire facts; the boot compat threads to the loop directly from
      # the catalog entry, bin/tart's boot kwargs).
      def boot_model_entry
        data = @footer_data || {}
        model = data.fetch(:model, nil) || "no-model"
        Shapes::Model.new(
          provider: data.fetch(:default_provider, "openai"), id: model, name: model,
          reasoning: data[:reasoning] == true, context_window: data[:context_window],
          max_tokens: nil, thinking_level_map: data[:thinking_level_map], compat: nil
        )
      end

      # The ✓ current marker's ref: the runtime switch, else the boot
      # model (footer_data) — cross-resolved against the catalog.
      def current_model_ref
        return @runtime_model if @runtime_model

        boot_model_ref
      end

      # The · default badge's ref: the settings-resolved boot pair —
      # footer_data[:model] stays the boot value (the runtime switch
      # overlays the per-frame view, never these facts).
      def default_model_ref
        boot_model_ref
      end

      # The boot pair's ref, cross-resolved against the catalog (I28 AC4,
      # the I27-verdict residual): an env/Settings boot names the WIRE
      # provider (TART_PROVIDER=openai — a native slug) while the catalog
      # keys the model under a non-native endpoint key (mock) — the ref
      # must match the catalog's key or the ✓/· markers drop. The catalog
      # entry serving the id supplies the matching provider (canonical
      # pair resolve first, then bare id; ambiguity keeps the boot pair).
      # pi needs none of this — its provider keys ARE wire slugs. Port
      # seam, itemized: models.json keys are endpoint configs, the
      # runtime pair is a wire pair.
      def boot_model_ref
        data = @footer_data || {}
        ref = Shapes::ModelRef.new(provider: data.fetch(:default_provider, "openai"),
          id: data.fetch(:model, nil) || "no-model")
        entry = @models&.resolve("#{ref.provider}/#{ref.id}") || @models&.resolve(ref.id.to_s)
        entry ? Shapes::ModelRef.new(provider: entry.provider, id: entry.id) : ref
      end

      # The settings-resolved thinking level (the · default badge) — the
      # UNCLAMPED boot fact when the launcher supplies it (pi badges
      # getDefaultThinkingLevel() ?? DEFAULT raw, thinking-selector.ts
      # :71-72 via interactive-mode.ts:5187 — an out-of-set default marks
      # NO row), the boot level fact otherwise (the pre-I40 footer
      # fixtures), or the built-in default.
      def default_thinking_level
        data = @footer_data || {}
        data.fetch(:default_thinking_level, nil) || data.fetch(:thinking_level, nil) ||
          Settings::DEFAULT_THINKING_LEVEL
      end

      public :set_thinking_level, :cycle_thinking_level, :current_model_ref

      # app.tools.expand (pi setToolsExpanded :6810-6826): the GLOBAL
      # toggle — every expandable block rebuilds collapsed↔expanded in
      # place (the registry sweep; since I33 that includes the MOTD header
      # block + the loaded-resource sections, pi's container sweep
      # :4568-4572), and the status reports as pi's showStatus — a
      # persistent transcript tail row, never the editor border.
      def set_tool_output_expanded(expanded)
        return unless @transcript_state.set_tool_output_expanded(expanded)

        @transcript_state.enqueue_status("Tool output: #{expanded ? "expanded" : "collapsed"}")
        @kernel.request_draw
      end

      public :set_tool_output_expanded, :display_lines
    end
  end
end
