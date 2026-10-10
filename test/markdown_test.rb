# frozen_string_literal: true

require_relative "test_helper"

module RaspberryPi
  # The markdown converter (AC4): every subset construct's observable
  # distinction, cited to the pi oracle
  # (repos/pi/packages/tui/src/components/markdown.ts).
  class MarkdownTest < Test
    S = Render::Markdown::Span

    def test_paragraph_is_default_styled_text
      assert_equal [[S.new(text: "plain words")]], Render::Markdown.rows("plain words")
    end

    def test_blank_source_line_renders_a_blank_row
      rows = Render::Markdown.rows("one\n\ntwo")
      assert_equal [[S.new(text: "one")], [], [S.new(text: "two")]], rows
    end

    def test_h1_is_yellow_bold_underlined
      assert_equal [[S.new(text: "Title", fg: :yellow, modifiers: %i[bold underlined])]],
        Render::Markdown.rows("# Title"), "h1 = heading(bold(underline)) (markdown.ts:481-483)"
    end

    def test_h2_is_yellow_bold_without_underline_or_prefix
      assert_equal [[S.new(text: "Title", fg: :yellow, modifiers: [:bold])]],
        Render::Markdown.rows("## Title")
    end

    def test_h3_plus_keeps_a_styled_hash_prefix
      assert_equal [[S.new(text: "### ", fg: :yellow, modifiers: [:bold]),
                     S.new(text: "deep", fg: :yellow, modifiers: [:bold])]],
        Render::Markdown.rows("### deep"), "h3+ renders the styled '#' prefix (markdown.ts:493)"
    end

    def test_heading_gets_a_blank_row_before_a_following_paragraph
      rows = Render::Markdown.rows("# H\ntext")
      assert_equal [], rows[1], "spacing after a heading unless a space token follows (markdown.ts:494-499)"
    end

    def test_bold_is_the_bold_modifier
      assert_equal [[S.new(text: "bold", modifiers: [:bold])]],
        Render::Markdown.rows("**bold**"), "strong → theme.bold (markdown.ts:683-687)"
    end

    def test_italic_is_the_italic_modifier
      assert_equal [[S.new(text: "em", modifiers: [:italic])]],
        Render::Markdown.rows("*em*"), "em → theme.italic (markdown.ts:689-693)"
    end

    def test_bold_and_italic_nest
      assert_equal [[S.new(text: "bold ", modifiers: [:bold]),
                     S.new(text: "nested", modifiers: %i[bold italic])]],
        Render::Markdown.rows("**bold *nested***")
    end

    def test_strikethrough_is_the_crossed_out_modifier
      assert_equal [[S.new(text: "gone", modifiers: [:crossed_out])]],
        Render::Markdown.rows("~~gone~~"), "del → theme.strikethrough (markdown.ts:725-729)"
    end

    def test_strikethrough_is_strict
      assert_equal [[S.new(text: "~~ padded ~~")]],
        Render::Markdown.rows("~~ padded ~~"),
        "padded delimiters stay literal (StrictStrikethroughTokenizer, markdown.ts:9-21)"
    end

    def test_inline_code_is_violet_and_unparsed
      assert_equal [[S.new(text: "x = 1", fg: :light_magenta)]],
        Render::Markdown.rows("`x = 1`"), "codespan → theme.code (markdown.ts:695-697)"
      assert_equal [[S.new(text: "*raw*", fg: :light_magenta)]], Render::Markdown.rows("`*raw*`")
    end

    def test_fenced_code_block_has_border_rows_and_indented_green_body
      rows = Render::Markdown.rows("```ruby\nputs 1\n```")
      assert_equal [[S.new(text: "```ruby", fg: :gray)],
                    [S.new(text: "  "), S.new(text: "puts 1", fg: :green)],
                    [S.new(text: "```", fg: :gray)]], rows,
        "codeBlockBorder fences + '  '-indented codeBlock body (markdown.ts:530-550)"
    end

    def test_blockquote_prefixes_with_border_and_grays_italics_content
      rows = Render::Markdown.rows("> quoted")
      assert_equal [[S.new(text: "│ ", fg: :gray),
                     S.new(text: "quoted", fg: :gray, modifiers: [:italic])]], rows,
        "quoteBorder('│ ') prefix + quote(italic(text)) (markdown.ts:566-606)"
    end

    def test_multiline_blockquote_is_one_row_per_source_line
      rows = Render::Markdown.rows("> a\n> b")
      assert_equal 2, rows.size
      assert_equal "│ ", rows[1].first.text
    end

    def test_hr_is_ashes_sized_to_width_capped_at_80
      assert_equal [[S.new(text: "─" * 80, fg: :gray)]], Render::Markdown.rows("---"),
        "theme.hr('─' * min(width, 80)) (markdown.ts:615-617)"
      assert_equal [[S.new(text: "─" * 10, fg: :gray)]], Render::Markdown.rows("***", width: 10)
    end

    def test_unordered_list_normalizes_to_dash_bullet
      rows = Render::Markdown.rows("* one\n+ two\n  wrapped")
      assert_equal [[S.new(text: "- ", fg: :light_magenta), S.new(text: "one")],
                    [S.new(text: "- ", fg: :light_magenta), S.new(text: "two")],
                    [S.new(text: "  "), S.new(text: "wrapped")]], rows,
        "bullets normalized to '- ', listBullet-styled, continuation indented to marker width (markdown.ts:775-789)"
    end

    def test_ordered_list_renumbers_from_the_list_start
      rows = Render::Markdown.rows("1. a\n2. b")
      assert_equal [[S.new(text: "1. ", fg: :light_magenta), S.new(text: "a")],
                    [S.new(text: "2. ", fg: :light_magenta), S.new(text: "b")]], rows
      assert_equal "3. ", Render::Markdown.rows("3. x").first.first.text, "start number honored (markdown.ts:776-777)"
    end

    def test_list_gets_no_trailing_blank_row_before_a_following_block
      rows = Render::Markdown.rows("- a\n\nnext")
      assert_equal [[S.new(text: "- ", fg: :light_magenta), S.new(text: "a")], [],
        [S.new(text: "next")]], rows,
        "exactly one blank row after a list — no list trailing spacing (markdown.ts:552-554)"
    end

    def test_nested_list_indents_and_bullets
      rows = Render::Markdown.rows("- a\n  - b")
      assert_equal [[S.new(text: "- ", fg: :light_magenta), S.new(text: "a")],
                    [S.new(text: "    "), S.new(text: "- ", fg: :light_magenta), S.new(text: "b")]], rows,
        "nested list: one indent level per depth, unprefixed (markdown.ts:794-798)"
    end

    def test_loose_list_inserts_blank_rows_between_items
      rows = Render::Markdown.rows("- a\n\n- b")
      assert_equal 3, rows.size
      assert_equal [], rows[1], "loose lists space their items (markdown.ts:799-802)"
    end

    def test_link_is_blue_underlined_with_the_url_fallback
      rows = Render::Markdown.rows("[pi](https://pi.dev)")
      assert_equal [[S.new(text: "pi", fg: :light_blue, modifiers: [:underlined]),
                     S.new(text: " (https://pi.dev)", fg: :gray)]], rows,
        "link(underline(text)) + linkUrl(' (href)') when text differs (markdown.ts:699-719)"
    end

    def test_link_with_text_equal_to_href_has_no_url_suffix
      assert_equal [[S.new(text: "https://pi.dev", fg: :light_blue, modifiers: [:underlined])]],
        Render::Markdown.rows("[https://pi.dev](https://pi.dev)"), "markdown.ts:712-714"
    end

    def test_escaped_delimiters_are_literal
      assert_equal [[S.new(text: "*not em*")]], Render::Markdown.rows("\\*not em\\*")
    end

    def test_converter_source_is_gem_neutral
      source = File.read(File.expand_path("../lib/raspberry_pi/render/markdown.rb", __dir__))
      refute_includes source, "RatatuiRuby", "the tui-seam gate scans all of lib"
    end
  end
end
