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
      # An expandable block riding the scrollback queue: the rows built at
      # the CURRENT toggle state + the builder (re-invoked with the new
      # state at the ctrl+o toggle; the drain records the transcript
      # range). pi's expandable tool children — and, since I33, the MOTD
      # header block + the loaded-resource sections.
      MarkedRegion = Struct.new(:rows, :builder)

      # A persistent status waiting for the flush (pi showStatus,
      # interactive-mode.ts:3824-3842): a Spacer(1) + dim one-pad text row
      # at the chat container's tail, a subsequent status REPLACING the
      # text in place while the pair is still the tail. The text wraps at
      # flush time (the live width) — the row count follows pi's Text.
      StatusEntry = Struct.new(:text)

      # The tool name that dispatches to pi's shell renderers (bash.ts:115
      # createShellRenderers — shared by bash and powershell; the port
      # runs bash only).
      BASH_TOOL = "bash".freeze

      # The file tools that dispatch to pi's per-tool renderers (I18 —
      # write.ts/read.ts renderCall/renderResult); everything else
      # non-bash keeps the generic ⎿ line (I17's ruling).
      WRITE_TOOL = "write".freeze
      READ_TOOL = "read".freeze

      # @param width_reader [Proc] +call+ → Integer — the surface's
      #   viewport width ({Chat#viewport_width}): the width the enqueue
      #   family wraps to, read fresh per call (the resize-fresh value).
      # @param history_sink [Proc] +call(text)+ — the editor-history
      #   record on replay (pi renderInitialMessages populateHistory;
      #   late-bound — the editor is the coordinator's).
      # @param reseed_sink [Proc] +call(message)+ — the footer usage
      #   reseed from a replayed assistant entry (late-bound — the footer
      #   is the coordinator's).
      def initialize(width_reader:, history_sink:, reseed_sink:)
        @width_reader = width_reader
        @history_sink = history_sink
        @reseed_sink = reseed_sink
        # Completed lines awaiting the transcript buffer on the next frame
        # (thread-safe: agent fiber produces, frame loop consumes).
        @scrollback = Queue.new
        # The surface-owned scrollback buffer (final display Lines) — the
        # transcript area draws its visible tail every frame.
        @transcript = []
        # The ctrl+o global tool-output toggle (pi toolOutputExpanded,
        # setToolsExpanded — interactive-mode.ts:6810-6826): every
        # expandable block rebuilds in place; the status row reports
        # (coordinator-side). The expandable registry tracks each block's
        # transcript row range + row builder (recorded at drain time — the
        # scrollback is a cross-thread queue, the transcript is flat).
        @tool_output_expanded = false
        @expandable_blocks = []
        # The tail status pair's Line objects (the replace-in-place check
        # — pi's lastStatusSpacer/lastStatusText comparison; identity
        # survives expandable rebuilds above the pair, which shift indexes
        # but never row objects).
        @status_pair = nil
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

      # A pre-built region pushed raw (the compaction line's blank, the
      # flushed reasoning rows): no container gate — none of the base call
      # sites rides one. (The MOTD blocks ride {push_expandable} since
      # I33 — they flip.)
      def enqueue_region(lines)
        @scrollback << lines
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
        @scrollback << [Panel.blank_line]
        # The joined thinking renders as a dim block BEFORE the content
        # (pi assistant-message.ts:99-175 render order). The live
        # reasoning buffer is the text source, not Message#thinking —
        # the loop strips the latter before this event (itemized
        # deviation from the spec's message.thinking.text letter).
        @scrollback << Transcript.reasoning_lines(reasoning, viewport_width) if has_reasoning
        if has_content
          # Assistant completions render as markdown (AC5).
          @scrollback << [Panel.blank_line] if has_reasoning
          enqueue_markdown(content)
        end
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

      # The resume replay (item 3, pi renderSessionEntries, interactive-
      # mode.ts :3900-3975): the recorded entries through the live-turn
      # shapes — user echoes, assistant thinking-then-content markdown,
      # tool blocks (the assistant's recorded tool_calls joined to their
      # recorded results), compaction summaries — as the entries carry
      # them. Recorded gaps (itemized, never invented): thinking is
      # stripped before record (agent/loop.rb strip_thinking_replay), so no
      # reasoning block replays; non-string (multimodal) content is
      # skipped; usage only when the provider reported it.
      def replay_entries(entries, update_footer: true, populate_history: true)
        results = entries.filter_map do |entry|
          next unless entry.is_a?(Hash) && entry["type"] == "message"
          message = entry["message"]
          next unless message.is_a?(Hash) && message["role"] == "tool" && message["tool_call_id"]

          [message["tool_call_id"], message["content"]]
        end.to_h
        entries.each { |entry| replay_entry(entry, results, update_footer:, populate_history:) }
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
          item = @scrollback.pop
          case item
          when MarkedRegion
            @expandable_blocks << {start: @transcript.size, size: item.rows.length,
                                   builder: item.builder}
            @transcript.concat(item.rows)
          when StatusEntry
            flush_status(item.text)
          else
            @transcript.concat(item)
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
      # every registered block rebuilds collapsed↔expanded in place.
      # Blocks register in ascending start order (the drain appends at the
      # tail), so the walk carries the row DELTA: an earlier block's size
      # change shifts every later block's start (the boot header +
      # sections flip exposed the stale-start latent). Returns whether the
      # state changed — the coordinator reports the status row and
      # requests the draw only then (the base gate).
      def set_tool_output_expanded(expanded)
        return false if expanded == @tool_output_expanded

        @tool_output_expanded = expanded
        delta = 0
        @expandable_blocks.each do |registered|
          start = registered[:start] + delta
          rows = registered[:builder].call(expanded)
          @transcript[start, registered[:size]] = rows
          delta += rows.length - registered[:size]
          registered[:start] = start
          registered[:size] = rows.length
        end
        true
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
        @status_pair = nil
        @chat_started = false
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
      def self.markdown_lines(text, width, prose_fg: nil, bg: nil)
        content_width = width - Panel::OUTPUT_PAD.length * 2
        rows = Render::Markdown.rows(text, width: content_width).flat_map { |row| Text.wrap_row(row, content_width) }
        rows.map do |row|
          themed = row.map do |span|
            fg = Theme.md_fg(span.fg)
            fg = prose_fg if fg.nil? && prose_fg # the panel's prose-color override
            Render::Markdown::Span.new(text: span.text, fg:, modifiers: span.modifiers)
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

      # Reasoning text as dim italic display lines (pi assistant-message.ts
      # :140-150: thinkingText fg, italic; markdown-of-reasoning is cut,
      # plain dim text — itemized reduction).
      def self.reasoning_lines(text, width)
        Text.wrap(text, width - Panel::OUTPUT_PAD.length * 2).map { |line| TUI.line([TUI.span(Panel::OUTPUT_PAD), TUI.span(line, fg: Theme[:thinkingText], modifiers: [:italic])]) }
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
      # container's children, and the status children count.
      def flush_status(text)
        rows = [Panel.blank_line]
        rows.concat(Text.wrap(text, viewport_width - Panel::OUTPUT_PAD.length * 2).map do |row|
          TUI.line([TUI.span(Panel::OUTPUT_PAD), TUI.span(row, fg: Theme[:dim])])
        end)
        @transcript.pop(@status_pair.size) if status_at_tail?
        @transcript.concat(rows)
        @status_pair = rows
        @chat_started = true
      end

      # Whether the recorded status pair is still the transcript's tail
      # (by Line identity — rebuilds above shift indexes, not objects).
      def status_at_tail?
        pair = @status_pair
        !pair.nil? && pair.size <= @transcript.size &&
          pair.each_with_index.all? { |line, i| @transcript[-pair.size + i].equal?(line) }
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

      def replay_entry(entry, results, update_footer:, populate_history:)
        return unless entry.is_a?(Hash)

        case entry["type"]
        when "message"
          message = entry["message"]
          return unless message.is_a?(Hash)

          case message["role"]
          when "user" then replay_user(message, populate_history:)
          when "assistant" then replay_assistant(message, results, update_footer:)
          when "bashExecution" then replay_user_bash(message)
          end
        when "compaction"
          # pi :3903-3904 — Spacer(1), then the panel at its
          # chronological position (renderSessionEntries case
          # compactionSummary, riding the global expand state).
          enqueue_compaction_panel(entry["summary"], entry["tokensBefore"])
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

      def replay_assistant(message, results, update_footer:)
        content = message["content"]
        has_content = content.is_a?(String) && !content.strip.empty?
        reasoning = message["thinking"]
        has_reasoning = reasoning.is_a?(String) && !reasoning.empty?
        tool_calls = message["tool_calls"].is_a?(Hash) ? message["tool_calls"] : {}
        return unless has_content || has_reasoning || tool_calls.any?

        @reseed_sink.call(message) if update_footer
        # pi assistant-message.ts:103-105 — the spacer rides VISIBLE
        # content only (a tool-call-only assistant entry renders no blank
        # of its own; its tool block brings one).
        @scrollback << [Panel.blank_line] if has_content || has_reasoning
        if has_reasoning
          @scrollback << Transcript.reasoning_lines(reasoning, viewport_width)
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

      # Assistant completions render through the markdown converter (AC5):
      # styled rows wrapped to the transcript width, every span's fg routed
      # through the theme (AC3), then converted row → Line at the TUI seam.
      def enqueue_markdown(text)
        return if text.nil? || text.empty?

        @scrollback << Transcript.markdown_lines(text, viewport_width)
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
      # ctrl+o toggle's in-place rebuild). Public — the coordinator's MOTD
      # header + resource-section blocks ride the same registry (I33, pi
      # BuiltInHeader/setToolsExpanded's container sweep).
      def push_expandable(builder)
        @scrollback << MarkedRegion.new(builder.(@tool_output_expanded), builder)
      end

      public :push_expandable

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
    end
  end
end
