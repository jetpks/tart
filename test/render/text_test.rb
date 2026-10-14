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

    # --- the span-aware wrapSingleLine port (I56 AC2) ---

    # pi wrapSingleLine over the span vocabulary against the live-oracle
    # shapes (tmp/resize-calib/stage3/pi-w*.txt): the whitespace-break
    # class keeps the separator's leading space on the continuation (the
    # separator is its own muted segment — the re-issued SGR survives
    # trim, utils.ts:941), the word-break class leads with the word, a
    # fitting row passes through as the SAME object (the frozen 120-col
    # bytes), and an over-long word hard-breaks at exactly width cells.
    def test_wrap_spans_reproduces_the_pi_artifact_rows
      dim = ->(text) { TUI.span(text, fg: Theme[:dim]) }
      muted = ->(text) { TUI.span(text, fg: Theme[:muted]) }
      # The collapsed hint row's content spans (motd.rb's segment
      # structure: keyHint + a separate muted ` · ` separator).
      row = [
        TUI.span("█▀", fg: Theme[:logoBlue]), TUI.span(" "), TUI.span("█", fg: Theme[:logoYellow]),
        TUI.span(" "), dim.("escape"), muted.(" interrupt"), muted.(" · "),
        dim.("ctrl+c/ctrl+d"), muted.(" clear/exit"), muted.(" · "),
        dim.("/"), muted.(" commands"), muted.(" · "),
        dim.("!"), muted.(" bash"), muted.(" · "),
        dim.("ctrl+o"), muted.(" more")
      ]
      text = ->(r) { r.map { |s| s.content }.join }

      assert_equal ["█▀ █ escape interrupt · ctrl+c/ctrl+d clear/exit",
                    " · / commands · ! bash · ctrl+o more"],
        Render::Text.wrap_spans(row, 48).map { |r| text.(r) },
        "w50's whitespace-break class: the separator's leading space rides the continuation"
      assert_equal ["█▀ █ escape interrupt · ctrl+c/ctrl+d clear/exit ·",
                    "/ commands · ! bash · ctrl+o more"],
        Render::Text.wrap_spans(row, 50).map { |r| text.(r) },
        "w52's separator-carrying class"
      assert_equal ["█▀ █ escape interrupt · ctrl+c/ctrl+d clear/exit · / commands · ! bash ·",
                    "ctrl+o more"],
        Render::Text.wrap_spans(row, 78).map { |r| text.(r) },
        "w80's word-break class: no leading space"
      assert_equal [row], Render::Text.wrap_spans(row, 84),
        "a fitting row passes through as the same object"

      # The continuation's runs re-open per source segment: the muted ` · `
      # (leading space inside), the dim key.
      cont = Render::Text.wrap_spans(row, 48)[1]
      assert_equal [" · ", "/", " commands", " · ", "!", " bash", " · ", "ctrl+o", " more"],
        cont.map { |s| s.content }
      assert_equal Theme[:muted], cont[0].style.fg
      assert_equal Theme[:dim], cont[1].style.fg
    end

    def test_wrap_spans_hard_breaks_over_long_words_and_never_leads_with_whitespace
      word = [TUI.span("#{"a" * 9}/g.md")]
      broken = Render::Text.wrap_spans(word, 10)
      assert broken.all? { |r| TUI.text_width(r.map(&:content).join) <= 10 }, "every row fits width"
      assert_equal "#{"a" * 9}/g.md", broken.map { |r| r.map(&:content).join }.join, "the rows rejoin the word"

      plain = [TUI.span("aaaa bbbb")]
      assert_equal ["aaaa", "bbbb"], Render::Text.wrap_spans(plain, 5).map { |r| r.map(&:content).join }
      assert_equal ["", "aaaa"], Render::Text.wrap_spans([TUI.span(" aaaa")], 4).map { |r| r.map(&:content).join },
        "a plain whitespace token never starts a continuation"
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
