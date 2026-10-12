# frozen_string_literal: true

module Tart
  module Render
    # The bash tool-block and user-bash display builders extracted from
    # the chat surface (I21 wave 1 — pi's shell renderers over the
    # tool-turn component, renderers/bash.ts; the !-prefix BashExecution
    # display, bash-execution.ts). Execution state stays in Chat; these
    # are the row builders. Module functions: no ivar access, no Chat
    # dependency — the viewport width is threaded by the caller.
    module BashBlock
      # pi bash.ts:14 (BASH_PREVIEW_LINES): at most this many visual rows
      # of shell output render unexpanded, then the earlier-lines hint.
      BASH_PREVIEW_LINES = 5

      USER_BASH_PREVIEW_LINES = 20 # pi bash-execution.ts:19 PREVIEW_LINES

      module_function

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
      # component), +expanded+ = pi's toolOutputExpanded state: the output
      # renders whole (no collapse, no hint — bash.ts:67-70 `if
      # (options.expanded) addChild(Text)` vs the VisualLinePreview); the
      # notice + Took compose identically in both states.
      def bash_block_rows(command, output, duration, width, expanded:, error: false)
        # The Box(1,1) panel (tool-execution.ts:90): the Spacer blank
        # stays PLAIN, every row after rides the result bg (an isError
        # result renders toolErrorBg — tool-execution.ts:272-275).
        bg = error ? Theme[:tool_error_bg] : Theme[:tool_success_bg]
        region = [Panel.blank_line, Panel.panel_blank_line(width, bg)]
        # pi formatShellCall (renderers/bash.ts:41-44): the header is
        # toolTitle bold — NOT bashMode (that token is the user-bash !
        # block's header; the old bashMode pin was the system-theme
        # artifact).
        region.concat(Panel.padded_fg_rows("$ #{command.to_s.empty? ? "..." : command}",
          width, fg: Theme[:toolTitle], modifiers: [:bold], bg: bg))
        body, notice = split_truncation_notice(output)
        unless body.empty?
          region << Panel.panel_blank_line(width, bg)
          rows = Panel.padded_fg_rows(body, width, fg: Theme[:tool_output], bg: bg)
          region.concat(expanded ? rows : collapse_bash_preview(rows, width, bg: bg))
        end
        unless notice.empty?
          region << Panel.panel_blank_line(width, bg)
          # pi bash.ts:88-99 — the truncation notice renders the warning fg
          # (theme.fg("warning", `[...]`)), not the inherited tool_output
          # (the I19 carry-forward, AC6), composed as pi's DISPLAY warnings
          # ({display_truncation_notice}).
          region.concat(Panel.padded_fg_rows(display_truncation_notice(notice), width, fg: Theme[:warning], bg: bg))
        end
        if duration
          region << Panel.panel_blank_line(width, bg)
          region.concat(Panel.padded_fg_rows("Took #{format_duration(duration * 1000.0)}", width, fg: Theme[:tool_output], bg: bg))
        end
        region << Panel.panel_blank_line(width, bg)
        region
      end

      # pi renderers/bash.ts:88-99 — the DISPLAYED notice is composed from
      # the tool's truncation details: `[Full output: <path>. Truncated: …]`
      # — the warnings joined on ONE line, path FIRST. The model-facing
      # footer the render layer receives (bash.ts:348-352, port
      # format_output) composes differently ("[Showing lines …]"), so the
      # display parses the footer's shape (the {split_truncation_notice}
      # guard) and recomposes pi's warnings. The lines and bytes variants
      # recover every field the warnings carry; the partial-line footer
      # ("Showing last …") carries no output-line count — it renders
      # as-is (itemized residual).
      def display_truncation_notice(footer)
        lines = footer.match(/\A\[Showing lines (\d+)-(\d+) of (\d+)\. Full output: (.+)\]\z/)
        bytes = footer.match(/\A\[Showing lines (\d+)-(\d+) of (\d+) \(([^)]+) limit\)\. Full output: (.+)\]\z/)
        if lines
          "[Full output: #{lines[4]}. Truncated: showing #{lines[2].to_i - lines[1].to_i + 1} of #{lines[3]} lines]"
        elsif bytes
          "[Full output: #{bytes[5]}. Truncated: #{bytes[2].to_i - bytes[1].to_i + 1} lines shown (#{bytes[4]} limit)]"
        else
          footer
        end
      end

      # pi bash.ts:63-71 — the preview trims the output, and the model-
      # facing truncation footer ("…\n\n[… Full output: <path>]") splits
      # OFF the preview: the body collapses, the notice renders after it.
      # pi guards on the tool's truncation details; the render layer sees
      # only the result text, so the guard is the footer's shape itself
      # (recorded — see the I19 report).
      def split_truncation_notice(output)
        text = output.strip
        footer_start = text.rindex("\n\n[")
        return [text, ""] unless footer_start && text.end_with?("]") &&
          text[footer_start..].include?("Full output: ")

        [text[0, footer_start].strip, text[(footer_start + 2)..]]
      end

      # pi bash.ts:78-90 + visual-truncate.ts VisualLinePreview (keep
      # "end"): more than BASH_PREVIEW_LINES visual rows renders the
      # muted earlier-lines hint row before the LAST 5 (wrapped rows —
      # a long line spanning the screen counts like pi's); 5 or fewer
      # render whole. Presentation-only: the model sees the full output
      # (the tools' tail truncation is upstream and composes after).
      def collapse_bash_preview(rows, width, bg: nil)
        return rows if rows.length <= BASH_PREVIEW_LINES

        [Panel.expand_hint_row("... (#{rows.length - BASH_PREVIEW_LINES} earlier lines,", width, bg: bg),
          *rows.last(BASH_PREVIEW_LINES)]
      end

      # The !-prefix bash block (pi BashExecutionComponent, backlog C),
      # +expanded+ = pi's toolOutputExpanded: the output renders WHOLE
      # (all tail-truncated lines — bash-execution.ts:104-108) and the
      # hidden-hint row becomes the collapse hint (statusParts' expanded
      # branch). The borders, header, and other status rows are
      # state-invariant.
      def user_bash_block_rows(command, width, content:, exit_code:, cancelled:, truncated:,
                               full_output_path:, excluded:, expanded:)
        color = excluded ? Theme[:dim] : Theme[:bashMode]
        region = [Panel.blank_line, TUI.line([TUI.span("─" * width, fg: color)])]
        region.concat(Panel.padded_fg_rows("$ #{command}", width, fg: color, modifiers: [:bold]))
        available = content.empty? ? [] : content.split("\n", -1)
        unless available.empty?
          region << Panel.blank_line
          shown = expanded ? available : available.last(USER_BASH_PREVIEW_LINES)
          visual = Panel.padded_fg_rows(shown.join("\n"), width, fg: Theme[:muted])
          region.concat(expanded ? visual : visual.last(USER_BASH_PREVIEW_LINES))
        end
        hidden_logical = available.length - available.last(USER_BASH_PREVIEW_LINES).length
        status = user_bash_status_rows(width, exit_code:, cancelled:, truncated:,
                                       full_output_path:, hidden_logical:, expanded:)
        unless status.empty?
          region << Panel.blank_line
          region.concat(status)
        end
        region << TUI.line([TUI.span("─" * width, fg: color)])
        region
      end

      # The status rows (pi statusParts order: hidden-hint, cancelled/
      # exit, truncation warning).
      def user_bash_status_rows(width, exit_code:, cancelled:, truncated:, full_output_path:, hidden_logical:, expanded:)
        rows = []
        if hidden_logical.positive?
          rows << if expanded
            Panel.expand_hint_row("(", width, gap: "", tail: " to collapse)")
          else
            Panel.expand_hint_row("... #{hidden_logical} more lines (", width, gap: "")
          end
        end
        rows.concat(Panel.padded_fg_rows("(cancelled)", width, fg: Theme[:warning])) if cancelled
        if !cancelled && exit_code.is_a?(Integer) && exit_code != 0
          rows.concat(Panel.padded_fg_rows("(exit #{exit_code})", width, fg: Theme[:error]))
        end
        if truncated && full_output_path
          rows.concat(Panel.padded_fg_rows("Output truncated. Full output: #{full_output_path}", width, fg: Theme[:warning]))
        end
        rows
      end
    end
  end
end
