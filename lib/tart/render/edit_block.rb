# frozen_string_literal: true

module Tart
  module Render
    # The edit tool's block family (I57 — pi renderers/edit.ts spread into
    # the edit definition at edit.ts:214, over tool-execution.ts's
    # contentBox): the PENDING frame (the header alone under
    # toolPendingBg — pi's own pre-preview frame; the mid-call async
    # preview diff is the recorded Grounds §6 cut) and the SETTLED frame
    # (the header + the recorded diff per pi renderDiff — components/
    # diff.ts — with the intra-line word diff on 1-removed+1-added runs,
    # or the no-preview error shape; all over the result panel bg, pads
    # included). The block is NOT expandable: a constant builder — pi's
    # edit renderers ignore setExpanded.
    #
    # Row geometry is the port's I17/I18 wrap convention (the write/read
    # families'): the viewport width threaded by the caller, ONE OUTPUT_PAD
    # lead cell per content row (pi's nested contentBox+call Box pads
    # flatten — the installed pi's live bytes carry the single-lead shape
    # the rig's parity differ judges; the deno oracle's row ORDER and
    # tokens are the unit pins). No file reads anywhere in this module —
    # the diff comes from the recorded details channel (agent/message.rb).
    module EditBlock
      # pi diff.ts parseDiffLine — "+123 content" / "-123 content" /
      # " 123 content" / the "   ..." truncation row (empty lineNum).
      DIFF_LINE_RE = /\A([+\-\s])(\s*\d*)\s(.*)\z/.freeze

      # pi renderIntraLineDiff's changed-part treatment: the first changed
      # part per side keeps its leading whitespace PLAIN (un-inverted —
      # "avoids highlighting indentation", diff.ts), the rest inverts.
      # Composed as {text:, inverse:} parts.
      Part = Struct.new(:text, :inverse)

      # jsdiff 8.0.4 word.js — the tokenizer's word-char class, verbatim
      # (the Latin-script ranges word.js counts as word characters).
      EXTENDED_WORD_CHARS = "a-zA-Z0-9_\\u{AD}\\u{C0}-\\u{D6}\\u{D8}-\\u{F6}\\u{F8}-\\u{2C6}" \
        "\\u{2C8}-\\u{2D7}\\u{2DE}-\\u{2FF}\\u{1E00}-\\u{1EFF}".freeze

      # JS \s (WhiteSpace + LineTerminator) — NOT Ruby's ASCII \s; the
      # tokenizer's whitespace runs, the ws tests, and the trim/leading/
      # trailing helpers all speak this class (word.js fidelity).
      JS_WS = "[ \\t\\n\\v\\f\\r\\u{00A0}\\u{1680}\\u{2000}-\\u{200A}\\u{2028}\\u{2029}" \
        "\\u{202F}\\u{205F}\\u{3000}\\u{FEFF}]".freeze
      JS_WS_RE = /#{JS_WS}/.freeze

      # word.js tokenizeIncludingWhitespace: word runs / whitespace runs /
      # single non-word chars; the tokenize stitch loop (below) then folds
      # whitespace onto adjacent tokens.
      TOKENIZE_RE = /[#{EXTENDED_WORD_CHARS}]+|#{JS_WS}+|[^#{EXTENDED_WORD_CHARS}]/.freeze

      module_function

      # ── the block families ────────────────────────────────────────

      # The SETTLED edit block — the SELF-render shell (pi edit.ts:157
      # registers renderShell: "self": the renderer owns its framing, the
      # tool-exec contentBox is bypassed; the spec-time oracle probe
      # omitted the renderShell key and captured the default-shell frame —
      # the live parity target is the self-shell, re-probed and confirmed
      # against the installed 1.1.0 binary). The frames, row-exact:
      #
      #   success: [Spacer(plain), padY, header, [padY-spacer, body...], padY]
      #   error:   [Spacer(plain), padY, header, padY-spacer, error rows, padY]
      #   pending: [Spacer(plain), padY, header, padY]
      #
      # All the Box rows ride ONE bg (the call component's own bgFn —
      # toolPendingBg / toolErrorBg / toolSuccessBg by the result state,
      # tool-execution.ts:271-277 + getEditHeaderBg); the header/body rows
      # carry ONE padX lead cell + the bg fill (the call Box paddingX).
      # The ERROR body renders INSIDE the call component (the preview
      # error == the result error text → formatEditResult returns
      # undefined and the rebuild's own Spacer + error Text carry the
      # body — edit.ts buildEditCallComponent; the renderResult Container
      # stays empty), so the error rows are bg-filled like the diff rows.
      # +details+ is the recorded {diff:, patch:, firstChangedLine:} side
      # channel (symbol keys live, string keys replayed); success WITHOUT
      # it renders the header-only block (sessions recorded pre-I57).
      def edit_block_rows(args, result, details, width)
        bg = Panel.tool_panel_bg(result)
        region = [Panel.blank_line,                        # the component's Spacer(1) — PLAIN
                  Panel.panel_blank_line(width, bg)]       # the call Box padY top
        region.concat(header_rows(args, width, bg: bg))
        error = result.is_a?(Hash) ? result[:error] : nil
        body = if error
          # The rebuild's body: theme.fg("error", errorText) after the
          # component's Spacer (buildEditCallComponent, Text(body, 0, 0)).
          Panel.padded_fg_rows(error.to_s, width, fg: Theme[:error], bg: bg)
        else
          diff = details.is_a?(Hash) ? (details[:diff] || details["diff"]) : nil
          diff.is_a?(String) && !diff.empty? ? diff_rows(diff, width, bg: bg) : []
        end
        unless body.empty?
          region << Panel.panel_blank_line(width, bg)      # the call component's Spacer(1)
          region.concat(body)
        end
        region << Panel.panel_blank_line(width, bg)        # the call Box padY bottom
        region
      end

      # The PENDING edit block — the self-shell pending frame (4 rows):
      # the header alone between the call Box's pending-bg pads (the
      # preview cut, Grounds §6). Row-exact against the re-probed oracle.
      def pending_edit_block_rows(args, width)
        bg = Theme[:tool_pending_bg]
        [Panel.blank_line,
         Panel.panel_blank_line(width, bg),
         *header_rows(args, width, bg: bg),
         Panel.panel_blank_line(width, bg)]
      end

      # ── the pieces ────────────────────────────────────────────────

      # pi formatEditCall (edit.ts:99-102) over the write family's exact
      # primitives: the bold toolTitle `edit` + the tool-path display
      # (accent token, the ~ contraction, "..." when the path is absent),
      # wrapped through the call-row family. The OSC8 hyperlink stays cut
      # (the recorded I18 cut — the TUI carries no link capability).
      def header_rows(args, width, bg: nil)
        FileBlocks.wrapped_call_rows(
          [FileBlocks.tool_title_span("edit"), Markdown::Span.new(text: " "),
           Markdown::Span.new(text: FileBlocks.tool_path_display(args), fg: Theme[:accent])],
          width, bg: bg
        )
      end

      # renderDiff — pi components/diff.ts verbatim (see diff_rows).
      # (The error arm lives inline in {edit_block_rows}: the error text
      # is formatEditResult's theme.fg("error", errorText) after the
      # renderResult's own Spacer — Text(output, outputPad, 0) inside the
      # contentBox; the port's padded_fg_rows is that row.)

      # pi renderDiff (components/diff.ts) verbatim: parse each line,
      # non-parsing rows verbatim in toolDiffContext; consecutive
      # removed-then-added runs render per-row, and EXACTLY one removed +
      # one added renders the intra-line word diff; everything replaces
      # tabs with 3 spaces (renderDiff's replaceTabs on every parsed row).
      def diff_rows(diff, width, bg:)
        lines = diff.split("\n")
        rows = []
        i = 0
        while i < lines.length
          parsed = parse_diff_line(lines[i])
          if parsed.nil?
            rows.concat(Panel.padded_fg_rows(lines[i], width, fg: Theme[:tool_diff_context], bg: bg))
            i += 1
            next
          end

          case parsed[:prefix]
          when "-"
            removed = []
            while (p = i < lines.length ? parse_diff_line(lines[i]) : nil) && p[:prefix] == "-"
              removed << p
              i += 1
            end
            added = []
            while (p = i < lines.length ? parse_diff_line(lines[i]) : nil) && p[:prefix] == "+"
              added << p
              i += 1
            end
            rows.concat(removed_added_rows(removed, added, width, bg: bg))
          when "+"
            rows.concat(composed_rows("+", parsed, plain_parts(parsed[:content]), width,
                                      fg: Theme[:tool_diff_added], bg: bg))
            i += 1
          else
            rows.concat(composed_rows(" ", parsed, plain_parts(parsed[:content]), width,
                                      fg: Theme[:tool_diff_context], bg: bg))
            i += 1
          end
        end
        rows
      end

      # The run arm (diff.ts:120-153): exactly one removed + one added →
      # the intra-line word diff; every other run shape renders as-is
      # per-row (the Grounds §4 calib-2/3 no-intra classes).
      def removed_added_rows(removed, added, width, bg:)
        rows = []
        if removed.length == 1 && added.length == 1
          removed_parts, added_parts = intra_line_parts(replace_tabs(removed[0][:content]),
                                                        replace_tabs(added[0][:content]))
          rows.concat(composed_rows("-", removed[0], removed_parts, width,
                                    fg: Theme[:tool_diff_removed], bg: bg))
          rows.concat(composed_rows("+", added[0], added_parts, width,
                                    fg: Theme[:tool_diff_added], bg: bg))
        else
          removed.each do |parsed|
            rows.concat(composed_rows("-", parsed, plain_parts(parsed[:content]), width,
                                      fg: Theme[:tool_diff_removed], bg: bg))
          end
          added.each do |parsed|
            rows.concat(composed_rows("+", parsed, plain_parts(parsed[:content]), width,
                                      fg: Theme[:tool_diff_added], bg: bg))
          end
        end
        rows
      end

      # One parsed diff line's rows: pi composes `#{marker}#{lineNum}
      # #{text}` in the row's token; the intra parts carry the
      # [:reversed] runs. Wrapped through the call-row family (pi's Text
      # wraps inside the box).
      def composed_rows(marker, parsed, parts, width, fg:, bg:)
        prefix = "#{marker}#{parsed[:line_num]} "
        spans = [Markdown::Span.new(text: prefix, fg: fg)]
        parts.each do |part|
          spans << if part.inverse
            Markdown::Span.new(text: part.text, fg: fg, modifiers: [:reversed])
          else
            Markdown::Span.new(text: part.text, fg: fg)
          end
        end
        FileBlocks.wrapped_call_rows(spans, width, bg: bg)
      end

      def plain_parts(content)
        [Part.new(replace_tabs(content), false)]
      end

      def parse_diff_line(line)
        match = DIFF_LINE_RE.match(line)
        return nil unless match

        {prefix: match[1], line_num: match[2], content: match[3]}
      end

      # pi diff.ts replaceTabs — "   " per tab (Text's own normalization
      # would too; renderDiff does it before composing).
      def replace_tabs(text)
        text.gsub("\t", "   ")
      end

      # ── the intra-line word diff (jsdiff 8.0.4 port) ─────────────

      # pi renderIntraLineDiff's partition (diff.ts:29-66) as span parts:
      # common parts plain on both sides, changed parts [:reversed] —
      # except the FIRST changed part per side, whose leading whitespace
      # stays plain (diff.ts's strip; the stripped leading ws is kept as
      # its own plain part, matching the JS append order).
      def intra_line_parts(old_content, new_content)
        removed_parts = []
        added_parts = []
        first_removed = true
        first_added = true
        word_diff(old_content, new_content).each do |part|
          value = part[:value]
          if part[:removed]
            if first_removed
              leading = leading_ws(value)
              removed_parts << Part.new(leading, false) unless leading.empty?
              value = value[leading.length..].to_s
              first_removed = false
            end
            removed_parts << Part.new(value, true) unless value.empty?
          elsif part[:added]
            if first_added
              leading = leading_ws(value)
              added_parts << Part.new(leading, false) unless leading.empty?
              value = value[leading.length..].to_s
              first_added = false
            end
            added_parts << Part.new(value, true) unless value.empty?
          else
            removed_parts << Part.new(value, false) unless value.empty?
            added_parts << Part.new(value, false) unless value.empty?
          end
        end
        [removed_parts, added_parts]
      end

      # jsdiff 8.0.4 diffWords (word.js + base.js) — the observable
      # partition pi's pinned dep produces. Frozen ground truths (Grounds
      # §4, the deno jsdiff runs): "line two bravo"→"line two charlie
      # (edited)" = [COM "line two " / REM "bravo" / ADD "charlie
      # (edited)"]; "line four"→"line; four" = [COM "line" / ADD "; " /
      # COM "four"]; "line six"→"line six!" = [COM "line six" / ADD "!"].
      def word_diff(old_string, new_string)
        old_tokens = tokenize(old_string).reject(&:empty?)
        new_tokens = tokenize(new_string).reject(&:empty?)
        post_process(myers_diff(old_tokens, new_tokens))
      end

      # word.js tokenize: whitespace runs stitch onto the PRECEDING token;
      # a non-ws part after ws joins prevPart + part (the surrounding-
      # whitespace duplication join() undoes).
      def tokenize(value)
        tokens = []
        prev_part = nil
        value.scan(TOKENIZE_RE).each do |part|
          if part.match?(JS_WS_RE)
            if prev_part.nil?
              tokens << part
            else
              tokens << (tokens.pop + part)
            end
          elsif prev_part && prev_part.match?(JS_WS_RE)
            tokens << if tokens.last == prev_part
              tokens.pop + part
            else
              prev_part + part
            end
          else
            tokens << part
          end
          prev_part = part
        end
        tokens
      end

      # word.js equals — trimmed comparison (JS trim's whitespace class).
      def token_equals?(left, right)
        js_trim(left) == js_trim(right)
      end

      # word.js join: the first token verbatim, the rest stripped of
      # leading whitespace (undoes the stitch duplication).
      def word_join(tokens)
        tokens.each_with_index.map { |token, i| i.zero? ? token : token.sub(/\A#{JS_WS}+/, "") }.join
      end

      # base.js Myers O(ND) — the exact diagonal-pruning shape (the
        # bestPath sparse array over diagonals, the add/remove path
      # selection, the early min/max diagonal bounds, addToPath's run
      # coalescing, buildValues over the component list). Transcribed,
      # not approximated — the partition identity is the pin.
      def myers_diff(old_tokens, new_tokens)
        old_len = old_tokens.length
        new_len = new_tokens.length
        best_path = {0 => {old_pos: -1, last_component: nil}}
        min_diagonal = nil
        max_diagonal = nil

        new_pos = extract_common(best_path[0], new_tokens, old_tokens, 0)
        if best_path[0][:old_pos] + 1 >= old_len && new_pos + 1 >= new_len
          return build_values(best_path[0][:last_component], new_tokens, old_tokens)
        end

        edit_length = 1
        max_edit_length = new_len + old_len
        while edit_length <= max_edit_length
          # Math.max(minDiagonalToConsider, -editLength) ..
          # Math.min(maxDiagonalToConsider, editLength) — the bounds stay
          # infinite (nil here) until a path hits an edit-graph edge.
          diagonal = [min_diagonal || -Float::INFINITY, -edit_length].max
          last_diagonal = [max_diagonal || Float::INFINITY, edit_length].min
          while diagonal <= last_diagonal
            remove_path = best_path.delete(diagonal - 1)
            add_path = best_path[diagonal + 1]
            can_add = false
            if add_path
              add_path_new_pos = add_path[:old_pos] - diagonal
              can_add = add_path_new_pos >= 0 && add_path_new_pos < new_len
            end
            can_remove = remove_path && remove_path[:old_pos] + 1 < old_len
            if !can_add && !can_remove
              best_path.delete(diagonal)
              diagonal += 2
              next
            end
            base_path = if !can_remove || (can_add && remove_path[:old_pos] < add_path[:old_pos])
              add_to_path(add_path, true, false, 0)
            else
              add_to_path(remove_path, false, true, 1)
            end
            new_pos = extract_common(base_path, new_tokens, old_tokens, diagonal)
            if base_path[:old_pos] + 1 >= old_len && new_pos + 1 >= new_len
              return build_values(base_path[:last_component], new_tokens, old_tokens)
            end

            best_path[diagonal] = base_path
            max_diagonal = [max_diagonal || Float::INFINITY, diagonal - 1].min if base_path[:old_pos] + 1 >= old_len
            min_diagonal = [min_diagonal || -Float::INFINITY, diagonal + 1].max if new_pos + 1 >= new_len
            diagonal += 2
          end
          edit_length += 1
        end
        []
      end

      # base.js addToPath — the run coalescing (a same-kind step extends
      # the head component's count).
      def add_to_path(path, added, removed, old_pos_inc)
        last = path[:last_component]
        if last && last[:added] == added && last[:removed] == removed
          {old_pos: path[:old_pos] + old_pos_inc,
           last_component: {count: last[:count] + 1, added:, removed:,
                            previous_component: last[:previous_component]}}
        else
          {old_pos: path[:old_pos] + old_pos_inc,
           last_component: {count: 1, added:, removed:, previous_component: last}}
        end
      end

      # base.js extractCommon — the diagonal's keep run.
      def extract_common(base_path, new_tokens, old_tokens, diagonal)
        old_pos = base_path[:old_pos]
        new_pos = old_pos - diagonal
        common_count = 0
        while new_pos + 1 < new_tokens.length && old_pos + 1 < old_tokens.length &&
              token_equals?(old_tokens[old_pos + 1], new_tokens[new_pos + 1])
          new_pos += 1
          old_pos += 1
          common_count += 1
        end
        if common_count.positive?
          base_path[:last_component] = {count: common_count, previous_component: base_path[:last_component],
                                        added: false, removed: false}
        end
        base_path[:old_pos] = old_pos
        new_pos
      end

      # base.js buildValues (useLongestToken false for WordDiff): keeps
      # speak the NEW tokens, removals the OLD tokens.
      def build_values(last_component, new_tokens, old_tokens)
        components = []
        component = last_component
        while component
          components << component
          component = component[:previous_component]
        end
        components.reverse!
        new_pos = 0
        old_pos = 0
        components.map do |c|
          if c[:removed]
            value = word_join(old_tokens[old_pos, c[:count]] || [])
            old_pos += c[:count]
          else
            value = word_join(new_tokens[new_pos, c[:count]] || [])
            new_pos += c[:count]
            old_pos += c[:count] unless c[:added]
          end
          {value:, added: c[:added] ? true : false, removed: c[:removed] ? true : false}
        end
      end

      # word.js postProcess → dedupeWhitespaceInChangeObjects — the
      # whitespace dedupe over each keep-delimited segment, verbatim
      # branch for branch.
      def post_process(changes)
        last_keep = nil
        insertion = nil
        deletion = nil
        changes.each do |change|
          if change[:added]
            insertion = change
          elsif change[:removed]
            deletion = change
          else
            dedupe_whitespace(last_keep, deletion, insertion, change) if insertion || deletion
            last_keep = change
            insertion = nil
            deletion = nil
          end
        end
        dedupe_whitespace(last_keep, deletion, insertion, nil) if insertion || deletion
        changes
      end

      def dedupe_whitespace(start_keep, deletion, insertion, end_keep)
        if deletion && insertion
          old_ws_prefix = leading_ws(deletion[:value])
          old_ws_suffix = trailing_ws(deletion[:value])
          new_ws_prefix = leading_ws(insertion[:value])
          new_ws_suffix = trailing_ws(insertion[:value])
          if start_keep
            common_ws_prefix = longest_common_prefix(old_ws_prefix, new_ws_prefix)
            start_keep[:value] = replace_suffix(start_keep[:value], new_ws_prefix, common_ws_prefix)
            deletion[:value] = remove_prefix(deletion[:value], common_ws_prefix)
            insertion[:value] = remove_prefix(insertion[:value], common_ws_prefix)
          end
          if end_keep
            common_ws_suffix = longest_common_suffix(old_ws_suffix, new_ws_suffix)
            end_keep[:value] = replace_prefix(end_keep[:value], new_ws_suffix, common_ws_suffix)
            deletion[:value] = remove_suffix(deletion[:value], common_ws_suffix)
            insertion[:value] = remove_suffix(insertion[:value], common_ws_suffix)
          end
        elsif insertion
          # The whitespaces all reflect the new text: each keep keeps its
          # trailing whitespace, duplicate leading ws drops.
          if start_keep
            ws = leading_ws(insertion[:value])
            insertion[:value] = insertion[:value][ws.length..].to_s
          end
          if end_keep
            ws = leading_ws(end_keep[:value])
            end_keep[:value] = end_keep[:value][ws.length..].to_s
          end
        elsif start_keep && end_keep
          new_ws_full = leading_ws(end_keep[:value])
          del_ws_start = leading_ws(deletion[:value])
          del_ws_end = trailing_ws(deletion[:value])
          new_ws_start = longest_common_prefix(new_ws_full, del_ws_start)
          deletion[:value] = remove_prefix(deletion[:value], new_ws_start)
          new_ws_end = longest_common_suffix(remove_prefix(new_ws_full, new_ws_start), del_ws_end)
          deletion[:value] = remove_suffix(deletion[:value], new_ws_end)
          end_keep[:value] = replace_prefix(end_keep[:value], new_ws_full, new_ws_end)
          start_keep[:value] = replace_suffix(start_keep[:value], new_ws_full,
                                              new_ws_full[0...(new_ws_full.length - new_ws_end.length)].to_s)
        elsif end_keep
          end_keep_ws_prefix = leading_ws(end_keep[:value])
          deletion_ws_suffix = trailing_ws(deletion[:value])
          overlap = maximum_overlap(deletion_ws_suffix, end_keep_ws_prefix)
          deletion[:value] = remove_suffix(deletion[:value], overlap)
        elsif start_keep
          start_keep_ws_suffix = trailing_ws(start_keep[:value])
          deletion_ws_prefix = leading_ws(deletion[:value])
          overlap = maximum_overlap(start_keep_ws_suffix, deletion_ws_prefix)
          deletion[:value] = remove_prefix(deletion[:value], overlap)
        end
      end

      # ── util/string.js transcriptions ─────────────────────────────

      def longest_common_prefix(str1, str2)
        i = 0
        i += 1 while i < str1.length && i < str2.length && str1[i] == str2[i]
        str1[0, i]
      end

      def longest_common_suffix(str1, str2)
        return "" if str1.empty? || str2.empty? || str1[-1] != str2[-1]

        i = 0
        i += 1 while i < str1.length && i < str2.length && str1[str1.length - (i + 1)] == str2[str2.length - (i + 1)]
        i.zero? ? "" : str1[-i, i]
      end

      def replace_prefix(string, old_prefix, new_prefix)
        raise ArgumentError, "string doesn't start with prefix (bug)" unless string[0, old_prefix.length] == old_prefix

        new_prefix + string[old_prefix.length..].to_s
      end

      def replace_suffix(string, old_suffix, new_suffix)
        return string + new_suffix if old_suffix.empty?
        raise ArgumentError, "string doesn't end with suffix (bug)" unless string[-old_suffix.length, old_suffix.length] == old_suffix

        string[0...-old_suffix.length] + new_suffix
      end

      def remove_prefix(string, old_prefix)
        replace_prefix(string, old_prefix, "")
      end

      def remove_suffix(string, old_suffix)
        replace_suffix(string, old_suffix, "")
      end

      # util/string.js maximumOverlap — the KMP overlap count, transcribed
      # (string2's prefix that is string1's suffix).
      def maximum_overlap(string1, string2)
        string2[0, overlap_count(string1, string2)].to_s
      end

      def overlap_count(a, b)
        start_a = a.length > b.length ? a.length - b.length : 0
        end_b = a.length < b.length ? a.length : b.length
        map = Array.new(end_b, 0)
        k = 0
        (1...end_b).each do |j|
          if b[j] == b[k]
            map[j] = map[k]
          else
            map[j] = k
          end
          k = map[k] while k.positive? && b[j] != b[k]
          k += 1 if b[j] == b[k]
        end
        k = 0
        (start_a...a.length).each do |i|
          k = map[k] while k.positive? && a[i] != b[k]
          k += 1 if a[i] == b[k]
        end
        k
      end

      def leading_ws(string)
        string[/\A#{JS_WS}*/] || ""
      end

      def trailing_ws(string)
        i = string.length - 1
        i -= 1 while i >= 0 && string[i].match?(JS_WS_RE)
        string[(i + 1)..].to_s
      end

      def js_trim(string)
        string.sub(/\A#{JS_WS}+/, "").sub(/#{JS_WS}+\z/, "")
      end
    end
  end
end
