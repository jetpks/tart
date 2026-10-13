# frozen_string_literal: true

require_relative "../test_helper"

module Tart
  module Render
    # The RUNNING !-prefix bash block's composer (I38 — pi's
    # BashExecutionComponent running branch, bash-execution.ts:147-165):
    # the prefix property against the completed family (byte-shared head),
    # the loader row's bytes/colors, and the mid-flight status
    # suppressions. Builder-level pins; the wiring lives in chat_test.
    class BashBlockTest < Test
      WIDTH = 40
      COMMAND = "echo hi"

      def texts(rows)
        rows.map { |line| line.spans.map(&:content).join }
      end

      # Byte + style digests: the prefix property compares SPANS, not just
      # text (fg/modifiers ride the shared head too).
      def digests(rows)
        rows.map do |line|
          line.spans.map { |span| [span.content, span.style&.fg, span.style&.bg, (span.style&.modifiers || []).sort] }
        end
      end

      def completed_rows(content:, excluded: false, expanded: false)
        BashBlock.user_bash_block_rows(COMMAND, WIDTH, content:, exit_code: nil, cancelled: false,
                                       truncated: false, full_output_path: nil, excluded:, expanded:)
      end

      def running_rows(content:, excluded: false, expanded: false, glyph: "⠋")
        BashBlock.running_user_bash_rows(COMMAND, WIDTH, content:, excluded:, spinner_glyph: glyph, expanded:)
      end

      # The zero-status completed family's status block, derived
      # ANALYTICALLY from the shape (independent of the composer): blank +
      # hidden-hint rows whenever >20 logical lines exist — collapsed
      # renders "... N more lines (ctrl+o to expand)", expanded renders
      # "(ctrl+o to collapse)"; either way 2 rows.
      def status_block_length(content, _expanded)
        logical = content.empty? ? 0 : content.split("\n", -1).length
        hidden = logical - [logical, BashBlock::USER_BASH_PREVIEW_LINES].min
        hidden.positive? ? 2 : 0
      end

      # AC1's prefix property (the composer's observable contract): for any
      # accumulated text T, the running rows are the completed family with
      # the status block replaced by [blank, loader row].
      def test_running_rows_equal_the_completed_family_with_the_status_block_replaced
        contents = {
          "" => "the empty T",
          "short" => "one short line",
          Array.new(25) { |i| "row #{i + 1}" }.join("\n") => "25 logical lines",
          "#{'x' * 120}\n#{'y' * 120}" => "wrapped long lines",
        }
        contents.each do |content, label|
          [false, true].each do |expanded|
            completed = completed_rows(content:, expanded:)
            running = running_rows(content:, expanded:)
            expected = completed.take(completed.length - 1 - status_block_length(content, expanded)) +
              [Panel.blank_line, running[-2]] + [completed.last]
            assert_equal digests(expected), digests(running),
              "the prefix property holds for #{label} (expanded: #{expanded})"
          end
        end

        [false, true].each do |excluded|
          completed = completed_rows(content: "a\nb", excluded:)
          running = running_rows(content: "a\nb", excluded:)
          expected = completed.take(completed.length - 1 - status_block_length("a\nb", false)) +
            [Panel.blank_line, running[-2]] + [completed.last]
          assert_equal digests(expected), digests(running), "the prefix property holds excluded: #{excluded}"
        end
      end

      # AC1's empty-T shape: header + blank + loader row + border (over the
      # family's leading blank).
      def test_empty_content_renders_header_blank_loader_border
        rows = running_rows(content: "")
        assert_equal ["", "─" * WIDTH, " $ echo hi", "", " ⠋ Running... (escape/ctrl+c to cancel)", "─" * WIDTH],
          texts(rows), "the empty-T running shape"
      end

      # The loader row is pi's Loader bytes (loader.ts): pad unstyled, the
      # spinner in the colorKey, the message muted — the literal text
      # keyText("tui.select.cancel") resolves to (keybindings.ts:155-158).
      def test_loader_row_bytes_and_colors
        rows = running_rows(content: "out", glyph: "⠙")
        loader = rows.find { |row| texts([row]).first.include?("Running...") }
        spans = loader.spans
        assert_equal " ", spans[0].content, "the one-space pad (Text padX 1)"
        assert_nil spans[0].style&.fg, "the pad is unstyled"
        assert_equal "⠙", spans[1].content
        assert_equal Theme[:bashMode], spans[1].style.fg, "the spinner rides the block's colorKey"
        assert_equal " Running... (escape/ctrl+c to cancel)", spans[2].content, "pi's literal message bytes"
        assert_equal Theme[:muted], spans[2].style.fg, "the message is muted (loader.ts messageColorFn)"
      end

      # The colorKey: "!!" marks the excluded execution dim (the component
      # constructor's colorKey — bash-execution.ts:38).
      def test_bang_bang_running_rows_ride_dim
        rows = running_rows(content: "out", excluded: true, glyph: "⠙")
        assert_equal Theme[:dim], rows[1].spans[0].style.fg, "the border rides dim"
        assert_equal Theme[:dim], rows[2].spans[1].style.fg, "the header rides dim"
        assert_equal Theme[:dim], rows[-2].spans[1].style.fg, "the spinner rides dim"
      end

      # pi's running branch REPLACES the whole statusParts block
      # (bash-execution.ts:147-165) — no hidden-lines hint mid-flight in
      # either toggle state.
      def test_running_rows_render_no_hidden_lines_hint
        content = Array.new(25) { |i| "row #{i + 1}" }.join("\n")
        [false, true].each do |expanded|
          rows = texts(running_rows(content:, expanded:))
          refute rows.any? { |row| row.include?("more lines") || row.include?("to collapse") },
            "no hidden-lines hint mid-flight (expanded: #{expanded})"
        end
      end
    end
  end
end
