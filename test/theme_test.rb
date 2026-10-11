# frozen_string_literal: true

require_relative "test_helper"

module Tart
  # The theme token table (AC3): pure data + lookup, no LLM, no tty —
  # the table is checked against the pi transcription (theme-tokens.ts
  # names, dark.json values mapped onto the gem's ANSI color symbols).
  class ThemeTest < Test
    # Every token the port's surface renders, with its pi dark.json source
    # value and the color the port renders. Content-path tokens carry the
    # TRUE hex (converted with pi's own pi-tui parseColor/colorToHex,
    # verified live); non-content tokens keep their 16-color analogs
    # (itemized reduction).
    EXPECTED = {
      text: "#dee0e1",                # dark.json:6 "text" okhsl(234 3% 89%) — body prose, truecolor
      dim: :gray,                     # "dim" okhsl(229 8% 56%) (dark.json:24) — the mid-gray analog, I14 item 9
      muted: :gray,                   # "muted" okhsl(229 6% 67%) — footer/autocomplete (non-content)
      border: :gray,                  # "borderMuted" okhsl(229 8% 53%)
      warning: :yellow,               # "warning" yellow
      error: :red,                    # "error" red
      accent: :light_magenta,         # "accent" violet (dark.json vars)
      user_message_text: "#dee0e1",   # dark.json:32 — userMessageText = the "text" token
      user_message_bg: "#213b49",     # dark.json:13/:33 — blueBg okhsl(233 41% 24%)
      tool_output: "#9da5a9",         # dark.json:35 "toolOutput" = muted okhsl(229 6% 67%)
      md_heading: :yellow,            # dark.json:42
      md_link: :light_blue,           # dark.json:43 blue
      md_link_url: :gray,             # dark.json:44 muted
      md_code: :light_magenta,        # dark.json:45 violet
      md_code_block: :green,          # dark.json:46
      md_code_block_border: :gray,    # dark.json:47 muted
      md_quote: :gray,                # dark.json:48 muted
      md_quote_border: :gray,         # dark.json:49 muted
      md_hr: :gray,                   # dark.json:50 muted
      md_list_bullet: :light_magenta, # dark.json:51 violet
      thinkingText: "#96a0a4",        # dark.json:26 okhsl(226 7% 65%) — truecolor
      scrollbarTrack: :blue,      # dark.json:28 okhsl(237 7% 33%) — dark member of the blue pair
      scrollbarThumb: :light_blue, # dark.json:29 okhsl(232 7% 65%) — light member of the blue pair
    }.freeze

    def test_token_table_carries_the_pi_transcription
      assert_equal EXPECTED, Theme::TOKENS
    end

    def test_lookup_returns_the_token_color
      assert_equal :red, Theme[:error]
      assert_equal "#dee0e1", Theme[:text], "body prose carries the text token's true color (dark.json:6)"
      assert_raises(KeyError) { Theme[:not_a_token] }
    end

    def test_markdown_fg_routes_through_the_table
      assert_equal Theme[:md_heading], Theme.md_fg(:yellow)
      assert_equal Theme[:md_link], Theme.md_fg(:light_blue)
      assert_equal Theme[:md_code], Theme.md_fg(:light_magenta)
      assert_equal Theme[:md_code_block], Theme.md_fg(:green)
      assert_equal Theme[:md_quote], Theme.md_fg(:gray)
    end

    def test_markdown_fg_passes_unknown_symbols_through
      assert_equal :custom, Theme.md_fg(:custom)
      assert_equal Theme[:text], Theme.md_fg(nil), "plain prose routes to the text token (pi renders prose truecolor)"
    end

    # The I05 FG map is absorbed: every role the chat surface renders has a
    # theme token (no color literals left in the surface). The content-path
    # tokens carry TRUE values (I15 item 4); the non-content analogs stand.
    def test_surface_roles_resolve_through_the_theme
      assert_equal Theme[:user_message_text], Theme[:text], "pi userMessageText = text on the blue bg (dark.json:32-33)"
      refute_equal Theme[:tool_output], Theme[:muted], "tool output is truecolor; the autocomplete muted analog stands"
      assert_equal Theme[:dim], :gray, "the footer-dim analog (I14 item 9: pi's whole footer is dim, okhsl 56%)"
      assert_equal Theme[:warning], :yellow
      assert_equal Theme[:error], :red
    end

    # The I13 promotions (dark.json:26-29, blue-tinted family): the
    # scrollbar keeps its 16-color analogs (non-content, itemized);
    # thinkingText went truecolor (I15 item 4).
    def test_scrollbar_and_reasoning_tokens_carry_pis_blue_tinted_values
      assert_equal "#96a0a4", Theme[:thinkingText]
      assert_equal :blue, Theme[:scrollbarTrack]
      assert_equal :light_blue, Theme[:scrollbarThumb]
      refute_equal Theme[:dim], Theme[:scrollbarTrack]
      refute_equal Theme[:muted], Theme[:scrollbarThumb]
    end
  end
end
