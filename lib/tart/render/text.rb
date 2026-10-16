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

      # pi wrapSingleLine (tui utils.ts:925-1010) over the TUI span
      # vocabulary — the HEADER-family wrap (I56): one row of duck-typed
      # spans (content + style) in, wrapped span rows out, regrouped by
      # contiguous source span. Rows that fit pass through UNCHANGED (the
      # frozen s1/s9 shapes ride the identity arm). The port reproduces
      # pi's token mechanics exactly (verified against the live-oracle
      # artifact table + a deno run of pi's own tokenizer):
      #   · tokens are whitespace/word runs built ACROSS span boundaries
      #     (utils.ts:799-880 splitIntoTokensWithAnsi);
      #   · an SGR code rides every segment boundary (each theme.fg emits
      #     its own), so pi's whitespace test — `token.trim() === ""`
      #     (:941) — sees the code and a token that OPENS a span is never
      #     whitespace, even when its visible text is spaces. That is the
      #     whole continuation game: at content width 48 the ` · `
      #     separator's leading space (its own muted segment,
      #     interactive-mode.ts:1049-1056) survives the break and LEADS
      #     the next row (`␣␣· / commands…`, pi-w50.txt row 3); a plain
      #     whitespace token never starts a row (:968-970);
      #   · breaks trimEnd the row (:965), over-long word tokens
      #     hard-break at exactly +width+ cells (breakLongWord). The ANSI
      #     tracker's line-end resets have no cell-vocabulary equivalent
      #     — styles ride the cells themselves.
      def wrap_spans(row, width)
        return [row] if row.empty? || TUI.text_width(row.map(&:content).join) <= width

        lines = []
        current = []
        span_tokens(row).each do |token|
          token_width = TUI.text_width(token[:cells].map(&:first).join)
          if token_width > width && !token[:ws]
            lines << current unless current.empty?
            broken = break_span_cells(token[:cells], width)
            lines.concat(broken[0..-2])
            current = broken.last
            next
          end

          if TUI.text_width(current.map(&:first).join) + token_width > width && !current.empty?
            lines << current
            current = token[:ws] ? [] : token[:cells].dup
          else
            current.concat(token[:cells])
          end
        end
        lines << current unless current.empty?
        lines.map { |cells| span_row(cells, row) }
      end

      # pi splitIntoTokensWithAnsi over cells: maximal same-kind runs
      # (" " is the only space kind — utils.ts:839). +ws+ is pi's
      # isWhitespace — `token.trim() === ""` (:941): the trim strips
      # whitespace but leaves ANSI codes, so a token is whitespace only
      # when its visible text is all spaces AND it carries no code —
      # codes ride segment joins (each theme.fg emits one), inside the
      # token just as at its head. That is the continuation mechanic: the
      # ` · ` separator's leading space re-opens the muted run, survives
      # trim, and leads the next row (pi-w50.txt row 3).
      def span_tokens(row)
        cells = row.each_with_index.flat_map { |span, index| span.content.chars.product([index]) }
        tokens = []
        current = nil
        current_kind = nil
        previous_index = nil
        cells.each do |(char, index)|
          kind = char == " " ? :space : :word
          if current_kind && current_kind != kind
            tokens << finish_span_token(current)
            current = nil
          end
          current ||= {cells: [], ws: true}
          current_kind = kind
          current[:cells] << [char, index]
          current[:ws] &&= !previous_index.nil? && index == previous_index
          previous_index = index
        end
        tokens << finish_span_token(current) if current
        tokens
      end

      # pi's trim check over one token: whitespace only when no cell
      # opened (or crossed) a source span and every visible char is a
      # space. Empty tokens (never produced) would read whitespace.
      def finish_span_token(token)
        token[:ws] &&= token[:cells].all? { |(char, _)| char == " " }
        token
      end

      # pi breakLongWord (:1022-1062) over cells: width-cell rows,
      # split only where the next grapheme would overflow.
      def break_span_cells(cells, width)
        rows = []
        current = []
        current_width = 0
        cells.each do |cell|
          char_width = TUI.text_width(cell.first)
          if current_width + char_width > width
            rows << current
            current = []
            current_width = 0
          end
          current << cell
          current_width += char_width
        end
        rows << current unless current.empty?
        rows
      end

      # One wrapped row's cells regrouped into spans (contiguous source
      # spans coalesce; trailing whitespace trimmed — pi's final
      # `wrapped.map(line => line.trimEnd())`, :1006-1008).
      def span_row(cells, row)
        cells.pop while !cells.empty? && cells.last.first =~ /\s/
        cells.chunk_while { |(_, a), (_, b)| a == b }.map do |group|
          source = row[group.first[1]]
          RatatuiRuby::Text::Span.new(content: group.map(&:first).join, style: source.style)
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

      # Clips styled spans to +width+ visible columns (the editor's inner
      # width); the trailing partial span is trimmed cell-wise.
      def clip_spans(spans, width)
        out = []
        budget = width
        spans.each do |span|
          break if budget <= 0

          text = span.content
          if TUI.text_width(text) <= budget
            out << span
            budget -= TUI.text_width(text)
          else
            head, = fit(text, budget)
            # The bg rides the rebuild too — the bg panels' fill spans are
            # the ones that get trimmed here (the scrollbar overlay clips
            # every row to width−1), and dropping it was the "backgrounds
            # vanish while scrolling" defect.
            out << TUI.span(head, fg: span.style&.fg, bg: span.style&.bg, modifiers: span.style&.modifiers.to_a)
            budget -= TUI.text_width(head)
          end
        end
        out
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

      # The character covering cell +col+ of +text+.
      def char_index_at_cell(text, col)
        cell = 0
        text.each_char.with_index do |ch, i|
          cell += TUI.text_width(ch)
          return i if cell > col
        end
        text.length - 1
      end

      # The leading text fitting +width+ cells (whole characters; a wide
      # character that would straddle the bound moves whole to the
      # remainder — widths stay additive).
      def take_cells(text, width)
        out = +""
        text.each_char do |ch|
          break if TUI.text_width(out) + TUI.text_width(ch) > width

          out << ch
        end
        out
      end

      # The +width+-cell substring of +text+ starting at cell +start+.
      def slice_cells(text, start, width)
        rest = take_cells(text, start)
        take_cells(text[rest.length..] || "", width)
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
