# frozen_string_literal: true

require_relative "../test_helper"

module Tart
  module Render
    # The edit block family (I57 — pi renderers/edit.ts + components/
    # diff.ts over tool-execution.ts's box): the settled success/error/
    # no-details frames, the pending frame, the renderDiff row vocabulary
    # (context/removed/added tokens, the intra-line inverse runs, the
    # truncation row, the no-intra run shapes), the jsdiff 8.0.4
    # partition ground truths (Grounds §4, the deno runs), and the theme
    # tokens. Row-exact against build/i57-spec/pi-edit-block-oracle.txt
    # (pi's own ToolExecutionComponent rendered at width 120) and the
    # live captures under tmp/edit-bg-calib/.
    class EditBlockTest < Test
      WIDTH = 120

      ARGS = { "path" => "edit-bg.txt" }.freeze
      SUCCESS = "Successfully replaced 1 block(s) in edit-bg.txt."
      DETAILS = { diff: " 1 alpha line one\n-2 line two bravo\n+2 line two charlie (edited)\n 3 line three",
                  patch: "", firstChangedLine: 2 }.freeze

      def texts(rows)
        rows.map { |line| row_text(line) }
      end

      def row_text(line)
        line.spans.map(&:content).join
      end

      def fg_of(line)
        line.spans.map { |span| span.style&.fg }.compact.uniq
      end

      def pads_carry_bg?(rows, bg)
        rows.all? { |row| row.spans.all? { |span| span.style&.bg == bg } }
      end

      # --- AC2: the settled frames ---

      # The SELF-SHELL oracle's SETTLED success frame (rows 0-8, the
      # re-probed renderShell:"self" component at 120): the plain Spacer,
      # one padY, the header, the call spacer, the four diff rows, the
      # padY bottom — every pad full-width over the success bg.
      def test_settled_success_renders_the_oracle_row_skeleton
        rows = EditBlock.edit_block_rows(ARGS, SUCCESS, DETAILS, WIDTH)

        assert_equal 9, rows.length, "spacer + pad + header + spacer + 4 diff rows + pad"
        assert_equal "", texts(rows)[0], "the component's Spacer stays PLAIN"
        assert_equal [" edit edit-bg.txt"], texts(rows)[2..2].map(&:rstrip), "the header row"
        assert_equal ["  1 alpha line one", " -2 line two bravo", " +2 line two charlie (edited)",
                      "  3 line three"], texts(rows)[4, 4].map(&:rstrip), "the diff rows (pad-led)"
        assert_equal ["", "", ""], [1, 3, 8].map { |i| texts(rows)[i].rstrip }, "the pads"
        assert pads_carry_bg?([rows[1], rows[3], rows[8]], Theme[:tool_success_bg]),
               "every pad rides the success bg"
        refute rows[0].spans.any? { |span| span.style&.bg }, "the Spacer row stays bg-less"
      end

      # pi formatEditCall: bold toolTitle `edit` + space + the accent path.
      def test_header_renders_the_bold_title_and_the_accent_path
        header = EditBlock.header_rows(ARGS, WIDTH, bg: Theme[:tool_success_bg])

        assert_equal 1, header.length, "the short header is one row"
        spans = header[0].spans
        assert_equal "edit", spans[1].content
        assert_equal Theme[:toolTitle], spans[1].style.fg, "the toolTitle token"
        assert_includes spans[1].style.modifiers, :bold, "theme.bold"
        assert_equal "edit-bg.txt", spans[3].content
        assert_equal Theme[:accent], spans[3].style.fg, "the renderToolPath accent token"
        assert_equal Theme[:tool_success_bg], spans[0].style.bg, "the OUTPUT_PAD lead rides the bg"
      end

      # pi renderToolPath: the ~ contraction under home, "..." when the
      # path is absent (write.ts:105's fallback shape).
      def test_header_contracts_home_and_falls_back_to_ellipsis
        contracted = EditBlock.header_rows({ "path" => "#{Dir.home}/x/y.md" }, WIDTH)
        assert_includes texts(contracted)[0], " ~/x/y.md", "the ~ contraction"

        absent = EditBlock.header_rows({}, WIDTH)
        assert_includes texts(absent)[0], " ...", "the absent-path fallback"
      end

      # The diff rows speak pi's renderDiff tokens (Grounds §3 — context
      # #9da5a9, removed #ea7f81, added #68b78d against the live capture).
      def test_success_diff_rows_carry_the_token_colors
        rows = EditBlock.edit_block_rows(ARGS, SUCCESS, DETAILS, WIDTH)
        context, removed, added = rows[4], rows[5], rows[6]

        assert_equal [Theme[:tool_diff_context]], fg_of(context), "context rows ride toolDiffContext"
        assert_equal [Theme[:tool_diff_removed]], fg_of(removed), "removed rows ride toolDiffRemoved"
        assert_equal [Theme[:tool_diff_added]], fg_of(added), "added rows ride toolDiffAdded"
      end

      # pi renderIntraLineDiff: the changed parts render [:reversed]; the
      # prefix and common text stay plain.
      def test_intra_line_inverse_runs
        rows = EditBlock.edit_block_rows(ARGS, SUCCESS, DETAILS, WIDTH)
        removed_spans = rows[5].spans
        added_spans = rows[6].spans

        reversed_removed = removed_spans.select { |span| span.style.modifiers.include?(:reversed) }
        assert_equal ["bravo"], reversed_removed.map(&:content), "the removed changed part inverts"
        plain_removed = removed_spans.reject { |span| span.style.modifiers.include?(:reversed) }
        assert_equal [" ", "-2 ", "line two "], plain_removed[0, 3].map(&:content),
               "the pad, the prefix and the common text stay plain"
        reversed_added = added_spans.select { |span| span.style.modifiers.include?(:reversed) }
        assert_equal ["charlie (edited)"], reversed_added.map(&:content), "the added changed part inverts"
        plain_added_prefix = added_spans.take_while { |span| !span.style.modifiers.include?(:reversed) }
        assert_equal [" ", "+2 ", "line two "], plain_added_prefix.map(&:content),
               "the added row's plain prefix"
      end

      # The Grounds §4 "line four"→"line; four" case: the removed row's
      # first changed part is pure whitespace — its leading ws renders
      # PLAIN (diff.ts's strip), the rest is empty → the space VANISHES
      # and no inverse run rides the removed row (the oracle's -4 row).
      def test_intra_line_whitespace_only_changed_part_stays_plain_and_vanishes
        details = { diff: "-4 line four\n+4 line; four", patch: "", firstChangedLine: 4 }
        rows = EditBlock.edit_block_rows(ARGS, SUCCESS, details, WIDTH)
        removed, added = rows[4], rows[5]

        assert_equal "-4 linefour", row_text(removed).strip, "the swallowed space (the oracle row)"
        refute removed.spans.any? { |span| span.style.modifiers.include?(:reversed) },
               "no inverse bytes on the removed row"
        reversed = added.spans.select { |span| span.style.modifiers.include?(:reversed) }
        assert_equal ["; "], reversed.map(&:content), "the '; ' token inverts on the added row"
        assert_equal "+4 line; four", row_text(added).strip, "line + reversed('; ') + four (the oracle row)"
      end

      # The frozen jsdiff 8.0.4 partitions (Grounds §4 — the deno runs
      # against pi's pinned dep; the port reproduces all three verbatim).
      def test_word_diff_partitions_match_the_frozen_ground_truths
        part = ->(text, inverse) { EditBlock::Part.new(text, inverse) }
        e1, = EditBlock.intra_line_parts("line two bravo", "line two charlie (edited)")
        assert_equal [part.call("line two ", false), part.call("bravo", true)], e1

        rem2, add2 = EditBlock.intra_line_parts("line four", "line; four")
        assert_equal [part.call("line", false), part.call("four", false)], rem2,
               "COM line / (the ws part strips empty) / COM four"
        assert_equal [part.call("line", false), part.call("; ", true), part.call("four", false)], add2

        rem3, add3 = EditBlock.intra_line_parts("line six", "line six!")
        assert_equal [part.call("line six", false)], rem3, "no removed parts — the removed row stays plain"
        assert_equal [part.call("line six", false), part.call("!", true)], add3

        parts = EditBlock.word_diff("line two bravo", "line two charlie (edited)")
        assert_equal [{ value: "line two ", added: false, removed: false },
                      { value: "bravo", added: false, removed: true },
                      { value: "charlie (edited)", added: true, removed: false }], parts
      end

      # The SELF-SHELL oracle's SETTLED error frame (rows 0-5): the error
      # body renders INSIDE the call component after its Spacer (the
      # preview error == the result error — the rebuild carries the body;
      # the renderResult Container stays empty) — bg-filled error-token
      # rows, then the padY bottom.
      def test_error_arm_renders_the_error_rows_after_the_spacer
        message = "Could not find the exact text in edit-bg.txt. The old text must match exactly " \
                  "including all whitespace and newlines."
        rows = EditBlock.edit_block_rows(ARGS, { error: message }, nil, WIDTH)

        assert_equal 6, rows.length, "spacer + pad + header + spacer + error row + pad"
        assert_includes row_text(rows[4]), message, "the error text row"
        assert_equal [Theme[:error]], fg_of(rows[4]), "the error token"
        assert_equal Theme[:tool_error_bg], rows[4].spans[0].style.bg, "the error row rides the bg"
        assert pads_carry_bg?([rows[1], rows[3], rows[4], rows[5]], Theme[:tool_error_bg]),
               "the pads + the error row ride the error bg"
        assert_equal Theme[:tool_error_bg], Panel.tool_panel_bg({ error: message }), "the error bg pin"
      end

      # Success with NO details (sessions recorded pre-I57): the
      # header-only block — no spacer, no body rows.
      def test_success_without_details_renders_header_only
        rows = EditBlock.edit_block_rows(ARGS, SUCCESS, nil, WIDTH)

        assert_equal 4, rows.length, "spacer + pad + header + pad"
        assert_includes texts(rows)[2], " edit edit-bg.txt"
      end

      # The replayed recorded shape: string-keyed details (the session
      # JSON) render the same diff rows.
      def test_replayed_string_key_details_render_the_diff
        recorded = { "diff" => "-2 line two bravo\n+2 line two charlie (edited)",
                     "patch" => "", "firstChangedLine" => 2 }
        rows = EditBlock.edit_block_rows(ARGS, SUCCESS, recorded, WIDTH)

        assert_equal "-2 line two bravo", row_text(rows[4]).strip
        assert_equal "+2 line two charlie (edited)", row_text(rows[5]).strip
      end

      # --- AC3: the pending frame ---

      # The SELF-SHELL oracle's PENDING frame (rows 0-3): the header alone
      # under the pending bg between the call Box pads — the preview cut
      # (Grounds §6).
      def test_pending_block_renders_the_header_under_the_pending_bg
        rows = EditBlock.pending_edit_block_rows(ARGS, WIDTH)

        assert_equal 4, rows.length, "Spacer + pad + header + pad"
        assert_equal "", texts(rows)[0], "the Spacer stays PLAIN"
        assert_includes texts(rows)[2], " edit edit-bg.txt"
        assert pads_carry_bg?([rows[1], rows[3]], Theme[:tool_pending_bg]), "the pads ride the pending bg"
        assert_equal Theme[:tool_pending_bg], rows[2].spans[0].style.bg, "the header row rides the bg too"
      end

      # --- the renderDiff row vocabulary ---

      # The "   ..." truncation row parses with an EMPTY lineNum and
      # renders as context (the live pi row "    ...").
      def test_truncation_row_renders_as_context
        rows = EditBlock.edit_block_rows(ARGS, SUCCESS,
                                         { diff: " 1 alpha line one\n   ...", patch: "", firstChangedLine: 1 }, WIDTH)

        assert_equal "    ...", texts(rows)[5].rstrip, "pad + ' ' + '' + ' ' + '...'"
        assert_equal [Theme[:tool_diff_context]], fg_of(rows[5])
      end

      # Non-parsing rows render VERBATIM in toolDiffContext (diff.ts's
      # !parsed arm — no tab replacement, no recomposition).
      def test_non_parsing_rows_render_verbatim_in_context
        rows = EditBlock.edit_block_rows(ARGS, SUCCESS,
                                         { diff: "garbage line\tstays", patch: "", firstChangedLine: 1 }, WIDTH)

        assert_equal " garbage line\tstays", row_text(rows[4]).rstrip, "the raw line, pad-led (no re-composition)"
        assert_equal [Theme[:tool_diff_context]], fg_of(rows[4])
      end

      # The Grounds §4 calib-2/3 classes: multi-row runs (2+2) render
      # as-is per-row — NO intra-line diffing.
      def test_multi_row_runs_render_without_intra
        details = { diff: "-1 a one\n-2 a two\n+1 b one\n+2 b two", patch: "", firstChangedLine: 1 }
        rows = EditBlock.edit_block_rows(ARGS, SUCCESS, details, WIDTH)
        body = rows[4, 4]

        assert_equal ["-1 a one", "-2 a two", "+1 b one", "+2 b two"], body.map { |r| row_text(r).strip }
        refute body.any? { |row| row.spans.any? { |span| span.style.modifiers.include?(:reversed) } },
               "no inverse runs in a merged run"
        assert_equal [Theme[:tool_diff_removed]], fg_of(body[0]), "removed rows first"
        assert_equal [Theme[:tool_diff_added]], fg_of(body[2]), "then the added rows"
      end

      # pi's Text wraps inside the box: an over-wide diff row wraps
      # through the call-row family, every row bg-padded to the width.
      def test_long_rows_wrap_at_the_width
        long_content = "word " * 40
        details = { diff: "-1 #{long_content}\n+1 #{long_content}x", patch: "", firstChangedLine: 1 }
        rows = EditBlock.edit_block_rows(ARGS, SUCCESS, details, WIDTH)
        body = rows[4..].reject { |row| row_text(row).strip.empty? }

        assert body.length > 2, "the removed and added rows each wrapped"
        body.each do |row|
          assert_operator TUI.text_width(row_text(row).rstrip), :<=, WIDTH, "no row overflows"
          assert_equal Theme[:tool_success_bg], row.spans[0].style.bg, "wrapped rows keep the bg"
        end
      end

      # --- P4: the theme tokens ---

      # dark.json's green/red/muted vars (Grounds §3 — confirmed against
      # the live-pi styled capture), resolvable through Theme[].
      def test_theme_tokens_carry_the_pi_diff_colors
        assert_equal "#68b78d", Theme::DIFF_TOKENS[:tool_diff_added], "dark.json green var"
        assert_equal "#ea7f81", Theme::DIFF_TOKENS[:tool_diff_removed], "dark.json red var"
        assert_equal "#9da5a9", Theme::DIFF_TOKENS[:tool_diff_context], "dark.json muted var"
        # The frozen full-table pin on TOKENS is untouched — the diff
        # tokens ride the sibling table.
        refute Theme::TOKENS.key?(:tool_diff_added), "TOKENS itself stays byte-frozen"
      end

      def test_diff_tokens_resolve_through_the_theme_lookup
        color = Theme[:tool_diff_removed]
        if Theme.truecolor?
          assert_equal "#ea7f81", color
        else
          assert_kind_of Integer, color, "the 256-color downgrade path"
        end
      end
    end
  end
end
