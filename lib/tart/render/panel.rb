# frozen_string_literal: true

module Tart
  module Render
    # Pure panel-row composition extracted from the chat surface (I21
    # wave 1): the render-box pad rule, the bg tail, and the row shapes
    # every tool-block family shares. Module functions: no ivar access,
    # no Chat dependency — the viewport width is threaded by the caller.
    module Panel
      # The render-box paddingX cell (pi tool-execution.ts:87 paddingX —
      # one pad cell, content wrapped to width minus both pads).
      OUTPUT_PAD = " ".freeze

      module_function

      # A plain blank scrollback row.
      def blank_line
        TUI.line("")
      end

      # The bg panel's trailing fill: bg-styled spaces from the row's
      # content end to the viewport's right edge (pi markdown.ts:352
      # applyBackgroundToLine — the bg rides the FULL row width; the -e
      # capture trims trailing cells, a real terminal doesn't).
      def panel_tail(content_width, width, bg)
        TUI.span(" " * [width - OUTPUT_PAD.length - content_width, 0].max, bg: bg)
      end

      # A full-width bg blank row (the Box paddingY rows over the panel bg).
      def panel_blank_line(width, bg)
        TUI.line([TUI.span(" " * width, bg: bg)])
      end

      # One content row with the {OUTPUT_PAD} leading the spans (pi's
      # Markdown paddingX — the pad renders unstyled before the row).
      def padded_row(spans)
        TUI.markdown_line([Render::Markdown::Span.new(text: OUTPUT_PAD)] + spans)
      end

      # One row of pre-built spans through the {OUTPUT_PAD} rule with the
      # panel bg + tail (the multi-span analog of {padded_fg_rows}'s
      # single-span row).
      def padded_spans_row(spans, width, bg)
        content_width = spans.sum { |span| TUI.text_width(span.content) }
        TUI.line([TUI.span(OUTPUT_PAD, bg: bg), *spans, panel_tail(content_width, width, bg)])
      end

      # Wrapped themed rows through the {OUTPUT_PAD} rule (pi's render-box
      # paddingX, tool-execution.ts:87 — one pad cell, content wrapped to
      # width minus both pads).
      def padded_fg_rows(text, width, fg:, modifiers: [], bg: nil)
        Text.wrap(text, width - OUTPUT_PAD.length * 2).map do |row|
          spans = [TUI.span(OUTPUT_PAD, bg: bg), TUI.span(row, fg:, modifiers:, bg: bg)]
          spans << panel_tail(TUI.text_width(row), width, bg) if bg
          TUI.line(spans)
        end
      end

      # The expand-hint row family (pi keybinding-hints.ts keyHint over the
      # muted count prefix — write.ts:117-118, bash.ts:82-84,
      # bash-execution.ts:146 + the collapse variant): muted prefix, the
      # gap (keyHint composes `prefix${keyText}` with NO space in the
      # user-bash shapes), dim key, muted tail.
      def expand_hint_row(prefix, width, gap: " ", tail: " to expand)", bg: nil)
        spans = [TUI.span(OUTPUT_PAD, bg: bg),
                 TUI.span(prefix, fg: Theme[:muted], bg: bg),
                 TUI.span(gap, bg: bg),
                 TUI.span("ctrl+o", fg: Theme[:dim], bg: bg),
                 TUI.span(tail, fg: Theme[:muted], bg: bg)]
        if bg
          hint_width = TUI.text_width(prefix) + TUI.text_width(gap) +
                       TUI.text_width("ctrl+o") + TUI.text_width(tail)
          spans << panel_tail(hint_width, width, bg)
        end
        TUI.line(spans)
      end

      # The tool-block panel bg (tool-execution.ts:272-275): an error
      # result renders toolErrorBg, the rest toolSuccessBg (the pending
      # bg never reaches the scrollback — the port's blocks enqueue at
      # completion).
      def tool_panel_bg(result)
        result.is_a?(Hash) && result[:error] ? Theme[:tool_error_bg] : Theme[:tool_success_bg]
      end
    end
  end
end
