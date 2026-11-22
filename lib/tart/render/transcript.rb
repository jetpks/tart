# frozen_string_literal: true

module Tart
  module Render
    # The transcript/scrollback assembly extracted from the chat surface
    # (I25 wave 5 — pi interactive-mode.ts addMessageToChat +
    # renderInitialSessionEntries over the per-tool component family): the
    # completed-content side of the chat container — the cross-thread
    # scrollback queue (agent fiber produces, frame loop drains), the flat
    # transcript buffer, the ctrl+o expandable registry, and the resume
    # replay through the live-turn shapes. The live streaming region (the
    # reasoning buffer and the in-flight content) and the widget assembly
    # stay on the Chat coordinator; the shared row composition
    # ({markdown_lines}, {panel_markdown_row}, {reasoning_lines}) is pure —
    # class functions, the {Motd}/{Text} wave-1 idiom — so the live region
    # composes the same shapes.
    #
    # Seams (the {UserBash}/{Footer} constructor-injection idiom): the
    # width reader (the enqueue family wraps to the viewport width at
    # base), and the late-bound completion sinks — the editor-history
    # record ({replay_user}'s add_to_history) and the footer usage reseed
    # ({replay_assistant}'s reseed_usage). Unsynchronized by design: the
    # Chat surface owns the mutex, and the class is called from exactly
    # the fibers/threads that touched the state at base (the agent fiber
    # enqueues, the frame loop drains and toggles).
    class Transcript
      # A builder-carrying region riding the scrollback queue: the rows
      # built at the CURRENT toggle state + width, and the builder
      # re-invoked at the CURRENT toggle state by BOTH sweeps (the drain
      # records the transcript range). pi's expandable tool children —
      # and, since I33, the MOTD header block + the loaded-resource
      # sections. I105: +expands+ marks the ctrl+o-participating blocks
      # ({push_expandable} callers — the header/sections/skill/bash/
      # tool-builder/compaction families); plain families ride
      # +expands: false+ (the flip walk skips them, the winch sweep
      # re-invokes them like every registration — the whole-transcript
      # re-wrap, the PARKED I56 divergence closed).
      MarkedRegion = Struct.new(:rows, :builder, :expands)

      # A persistent status waiting for the flush (pi showStatus,
      # interactive-mode.ts:3824-3842): a Spacer(1) + dim one-pad text row
      # at the chat container's tail, a subsequent status REPLACING the
      # text in place while the pair is still the tail. The text wraps at
      # flush time (the live width) — the row count follows pi's Text.
      StatusEntry = Struct.new(:text)

      # The live pending tool-call registration (I34 — pi's pendingTools
      # Map, interactive-mode.ts:3532; I65 D2 re-keys the bookkeeping by
      # the TOOL CALL ID — the I34 single slot SUPERSEDED on every
      # enqueue, orphaning the executor's concurrent batch): the settle
      # payload (the name + args the error finalize re-dispatches), the
      # queued {MarkedRegion} (identity — the drain links it to its
      # expandable registration), and the registration hash once the
      # region reached the buffer.
      PendingTool = Struct.new(:name, :args, :region, :registration)

      # The winch sweep's continuation-slice budget (I108): an INTEGER count
      # of registrations rebuilt per non-window slice — never wall-clock (the
      # I37/I103 owner law; the counter IS the deterministic bound). Default
      # measured at the Grounds §1 bench shape: a registration's rebuild
      # (markdown re-parse + re-wrap) costs ≈0.29–0.35 ms at 7501
      # registrations, so 128 ≈ 41–45 ms of builder work per continuation
      # frame — one render interval at pi's measured ≈22 fps; 7501 stale
      # registrations drain in ≤59 continuation frames after the window
      # pass, and no frame ever pays the old one-shot's O(scrollback) cost.
      DEFAULT_SWEEP_SLICE_BUDGET = 128

      # The tool name that dispatches to pi's shell renderers (bash.ts:115
      # createShellRenderers — shared by bash and powershell; the port
      # runs bash only).
      BASH_TOOL = "bash".freeze

      # The file tools that dispatch to pi's per-tool renderers (I18 —
      # write.ts/read.ts renderCall/renderResult); everything else
      # non-bash keeps the generic ⎿ line (I17's ruling).
      WRITE_TOOL = "write".freeze
      READ_TOOL = "read".freeze

      # The edit tool (I57): pi does NOT render edit through the generic
      # family — it registers the diff-display renderer family
      # (renderers/edit.ts), so edit dispatches to {EditBlock}.
      EDIT_TOOL = "edit".freeze

      # @param width_reader [Proc] +call+ → Integer — the surface's
      #   viewport width ({Chat#viewport_width}): the width the enqueue
      #   family wraps to, read fresh per call (the resize-fresh value).
      # @param history_sink [Proc] +call(text)+ — the editor-history
      #   record on replay (pi renderInitialMessages populateHistory;
      #   late-bound — the editor is the coordinator's).
      # @param reseed_sink [Proc] +call(message)+ — the footer usage
      #   reseed from a replayed assistant entry (late-bound — the footer
      #   is the coordinator's).
      def initialize(width_reader:, history_sink:, reseed_sink:, sweep_slice_budget: DEFAULT_SWEEP_SLICE_BUDGET)
        @width_reader = width_reader
        @history_sink = history_sink
        @reseed_sink = reseed_sink
        # The continuation-slice budget (I108 — the injected counter seam;
        # the Chat constructor kwarg threads through, the accessor lets the
        # pins dial it). nil = the caller asked for the default explicitly.
        @sweep_slice_budget = sweep_slice_budget || DEFAULT_SWEEP_SLICE_BUDGET
        # The winch sweep's pending flag (I108): armed by {mark_sweep_pending}
        # (every registration stale), drained by {sweep_slice} — the frame
        # boundary's gate and the completion observable ({Chat
        # #sweep_pending?} delegates it). Plain flag — same-reactor writes only.
        @sweep_pending = false
        # Completed lines awaiting the transcript buffer on the next frame
        # (I107/Q1 — a plain Array: producer + consumer are fibers on the
        # host reactor, drained each frame as today; the enqueue family's
        # bytes are unchanged).
        @scrollback = []
        # The surface-owned scrollback buffer (final display Lines) — the
        # transcript area draws its visible tail every frame.
        @transcript = []
        # The ctrl+o global tool-output toggle (pi toolOutputExpanded,
        # setToolsExpanded — interactive-mode.ts:6810-6826): every
        # expandable block rebuilds in place; the status row reports
        # (coordinator-side). The expandable registry tracks each block's
        # transcript row range + row builder (recorded at drain time — the
        # scrollback is a same-reactor hand-off Array (I107/Q1), the transcript is flat).
        @tool_output_expanded = false
        @expandable_blocks = []
        # The tail status pair's Line objects (the replace-in-place check
        # — pi's lastStatusSpacer/lastStatusText comparison; identity
        # survives expandable rebuilds above the pair, which shift indexes
        # but never row objects). I105: the pair's registry entry
        # ({@status_registration} — expands: false, the builder re-wraps
        # the retained text) joins the winch sweep, which re-points the
        # pair at the rebuilt rows.
        @status_pair = nil
        @status_registration = nil
        # The live pending tool calls, keyed by the tool call id (I65 D2 —
        # the I34 single slot's registry successor; empty = none mid-flight).
        @pending_tools = {}
        # pi's chat container is a separate component from the header
        # (interactive-mode.ts:633-639); its leading-spacer gate (children
        # non-empty, :3930-3931) reads this — any chat region since the
        # boot/new/resume reset, header excluded.
        @chat_started = false
      end

      # @return [Array] the transcript buffer's display Lines — the
      #   coordinator's readback and live-region composition seam.
      def lines
        @transcript
      end

      # The ctrl+o toggle's state (the coordinator's dispatcher reads it
      # to flip — pi's setToolsExpanded call site).
      attr_reader :tool_output_expanded

      # The continuation-slice budget (I108 — registrations rebuilt per
      # non-window slice; the injected counter seam, never wall-clock).
      attr_accessor :sweep_slice_budget

      # A pre-built region pushed raw (the compaction line's blank, the
      # flushed reasoning rows): no container gate — none of the base call
      # sites rides one. (The MOTD blocks ride {push_expandable} since
      # I33 — they flip.) The drain registers the rows under an IDENTITY
      # builder (I105 — every scrollback item joins the registry; the
      # rows re-derive byte-identically at any width, the sweep no-ops).
      def enqueue_region(lines)
        @scrollback << lines
      end

      # Verbatim completed text (tool output, status): wrapped to
      # the transcript width, one line-level fg. Everything routed here is
      # a chat-container child in pi (tool blocks, chat lines, compaction
      # and status lines), so it arms the leading-spacer gate. I105: the
      # rows close over (text, fg) and re-wrap at the builder's invoked
      # width — the winch sweep re-derives them (the arming stays an
      # enqueue-time side effect).
      def enqueue_scrollback(text, fg:)
        return if text.nil? || text.empty?

        @chat_started = true
        push_plain_region(->(_expanded) { Text.wrap(text, viewport_width).map { |line| TUI.line(line, fg:) } })
      end

      # A completed assistant message as transcript rows (pi
      # assistant-message.ts updateContent): the leading blank every
      # message with visible content opens with (:103-105 — the
      # between-item rule), the joined reasoning block, the blank after a
      # thinking run when content follows (:172-174), then the content.
      # A reasoning-only message gets no trailing blank. The live
      # reasoning buffer is the coordinator's — the completed text threads
      # in (+reasoning:+) at the completion event (I25 extraction seam).
      def enqueue_message(content, reasoning:)
        has_reasoning = !reasoning.empty?
        has_content = !content.nil?
        return unless has_reasoning || has_content

        @chat_started = true
        # ENQUEUE-TIME DECISIONS ARE CAPTURED (I105): the arithmetics
        # below are decided HERE — the between-blank rides has_content
        # (nil-ness), the markdown rows ride the non-empty gate the
        # enqueue path carried — never re-derived at rebuild.
        renders_content = has_content && !content.empty?
        push_plain_region(->(_expanded) do
          rows = [Panel.blank_line]
          # The joined thinking renders as a dim block BEFORE the content
          # (pi assistant-message.ts:99-175 render order). The live
          # reasoning buffer is the text source, not Message#thinking —
          # the loop strips the latter before this event (itemized
          # deviation from the spec's message.thinking.text letter).
          rows.concat(Transcript.reasoning_lines(reasoning, viewport_width)) if has_reasoning
          rows << Panel.blank_line if has_reasoning && has_content
          # Assistant completions render as markdown (AC5).
          rows.concat(Transcript.markdown_lines(content, viewport_width)) if renders_content
          rows
        end)
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
      # write/read their file-tool shapes, edit the diff-display family
      # (I57 — {EditBlock}, fed the per-call details side channel),
      # everything else the generic ⎿ line. Shared by the live and replay
      # paths (I17's shape-sharing ruling); +duration+ is nil on replay
      # (the recorded gap). The finalize replaces the pending block with
      # exactly these rows (same dispatch, same builders) — the settled
      # bytes never moved.
      def enqueue_tool_block(name, args, result, duration, details: nil)
        args = {} unless args.is_a?(Hash)
        builder = tool_block_builder(name, args, result, duration, details)
        @chat_started = true
        if builder
          push_expandable(builder)
        else
          # Every tool block opens with a leading blank (pi
          # tool-execution.ts:85 — the constructor's Spacer), then the
          # bg'd contentText panel (the Box shape over ToolBlock.tool_line).
          # The bg default derivation stays enqueue-time (I105 — it is
          # result-derived, not width-derived; captured, never re-derived).
          bg = Panel.tool_panel_bg(result)
          push_plain_region(->(_expanded) { generic_tool_rows(name, result, bg: bg) })
        end
      end

      # The PENDING tool block's enqueue (I34 — pi renders the running
      # call's block immediately under toolPendingBg: the component
      # constructs at :tool_execution_start with theme.bg("toolPendingBg")
      # and rides the chat container mid-flight, tool-execution.ts:90-91
      # + updateDisplay :271-277 isPartial): the settled family truncated
      # to the call rows ({pending_tool_rows}), pushed through the
      # scrollback queue like any region — order preserved vs queued
      # submissions/statuses, never spliced ahead. The block rides the
      # expandable registry with a CONSTANT-SIZE builder (the pending
      # shape reads no toggle state — a mid-flight ctrl+o rebuilds it
      # identically; the finalize swaps the builder for the real one).
      # A second enqueue while one is live ADDS a registry entry keyed by
      # its call id, never supersedes (pi pendingTools.set — a component
      # per call, interactive-mode.ts:3611-3621; the executor runs the
      # batch concurrently on the reactor, so a batch's ends arrive out
      # of start order and each call settles its OWN block).
      def enqueue_pending_tool_block(id, name, args)
        args = {} unless args.is_a?(Hash)
        @chat_started = true
        # expands: false — the pending shape reads no toggle state (a
        # mid-flight ctrl+o rebuilds it identically at base too); the
        # finalize re-points the registration to the final builder
        # ({replace_flushed_pending}), which joins the flip walk.
        region = MarkedRegion.new(pending_tool_rows(name, args), ->(_expanded) { pending_tool_rows(name, args) }, false)
        @scrollback << region
        @pending_tools[id] = PendingTool.new(name, args, region)
      end

      # The tool end's settle (I34 — pi :tool_execution_end's
      # updateResult GETS THE COMPONENT BY toolCallId and mutates the
      # SAME component in place, never a second block,
      # interactive-mode.ts:3645-3652): the live pending block keyed by
      # the call id is replaced IN PLACE with the rows
      # {enqueue_tool_block} composes — same dispatch, same builders,
      # the toggle state read at replacement time — and the expandable
      # registry re-points to the final block at the updated start. With
      # NO live registration for the id (nil id — reader-less display
      # doubles; the replay path never engages the pending machinery; a
      # post-reset or unknown id) this falls back to today's append.
      def finalize_tool_block(id, name, args, result, duration, details: nil)
        args = {} unless args.is_a?(Hash)
        pending = id && @pending_tools[id]
        return enqueue_tool_block(name, args, result, duration, details:) unless pending

        @pending_tools.delete(id)
        builder = tool_block_builder(name, args, result, duration, details)
        final_rows = builder ? builder.(@tool_output_expanded) : generic_tool_rows(name, result)
        if pending.registration
          replace_flushed_pending(pending.registration, final_rows, builder)
        else
          swap_queued_pending(pending.region, final_rows, builder)
        end
      end

      # The orphaned pending blocks' finalize (I34 — pi's message_end
      # abort/error arm LOOPS pendingTools with updateResult({content:
      # [errorMessage], isError: true}) then clears the map,
      # interactive-mode.ts:3573-3586): EVERY live pending settles as the
      # error block with today's exact bytes (the settle dispatch, no
      # second composition path — the loop runs in START order, Hash
      # insertion order), then the registry clears. An id-less entry
      # (reader-less double) rides the append fallback like its finalize.
      def finalize_pending_as_error(text)
        @pending_tools.keys.each do |id|
          pending = @pending_tools[id]
          finalize_tool_block(id, pending.name, pending.args, {error: text}, nil)
        end
        @pending_tools.clear
      end

      # The compaction panel enqueue (pi addMessageToChat case
      # compactionSummary — the live rebuild and the replay both land
      # here): the case's unconditional Spacer(1), then the panel as an
      # expandable region riding the ctrl+o global state (pi
      # component.setExpanded(this.toolOutputExpanded) on both paths).
      def enqueue_compaction_panel(summary, tokens_before)
        @chat_started = true
        @scrollback << [Panel.blank_line]
        push_expandable(->(expanded) { compaction_panel_rows(summary, tokens_before, expanded) })
      end

      # The custom-message block (I47 — pi CustomMessageComponent,
      # custom-message.ts:41-115, default rendering — memory.ts registers
      # no custom renderer): the component's own Spacer(1), then the Box
      # (customMessageBg, paddingX = outputPad, paddingY 1): the bold
      # [<customType>] label row in customMessageLabel, the Box's inner
      # blank row, the content through the existing markdown path in
      # customMessageText (one-column padded, links render `text (href)`),
      # the Box's bottom blank row. A plain region — the default path
      # never reads the expand state. The Grounds §6 staged-pi capture is
      # the row-shape oracle; the s11 gate is the byte judge.
      def enqueue_custom_block(custom_type, content)
        content = "" unless content.is_a?(String) # malformed-entry tolerance
        @chat_started = true
        bg = Theme[:custom_message_bg]
        push_plain_region(->(_expanded) do
          label = TUI.span("[#{custom_type}]", fg: Theme[:custom_message_label], modifiers: [:bold], bg: bg)
          rows = [Panel.panel_blank_line(viewport_width, bg), # Box paddingY top
                  Panel.padded_spans_row([label], viewport_width, bg),
                  Panel.panel_blank_line(viewport_width, bg)] # the Box's inner Spacer(1)
          rows.concat(Transcript.markdown_lines(content, viewport_width,
            prose_fg: Theme[:custom_message_text], bg: bg))
          rows << Panel.panel_blank_line(viewport_width, bg) # Box paddingY bottom
          [Panel.blank_line, *rows]
        end)
      end

      # The resume replay (item 3, pi renderSessionEntries, interactive-
      # mode.ts :3900-3975): the recorded entries through the live-turn
      # shapes — user echoes, assistant thinking-then-content markdown,
      # tool blocks (the assistant's recorded tool_calls joined to their
      # recorded results), compaction summaries — as the entries carry
      # them. Recorded gaps (itemized, never invented): non-string
      # (multimodal) content is skipped; usage only when the provider
      # reported it. Since I36 the recorded `thinking` REPLAYS as the dim
      # markdown block ({replay_assistant}) — the old
      # strip-thinkings-before-record is gone.
      def replay_entries(entries, update_footer: true, populate_history: true)
        messages = entries.filter_map do |entry|
          next unless entry.is_a?(Hash) && entry["type"] == "message"
          message = entry["message"]
          next unless message.is_a?(Hash) && message["role"] == "tool" && message["tool_call_id"]

          [message["tool_call_id"], message]
        end.to_h
        results = messages.transform_values { |message| message["content"] }
        # The recorded details side channel (I57 — pi records it on the
        # toolResult; the replay re-renders the diff from it). Absent on
        # sessions recorded pre-I57 → the header-only block.
        recorded_details = messages.transform_values { |message| message["details"] }
        entries.each { |entry| replay_entry(entry, results, recorded_details, update_footer:, populate_history:) }
      end

      # Completed lines move into the transcript buffer (pi: completed
      # content into scrollback). Entries are final display Lines — a
      # {MarkedRegion}: an expandable block, whose transcript range is
      # recorded at drain time so the ctrl+o toggle can rebuild it in
      # place (pi setToolsExpanded's child sweep) — or a {StatusEntry}:
      # the replace-or-append status pair. The inline insert_before path
      # is retired from the interactive surface — the buffer is drawn
      # wholesale every frame.
      def flush_scrollback
        until @scrollback.empty?
          item = @scrollback.shift
          case item
          when MarkedRegion
            # stale: false — the rows materialized at the CURRENT width
            # (I108: the flush registers CLEAN; only {mark_sweep_pending}
            # arms staleness, so a mid-sweep enqueue never re-builds).
            registered = {start: @transcript.size, size: item.rows.length,
                          builder: item.builder, expands: item.expands, stale: false}
            @expandable_blocks << registered
            @transcript.concat(item.rows)
            # The pending blocks' drain links EVERY registry entry's
            # flushed region to its registration by region identity (I65
            # D2 — the I34 single-slot link orphaned the batch siblings):
            # the finalize replaces through these registrations.
            @pending_tools.each_value do |pending|
              pending.registration = registered if pending.region.equal?(item)
            end
          when StatusEntry
            flush_status(item.text)
          else
            # Raw rows (the {enqueue_region} legacy callers, the tests'
            # direct pushes — I105): an IDENTITY builder registers with
            # the sweep like every scrollback item; the rows re-derive
            # byte-identically at any width (the sweep's no-op). Bound
            # PER ITEM — the builder must close over this item's rows,
            # not the drain loop's variable.
            rows = item
            registered = {start: @transcript.size, size: rows.length,
                          builder: ->(_expanded) { rows }, expands: false, stale: false}
            @expandable_blocks << registered
            @transcript.concat(rows)
          end
        end
      end

      # A persistent status row (pi showStatus :3824-3842 — the three
      # sites: thinking-level selection, model selection, the tool-output
      # toggle). Never transient, never border chrome.
      def enqueue_status(text)
        return if text.nil? || text.empty?

        @scrollback << StatusEntry.new(text)
      end

      # The ctrl+o toggle's state half (pi setToolsExpanded's child sweep):
      # every EXPANDING block rebuilds collapsed↔expanded in place (I105 —
      # the plain families' builders ignore the toggle state; their ranges
      # still shift with the delta). Blocks register in ascending start
      # order (the drain appends at the tail), so the walk carries the row
      # DELTA: an earlier block's size change shifts every later block's
      # start (the boot header + sections flip exposed the stale-start
      # latent). Returns whether the state changed — the coordinator
      # reports the status row and requests the draw only then (the base
      # gate).
      def set_tool_output_expanded(expanded)
        return false if expanded == @tool_output_expanded

        @tool_output_expanded = expanded
        delta = 0
        @expandable_blocks.each do |registered|
          if registered[:expands]
            start = registered[:start] + delta
            rows = registered[:builder].call(expanded)
            @transcript[start, registered[:size]] = rows
            delta += rows.length - registered[:size]
            registered[:start] = start
            registered[:size] = rows.length
            # The flip rebuilt at the CURRENT width — the block is clean for
            # the pending sweep (I108 §c interleavings: ctrl+o mid-sweep
            # leaves touched registrations clean; the winch mark need not
            # re-invoke them).
            registered[:stale] = false
          else
            registered[:start] += delta # the rows stay; the range moves
          end
        end
        true
      end

      # The winch sweep (I105 — replaces I56's rebuild_live_expandables):
      # re-invoke EVERY registration's builder at the CURRENT toggle state
      # and splice in place — {set_tool_output_expanded}'s arithmetic (the
      # ascending-start walk carrying the row DELTA) without the state
      # flip. The builders' viewport_width reads resolve through the seam
      # (the latch during the resize arm — no width plumbing here). The
      # status pair re-wraps with the sweep and {@status_pair} re-points
      # at the rebuilt rows (the replace-in-place identity check keeps
      # working). Returns whether anything rebuilt — once per winch, never
      # per frame (builders run only at push, drain-materialize, toggle,
      # and winch).
      def rebuild_scrollback
        delta = 0
        rebuilt = false
        @expandable_blocks.each do |registered|
          start = registered[:start] + delta
          rows = registered[:builder].call(@tool_output_expanded)
          @transcript[start, registered[:size]] = rows
          delta += rows.length - registered[:size]
          registered[:start] = start
          registered[:size] = rows.length
          registered[:stale] = false # every registration rebuilt — nothing stale survives
          rebuilt = true
        end
        # The one-shot IS the full drain (I108 — the staged path's byte
        # comparator): no sweep work may survive it.
        @sweep_pending = false
        return rebuilt unless @status_registration

        # The walk rebuilt the pair's range too (expands: false — swept,
        # never flipped): re-point at the rebuilt Line objects (identity —
        # the {status_at_tail?} comparison survives).
        @status_pair = @transcript[@status_registration[:start], @status_registration[:size]]
        rebuilt
      end

      # The winch's mark (I108 §c): EVERY registration goes stale + the
      # pending flag arms — O(registry), zero builder work (the handler's
      # cheap arm; the frame boundary does the building). Idempotent: a
      # drag burst's second winch re-marks without double-charging the
      # builders (the flags are booleans, not work orders yet).
      def mark_sweep_pending
        @expandable_blocks.each { |registered| registered[:stale] = true }
        @sweep_pending = true
        nil
      end

      # The sweep's completion observable (I108 AC3): true while any
      # registration still needs a rebuild — {Chat#sweep_pending?}
      # delegates it, the pins and the self-pumping continuation read it.
      def sweep_pending?
        @sweep_pending
      end

      # ONE bounded sweep pass (I108 §c): {set_tool_output_expanded}'s
      # ascending delta-carrying walk where a registration rebuilds ONLY
      # if stale AND (window nil OR intersecting the window — the first
      # pass); already-clean or out-of-window registrations take the
      # SHIFT-ONLY branch (+start += delta+, builder NOT invoked) — their
      # rows physically moved when earlier splices changed sizes, the
      # walk's own invariant keeps starts/sizes coherent. The +window+ is
      # a Row-index Range over the pre-slice buffer (the coordinator's
      # read-only {Viewport#window} arithmetic); the window pass covers
      # its WHOLE intersecting stale range — bounded by the window rows,
      # never by the budget (AC2's nothing-over-new-width-in-one-frame
      # needs more registrations than any useful budget at real
      # scrollback; the budget bounds the ASCENDING continuation, AC3's
      # +1 slice in the ceil bound IS this window pass). +budget+ bounds
      # the continuation: stale registrations rebuild lowest-start-first
      # until the count is spent; the rest stay stale for the next frame.
      # Returns the count rebuilt (0 when nothing was stale); clears the
      # pending flag when no stale registration remains.
      def sweep_slice(budget:, window: nil)
        delta = 0
        rebuilt = 0
        @expandable_blocks.each do |registered|
          start = registered[:start] + delta
          if registered[:stale] && (window ? window_intersects?(registered, window) : rebuilt < budget)
            rows = registered[:builder].call(@tool_output_expanded)
            @transcript[start, registered[:size]] = rows
            delta += rows.length - registered[:size]
            registered[:start] = start
            registered[:size] = rows.length
            registered[:stale] = false
            rebuilt += 1
          else
            registered[:start] = start # shift-only: rows stay, the range moves
          end
        end
        @sweep_pending = @expandable_blocks.any? { |registered| registered[:stale] }
        repoint_status_pair
        rebuilt
      end

      # The /new + resume shared reset's component half (the coordinator's
      # {Chat#clear_transcript} component reset — the {Footer#reset_usage}
      # I24 precedent): the buffer, the queue, the expandable registry and
      # the status pair drop. The chat container emptied with the
      # transcript (pi renderCurrentSessionState, interactive-mode.ts
      # :2210-2216) — the leading-spacer gate restarts. The ctrl+o toggle
      # state survives (base behavior).
      def reset
        @transcript = []
        @scrollback.clear
        @expandable_blocks.clear
        @pending_tools.clear
        @status_pair = nil
        @status_registration = nil
        @chat_started = false
        @sweep_pending = false # /new mid-sweep: no stale residue (I108 §c)
      end

      # Markdown text as themed display lines (the Render::Markdown
      # converter is read-only — theme colors apply at the span level via
      # {Theme.md_fg}; rows re-wrapped to the content width — pi's
      # Markdown wraps to width minus its paddingX on both sides,
      # markdown.ts:289 — every row through the {OUTPUT_PAD} rule).
      # Shared by the completion path and the live region (item 3: pi
      # re-renders the whole streaming message as markdown on every
      # update — interactive-mode.ts:3519-3535, assistant-message.ts
      # :107-109) — and, since I37, by the reasoning block
      # ({reasoning_lines}).
      #
      # +prose_fg+ recolors the PROSE spans (the panel's custom-text
      # override). +prose_modifiers+ unions modifiers into the same spans
      # (the reasoning default style — pi's defaultTextStyle {color,
      # italic}: applyDefaultStyle reaches the text tokens and the
      # strong/em/del runs, never the themed structure — markdown.ts
      # :382-413/:683-698 vs :477-493/:567-585/:695-697). "Prose" is the
      # CONVERTER's nil-fg vocabulary — plain text, bold/em/del runs,
      # list-item text; every structure span (code/heading/link/quote/
      # list-bullet/code-block — a non-nil fg from Render::Markdown::FG)
      # gains nothing.
      def self.markdown_lines(text, width, prose_fg: nil, bg: nil, prose_modifiers: nil)
        content_width = width - Panel::OUTPUT_PAD.length * 2
        rows = Render::Markdown.rows(text, width: content_width).flat_map { |row| Text.wrap_row(row, content_width) }
        rows.map do |row|
          themed = row.map do |span|
            fg = Theme.md_fg(span.fg)
            modifiers = span.modifiers
            if span.fg.nil?
              fg = prose_fg if prose_fg
              modifiers = (modifiers | prose_modifiers) if prose_modifiers
            end
            Render::Markdown::Span.new(text: span.text, fg:, modifiers:)
          end
          bg ? panel_markdown_row(themed, bg, width) : Panel.padded_row(themed)
        end
      end

      # One markdown row through the {OUTPUT_PAD} rule with the panel bg
      # + tail (the expanded skill panel's content rows —
      # applyBackgroundToLine over the Markdown component).
      def self.panel_markdown_row(spans, bg, width)
        content_width = spans.sum { |span| TUI.text_width(span.text) }
        content = spans.map { |span| TUI.span(span.text, fg: span.fg, modifiers: span.modifiers, bg: bg) }
        TUI.line([TUI.span(Panel::OUTPUT_PAD, bg: bg), *content, Panel.panel_tail(content_width, width, bg)])
      end

      # pi's toLocaleString() comma grouping (compaction-summary-message.ts
      # tokenStr — the en-US form every capture renders): 12345 → "12,345".
      # The footer's {Text.format_tokens} is pi's COMPACT formatTokens — a
      # different format; the panel keeps pi's full grouped form.
      def self.grouped_tokens(count)
        count.to_i.to_s.gsub(/(\d)(?=(\d{3})+$)/, '\\1,')
      end

      # Reasoning text as DIM MARKDOWN (pi assistant-message.ts:99-176:
      # the thinking runs render as a Markdown component over
      # defaultTextStyle {color: thinkingText, italic: true}): the SAME
      # converter as the content, the prose default riding the nil-fg
      # spans ({markdown_lines} +prose_fg+/+prose_modifiers+ — structure
      # keeps its theme fns). Stripped first (pi thinking.trim(),
      # assistant-message.ts:125 — leading/trailing delta whitespace no
      # longer renders blank rows). Shared by all three sites — the live
      # region, the completion, the replay (one path: the settled-shape
      # discipline). The I13 "markdown-of-reasoning is cut" ruling
      # retired (I37 — the owner's live finding is the ruling).
      def self.reasoning_lines(text, width)
        markdown_lines(text.strip, width, prose_fg: Theme[:thinkingText], prose_modifiers: [:italic])
      end

      private

      # The threaded width seam: the surface's viewport width.
      def viewport_width
        @width_reader.call
      end

      # pi showStatus (:3824-3842): a Spacer(1) + dim one-pad text row at
      # the tail — REPLACED in place while that pair is still the tail
      # (the lastStatusSpacer/lastStatusText comparison), else appended.
      # The pair arms the leading-spacer gate: pi's gate reads the chat
      # container's children, and the status children count. I105: the
      # TEXT is retained behind the registration's builder — the winch
      # sweep re-wraps the pair at the new width (replace-or-append
      # semantics unchanged; the rebuilt pair becomes {@status_pair}).
      def flush_status(text)
        builder = ->(_expanded) { status_rows(text) }
        if @status_registration && status_at_tail?
          registration = @status_registration # replaced in place
          @transcript.pop(@status_pair.size)
        else
          # Content followed the pair (no longer the tail): the old rows
          # stay, the fresh pair appends with its own registration.
          registration = {start: 0, size: 0, builder: builder, expands: false, stale: false}
          @expandable_blocks << registration
        end
        rows = status_rows(text)
        registration[:start] = @transcript.size
        registration[:size] = rows.length
        registration[:builder] = builder
        registration[:stale] = false # the pair rebuilt at the CURRENT width (I108)
        @transcript.concat(rows)
        @status_pair = rows
        @status_registration = registration
        @chat_started = true
      end

      # The status pair's rows at the invoked width (a Spacer(1) + the
      # dim one-pad wrapped text — pure function of (text, width), the
      # sweep's re-derivation seam).
      def status_rows(text)
        rows = [Panel.blank_line]
        rows.concat(Text.wrap(text, viewport_width - Panel::OUTPUT_PAD.length * 2).map do |row|
          TUI.line([TUI.span(Panel::OUTPUT_PAD), TUI.span(row, fg: Theme[:dim])])
        end)
        rows
      end

      # Whether the recorded status pair is still the transcript's tail
      # (by Line identity — rebuilds above shift indexes, not objects).
      def status_at_tail?
        pair = @status_pair
        !pair.nil? && pair.size <= @transcript.size &&
          pair.each_with_index.all? { |line, i| @transcript[-pair.size + i].equal?(line) }
      end

      # Whether a registration's row range meets the slice's +window+ (a
      # row-index Range over the PRE-slice buffer — I108: membership is
      # decided against the original start/size, the coordinates the
      # coordinator computed the window over, never against the walk's
      # shifting positions). Endless/beginless ranges tolerated (nil end).
      def window_intersects?(registered, window)
        first = registered[:start]
        last = first + registered[:size] - 1
        from = window.begin
        to = window.end
        to -= 1 if to && window.exclude_end?
        (from.nil? || from <= last) && (to.nil? || first <= to)
      end

      # The pair's post-slice re-point ({rebuild_scrollback}'s tail, one
      # slice at a time): a slice that moved the pair's range (rebuilt it,
      # or shifted its start) must refresh {@status_pair} so the
      # {status_at_tail?} identity check keeps working. Reading the same
      # objects when nothing moved is a no-op.
      def repoint_status_pair
        return unless @status_registration

        @status_pair = @transcript[@status_registration[:start], @status_registration[:size]]
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
        leading_blank = @chat_started # enqueue-time capture (the container's non-empty gate)
        push_plain_region(->(_expanded) do
          region = []
          region << Panel.blank_line if leading_blank
          region << Panel.panel_blank_line(viewport_width, bg) # paddingY top (user-message.ts:23)
          region.concat(Text.wrap(text, viewport_width - Panel::OUTPUT_PAD.length * 2).map do |row|
            TUI.line([TUI.span(Panel::OUTPUT_PAD, bg: bg),
                      TUI.span(row, fg: Theme[:user_message_text], bg: bg),
                      Panel.panel_tail(TUI.text_width(row), viewport_width, bg)])
          end)
          region << Panel.panel_blank_line(viewport_width, bg) # paddingY bottom
          region
        end)
        @chat_started = true
      end

      # The compaction panel rows (pi compaction-summary-message.ts — the
      # skill panel's Box(outputPad, 1, customMessageBg) shape with the
      # label on its own row): the padY top, the bold customMessageLabel
      # [compaction] row, the bg'd inner Spacer(1) (the Box bgs every
      # child line), then the state's content. Collapsed: the three-fg-run
      # hint row — customMessageText "Compacted from N tokens (", the dim
      # ctrl+o key, customMessageText " to expand)". Expanded: the bold
      # markdown header + blank + the summary as customMessageText prose
      # over the panel (the skill panel's markdown machinery).
      # MouseRegion click-to-toggle cut — the standing skill-panel
      # deviation (the port's mouse owns selection).
      def compaction_panel_rows(summary, tokens_before, expanded)
        bg = Theme[:custom_message_bg]
        summary = "" unless summary.is_a?(String) # malformed-entry tolerance
        label = TUI.span("[compaction]", fg: Theme[:custom_message_label], modifiers: [:bold], bg: bg)
        rows = [Panel.panel_blank_line(viewport_width, bg),
                Panel.padded_spans_row([label], viewport_width, bg),
                Panel.panel_blank_line(viewport_width, bg)]
        if expanded
          header = "**Compacted from #{Transcript.grouped_tokens(tokens_before)} tokens**\n\n"
          rows.concat(Transcript.markdown_lines(header + summary, viewport_width,
            prose_fg: Theme[:custom_message_text], bg: bg))
        else
          rows << Panel.padded_spans_row(
            [TUI.span("Compacted from #{Transcript.grouped_tokens(tokens_before)} tokens (",
                      fg: Theme[:custom_message_text], bg: bg),
             TUI.span("ctrl+o", fg: Theme[:dim], bg: bg),
             TUI.span(" to expand)", fg: Theme[:custom_message_text], bg: bg)], viewport_width, bg
          )
        end
        rows << Panel.panel_blank_line(viewport_width, bg)
        rows
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
        rows.concat(Transcript.markdown_lines("**#{block.name}**\n\n#{block.content}", viewport_width,
          prose_fg: Theme[:custom_message_text], bg: bg))
        rows << Panel.panel_blank_line(viewport_width, bg)
        rows
      end

      def replay_entry(entry, results, recorded_details, update_footer:, populate_history:)
        return unless entry.is_a?(Hash)

        case entry["type"]
        when "message"
          message = entry["message"]
          return unless message.is_a?(Hash)

          case message["role"]
          when "user" then replay_user(message, populate_history:)
          when "assistant" then replay_assistant(message, results, recorded_details, update_footer:)
          when "bashExecution" then replay_user_bash(message)
          end
        when "compaction"
          # pi :3903-3904 — Spacer(1), then the panel at its
          # chronological position (renderSessionEntries case
          # compactionSummary, riding the global expand state).
          enqueue_compaction_panel(entry["summary"], entry["tokensBefore"])
        when "custom_message"
          # pi renderSessionEntries' custom_message case (the resume
          # replay renders the recorded recall — pi renders it from the
          # session entries; display-gated like the live path).
          enqueue_custom_block(entry["customType"], entry["content"]) if entry["display"]
        end
      end

      def replay_user(message, populate_history:)
        content = message["content"]
        return unless content.is_a?(String) && !content.strip.empty?

        enqueue_user_submission(content)
        @history_sink.call(content) if populate_history # pi renderInitialMessages populateHistory
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

      def replay_assistant(message, results, recorded_details, update_footer:)
        content = message["content"]
        has_content = content.is_a?(String) && !content.strip.empty?
        reasoning = message["thinking"]
        has_reasoning = reasoning.is_a?(String) && !reasoning.empty?
        tool_calls = message["tool_calls"].is_a?(Hash) ? message["tool_calls"] : {}
        # The failure row's readback (I60 D4 — pi assistant-message.ts
        # :184-198's guard): a recorded finish_reason "error" with a
        # non-empty error_message String. Pre-I60 files (no error_message
        # key — and no "error" finish_reason) read has_error false: the
        # old guard, byte-identical renders.
        error_message = message["error_message"]
        has_error = message["finish_reason"] == "error" && error_message.is_a?(String) &&
                    !error_message.empty?
        return unless has_content || has_reasoning || tool_calls.any? || has_error

        @reseed_sink.call(message) if update_footer
        # pi assistant-message.ts:103-105 — the spacer rides VISIBLE
        # content only (a tool-call-only assistant entry renders no blank
        # of its own; its tool block brings one). I105: the whole prefix
        # region closes over the replay-local decisions (has_content =
        # recorded-String arithmetic, NOT the live path's nil-check —
        # captured, never re-derived) and re-wraps with the sweep (the
        # /resume screens re-wrap).
        if has_content || has_reasoning
          renders_content = has_content && !content.empty?
          push_plain_region(->(_expanded) do
            rows = [Panel.blank_line]
            rows.concat(Transcript.reasoning_lines(reasoning, viewport_width)) if has_reasoning
            rows << Panel.blank_line if has_reasoning && has_content # pi :172-174
            rows.concat(Transcript.markdown_lines(content, viewport_width)) if renders_content
            rows
          end)
        end
        if has_error
          # pi :184-198 — the same component serves live AND replay (the
          # resume renders through renderSessionEntries): Spacer(1), then
          # the pad-led wrapped error-fg row AFTER any partial content —
          # the same region shape the live :message_end arm enqueues (D3).
          fg = Theme[:error]
          push_plain_region(->(_expanded) do
            [Panel.blank_line, *Panel.padded_fg_rows("Error: #{error_message}", viewport_width, fg: fg)]
          end)
        end
        tool_calls.each_value do |call|
          next unless call.is_a?(Hash) && call["name"].is_a?(String)

          # The replay dispatches through the same per-tool shapes (I18):
          # call lines from the recorded arguments, outputs from the
          # recorded results, NO duration — the recorded entries carry
          # none (the frozen contract's replay gap, never invented). The
          # recorded details ride their side channel (I57).
          enqueue_tool_block(call["name"], call["arguments"], results[call["id"]], nil,
                             details: recorded_details[call["id"]])
        end
      end

      # The per-tool final-block BUILDER (pi's per-tool renderers — the
      # dispatch {enqueue_tool_block} and {finalize_tool_block} share,
      # I17/I18's shape-sharing ruling): a lambda re-invoked at the
      # CURRENT toggle state (the expandable registry's builder
      # contract), or nil for the generic family (a plain, non-expandable
      # region — {generic_tool_rows}). bash owns the shell shapes (I17 —
      # carries the duration; the error-result gate rides through so the
      # failed call renders toolErrorBg — the s4 capture, Tools::Bash
      # bash.rb:126), write/read their file-tool shapes (I18 —
      # write_block_rows/read_block_rows' formatWriteResult/formatReadResult
      # paths), edit the diff-display family (I57 — a CONSTANT builder:
      # pi's edit renderers ignore setExpanded, the rebuild is
      # byte-identical), everything else the generic ⎿ line.
      def tool_block_builder(name, args, result, duration, details = nil)
        case name
        when BASH_TOOL
          error = result.is_a?(Hash) && result[:error]
          ->(expanded) { BashBlock.bash_block_rows(args["command"], ToolBlock.tool_result_text(result), duration, viewport_width, expanded:, error:) }
        when WRITE_TOOL
          ->(expanded) { FileBlocks.write_block_rows(args, result, viewport_width, expanded:) }
        when READ_TOOL
          ->(expanded) { FileBlocks.read_block_rows(args, result, viewport_width, expanded:) }
        when EDIT_TOOL
          ->(_expanded) { EditBlock.edit_block_rows(args, result, details, viewport_width) }
        end
      end

      # The PENDING block's rows per family (I34 — pi renders the call
      # rows alone under toolPendingBg while isPartial,
      # tool-execution.ts:271-277): the settled family truncated to the
      # call — Spacer blank (PLAIN), the pending-bg pad, the family's
      # CALL rows, the closing pending-bg pad. No output rows, no Took
      # row, no expand hint — nothing exists to show yet. The edit family
      # renders the header alone (the preview cut, Grounds §6).
      def pending_tool_rows(name, args)
        case name
        when BASH_TOOL then BashBlock.pending_block_rows(args["command"], viewport_width)
        when WRITE_TOOL then FileBlocks.pending_write_block_rows(args, viewport_width)
        when READ_TOOL then FileBlocks.pending_read_block_rows(args, viewport_width)
        when EDIT_TOOL then EditBlock.pending_edit_block_rows(args, viewport_width)
        else generic_tool_rows(name, nil, bg: Theme[:tool_pending_bg])
        end
      end

      # The generic family's plain region (the arm {enqueue_tool_block}
      # composes — the constructor's Spacer, then the bg'd contentText
      # panel); the bg default IS the result-derived panel bg (I57 P1 —
      # the root-cause cure: an absent key used to forward an explicit
      # nil, suppressing generic_panel_rows' identical default and
      # settling every live generic block bg-less while the replay arm
      # painted). The pending arm overrides explicitly; its bytes are
      # unchanged.
      def generic_tool_rows(name, result, bg: Panel.tool_panel_bg(result))
        [Panel.blank_line, *ToolBlock.generic_panel_rows(name, result, viewport_width, bg:)]
      end

      # The FLUSHED pending's in-place replacement (the I33 discipline —
      # the stale-start cure): the final rows splice in at the recorded
      # start, the row DELTA threads to every later registration, and
      # the registration re-points to the final block's builder at the
      # updated start. The generic family rides no builder — its
      # registration drops (the append path registers it nowhere).
      def replace_flushed_pending(registration, final_rows, builder)
        start = registration[:start]
        @transcript[start, registration[:size]] = final_rows
        index = @expandable_blocks.index { |registered| registered.equal?(registration) }
        delta = final_rows.length - registration[:size]
        @expandable_blocks[(index + 1)..]&.each { |registered| registered[:start] += delta }
        if builder
          registration[:start] = start
          registration[:size] = final_rows.length
          registration[:builder] = builder
          registration[:expands] = true # the final family reads the toggle
          registration[:stale] = false  # the final rows built at the CURRENT width (I108)
        else
          @expandable_blocks.delete_at(index)
        end
      end

      # The QUEUED pending's swap: the region still rides the scrollback
      # queue — drain-and-repush under the coordinator's mutex swaps the
      # entry in place, order preserved (the plain region's final block
      # replaces the MarkedRegion; the registry never sees either —
      # matching the append path's generic arm).
      def swap_queued_pending(region, final_rows, builder)
        replacement = builder ? MarkedRegion.new(final_rows, builder, true) : final_rows
        requeue = []
        until @scrollback.empty?
          item = @scrollback.shift
          requeue << (item.equal?(region) ? replacement : item)
        end
        requeue.each { |item| @scrollback << item }
      end

      # The plain-region enqueue (I105): the builder-carrying region whose
      # builder ignores the toggle state — expands: false, the ctrl+o walk
      # skips it while its range still shifts with the delta; the winch
      # sweep re-invokes it like every registration. Public — the
      # coordinator's error-row arm rides it (chat.rb's :message_end
      # family); the plain enqueue families route through it too.
      def push_plain_region(builder)
        @scrollback << MarkedRegion.new(builder.(@tool_output_expanded), builder, false)
      end

      # The expandable-block enqueue: the block rides the scrollback as a
      # {MarkedRegion} (the drain records its transcript range for the
      # ctrl+o toggle's in-place rebuild). Public — the coordinator's MOTD
      # header + resource-section blocks ride the same registry (I33, pi
      # BuiltInHeader/setToolsExpanded's container sweep). I105: the
      # resize_live flag is RETIRED (Grounds S1) — every block sweeps; the
      # expands distinction lives in the registration.
      def push_expandable(builder)
        @scrollback << MarkedRegion.new(builder.(@tool_output_expanded), builder, true)
      end

      public :push_expandable, :push_plain_region
    end
  end
end
