# frozen_string_literal: true

module Tart
  module Render
    # The generic (non-bash, non-file) tool-block builders extracted from
    # the chat surface (I21 wave 1 — the ⎿ preview line and the
    # contentText panel, tool-execution.ts:85-92). Module functions: no
    # ivar access, no Chat dependency — the viewport width is threaded by
    # the caller.
    module ToolBlock
      # Bounded multi-line tool-result preview: at most this many content
      # lines, then an ellipsis row (pi truncates tool output previews).
      TOOL_PREVIEW_LINES = 3

      module_function

      # The result's text (tool-execution.ts getTextOutput shape): a result
      # Hash carries :content or :error, recorded entries carry the string
      # content itself.
      def tool_result_text(result)
        result.is_a?(Hash) ? (result[:error] || result[:content] || "").to_s : result.to_s
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

      # The generic no-renderer tool block (edit/grep/ls/find): the
      # contentText panel (tool-execution.ts:90-92 — Text over the result
      # bg) around {tool_line}'s preview, full-width bg rows; the port's
      # I17 wrap geometry (viewport width, tool_line's own indent) stands —
      # unmeasured by any scenario, the bg is the pi-source carry. +bg:+
      # overrides the result-derived bg (I34 — the PENDING shape rides
      # Theme[:tool_pending_bg] while the call runs, result nil).
      def generic_panel_rows(name, result, width, bg: Panel.tool_panel_bg(result))
        region = [Panel.panel_blank_line(width, bg)]
        Text.wrap(tool_line(name, result), width).each do |row|
          fill = [width - TUI.text_width(row), 0].max
          region << TUI.line([TUI.span(row, fg: Theme[:tool_output], bg: bg),
                              TUI.span(" " * fill, bg: bg)])
        end
        region << Panel.panel_blank_line(width, bg)
        region
      end
    end
  end
end
