# frozen_string_literal: true

module Tart
  module Render
    # The write/read file-tool block builders extracted from the chat
    # surface (I21 wave 1 — pi write.ts/read.ts renderers over the
    # tool-turn component). Module functions: no ivar access, no Chat
    # dependency — the viewport width is threaded by the caller.
    module FileBlocks
      # pi write.ts:113 (formatWriteCall): at most this many content lines
      # render unexpanded, then the expand hint.
      WRITE_PREVIEW_LINES = 10

      # pi read.ts:56 (COMPACT_RESOURCE_FILE_NAMES) — the file names whose
      # read collapses to the compact `read resource` shape.
      COMPACT_RESOURCE_FILE_NAMES = ["AGENTS.override.md", "AGENTS.md", "AGENTS.MD", "CLAUDE.md", "CLAUDE.MD"].freeze

      module_function

      # The write tool block (I18 — pi write.ts renderers), +expanded+ =
      # the content preview uncapped (write.ts:117 maxLines = expanded ?
      # lines.length : 10 — the hint dies with the cap).
      def write_block_rows(args, result, width, expanded:)
        bg = Panel.tool_panel_bg(result)
        region = [Panel.blank_line, Panel.panel_blank_line(width, bg)]
        region.concat(write_call_rows(args, width, bg:))
        content_rows = write_content_rows(args, width, expanded:, bg:)
        unless content_rows.empty?
          region << Panel.panel_blank_line(width, bg)
          region.concat(content_rows)
        end
        error = result.is_a?(Hash) ? result[:error] : nil
        if error
          region << Panel.panel_blank_line(width, bg)
          region.concat(Panel.padded_fg_rows(error.to_s, width, fg: Theme[:error], bg: bg))
        end
        region << Panel.panel_blank_line(width, bg)
        region
      end

      # The read tool block (I18 — pi read.ts renderers), +expanded+ =
      # pi's toolOutputExpanded: the PLAIN call line forces over the
      # compact shape (read.ts:155 — getCompactReadClassification is
      # gated on !expanded) and the result content renders as toolOutput
      # rows, uncapped (formatReadResult:130 — maxLines = expanded ?
      # lines.length : 10; trailing-empty lines trimmed). The error text
      # renders in both states.
      def read_block_rows(args, result, width, expanded:)
        bg = Panel.tool_panel_bg(result)
        region = [Panel.blank_line, Panel.panel_blank_line(width, bg)]
        region.concat(read_call_rows(args, width, expanded, bg:))
        error = result.is_a?(Hash) ? result[:error] : nil
        rows = if error
          Panel.padded_fg_rows(error.to_s, width, fg: Theme[:tool_output], bg: bg)
        elsif expanded
          read_content_rows(result, width, bg:)
        else
          []
        end
        unless rows.empty?
          region << Panel.panel_blank_line(width, bg)
          region.concat(rows)
        end
        region << Panel.panel_blank_line(width, bg)
        region
      end

      # pi read.ts:122-131 formatReadResult's expanded body: the result
      # text (trailing-empty lines trimmed) as toolOutput rows, uncapped.
      def read_content_rows(result, width, bg: nil)
        lines = ToolBlock.tool_result_text(result).split("\n", -1)
        lines.pop while !lines.empty? && lines.last.empty?
        return [] if lines.empty?

        Panel.padded_fg_rows(lines.join("\n"), width, fg: Theme[:tool_output], bg: bg)
      end

      # pi write.ts:99-100 — the bold toolTitle `write` header + the
      # renderToolPath display (accent token), wrapped through the
      # call-row family ({wrapped_call_rows}).
      def write_call_rows(args, width, bg: nil)
        wrapped_call_rows([tool_title_span("write"), Markdown::Span.new(text: " "),
                           Markdown::Span.new(text: tool_path_display(args), fg: Theme[:accent])], width, bg:)
      end

      # The styled call-row family (pi's per-tool renderCall Texts inside
      # the tool-execution box): the box pad rides EVERY wrapped row
      # ({Panel.padded_fg_rows}' rule — pi's box paddingX,
      # tool-execution.ts:87), the mixed spans wrap through {Text.wrap_row}
      # at the padded content width — pi's Text wraps the header to the
      # viewport (the I18 recorded gap, closed: an over-long word moves to
      # its own row, then hard-splits — the s6 capture's shape).
      def wrapped_call_rows(spans, width, bg: nil)
        Text.wrap_row(spans, width - Panel::OUTPUT_PAD.length * 2).map do |row|
          tail = nil
          if bg
            row.each { |s| s.bg = bg }
            content_width = row.sum { |s| TUI.text_width(s.text) }
            fill = [width - Panel::OUTPUT_PAD.length - content_width, 0].max
            tail = Markdown::Span.new(text: " " * fill, bg: bg)
          end
          TUI.markdown_line([Markdown::Span.new(text: Panel::OUTPUT_PAD, bg: bg), *row, tail].compact)
        end
      end

      # pi write.ts:108-122 — the content preview: \r stripped
      # (normalizeDisplayText), trailing empty lines trimmed
      # (trimTrailingEmptyLines), at most 10 lines, then the expand hint
      # row (keyHint app.tools.expand — the dim key + muted text bytes;
      # the ctrl+o binding is cut, the bytes are the contract).
      def write_content_rows(args, width, expanded: false, bg: nil)
        lines = args["content"].to_s.gsub("\r", "").split("\n", -1)
        lines.pop while !lines.empty? && lines.last.empty?
        return [] if lines.empty?

        display = expanded ? lines : lines.first(WRITE_PREVIEW_LINES)
        rows = Panel.padded_fg_rows(display.join("\n"), width, fg: Theme[:tool_output], bg: bg)
        remaining = lines.length - display.length
        rows << Panel.expand_hint_row("... (#{remaining} more lines, #{lines.length} total,", width, bg: bg) if remaining.positive?
        rows
      end

      # pi read.ts:35-42 formatReadCall vs :79-90 formatCompactReadCall —
      # the plain call line, or the compact resource shape with the dim
      # expand hint (the [skill] label rides customMessageLabel violet —
      # the port's accent analog — over customMessageText muted), wrapped
      # through the call-row family ({wrapped_call_rows}).
      def read_call_rows(args, width, expanded = false, bg: nil)
        classification = expanded ? nil : compact_read_classification(args)
        if classification
          label_spans = if classification[:kind] == :skill
            [Markdown::Span.new(text: "[skill] ", fg: Theme[:accent], modifiers: [:bold]),
             Markdown::Span.new(text: classification[:label], fg: Theme[:muted])]
          else
            [tool_title_span("read resource"), Markdown::Span.new(text: " "),
             Markdown::Span.new(text: classification[:label], fg: Theme[:accent])]
          end
          wrapped_call_rows([*label_spans, *line_range_spans(args),
                             Markdown::Span.new(text: " (ctrl+o to expand)", fg: Theme[:dim])], width, bg:)
        else
          wrapped_call_rows([tool_title_span("read"), Markdown::Span.new(text: " "),
                             Markdown::Span.new(text: tool_path_display(args), fg: Theme[:accent]),
                             *line_range_spans(args)], width, bg:)
        end
      end

      # pi write.ts:99 theme.fg("toolTitle", theme.bold(...)) — the tool
      # call header token (dark.json:40 toolTitle = text, the truecolor
      # prose value). The call rows speak the wrap vocabulary
      # ({Text.wrap_row} re-groups {Render::Markdown::Span}s).
      def tool_title_span(title)
        Markdown::Span.new(text: title, fg: Theme[:toolTitle], modifiers: [:bold])
      end

      # pi render-utils.ts:102-110 renderToolPath over :10-18 shortenPath
      # — the display path: the ~ contraction under home, verbatim
      # otherwise; the empty/absent path renders the toolOutput "..."
      # (write.ts:105 / read.ts:104 fallback). linkPath's OSC8 hyperlink
      # is capability-gated — the port's TUI carries none (recorded).
      def tool_path_display(args)
        raw_path = args["file_path"] || args["path"]
        return "..." if raw_path.nil? || raw_path.empty?

        home = Dir.home
        raw_path.start_with?(home) ? "~#{raw_path[home.length..]}" : raw_path
      end

      # pi read.ts:35-42 formatReadLineRange — the warning-colored
      # :start-end suffix when offset/limit narrow the read (start
      # defaults to 1; a limit without offset still ranges from 1).
      def line_range_spans(args)
        offset = args["offset"]
        limit = args["limit"]
        return [] if offset.nil? && limit.nil?

        start_line = offset || 1
        end_line = limit ? start_line + limit - 1 : ""
        [Markdown::Span.new(text: ":#{start_line}-#{end_line}", fg: Theme[:warning])]
      end

      # pi read.ts:63-88 getCompactReadClassification — the compact shape
      # for resource-like reads: SKILL.md → the [skill] shape (label =
      # the skill directory), the AGENTS.md/CLAUDE.md resource names →
      # the `read resource` shape (label = the cwd-relative or absolute
      # path, formatPathRelativeToCwdOrAbsolute). pi's own-package docs
      # class (getPiDocsClassification) is cut, itemized: the port has no
      # pi package root.
      def compact_read_classification(args)
        raw_path = tool_path_display(args)
        return if raw_path == "..."

        absolute_path = File.expand_path(raw_path)
        name = File.basename(absolute_path)
        return {kind: :skill, label: File.basename(File.dirname(absolute_path))} if name == "SKILL.md"
        return {kind: :resource, label: Text.cwd_relative_path(absolute_path)} if COMPACT_RESOURCE_FILE_NAMES.include?(name)

        nil
      end
    end
  end
end
