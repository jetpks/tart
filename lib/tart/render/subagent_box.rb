# frozen_string_literal: true

require_relative "text"
require_relative "../theme"

module Tart
  module Render
    # The subagent status box (I79 — pi-subagents' `subagent-async`
    # aboveEditor widget, WIDGET_KEY "subagent-async", render.js:2975): the
    # panel rendered ABOVE the editor while async subagent runs are visible
    # — one row set per frame, composed from the Manager's box-facing
    # snapshot (Law 3), persisted across redraws through the Chat surface's
    # render-key cache (Law 2).
    #
    # The row law is pi's, ported verbatim against the FROZEN oracle
    # fixtures (gems/tui-split-rig/fixtures/subagent-box/, the I79 spec
    # session's tmux captures of the pinned pi 1.1.0 + pi-subagents 0.79.1
    # boot — Grounds): form selection (multi ≥2 visible runs / single),
    # the RUNNING_FRAMES spinner charset + the ● static glyph, the running
    # tone (the child's thinking border color → the main session's →
    # accent, running-tone.js:21-24), the ✓/✗/■ terminal glyphs, the
    # `[fresh]`/`[fork]` context badge (context-mode.js:23-29), the
    # display-layer state map (the disk vocabulary stays the frozen I48
    # schema — the box renders pi's words), the `⎿` activity details
    # (formatActivityLabel + the `thinking…` fallback), the running hint +
    # output rows, `error: <one line>`, formatDuration verbatim
    # (formatters.js:64-70), NEVER a task row (pi's redaction law —
    # compactTaskText filters the redacted marker so no task text exists in
    # any frozen state), and the `+N more` overflow beyond MAX_WIDGET_JOBS.
    #
    # PURE rendering over a snapshot: no IO, no threads, no clock reads of
    # its own — `now` and the 1s `frame` bucket arrive from the caller (the
    # Chat surface derives both from its monotonic clock seam, pi's own
    # time-derived-frame law). Every helper is a module function.
    module SubagentBox
      # pi render.js:158-159 — the spinner charset and the static glyph
      # (the seeded non-animated form).
      RUNNING_FRAMES = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"].freeze
      STATIC_RUNNING_GLYPH = "●"

      # pi types.js MAX_WIDGET_JOBS — the multi form's visible-row bound;
      # beyond it the `+N more (X running, Y finished)` overflow item.
      MAX_WIDGET_JOBS = 4

      # pi async-job-tracker.js:38 completionRetentionMs ?? 10000 — a
      # terminal row stays visible 10s after its flip (the box disappears
      # with the last row).
      RETENTION_MS = 10_000

      # The display-layer state map (Law 3 — render-only): the port's disk
      # vocabulary renders pi's words; the step state follows pi's
      # childState law (result success → complete; failure → failed; the
      # stopped run's failed child still renders "failed" — fixture
      # 11-single-stopped).
      STATE_LABELS = {
        "running" => "running", "completed" => "complete", "failed" => "failed",
        "stopped" => "stopped", "paused" => "paused"
      }.freeze

      module_function

      # The visible rows (Law 2): running runs, plus terminal runs within
      # the 10s retention window anchored at the flip time (ended_at; the
      # lastUpdate fallback covers flips that recorded no endedAt). A
      # terminal row with no timestamps at all is already past any
      # retention it could have had — absent.
      def visible(rows, now)
        rows.select do |row|
          next true if row[:state] == "running"

          retire_at = row[:ended_at] || row[:last_update]
          retire_at && now < retire_at + RETENTION_MS
        end
      end

      # The observable fact key (order-independent): the visible rows'
      # identity + state + attention + flip time + error. The render key
      # adds the 1s glyph frame bucket whenever any visible row runs (the
      # elapsed/age/glyph spans refresh at pi's WIDGET_ANIMATION_INTERVAL_MS
      # cadence — render.js types.js:132), so streaming/scroll/resize never
      # rebuild the row set without an observable change.
      def stable_key(rows)
        rows.map do |row|
          [row[:id].to_s, row[:state], row[:attention] ? 1 : 0, row[:ended_at], row[:error].to_s]
        end.sort
      end

      def render_key(rows, now)
        vis = visible(rows, now)
        bucket = vis.any? { |row| row[:state] == "running" } ? now / 1000 : nil
        [stable_key(vis), bucket]
      end

      # @return [Array<TUI::Text::Line>] the box's rows for one frame —
      #   empty when no run is visible (the absent box: zero rows).
      # @param rows [Array<Hash>] the Manager snapshot's rows: {id:, agent:,
      #   state:, started_at:, last_update:, ended_at:, model:, context:,
      #   dir:, error:, attention:} (all fields nil-tolerant — historical
      #   dirs without the additive fields render no badge/model).
      # @param now [Integer] monotonic ms — the elapsed/retention clock.
      # @param frame [Integer] the 1s glyph frame bucket.
      # @param main_level [String] the main session's thinking level (the
      #   running tone's fallback read — pi running-tone.js
      #   setMainThinkingLevelSource; the Chat passes its resolved level
      #   with pi's session default "off").
      def render(rows:, now:, frame:, width:, main_level:)
        vis = visible(rows, now)
        return [] if vis.empty?

        # pi renders running first, then the finished tail (the port has no
        # queued state), newest-last within class; the id tiebreak keeps
        # equal-start runs in their creation order (uuidv7 ids are
        # time-ordered, matching pi's insertion order).
        ordered = vis.sort_by { |row| [row[:state] == "running" ? 0 : 1, row[:started_at] || 0, row[:id].to_s] }
        lines = ordered.size == 1 ? single_lines(ordered.first, now:, frame:, main_level:) : multi_lines(ordered, now:, frame:, main_level:)
        lines.map { |line| clip_line(line, width) }
      end

      # --- the multi form (render.js buildWidgetLinesWithProjection :2931) ---

      def multi_lines(rows, now:, frame:, main_level:)
        running = rows.select { |row| row[:state] == "running" }
        header_tone = running.any? ? tone_color(main_level) : Theme[:dim]
        glyph = if running.any?
                  spinner_span(running.first, frame, header_tone)
                else
                  # pi: no running, no queued → the ○ dim header glyph (the
                  # port spawns immediately — no queued state).
                  TUI.span("○", fg: Theme[:dim])
                end
        lines = [TUI.line([TUI.span(" "), glyph, TUI.span(" "),
                           TUI.span("Async agents", fg: header_tone), TUI.span(" "),
                           TUI.span("· background", fg: Theme[:dim])])]
        items = rows.map do |row|
          stats = duration_spans(row, now)
          head = [TUI.span(" "), state_glyph(row, frame, main_level), TUI.span(" "),
                  TUI.span(row[:agent].to_s, modifiers: [:bold]), badge_span(row[:context])]
          head.concat(stats)
          activity = job_activity(row)
          # the detail's own 2-space indent rides branch_lines' separator
          # span (pi: `${dim(cont)} ${detail}` with detail = `  ⎿ …`)
          details = activity.empty? ? [] : [TUI.line([TUI.span("⎿  #{activity}", fg: Theme[:dim])])]
          [head, details]
        end
        append_overflow(items, rows)
        branch_lines(lines, items)
      end

      # The `+N more` overflow (pi render.js :2965-2978): beyond
      # MAX_WIDGET_JOBS the hidden tail collapses into one dim item row.
      # The port has no queued state, so the hidden parts are running and
      # finished only.
      def append_overflow(items, rows)
        hidden = rows.size - MAX_WIDGET_JOBS
        return unless hidden.positive?

        running_hidden = rows[MAX_WIDGET_JOBS..].count { |row| row[:state] == "running" }
        finished_hidden = hidden - running_hidden
        parts = []
        parts << "#{running_hidden} running" if running_hidden.positive?
        parts << "#{finished_hidden} finished" if finished_hidden.positive?
        items.slice!(MAX_WIDGET_JOBS..)
        items << [[TUI.span(" "), TUI.span("+#{hidden} more (#{parts.join(', ')})", fg: Theme[:dim])], []]
      end

      # The branch pass (pi :2980-2994): `├─`/`└─` + one space before each
      # item head; the 3-char continuation (`│  `, or all spaces on the
      # last) + one space + the 2-space detail indent before each detail.
      def branch_lines(lines, items)
        items.each_with_index do |(head, details), index|
          last = index == items.size - 1
          branch = last ? "└─" : "├─"
          continuation = last ? "   " : "│  "
          lines << TUI.line([TUI.span(" "), TUI.span(branch, fg: Theme[:dim]), *head])
          details.each do |detail|
            lines << TUI.line([TUI.span(" "), TUI.span(continuation, fg: Theme[:dim]),
                               TUI.span("   "), *detail.spans])
          end
        end
        lines
      end

      # --- the single form (render.js buildSingleWidgetLines :2342) ---

      def single_lines(row, now:, frame:, main_level:)
        title = [TUI.span(" "),
                 TUI.span("async subagent", fg: Theme[:toolTitle], modifiers: [:bold]),
                 TUI.span(" "), TUI.span("· background", fg: Theme[:dim])]
        lines = [TUI.line(title)]
        # The job-level stats tail (pi widgetStats :1932) rides the
        # uncollapsed summary row; the step row's own stats tail (pi
        # widgetStepStats :2012) is the step's durationMs — written only at
        # the terminal derive, so a running step shows no duration there
        # (fixture 04) while a terminal step does (fixtures 05/08/11).
        job_stats = duration_spans(row, now)
        step_stats = row[:state] == "running" ? [] : job_stats
        if single_collapsed?(row)
          lines << step_line(row, row[:agent].to_s, frame, main_level, step_stats)
        else
          # The uncollapsed shape (error/stop evidence — pi
          # shouldCollapseSingleChildDetails :1085-1093): the job summary
          # row (glyph + name + badge + stats, NO state word) above the
          # `Step 1/1:` step row.
          lines << TUI.line([TUI.span(" "), state_glyph(row, frame, main_level), TUI.span(" "),
                             TUI.span(row[:agent].to_s, modifiers: [:bold]),
                             badge_span(row[:context]), *job_stats])
          lines << step_line(row, "Step 1/1: #{row[:agent]}", frame, main_level, step_stats)
        end
        lines.concat(single_details(row, now))
      end

      # pi shouldCollapseSingleChildDetails (:1085-1093): one child, no
      # detail evidence (error / stop / timeout), and the run's own status
      # agrees with the child's — running→running, complete→complete.
      def single_collapsed?(row)
        return false if row[:error]
        return false if %w[failed stopped].include?(row[:state])

        %w[running completed].include?(row[:state])
      end

      def step_line(row, label, frame, main_level, stats)
        # pi's childState law (stale-run-reconciler.js:80-85): the step
        # state follows the CHILD's result — success → complete, failure →
        # failed, else the run's own state. The port's stop ladder always
        # settles with a failed child (the result records success:false),
        # so a stopped run's step renders "failed" when the error evidence
        # is present (fixture 11) and falls back to the run state without
        # it (legacy tolerance).
        child_state = row[:state] == "stopped" && row[:error] ? "failed" : row[:state]
        state = STATE_LABELS.fetch(child_state, child_state.to_s)
        state_color = state_color(child_state, main_level)
        spans = [TUI.span("   "), step_glyph(row, frame, main_level, child_state), TUI.span(" "),
                 TUI.span(label, modifiers: [:bold]), badge_span(row[:context]),
                 TUI.span(" "), TUI.span("·", fg: Theme[:dim]), TUI.span(" "),
                 TUI.span(state, fg: state_color), model_span(row[:model])]
        spans.concat(stats)
        TUI.line(spans)
      end

      # The step details (pi foregroundStyleWidgetStepLines :2226-2247):
      # the ⎿ activity row, the running hint + output rows, the error row.
      # The activity uses the STEP-level facts (pi widgetStepActivityLine
      # :2012) — the port's child writes none (the named residual), so a
      # running step falls back to `thinking…` unless the run needs
      # attention (the supervisor registry's run-level fact).
      def single_details(row, now)
        details = []
        activity = step_activity(row)
        details << TUI.line([TUI.span("     "), TUI.span("⎿  #{activity}", fg: Theme[:dim])]) unless activity.empty?
        # pi :2239-2241 — the error row rides the step's evidence, before
        # the running hint/output rows.
        details << TUI.line([TUI.span("     "),
                             TUI.span("error: #{one_line(row[:error])}", fg: Theme[:error])]) if row[:error]
        return details unless row[:state] == "running"

        details << TUI.line([TUI.span("     "), TUI.span("Press ctrl+o for live detail", fg: Theme[:accent])])
        if row[:dir]
          details << TUI.line([TUI.span("     "),
                               TUI.span("output: #{shorten_path(File.join(row[:dir], 'runner.stdout.log'))}",
                                        fg: Theme[:dim])])
        end
        details
      end

      # --- shared row pieces ---

      # The run/step glyph (pi widgetStatusGlyph :1172 / widgetStepGlyph
      # :1186): running → the spinner frame in the running tone;
      # completed → ✓ success; failed → ✗ error; stopped/paused → ■
      # warning.
      def state_glyph(row, frame, main_level)
        case row[:state]
        when "running" then spinner_span(row, frame, tone_color(main_level))
        when "completed" then TUI.span("✓", fg: success_color)
        when "failed" then TUI.span("✗", fg: Theme[:error])
        else TUI.span("■", fg: Theme[:warning])
        end
      end

      def step_glyph(row, frame, main_level, child_state = row[:state])
        case child_state
        when "running" then spinner_span(row, frame, tone_color(main_level))
        when "completed", "complete" then TUI.span("✓", fg: success_color)
        when "failed" then TUI.span("✗", fg: Theme[:error])
        else TUI.span("■", fg: Theme[:warning])
        end
      end

      # The spinner span: RUNNING_FRAMES[(seed + frame) % 10] — pi's
      # runningGlyph/animatedSeed (:160-178); the seed rides the run's
      # started_at (stable per run), the frame advances at the 1s cadence.
      def spinner_span(row, frame, tone)
        seed = row[:started_at].to_i.abs
        TUI.span(RUNNING_FRAMES[(seed + frame) % RUNNING_FRAMES.size], fg: tone)
      end

      # The running tone (pi running-tone.js:21-24): the child's thinking
      # border color → the main session's → accent. The level arrives as
      # the record's resolved level, else the caller's main-session read;
      # an unknown token falls back to accent (chat.rb:1843's guard).
      def tone_color(level)
        return Theme[:accent] unless level

        token = :"thinking_#{level}"
        Theme::TOKENS.key?(token) ? Theme[token] : Theme[:accent]
      end

      # pi's theme "success" var is dark.json's green var — the port's
      # table carries it under md_code_block/tool_diff_added (theme.rb is
      # outside this lane's touch set; the value is the frozen
      # 38;2;104;183;141 the fixtures pin).
      def success_color
        Theme[:md_code_block]
      end

      def state_color(state, main_level)
        case state
        when "running" then tone_color(main_level)
        when "completed" then success_color
        when "failed" then Theme[:error]
        else Theme[:warning]
        end
      end

      # The `[fresh]`/`[fork]` badge (pi contextModeBadge :23-29 — the
      # leading space rides the dim span; fork renders warning). nil
      # context (historical dirs) → no badge, never raises.
      def badge_span(context)
        case context
        when "fork" then TUI.span(" [fork]", fg: Theme[:warning])
        when "fresh" then TUI.span(" [fresh]", fg: Theme[:dim])
        else TUI.span("")
        end
      end

      def model_span(model)
        model ? TUI.span(" (#{model})", fg: Theme[:dim]) : TUI.span("")
      end

      # The stats tail (pi widgetStats :1932 / widgetStepStats :2012 — the
      # staged captures carry none of the tool/turn/token live facts, so
      # the honest port renders the duration segment only): running rows
      # show the wall-clock elapsed (the frozen elapsed-honesty decision),
      # terminal rows the flip-derived duration. nil facts → no segment.
      def duration_spans(row, now)
        ms = row[:state] == "running" ? running_elapsed(row, now) : terminal_duration(row)
        return [] if ms.nil?

        [TUI.span(" "), TUI.span("·", fg: Theme[:dim]), TUI.span(" "), TUI.span(format_duration(ms), fg: Theme[:dim])]
      end

      def running_elapsed(row, now)
        return nil unless row[:started_at]

        [0, now - row[:started_at]].max
      end

      def terminal_duration(row)
        return nil unless row[:started_at] && row[:ended_at]

        [0, row[:ended_at] - row[:started_at]].max
      end

      # formatDuration verbatim (pi formatters.js:64-70).
      def format_duration(ms)
        return "#{ms}ms" if ms < 1000
        return "#{(ms / 1000.0).round(1)}s" if ms < 60_000

        "#{ms / 60_000}m#{(ms % 60_000) / 1000}s"
      end

      # formatActivityAge verbatim (pi status-format.js:1-7).
      def format_activity_age(ms)
        return "now" if ms < 1000
        return "#{ms / 1000}s" if ms < 60_000

        "#{ms / 60_000}m"
      end

      # formatActivityLabel verbatim (pi status-format.js:8-24) over the
      # port's run-level facts.
      def format_activity_label(last_activity_at, activity_state, now)
        if last_activity_at.nil?
          return "needs attention" if activity_state == "needs_attention"
          return "active but long-running" if activity_state == "active_long_running"

          return nil
        end
        # pi guards the snapshot (buildLiveStatusLine:757 — the label only
        # computes when BOTH facts exist); a missing snapshot stays nil so
        # the fallback arms (thinking…/skipped detail row) take over — the
        # nil/legacy tolerance never raises.
        return nil if now.nil?

        age = format_activity_age([0, now - last_activity_at].max)
        if activity_state == "needs_attention"
          return "no activity for #{age}"
        end
        if activity_state == "active_long_running"
          activity_age = age == "now" ? "now" : "#{age} ago"
          return "active but long-running · last activity #{activity_age}"
        end
        age == "now" ? "active now" : "active #{age} ago"
      end

      # The multi form's job-level activity (pi widgetActivity :1118 via
      # buildLiveStatusLine :757): the job's derived facts — the age anchor
      # is the run's start, the snapshot its lastUpdate (the frozen Law-1
      # snapshot law). Terminal rows render the frozen "active now" byte:
      # pi's capture shows it (the derive-time flip's age collapses below
      # the 1s floor) and the port pins it at the flip's own endedAt.
      def job_activity(row)
        if row[:state] != "running"
          return format_activity_label(row[:ended_at], nil, row[:ended_at]).to_s
        end

        if row[:attention]
          return format_activity_label(row[:started_at], "needs_attention", row[:last_update]).to_s
        end

        format_activity_label(row[:started_at], nil, row[:last_update]) || "thinking…"
      end

      # The single form's step-level activity (pi widgetStepActivityLine
      # :2012 — the child-written facts the port's schema has none of):
      # running → the attention label when the run needs attention, else
      # the `thinking…` fallback; terminal steps render no activity row.
      def step_activity(row)
        return "" unless row[:state] == "running"

        return format_activity_label(row[:started_at], "needs_attention", row[:last_update]).to_s if row[:attention]

        "thinking…"
      end

      # pi formatters.js:131-137 shortenPath — the HOME contraction.
      def shorten_path(path)
        home = ENV["HOME"]
        return path unless home && path.start_with?(home)

        "~#{path[home.length..]}"
      end

      # pi render.js:230 oneLine — the error row's single-line collapse.
      def one_line(text)
        text.to_s.gsub(/\e\[[0-9;]*m/, "").gsub(/\s+/, " ").strip
      end

      # pi truncLine — clip a composed line to the width (display columns).
      def clip_line(line, width)
        return line if width.nil? || width <= 0

        used = 0
        spans = []
        line.spans.each do |span|
          remaining = width - used
          break if remaining <= 0

          content = span.content
          w = TUI.text_width(content)
          if w <= remaining
            spans << span
            used += w
          else
            spans << clip_span(span, remaining)
            used = width
          end
        end
        spans == line.spans ? line : TUI.line(spans)
      end

      def clip_span(span, remaining)
        chars = span.content.chars
        out = +""
        chars.each do |ch|
          w = TUI.text_width(ch)
          break if w > remaining

          out << ch
          remaining -= w
        end
        TUI.span(out, fg: span.style&.fg, bg: span.style&.bg, modifiers: span.style&.modifiers.to_a)
      end
    end
  end
end