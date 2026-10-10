# frozen_string_literal: true

module Tart
  module Render
    # The markdown converter (BRIEF §7.1): the pi `markdown.ts` subset —
    # headings h1–h6, paragraphs, bold, italic, strikethrough, inline code,
    # fenced code blocks, blockquotes, horizontal rules, unordered + ordered
    # lists, links — as a pure, gem-neutral styled-rows vocabulary. Hand-rolled
    # parser; no new runtime deps.
    #
    # Vocabulary (the wave-2 markdown-seam lane's consumption contract): a
    # conversion is an Array of rows, one row per display line; a row is an
    # Array of {Span}s; a Span is text plus a style — +fg+ a +TUI.style+
    # color symbol (nil = terminal default) and +modifiers+ a list of
    # +TUI.style+ modifier symbols (+:bold+, +:italic+, +:underlined+,
    # +:crossed_out+; ratatui_ruby 1.5.0 modifier names, style/style.rb).
    # The seam converts row → +TUI::Text::Line+, span → +TUI::Text::Span+
    # (+fg+ → +Style#fg+, +modifiers+ → +Style#modifiers+); an empty row is
    # a blank line. The file stays free of the underlying gem's name (the
    # tui-seam gate scans all of lib).
    #
    # Parity: the fg roles port pi's dark-theme markdown colors
    # (getMarkdownTheme, theme/theme.ts:1022-1036 → theme/dark.json:42-51),
    # mapped through the house precedents in Chat::FG (pi blue → +:light_blue+,
    # pi muted → +:gray+; violet → +:light_magenta+). pi's +code+ theme
    # function is fg-only, so code styling is carried as fg — ratatui has no
    # code modifier. The observable distinctions of markdown.ts are ported
    # (heading hierarchy markdown.ts:473-493, strict strikethrough :9-21,
    # link text/URL handling :699-719, list normalization :775-789), not the
    # marked/ink mechanism. Deviations itemized in the I06 markdown report:
    # paragraph soft breaks render as separate rows, delimiter-flanking rules
    # are approximated by a no-padded-content check, intraword +__+ emphasis
    # is allowed, OSC-8 hyperlinks are out of scope (the linkUrl fallback is
    # always taken).
    class Markdown
      # One styled run within a row: +text+, +fg+ (+TUI.style+ color symbol
      # or nil), +modifiers+ (+TUI.style+ modifier symbols).
      Span = Struct.new(:text, :fg, :modifiers, keyword_init: true) do
        def initialize(text:, fg: nil, modifiers: [])
          super
        end
      end

      # pi dark-theme markdown fg roles → house color vocabulary.
      FG = {
        heading: :yellow,           # mdHeading (dark.json:42)
        link: :light_blue,          # mdLink blue (dark.json:43); pi blue → :light_blue (Chat::FG)
        link_url: :gray,            # mdLinkUrl muted (dark.json:44); muted → :gray (Chat::FG[:tool])
        code: :light_magenta,       # mdCode violet (dark.json:45)
        code_block: :green,         # mdCodeBlock (dark.json:46)
        code_block_border: :gray,   # mdCodeBlockBorder muted (dark.json:47)
        quote: :gray,               # mdQuote muted (dark.json:48)
        quote_border: :gray,        # mdQuoteBorder muted (dark.json:49)
        hr: :gray,                  # mdHr muted (dark.json:50)
        list_bullet: :light_magenta # mdListBullet violet (dark.json:51)
      }.freeze

      # pi caps the hr at 80 columns and sizes it to the content width
      # (markdown.ts:616); the converter has no terminal context, so the
      # caller (the seam) passes +width+ — nil means the cap.
      MAX_HR_WIDTH = 80

      class << self
        # @param width [Integer, nil] content width, for the hr (markdown.ts:616).
        # @return [Array<Array<Span>>] styled rows; an empty row is a blank line.
        def rows(text, width: nil)
          new(text, width:).rows
        end
      end

      def initialize(text, width: nil)
        @text = text.to_s
        @width = width
      end

      def rows
        out = []
        blocks.each_with_index do |block, i|
          out.concat(render_block(block))
          nxt = blocks[i + 1]
          # pi pushes "" after a block unless a space token follows; lists
          # never get trailing spacing (markdown.ts:501-507, 552-554).
          out << [] if nxt && nxt[0] != :space && block[0] != :space && block[0] != :list
        end
        out
      end

      private

      FENCE = /\A {0,3}(`{3,}|~{3,})(.*)\z/
      CLOSING_FENCE = { "`" => /\A {0,3}`{3,}\s*\z/, "~" => /\A {0,3}~{3,}\s*\z/ }.freeze
      HEADING = /\A {0,3}([#]{1,6})\s+(.*)\z/
      HR = /\A {0,3}[-*_](?:[ \t]*[-*_]){2,}[ \t]*\z/
      QUOTE = /\A {0,3}> ?/
      LIST_ITEM = /\A( {0,3})([-+*]|\d{1,9}[.)])[ \t]+(.*)\z/
      BLOCK_START = /\A {0,3}(?:[#]{1,6}\s|>|`{3,}|~{3,}|[-+*][ \t]|\d{1,9}[.)][ \t]|[-*_][ \t]*[-*_][ \t]*[-*_])/

      # Inline delimiter scan (earliest match wins; alternation is rule
      # priority): escape, code, strong, em, del, link — the markdown.ts
      # inline token cases (:677-733).
      INLINE_SCAN = /
        (?<escape>\\.)
      | (?<code>`[^`\n]+`)
      | (?<strong>\*\*.+?\*\*(?!\*)|__.+?__(?!_))
      | (?<em>\*[^*\n]+\*|_[^_\n]+_)
      | (?<del>~~.+?~~)
      | (?<link>\[[^\]\n]+\]\([^)\n]+\))
      /mx

      def blocks
        # tabs → 3 spaces (markdown.ts:261)
        @blocks ||= parse_blocks(@text.gsub("\t", "   ").lines(chomp: true))
      end

      def parse_blocks(lines)
        blocks = []
        until lines.empty?
          line = lines.shift
          blocks << if line.strip.empty?
            [:space]
          elsif (m = FENCE.match(line))
            code_block(m, lines)
          elsif (m = HEADING.match(line))
            [:heading, m[1].length, m[2]]
          elsif HR.match?(line)
            [:hr]
          elsif line.match?(/\A {0,3}>/)
            quote_block(line, lines)
          elsif (m = LIST_ITEM.match(line))
            list_block(m, lines)
          else
            paragraph_block(line, lines)
          end
        end
        blocks
      end

      def code_block(open, lines)
        fence = open[1][0]
        body = []
        while (next_line = lines.shift)
          break if CLOSING_FENCE[fence].match?(next_line)

          body << next_line
        end
        [:code, open[2].strip, body.join("\n")]
      end

      def quote_block(first, lines)
        inner = [first.sub(QUOTE, "")]
        while lines.first&.match?(QUOTE)
          inner << lines.shift.sub(QUOTE, "")
        end
        [:quote, parse_blocks(inner)]
      end

      def list_block(first, lines)
        ordered = first[2].match?(/\d/)
        start = ordered ? first[2].to_i : nil
        base_indent = first[1].length
        items = []
        loose = false
        item = [first[3]]
        loop do
          nxt = lines.first
          break if nxt.nil?

          if (im = LIST_ITEM.match(nxt)) && im[1].length <= base_indent
            items << item
            item = [im[3]]
            lines.shift
          elsif nxt.strip.empty?
            # Blank line: loose-list separator when a sibling item follows,
            # otherwise the list ends and the blank stays in the stream.
            break unless (sibling = lines[1]) && LIST_ITEM.match?(sibling) && indent_of(sibling) <= base_indent

            lines.shift
            loose = true
          else # continuation (incl. deeper-indented nested markers, re-parsed per item)
            lines.shift
            item << nxt.lstrip
          end
        end
        items << item
        [:list, ordered, start, loose, items]
      end

      def paragraph_block(first, lines)
        src = [first]
        until lines.empty?
          nxt = lines.first
          break if nxt.strip.empty? || BLOCK_START.match?(nxt)

          src << lines.shift
        end
        [:paragraph, src.join("\n")]
      end

      def render_block(block)
        case block[0]
        when :space then [[]] # space token → blank row (markdown.ts:594-596)
        when :heading then heading_rows(block)
        when :paragraph then split_rows(inline_spans(block[1]))
        when :code then code_rows(block)
        when :quote then quote_rows(block)
        when :hr then [[Span.new(text: "─" * hr_length, fg: FG[:hr])]]
        when :list then list_rows(block)
        end
      end

      # H1 = heading(bold(underline)), H2+ = heading(bold); H3+ keeps a
      # styled "#"*level prefix (markdown.ts:481-493).
      def heading_rows(block)
        level, src = block[1], block[2]
        modifiers = level == 1 ? %i[bold underlined] : [:bold]
        spans = inline_spans(src, FG[:heading], modifiers)
        spans.unshift(Span.new(text: "#{"#" * level} ", fg: FG[:heading], modifiers: [:bold])) if level >= 3
        split_rows(spans)
      end

      def code_rows(block)
        _, lang, body = block
        rows = [[Span.new(text: "```#{lang}", fg: FG[:code_block_border])]] # :532
        body.split("\n", -1).each do |line|
          # "  " indent unstyled, code body codeBlock-styled (:537-539)
          row = [Span.new(text: "  "), Span.new(text: line, fg: FG[:code_block])]
          rows << row.reject { |span| span.text.empty? }
        end
        rows << [Span.new(text: "```", fg: FG[:code_block_border])]
        rows
      end

      # quote(italic(content)) behind a "│ " quoteBorder prefix (:566-606);
      # inner colored spans keep their fg (pi restyles via outer ANSI prefix).
      def quote_rows(block)
        block[1].flat_map { |inner| render_block(inner) }.map do |row|
          [Span.new(text: "│ ", fg: FG[:quote_border])] + row.map do |span|
            Span.new(text: span.text, fg: span.fg || FG[:quote], modifiers: span.modifiers | [:italic])
          end
        end
      end

      def list_rows(block, depth = 0)
        _, ordered, start, loose, items = block
        base = "    " * depth
        rows = []
        items.each_with_index do |item_lines, i|
          marker = ordered ? "#{start + i}. " : "- " # normalized bullets (:775-779)
          prefix = (base.empty? ? [] : [Span.new(text: base)]) + [Span.new(text: marker, fg: FG[:list_bullet])]
          continuation = Span.new(text: base + " " * marker.length) # :781-782
          first = true
          parse_blocks(item_lines).each do |inner|
            case inner[0]
            when :list then rows.concat(list_rows(inner, depth + 1)) # nested: unprefixed (:794-798)
            when :space then next
            else
              render_block(inner).each do |row|
                rows << [first ? prefix : [continuation], row].flatten
                first = false
              end
            end
          end
          rows << prefix if first # empty item keeps its bare marker (:804-806)
          rows << [] if loose && i < items.size - 1
        end
        rows
      end

      def hr_length
        [(@width || MAX_HR_WIDTH), MAX_HR_WIDTH].min
      end

      # Inline tokens → spans (markdown.ts:677-733). +fg+/+modifiers+ are the
      # enclosing style; delimiters nest by recursion.
      def inline_spans(src, fg = nil, modifiers = [])
        spans = []
        pos = 0
        while (m = INLINE_SCAN.match(src, pos))
          pre = src[pos...m.begin(0)]
          spans << span(pre, fg, modifiers) unless pre.empty?
          consumed = m.end(0)
          if m[:escape]
            spans << span(m[:escape][1..], fg, modifiers)
          elsif m[:code]
            spans << Span.new(text: m[:code][1..-2], fg: FG[:code]) # raw, no nesting (:695-697)
          elsif (body = m[:strong])
            spans.concat(inline_spans(body[2..-3], fg, modifiers + [:bold])) # :683-687
          elsif (body = m[:em])
            inner = body[1..-2]
            if padded?(inner) # padded delimiters are literal (flanking approximation)
              spans << span(src[pos], fg, modifiers)
              consumed = pos + 1
            else
              spans.concat(inline_spans(inner, fg, modifiers + [:italic])) # :689-693
            end
          elsif (body = m[:del])
            inner = body[2..-3]
            if strict_strikethrough?(inner)
              spans.concat(inline_spans(inner, fg, modifiers + [:crossed_out])) # :725-729
            else # StrictStrikethroughTokenizer (markdown.ts:9-21) rejects it → literal
              spans << span(src[pos], fg, modifiers)
              consumed = pos + 1
            end
          elsif m[:link]
            text = m[:link][1...m[:link].index("](")]
            href = m[:link][(m[:link].index("](") + 2)..-2]
            spans.concat(inline_spans(text, FG[:link], modifiers + [:underlined])) # :701
            # OSC-8 out of scope: the linkUrl fallback — URL appended in
            # parens unless text already is the href (:711-719).
            unless text == href || text == href.delete_prefix("mailto:")
              spans << Span.new(text: " (#{href})", fg: FG[:link_url])
            end
          end
          pos = consumed
        end
        spans << span(src[pos..], fg, modifiers) if pos < src.length
        merge_adjacent(spans)
      end

      # Adjacent same-style spans coalesce (one text run per style, as pi's
      # flat ANSI output renders).
      def merge_adjacent(spans)
        spans.chunk_while { |a, b| a.fg == b.fg && a.modifiers == b.modifiers }.map do |group|
          Span.new(text: group.map(&:text).join, fg: group.first.fg, modifiers: group.first.modifiers)
        end
      end

      # Padded delimiters are literal text (approximation of CommonMark
      # flanking rules; pi inherits marked's).
      def padded?(inner)
        inner.start_with?(" ") || inner.end_with?(" ")
      end

      # STRICT_STRIKETHROUGH_REGEX (markdown.ts:9): content neither starts
      # nor ends with whitespace or ~.
      def strict_strikethrough?(inner)
        !inner.match?(/\A[\s~]/) && !inner.match?(/[\s~]\z/)
      end

      # A row is one display line: spans containing "\n" split rows
      # (soft breaks render as new lines, as in pi's wrapped output).
      def split_rows(spans)
        rows = [[]]
        spans.each do |span|
          span.text.split("\n", -1).each_with_index do |part, i|
            rows << [] if i.positive?
            rows.last << Span.new(text: part, fg: span.fg, modifiers: span.modifiers) unless part.empty?
          end
        end
        rows
      end

      def span(text, fg, modifiers)
        Span.new(text:, fg:, modifiers:)
      end

      def indent_of(line)
        line[/\A */].length
      end
    end
  end
end
