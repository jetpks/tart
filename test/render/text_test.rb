# frozen_string_literal: true

require_relative "../test_helper"

module Tart
  # The pure text/wrap helpers moved off the chat surface (I21 wave 1):
  # word wrap, styled-row wrap, and the footer formatting pairs — the
  # moved families' tests, call sites updated (Chat.* → Text.*).
  class TextTest < Test
    def test_wrap_row_wraps_styled_rows_preserving_spans
      bold = Render::Markdown::Span.new(text: "bold", modifiers: [:bold])
      row = [Render::Markdown::Span.new(text: "plain "), bold]
      rows = Render::Text.wrap_row(row, 9) # "plain bold" is 10 cells

      assert_equal ["plain", "bold"], rows.map { |r| r.map(&:text).join },
        "the break consumes the separator space, as {wrap} does"
      assert_equal [:bold], rows[1].first.modifiers, "styling survives the wrap"
      assert_equal [row], Render::Text.wrap_row(row, 10), "a fitting row passes through unchanged"
      assert_equal [[]], Render::Text.wrap_row([], 10), "a blank row stays blank"
    end

    # --- wrapping ---

    def test_wrap_breaks_words_and_hard_splits_long_words
      assert_equal ["aaaa", "bbbb"], Render::Text.wrap("aaaa bbbb", 5)
      assert_equal ["aaaa bbbb"], Render::Text.wrap("aaaa bbbb", 9)
      assert_equal ["", "aaaa"], Render::Text.wrap(" aaaa", 4)
      assert_equal ["aaaa bbbb", "cccc dddd"], Render::Text.wrap("aaaa bbbb cccc dddd", 9)
      assert_equal ["aaaaa", "bbbbb"], Render::Text.wrap("aaaaabbbbb", 5), "over-long words hard-split"
      assert_equal [""], Render::Text.wrap("", 5)
    end

    # --- footer formatting (AC4, pi footer.ts) ---

    def test_format_tokens_compacts_counts_like_pi
      assert_equal "999", Render::Text.format_tokens(999)
      assert_equal "1.0k", Render::Text.format_tokens(1000)
      assert_equal "12k", Render::Text.format_tokens(12_345)
      assert_equal "1.2M", Render::Text.format_tokens(1_234_567)
      assert_equal "12M", Render::Text.format_tokens(12_345_678)
      assert_equal "1235M", Render::Text.format_tokens(1_234_567_890)
    end

    def test_format_cwd_contracts_the_home_prefix
      home = Dir.home
      assert_equal "~", Render::Text.format_cwd(home, home)
      assert_equal "~/sub/dir", Render::Text.format_cwd(File.join(home, "sub", "dir"), home)
      assert_equal "/elsewhere", Render::Text.format_cwd("/elsewhere", home), "outside home renders absolute"
    end
  end
end
