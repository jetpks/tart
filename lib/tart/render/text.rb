# frozen_string_literal: true

module Tart
  module Render
    # Pure text/wrap helpers extracted from the chat surface (I21 wave 1).
    # Module functions: no ivar access, no Chat dependency — width is
    # threaded by the caller.
    module Text
      # A parsed skill block (pi parseSkillBlock, agent-session.ts:177-187
      # — the display-side parse of the submitted text back into the
      # skill's name/location/content + the user message that followed):
      # the panel renders the skill, the echo renders the message.
      SkillBlock = Struct.new(:name, :location, :content, :user_message, keyword_init: true)

      module_function

      # Greedy word wrap to +width+ visible columns; over-long words hard-split.
      # pi wraps with ANSI/grapheme awareness (utils.ts); plain text is this
      # iteration's recorded scope.
      def wrap(text, width)
        return [""] if text.empty?

        text.lines(chomp: true).flat_map { |line| wrap_line(line, width) }
      end

      def wrap_line(line, width)
        out = []
        while TUI.text_width(line) > width
          head, consumed = fit(line, width)
          out << head
          line = line[consumed..]
        end
        out << line
        out
      end

      # Word-wrap one styled markdown row to +width+ visible columns: the
      # {fit} word-wrap over the row's visible text, spans re-grouped per
      # wrapped line (pi wraps rendered markdown to the terminal width).
      # Rows that fit — and blank rows — pass through unchanged.
      def wrap_row(row, width)
        return [row] if row.empty? || TUI.text_width(row.map(&:text).join) <= width

        cells = row.flat_map { |span| span.text.chars.product([span]) }
        out = []
        until cells.empty?
          head, consumed = fit(cells.map(&:first).join, width)
          out << styled_row(cells[0, head.length])
          cells = cells[consumed..] || []
        end
        out
      end

      # Wrapped cells re-grouped into spans (consecutive chars of one
      # source span coalesce back into a single run).
      def styled_row(cells)
        cells.chunk_while { |(_, a), (_, b)| a.equal?(b) }.map do |group|
          span = group.first[1]
          Render::Markdown::Span.new(text: group.map(&:first).join, fg: span.fg, modifiers: span.modifiers)
        end
      end

      # Hard cell-wise clip (pi truncateToWidth with an empty tail).
      def clip_text(text, width)
        out = []
        budget = width
        text.chars.each do |char|
          w = TUI.text_width(char)
          break if w > budget

          out << char
          budget -= w
        end
        out.join
      end

      # Longest prefix of +line+ fitting +width+, preferring a word break.
      # Returns [head, chars_consumed].
      def fit(line, width)
        w = 0
        line.chars.each_with_index do |char, i|
          char_width = TUI.text_width(char)
          break if w + char_width > width

          w += char_width
        end
        return [line, w] if w == line.length

        if line[w] == " "
          [line[0, w], w + 1] # word boundary at the width edge; consume the space
        elsif (space_break = line[0, w].rindex(" "))
          [line[0, space_break], space_break + 1] # break before the last word; consume the space
        elsif w.positive?
          [line[0, w], w] # hard split
        else
          [line.chars.first, 1] # over-wide first grapheme; force progress
        end
      end

      # pi formatTokens (footer.ts:23-30): compact token counts.
      def format_tokens(count)
        if count < 1000 then count.to_s
        elsif count < 10_000 then format("%.1fk", count / 1000.0)
        elsif count < 1_000_000 then "#{(count / 1000.0).round}k"
        elsif count < 10_000_000 then format("%.1fM", count / 1_000_000.0)
        else "#{(count / 1_000_000.0).round}M"
        end
      end

      # pi formatCwdForFooter (footer.ts:33-43): the cwd with the home
      # prefix contracted to "~"; paths outside home render absolute.
      def format_cwd(cwd, home = Dir.home)
        return cwd if home.nil? || home.empty?

        resolved = File.expand_path(cwd)
        resolved_home = File.expand_path(home)
        return resolved unless resolved == resolved_home || resolved.start_with?(resolved_home + File::SEPARATOR)

        resolved == resolved_home ? "~" : "~#{File::SEPARATOR}#{resolved[(resolved_home.length + 1)..]}"
      end

      # pi parseSkillBlock (:177-187), verbatim shape. nil when the text
      # carries no skill block (a plain submission).
      def parse_skill_block(text)
        match = text.match(/\A<skill name="([^"]+)" location="([^"]+)">\n([\s\S]*?)\n<\/skill>(?:\n\n([\s\S]+))?\z/)
        return nil unless match

        user_message = match[4]&.strip
        SkillBlock.new(name: match[1], location: match[2], content: match[3], user_message: user_message&.empty? ? nil : user_message)
      end

      # pi utils/paths.ts:120-123 formatPathRelativeToCwdOrAbsolute —
      # cwd-relative when under the cwd, absolute otherwise.
      def cwd_relative_path(absolute_path)
        cwd = "#{Dir.pwd}/"
        absolute_path.start_with?(cwd) ? absolute_path[cwd.length..] : absolute_path
      end
    end
  end
end
