# frozen_string_literal: true

require "strscan" # the inline probes: anchored scans with no tail-slice allocation

module Tart
  module Render
    # The markdown converter (BRIEF §7.1): the pi `markdown.ts` subset —
    # headings h1–h6 (ATX and setext), paragraphs, bold, italic, strikethrough,
    # inline code, fenced code blocks, blockquotes, horizontal rules,
    # unordered + ordered lists, task-list markers, GFM tables, links (bare,
    # titled and angle-wrapped destinations), angle autolinks — as a pure,
    # gem-neutral styled-rows vocabulary. Hand-rolled parser; no new runtime
    # deps.
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
    # marked/ink mechanism. Deviations itemized in the I06/I68 reports:
    # paragraph soft breaks render as separate rows, emphasis resolves by
    # the CommonMark delimiter-run law (I68 — the I06 no-padded-content
    # approximation and the intraword +__+ sanction are retired), inline
    # code stays line-bound, OSC-8 hyperlinks are out of scope (the
    # linkUrl fallback is always taken).
    class Markdown
      # One styled run within a row: +text+, +fg+ (+TUI.style+ color symbol
      # or nil), +modifiers+ (+TUI.style+ modifier symbols), +bg+ (the
      # panel bg the tool-block call rows ride — nil off-panel).
      Span = Struct.new(:text, :fg, :modifiers, :bg, keyword_init: true) do
        def initialize(text:, fg: nil, modifiers: [], bg: nil)
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

      # pi's maxUnbrokenWordWidth (markdown.ts:878): a column's minimum
      # never exceeds this, however long its longest word.
      MAX_UNBROKEN_WORD_WIDTH = 30

      # GFM table delimiter row (marked's gfmTable align capture, rules.ts):
      # ` {0,3}`-indented `-` runs with optional `:` at either end, pipe-
      # separated, optional edge pipes. The tokenizer additionally requires
      # a `:` or `|` somewhere in the row (other.tableDelimiter /[:|]/ — a
      # bare `---`/`===` underline is NEVER a delimiter row; it falls to
      # the setext scan). The shape alone (no guard, no cell count) is the
      # paragraph-interrupt probe.
      TABLE_DELIM = /\A {0,3}(?:\| *)?:?-+:? *(?:\| *:?-+:? *)*(?:\| *)?\z/.freeze

      # Setext underline (marked lheadingCore ` {0,3}(=+|-+) *`): `=` → h1,
      # `-` → h2. A single dash qualifies; three+ dashes also match HR —
      # the paragraph claims them as underlines first.
      SETEXT = /\A {0,3}(=+|-+) *\z/.freeze

      # lheadingGfm's content blocker (rules.ts, the `table` replacement):
      # a delimiter-ish pipe row (`\|?` then 1+ of `[:- ]*|`) that setext
      # content may neither START on nor cross — this is what keeps
      # `para\nTitle\n---` one heading while `para\n| a |\n| --- |\n---`
      # stays paragraph ∥ table ∥ hr (oracle-verified).
      PIPE_ROW = /\A {0,3}\|?(?:[-: ]*\|)+[-: ]*\z/.freeze

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

      # CommonMark's escapable set: backslash + ASCII punctuation ONLY
      # (R5) — a backslash before anything else is literal text.
      ESCAPABLE = /[!"#$%&'()*+,\-\/:;<=>?@\[\\\]^_`{|}~]/.freeze
      WHITESPACE = /\s/.freeze
      PUNCT = /[\p{P}\p{S}]/u.freeze # marked's punctuation class (_=/[\p{P}\p{S}]/u)
      # STRICT_STRIKETHROUGH_REGEX (markdown.ts:9): pi's del tokenizer
      # override — a `~~` pair whose content starts/ends with neither
      # whitespace nor `~`, the closer followed by a non-~ (or the end).
      # No match at the scan position → the tilde falls to the one-char
      # text fallback (marked's flow when the override returns undefined).
      # I72: anchored with StringScanner at the scan position (the \A-free
      # twin of the I68 STRICT_DEL.match(src[i..]) probe — no tail-slice
      # allocation); the caller pre-gates on a literal `~~`, so the probe
      # never runs at a position that cannot open the construct.
      STRICT_DEL = /(~~)(?=[^\s~])((?:\\.|[^\\])*?(?:\\.|[^\s~\\]))\1(?=[^~]|\z)/.freeze
      # A run carrying no character that can OPEN an inline construct — one
      # text node (the I72 boring-segment fast path: per-CHARACTER text-Node
      # emission was the linear-constant hog, ~7,000 Struct allocations per
      # 80-line paragraph). `]` and the parens are plain text at the scan
      # level (they only matter inside link parsing, which scans its own
      # window); `~` breaks the run only because the del probe re-checks
      # its own `~~` opening pair.
      BORING_RUN = /[^\\`*_~\[<]+/.freeze

      # One inline parse node: +kind+ is :text, :code (raw codespan
      # content), :link (+text+ the raw label, +href+, +children+ the
      # parsed label), :delim (a maximal +*+/+_+ run: +ch+, +count+,
      # +orig+ the original run length, the flanking verdicts), :del
      # (strict strikethrough, +children+), or a resolved :em/:strong
      # (+children+). Plain data — resolution and rendering are plain
      # functions over token arrays. +prev+/+next+ carry the doubly-linked
      # scan order during emphasis resolution (I72: O(1) splices — the
      # I68 cure's per-closer toks.index identity scans over the whole
      # token array made delimiter-dense text quadratic).
      Node = Struct.new(:kind, :text, :href, :children, :ch, :count, :orig, :can_open, :can_close,
        :prev, :next, keyword_init: true)

      # Inline tokens → nodes. At each position: escape, codespan, link,
      # delimiter run, strict-del pair — the markdown.ts inline token
      # cases (:677-733); anything else joins the plain-text run. The I65
      # D1 reject semantics fall out of that fallback: a delimiter that
      # can't pair (flanking law, strict content, unclosed span) renders
      # AT ITS POSITION and the scan advances one character, so the
      # remainder still pairs later delimiters.
      #
      # I72 O(n) guard: every probe is pre-gated on its opening character
      # and the strict-del probe only fires at a literal `~~` — a character
      # that cannot open a construct never pays for regex or slice work
      # (the I68 kill's dominant term). A construct-free run coalesces
      # into ONE text node.
      #
      # StringScanner probes are byte-indexed while the scan walks
      # characters, so the byte cursor (+bi+) rides alongside +i+ and each
      # token advances both (the token's own byte size — O(step), linear
      # across the line).
      def tokenize_inline(src)
        scan = StringScanner.new(src)
        toks = []
        i = 0
        bi = 0
        size = src.length
        while i < size
          ch = src[i]
          node, step =
            if ch == "\\" && src[i + 1] && ESCAPABLE.match?(src[i + 1])
              [Node.new(kind: :text, text: src[i + 1]), 2] # escape (:677-680)
            elsif ch == "`" && (tok = code_token(src, i))
              tok
            elsif ch == "[" && (tok = link_token(src, i))
              tok
            elsif ch == "<" && (tok = autolink_token(scan, bi))
              tok
            elsif (ch == "*" || ch == "_") && (tok = delim_token(src, i))
              tok
            elsif ch == "~" && src[i + 1] == "~" && (tok = del_token(scan, bi))
              tok
            else
              # boring-segment fast path: one text node per construct-free run
              scan.pos = bi
              if (run = scan.scan(BORING_RUN))
                [Node.new(kind: :text, text: run), run.length]
              else
                [Node.new(kind: :text, text: ch), 1]
              end
            end
          toks << node
          bi += src[i, step].bytesize
          i += step
        end
        toks
      end

      # Codespan (marked's code rule): a run of m backticks closes at the
      # next run of exactly m backticks; content keeps one edge space when
      # both surround a non-space core. A span stays on its source line
      # (base convention — soft-break lines render as separate rows). No
      # closer → the backticks are literal text, one char per scan step.
      def code_token(src, i)
        m = 1
        m += 1 while src[i + m] == "`" # the maximal opener run (no tail slice)
        j = i + m
        k = nil
        pos = j
        while pos < src.length
          c = src[pos]
          break if c == "\n"

          if c == "`"
            run = 1
            run += 1 while src[pos + run] == "`"
            if run == m && src[pos + run] != "`"
              k = pos
              break
            end
            pos += run
          else
            pos += 1
          end
        end
        return nil unless k

        content = src[j...k]
        return nil if content.empty?

        if content.length >= 2 && content.start_with?(" ") && content.end_with?(" ") && content.match?(/\S/)
          content = content[1..-2]
        end
        [Node.new(kind: :code, text: content), k + m - i]
      end

      # Angle autolink (marked's inline autolink rule, live-verified): a
      # URI — `<scheme:rest>` where the scheme is 2–32 chars and the rest
      # carries no whitespace, control char or `<>` — becomes a link whose
      # text IS the href; the marked email shape (atext @ labels with at
      # least one dot-label, the address not followed by `-/_`) becomes a
      # `mailto:` link. Both ride the standing link render (markdown.ts
      # :699-719) — the `" (href)"` suffix dies in the existing
      # text==href comparison, so neither form appends anything. Anything
      # else in angle brackets falls through to plain text.
      AUTOLINK_URI = /\A<([a-zA-Z][a-zA-Z0-9+.-]{1,31}):([^\s\x00-\x1f<>]*)>/.freeze
      AUTOLINK_EMAIL = %r{\A<([a-zA-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+)(?![-_])>}.freeze

      # StringScanner-anchored like {#del_token} (no tail slice); +scan+ is
      # shared with the del probe and repositioned on every use.
      def autolink_token(scan, bi)
        scan.pos = bi
        if scan.scan(AUTOLINK_URI)
          addr = "#{scan.captures[0]}:#{scan.captures[1]}"
          href = addr
        elsif scan.scan(AUTOLINK_EMAIL)
          addr = scan.captures[0]
          href = "mailto:#{addr}"
        else
          return nil
        end
        # marked builds one plain-text child (Tokenizer.autolink) — no
        # inline constructs inside an autolink.
        [Node.new(kind: :link, text: addr, href:, children: [Node.new(kind: :text, text: addr)]), scan.matched_size]
      end

      # Link (marked's link rule; rendered at markdown.ts:699-719):
      # [label](dest) — the label nests balanced brackets (escapes
      # skipped) and stays on one line; the destination, the parens'
      # whitespace tolerance and the optional (discarded) title live in
      # {#link_href}. No match → the `[` is literal text, one-char
      # advance (the R6 letter).
      def link_token(src, i)
        return nil unless src[i] == "["

        j = bracket_close(src, i)
        return nil unless j

        label = src[(i + 1)...j]
        return nil if label.empty? || label.include?("\n")

        href, end_ix = link_href(src, j + 1)
        return nil unless end_ix
        return nil if href.empty? # `[a]()` stays literal (the R6 letter)

        [Node.new(kind: :link, text: label, href:, children: parse_inline(label)), end_ix - i]
      end

      # The matching `]` for the `[` at i — balanced brackets, escapes
      # skipped — or nil.
      def bracket_close(src, i)
        depth = 1
        j = i + 1
        while j < src.length
          c = src[j]
          if c == "\\"
            j += 2
          else
            depth += 1 if c == "["
            depth -= 1 if c == "]"
            break if depth.zero?

            j += 1
          end
        end
        depth.zero? && j < src.length ? j : nil
      end

      # The destination arm (the I68 R6 law, superseded in two arms by the
      # I110 letter): `(` ws* dest ws* title? ws* `)`. The dest is
      # angle-wrapped ({#angle_dest} — inner whitespace allowed,
      # D-angle-dest) or bare ({#bare_dest} — balanced parens, escapes
      # skipped, no whitespace). The title (`"…"` / `'…'` / `(…)`), when
      # present, is parsed and DISCARDED — marked drops it at token level
      # (oracle: `[a](url "title")` → href `url`). Returns [href,
      # index-after-`)`], or nil when the production never closes.
      def link_href(src, k)
        return nil unless src[k] == "("

        k += 1
        k += 1 while src[k]&.match?(WHITESPACE)
        if src[k] == "<"
          href, k = angle_dest(src, k)
          return nil unless k
        else
          href, k = bare_dest(src, k)
          return nil unless k
        end
        k += 1 while src[k]&.match?(WHITESPACE)
        k = skip_title(src, k)
        return nil unless k
        k += 1 while src[k]&.match?(WHITESPACE)
        return nil unless src[k] == ")"

        [href, k + 1]
      end

      # The angle-wrapped destination (`[a](<url with space>)` —
      # D-angle-dest): `<…>` with inner whitespace, no raw newline or
      # angle, escapes skip, 1+ chars required (marked's
      # `<(?:\\.|[^\n<>\\])+>`). Returns [href, next_index].
      def angle_dest(src, k)
        j = k + 1
        while j < src.length && src[j] != ">"
          j += src[j] == "\\" ? 2 : 1
        end
        return nil unless j < src.length

        href = src[(k + 1)...j]
        return nil if href.empty? || href.include?("\n")

        [href, j + 1]
      end

      # The bare destination — the R6 walker (balanced parens, escapes
      # skipped) extended to STOP at the first whitespace so an optional
      # title may follow; whitespace inside a paren group still kills the
      # destination (the R6 no-whitespace law). Returns [href, next_index]
      # where next_index sits ON the closer paren or the separator.
      def bare_dest(src, k)
        depth = 1
        j = k
        while j < src.length
          c = src[j]
          if c == "\\"
            j += 2
            next
          end
          if c == "("
            depth += 1
          elsif c == ")"
            depth -= 1
            return [src[k...j], j] if depth.zero?
          elsif WHITESPACE.match?(c)
            return [src[k...j], j] if depth == 1 # title territory
            return nil                            # whitespace inside the dest
          end
          j += 1
        end
        nil
      end

      # The optional link title (marked's title shapes) — parsed and
      # discarded: a `"…"`/`'…'` run closed by the first unescaped
      # matching quote, or a `(…)` run closed by the first unescaped `)`.+
      # Returns the index after the title, or +k+ when there is none, or
      # nil when the title never closes (the whole link then fails).
      def skip_title(src, k)
        opener = src[k]
        return k unless opener == '"' || opener == "'" || opener == "("

        closer = opener == "(" ? ")" : opener
        j = k + 1
        while j < src.length
          c = src[j]
          if c == "\\"
            j += 2 # escapes skip
            next
          end
          break if c == closer

          j += 1
        end
        j < src.length ? j + 1 : nil
      end

      # A delimiter run: a maximal +*+/+_+ run with the CommonMark
      # flanking verdicts computed at the run's edges (line start/end
      # count as whitespace). `*` opens iff left-flanking and closes iff
      # right-flanking (intraword kept); `_` additionally may open only
      # when not right-flanking or preceded by punctuation, and may close
      # only when not left-flanking or followed by punctuation (intraword
      # disallowed) — the R1-R3 law, spec §"Emphasis and strong emphasis".
      def delim_token(src, i)
        ch = src[i]
        return nil unless ch == "*" || ch == "_"

        count = 1
        count += 1 while src[i + count] == ch # the maximal same-char run
        prev = i.zero? ? nil : src[i - 1]
        nxt = src[i + count] # nil = line end
        left = left_flanking?(prev, nxt)
        right = right_flanking?(prev, nxt)
        can_open = ch == "*" ? left : left && (!right || punct?(prev))
        can_close = ch == "*" ? right : right && (!left || punct?(nxt))
        [Node.new(kind: :delim, ch:, count:, orig: count, can_open:, can_close:), count]
      end

      # left-flanking: not followed by whitespace, and (not followed by
      # punctuation OR preceded by whitespace/punctuation).
      def left_flanking?(prev, nxt)
        !whitespace?(nxt) && (!punct?(nxt) || whitespace?(prev) || punct?(prev))
      end

      # right-flanking: not preceded by whitespace, and (not preceded by
      # punctuation OR followed by whitespace/punctuation).
      def right_flanking?(prev, nxt)
        !whitespace?(prev) && (!punct?(prev) || whitespace?(nxt) || punct?(nxt))
      end

      def whitespace?(ch)
        ch.nil? || WHITESPACE.match?(ch) # nil = line start/end
      end

      def punct?(ch)
        !ch.nil? && PUNCT.match?(ch)
      end

      # The strict-del pair (markdown.ts:9-21) anchored at the scan
      # position (the pattern is matched against the slice — \A anchors at
      # the absolute string start in Ruby); no match → nil (the tilde
      # falls to the text fallback). The caller pre-gates on a literal
      # `~~` (the I72 guard — a plain `~` never reaches here), so the
      # probe runs only where the construct can actually open.
      def del_token(scan, bi)
        scan.pos = bi
        m = scan.scan(STRICT_DEL)
        return nil unless m

        [Node.new(kind: :del, children: parse_inline(scan.captures[1])), m.length]
      end

      # Inline source → resolved nodes: tokenize, then the CommonMark
      # emphasis resolution (spec §"Emphasis and strong emphasis").
      def parse_inline(src)
        toks = tokenize_inline(src)
        resolve_emphasis(toks)
        toks
      end

      # Emphasis resolution: each delimiter run scans back for the NEAREST
      # same-char opener that can open (past the per-key openers bottom —
      # a failed closer never re-scans below where its search stopped);
      # two stars make strong, one makes em (mixed runs split, remnants
      # re-close — ***x*** nests em around the strong); the rule of 3
      # rejects a pair whose original run lengths sum to a multiple of 3
      # unless both runs are multiples of 3; delimiters that never match
      # render as their literal characters.
      #
      # I72: the resolution runs over a doubly-linked token list with
      # sentinel ends, so a match is one O(children) unlink + O(1) splice
      # and the opener stack prunes by truncation — the I68 cure's per-
      # closer toks.index identity scans and its openers.reject!/
      # children.any? nested walk are gone (the measured quadratic terms
      # on delimiter-dense text). The final sequence is written back
      # through +toks+, which the renderer walks as before.
      def resolve_emphasis(toks)
        head = Node.new(kind: :text, text: "") # sentinels: unlinks never touch a list edge
        tail = Node.new(kind: :text, text: "")
        prev = head
        toks.each do |t|
          prev.next = t
          t.prev = prev
          prev = t
        end
        prev.next = tail
        tail.prev = prev
        openers = [] # unmatched delimiter nodes, in scan order
        bottoms = {} # [ch, closer_can_open, closer_orig % 3] → search-stop bound
        tok = head.next
        while tok && !tok.equal?(tail)
          if tok.kind == :delim
            openers << tok
            close_emphasis(openers, bottoms, tok) if tok.can_close
          end
          tok = tok.next
        end
        resolved = []
        tok = head.next
        while tok && !tok.equal?(tail)
          resolved << tok
          tok = tok.next
        end
        toks.replace(resolved)
      end

      # Resolve +tok+ as a potential closer; splices emphasis nodes into
      # the linked run and prunes +openers+. The closer remnant (a run
      # only partly consumed) re-closes in the loop until spent or
      # unmatchable. Every opener above the hit sits strictly between the
      # two ends — absorbed into the new node's children, rendered
      # literally (the I68 children.any? containment walk was exactly that
      # stack segment).
      def close_emphasis(openers, bottoms, tok)
        key = [tok.ch, tok.can_open, tok.orig % 3]
        loop do
          j = openers.size - 2 # the closer itself is already on the stack
          hit = nil
          while j >= 0
            break if bottoms[key] && openers[j].equal?(bottoms[key])

            hit = openers[j] if openers[j].ch == tok.ch && openers[j].can_open
            break if hit

            j -= 1
          end
          unless hit
            # I72: the reference openers-bottom law — the bound rides just
            # below the failed closer (everything below it was proven dead
            # for this key by this or an earlier same-key walk), and a
            # closer that can no longer open is dead — off the stack. The
            # I68 cure's degenerate nil bound re-walked the whole
            # accumulated stack on every failed closer: the remaining
            # quadratic term on delimiter-dense text.
            bottoms[key] = openers.size >= 2 ? openers[-2] : nil
            openers.pop unless tok.can_open
            return
          end
          return unless rule_of_three_ok?(hit, tok)

          use = hit.count >= 2 && tok.count >= 2 ? 2 : 1
          children = [] # the run strictly between the two ends, unlinked once
          mid = hit.next
          until mid.equal?(tok)
            children << mid
            mid = mid.next
          end
          node = Node.new(kind: use == 2 ? :strong : :em, children: children)
          hit.count -= use
          tok.count -= use
          node.prev = hit
          node.next = tok
          hit.next = node
          tok.prev = node
          openers.slice!(j..) # the hit and everything above it (incl. the closer)
          openers << hit if hit.count.positive?
          openers << tok if tok.count.positive?
          if hit.count.zero? # the spent opener leaves the flow — the node takes its slot
            hit.prev.next = node
            node.prev = hit.prev
          end
          if tok.count.zero? # the spent closer likewise
            node.next = tok.next
            tok.next.prev = node
          end
          return if tok.count.zero? # spent — the scan resumes after the node
        end
      end

      # The rule of 3: when one of the two delimiters can both open and
      # close, their original run lengths must not sum to a multiple of 3
      # unless both runs are multiples of 3.
      def rule_of_three_ok?(opener, closer)
        either = (opener.can_open && opener.can_close) || (closer.can_open && closer.can_close)
        return true unless either
        return true if opener.orig % 3 == 0 && closer.orig % 3 == 0

        (opener.orig + closer.orig) % 3 != 0
      end

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
            table_block(line, lines) || paragraph_block(line, lines)
          end
        end
        blocks
      end

      def code_block(open, lines)
        fence = open[1][0]
        indent = indent_of(open[0]) # R7: the opening fence's own indent (≤ 3)
        body = []
        while (next_line = lines.shift)
          break if CLOSING_FENCE[fence].match?(next_line)

          # R7: marked strips the opening fence's indent from each body
          # line, bounded by the line's own indent (markdown.ts:526-550).
          body << (indent.positive? ? next_line.sub(/\A {1,#{indent}}/, "") : next_line)
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
          elsif BLOCK_START.match?(nxt) && indent_of(nxt) <= base_indent
            # An unindented block opener ends the item's lazy continuation
            # (marked: `- item\n---` → list ∥ hr — an hr can interrupt the
            # item paragraph); deeper-indented lines still continue.
            break
          else # continuation (incl. deeper-indented nested markers, re-parsed per item)
            lines.shift
            item << nxt.lstrip
          end
        end
        items << item
        [:list, ordered, start, loose, items]
      end

      def paragraph_block(first, lines)
        extent, level = setext_extent(first, lines)
        if level
          lines.shift(extent.length) # the extent (minus +first+) + the underline, claimed by lheading
          return [:heading, level, extent.join("\n")]
        end

        src = [first]
        until lines.empty?
          nxt = lines.first
          break if nxt.strip.empty? || BLOCK_START.match?(nxt)
          # marked's paragraph interrupt set (rules.ts _paragraph under
          # gfm — "interrupt paragraphs with table"): a table-shaped
          # header+delimiter pair at the next line ends the paragraph. The
          # pair re-dispatches from the top, so a count-mismatch pair
          # degrades to paragraph text (oracle-verified: the 2-vs-1 pair
          # after a paragraph splits into two paragraphs).
          break if table_shape?(nxt, lines[1])
          src << lines.shift
        end
        [:paragraph, src.join("\n")]
      end

      # The lheading scan (rules.ts lheadingGfm, run at dispatch BEFORE the
      # paragraph rule): +extent+ is the would-be heading content, +level+
      # 1 (`=`) / 2 (`-`) when the extent terminates in a setext underline,
      # nil otherwise. The content may neither START on nor cross a
      # pipe-row line (the `table` content blocker) or a blank/block
      # opener; an underline beyond any of them is unreachable and the
      # paragraph builds normally (oracle: `para\nTitle\n---` is ONE h2,
      # `para\n| a |\n| --- |\n---` is paragraph ∥ table ∥ hr).
      def setext_extent(first, lines)
        extent = [first]
        return [extent, nil] if PIPE_ROW.match?(first)

        lines.each do |nxt|
          if (m = SETEXT.match(nxt))
            return [extent, m[1].start_with?("=") ? 1 : 2] # the underline itself is NOT content
          end
          return [extent, nil] if nxt.strip.empty? || BLOCK_START.match?(nxt) || PIPE_ROW.match?(nxt)

          extent << nxt
        end
        [extent, nil]
      end

      # The paragraph-interrupt pair shape (marked's gfmTable pattern
      # level — no guard, no cell-count check: a count-mismatch pair still
      # interrupts): a non-blank header line + a delimiter-row line.
      def table_shape?(header, delim)
        !header.strip.empty? && delim && TABLE_DELIM.match?(delim)
      end

      # GFM table (marked 18.0.11's letter, live-verified): a header line
      # + delimiter row whose cell counts are EQUAL, the delimiter carrying
      # the `[:|]` guard (a bare `---`/`===` underline is never a delimiter
      # row and falls to the setext scan). Body rows run to a blank line or
      # a block opener; +raw+ keeps the source lines for the too-narrow
      # fallback. +align+ is captured but NOT rendered (D-align — pi
      # v1.1.0's renderTable never reads token.align).
      def table_block(header, lines)
        delim = lines.first
        return nil unless delim && TABLE_DELIM.match?(delim) && delim.match?(/[:|]/)

        headers = split_cells(header)
        aligns = table_aligns(delim)
        return nil unless headers.length == aligns.length

        # consumed only AFTER the count check — a mismatched pair consumes
        # nothing and degrades to paragraph text at re-dispatch
        delim = lines.shift
        body = []
        until lines.empty? || lines.first.strip.empty? || BLOCK_START.match?(lines.first)
          body << lines.shift
        end
        [:table, headers, aligns, body.map { |row| split_cells(row, headers.length) },
         [header, delim, *body].join("\n")]
      end

      # marked's splitCells (rules.ts helpers): every unescaped pipe gains
      # a leading space (an odd backslash-run before it = escaped), the row
      # splits on " |", an empty first/last cell is dropped (the edge
      # pipes), cells trim and `\|` unescapes; +count+ pads with empties /
      # truncates (body rows to the header count).
      def split_cells(row, count = nil)
        spaced = +""
        row.each_char.with_index do |ch, i|
          spaced << if ch != "|"
            ch
          elsif slash_run_odd?(row, i)
            "|" # escaped pipe: no split, no space
          else
            " |" # unescaped pipe: gains the split space
          end
        end
        cells = spaced.split(" |", -1)
        cells.shift if !cells.empty? && cells.first.strip.empty?
        cells.pop if !cells.empty? && cells.last.strip.empty?
        if count
          cells = cells.first(count)
          cells << "" while cells.length < count
        end
        cells.map { |cell| cell.strip.gsub("\\|", "|") }
      end

      # An odd number of backslashes immediately before the pipe at +i+
      # escapes it (marked's escape walk in splitCells).
      def slash_run_odd?(row, i)
        odd = false
        j = i - 1
        while j >= 0 && row[j] == "\\"
          odd = !odd
          j -= 1
        end
        odd
      end

      # marked's align read (Tokenizer.table): the delimiter minus one
      # leading pipe and one trailing `| *`, split on plain `|`; each cell
      # is right / center / left / none by its colon posture. Captured but
      # NOT rendered (D-align).
      def table_aligns(delim)
        delim.sub(/\A\|/, "").sub(/\| *\z/, "").split("|", -1).map do |cell|
          if cell.match?(/\A *-+: *\z/)
            :right
          elsif cell.match?(/\A *:-+: *\z/)
            :center
          elsif cell.match?(/\A *:-+ *\z/)
            :left
          end
        end
      end

      def render_block(block)
        case block[0]
        when :space then [[]] # space token → blank row (markdown.ts:594-596)
        when :heading then heading_rows(block)
        when :paragraph then split_rows(inline_spans(block[1]))
        when :table then table_rows(block)
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

      # pi v1.1.0 renderTable (markdown.ts:852-1015): bordered rows in the
      # Span vocabulary, sized against the converter's content width; nil
      # width = the natural-fit arm — columns at natural widths, cells
      # unwrapped (the display path always passes a width). Layout: the
      # top border; one row per wrapped header line (cells bold, padding
      # included — pi's theme.bold(padded)); a separator; the body rows
      # with separators BETWEEN them; the bottom border. Borders are
      # single default-styled spans (pi renders them unstyled —
      # D-border-style). Alignment is never read (D-align).
      def table_rows(block)
        _, headers, _align, body, raw = block
        num = headers.length
        return [] if num.zero?

        header_cells = headers.map { |cell| inline_spans(cell) }
        body_cells = body.map { |row| row.map { |cell| inline_spans(cell) } }
        widths = table_widths(header_cells, body_cells, num)
        return raw_fallback_rows(raw) unless widths

        sep = ->(left, mid, right) { [Span.new(text: left + widths.map { |w| "─" * w }.join(mid) + right)] }
        rows = [sep.call("┌─", "─┬─", "─┐")]
        rows.concat(bordered_cell_rows(header_cells, widths, num, bold: true))
        rows << sep.call("├─", "─┼─", "─┤")
        body_cells.each_with_index do |row, i|
          rows.concat(bordered_cell_rows(row, widths, num, bold: false))
          rows << sep.call("├─", "─┼─", "─┤") if i < body_cells.length - 1
        end
        rows << sep.call("└─", "─┴─", "─┘")
        rows
      end

      # The width arithmetic (markdown.ts:880-949): per-column natural and
      # min-word widths (visible width over the rendered cell spans; the
      # longest whitespace-delimited word, capped at
      # MAX_UNBROKEN_WORD_WIDTH); minimum regrow when the mins overflow;
      # then natural fit or proportional shrink. Returns nil when even one
      # column per cell cannot fit — the too-narrow raw fallback.
      def table_widths(header_cells, body_cells, num)
        natural = Array.new(num, 0)
        min_word = Array.new(num, 1)
        header_cells.each_with_index { |cell, i| note_cell(natural, min_word, i, cell) }
        body_cells.each { |row| row.each_with_index { |cell, i| note_cell(natural, min_word, i, cell) } }

        return (0...num).map { |i| [natural[i], min_word[i]].max } unless @width

        overhead = 3 * num + 1
        available = @width - overhead
        return nil if available < num

        mins = min_word.dup
        mins = regrown_minimums(min_word, available, num) if mins.sum > available
        if natural.sum + overhead <= @width
          (0...num).map { |i| [natural[i], mins[i]].max }
        else
          shrunk_columns(natural, mins, available, num)
        end
      end

      # One cell's contribution to its column's natural (full visible
      # width) and min-word (max(1, longest word ≤ 30)) measures
      # (markdown.ts:883-898 + getLongestWordWidth :821-830).
      def note_cell(natural, min_word, i, cell)
        text = cell.map(&:text).join
        natural[i] = [natural[i], TUI.text_width(text)].max
        longest = text.split(/[[:space:]]+/).reject(&:empty?).filter_map { |word| TUI.text_width(word) }.max || 0
        min_word[i] = [min_word[i], [longest, MAX_UNBROKEN_WORD_WIDTH].min, 1].max
      end

      # The minimum regrow (markdown.ts:907-931): floors of the weighted
      # share (weight = max(0, w−1)), the leftover round-robin from 1.
      def regrown_minimums(min_word, available, num)
        mins = Array.new(num, 1)
        remaining = available - num
        if remaining.positive?
          weights = min_word.map { |w| [0, w - 1].max }
          total = weights.sum
          growth = weights.map { |w| total.positive? ? w * remaining / total : 0 }
          mins = mins.each_with_index.map { |m, i| m + growth[i] }
          leftover = remaining - growth.sum
          i = 0
          while leftover.positive? && i < num
            mins[i] += 1
            leftover -= 1
            i += 1
          end
        end
        mins
      end

      # The proportional shrink (markdown.ts:946-968): each column grows
      # from its min by the floor of its share of the extra width (share =
      # minDelta / totalGrowPotential · extraWidth), then the remainder
      # goes round-robin to columns still below natural.
      def shrunk_columns(natural, mins, available, num)
        total_grow = (0...num).sum { |i| [0, natural[i] - mins[i]].max }
        extra = [0, available - mins.sum].max
        widths = (0...num).map do |i|
          delta = [0, natural[i] - mins[i]].max
          mins[i] + (total_grow.positive? ? delta * extra / total_grow : 0)
        end
        remaining = available - widths.sum
        while remaining.positive?
          grew = false
          (0...num).each do |i|
            break if remaining.zero?
            next unless widths[i] < natural[i]

            widths[i] += 1
            remaining -= 1
            grew = true
          end
          break unless grew
        end
        widths
      end

      # One display row per wrapped cell line: `│ ` + cells joined ` │ ` +
      # ` │`; a cell shorter than its row-mate fills with a pad-only line
      # (pi pads every line to the column width — markdown.ts:971-981).
      def bordered_cell_rows(cells, widths, num, bold:)
        lines = cells.each_with_index.map { |cell, i| table_cell_lines(cell, widths[i], bold) }
        (0...lines.map(&:length).max).map do |h|
          row = [Span.new(text: "│ ")]
          lines.each_with_index do |cell_lines, i|
            row.concat(cell_lines[h] || [Span.new(text: " " * widths[i], modifiers: bold ? [:bold] : [])])
            row << Span.new(text: i == num - 1 ? " │" : " │ ")
          end
          row
        end
      end

      # A cell's wrapped lines (the house Text.wrap_row, min width 1),
      # each right-padded to the column width; +bold+ adds :bold to every
      # span INCLUDING the padding (pi applies theme.bold to the padded
      # cell text, markdown.ts:975-982).
      def table_cell_lines(cell, width, bold)
        Text.wrap_row(cell, width).map do |line|
          line = line.map { |s| Span.new(text: s.text, fg: s.fg, modifiers: bold ? s.modifiers | [:bold] : s.modifiers) }
          pad = width - TUI.text_width(line.map(&:text).join)
          line << Span.new(text: " " * pad, modifiers: bold ? [:bold] : []) if pad.positive?
          line
        end
      end

      # The too-narrow fallback (markdown.ts:874-878): the block's raw
      # source lines as plain spans wrapped to the width — no borders.
      def raw_fallback_rows(raw)
        raw.split("\n", -1).flat_map { |line| Text.wrap_row([Span.new(text: line)], @width) }
      end

      def list_rows(block, depth = 0)
        _, ordered, start, loose, items = block
        base = "    " * depth
        rows = []
        items.each_with_index do |item_lines, i|
          marker = ordered ? "#{start + i}. " : "- " # normalized bullets (:775-779)
          # R8: a task item's `[x] `/`[ ] ` folds INTO the listBullet-styled
          # marker span (markdown.ts renderList taskMarker — checked
          # normalizes to x); the item text loses the marker and the
          # continuation prefix follows the FULL marker width (:781-782).
          task = item_lines.first.match(/\A\[([ xX])\] /)
          marker_text = task ? "#{marker}[#{task[1].downcase}] " : marker
          lines = item_lines.dup
          lines[0] = item_lines.first[task[0].length..] if task
          prefix = (base.empty? ? [] : [Span.new(text: base)]) + [Span.new(text: marker_text, fg: FG[:list_bullet])]
          continuation = Span.new(text: base + " " * marker_text.length) # :781-782
          first = true
          parse_blocks(lines).each do |inner|
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

      # Nodes → spans (markdown.ts:677-733 render cases). +fg+/+modifiers+
      # are the enclosing style; emphasis nests by recursion. A codespan
      # renders its raw content with the code fg and NO enclosing style
      # (:695-697). A link renders its label children with the link fg +
      # underline, then the linkUrl fallback — " (href)" unless the raw
      # label already is the href (mailto stripped) (:711-719). Unresolved
      # delimiter runs render their characters literally.
      def render_nodes(nodes, fg, modifiers)
        spans = []
        nodes.each do |node|
          case node.kind
          when :text
            spans << span(node.text, fg, modifiers) unless node.text.empty?
          when :code
            spans << Span.new(text: node.text, fg: FG[:code]) # raw, no nesting (:695-697)
          when :link
            spans.concat(render_nodes(node.children, FG[:link], modifiers + [:underlined])) # :701
            # OSC-8 out of scope: the linkUrl fallback — URL appended in
            # parens unless text already is the href (:711-719).
            unless node.text == node.href || node.text == node.href.delete_prefix("mailto:")
              spans << Span.new(text: " (#{node.href})", fg: FG[:link_url])
            end
          when :em
            spans.concat(render_nodes(node.children, fg, modifiers + [:italic])) # :689-693
          when :strong
            spans.concat(render_nodes(node.children, fg, modifiers + [:bold])) # :683-687
          when :del
            spans.concat(render_nodes(node.children, fg, modifiers + [:crossed_out])) # :725-729
          when :delim
            spans << span(node.ch * node.count, fg, modifiers) unless node.count.zero?
          end
        end
        merge_adjacent(spans)
      end

      # Inline tokens → spans: parse (tokenize + emphasis resolution), then
      # render with the enclosing style.
      def inline_spans(src, fg = nil, modifiers = [])
        render_nodes(parse_inline(src), fg, modifiers)
      end

      # Adjacent same-style spans coalesce (one text run per style, as pi's
      # flat ANSI output renders).
      def merge_adjacent(spans)
        spans.chunk_while { |a, b| a.fg == b.fg && a.modifiers == b.modifiers }.map do |group|
          Span.new(text: group.map(&:text).join, fg: group.first.fg, modifiers: group.first.modifiers)
        end
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
