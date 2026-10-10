# frozen_string_literal: true

require_relative "test_helper"

module Tart
  # The theme token table (AC3): pure data + lookup, no LLM, no tty —
  # the table is checked against the pi transcription (theme-tokens.ts
  # names, dark.json values mapped onto the gem's ANSI color symbols).
  class ThemeTest < Test
    # Every token the port's surface renders, with its pi dark.json source
    # value and the ANSI analog the port renders (the I05/I06-established
    # mappings — rendered output stays identical where tests pin it).
    EXPECTED = {
      text: nil,                      # dark.json "text" — the terminal default
      dim: :dark_gray,                # "dim" okhsl(229 8% 56%)
      muted: :gray,                   # "muted" okhsl(229 6% 67%)
      border: :gray,                  # "borderMuted" okhsl(229 8% 53%)
      warning: :yellow,               # "warning" yellow
      error: :red,                    # "error" red
      accent: :light_magenta,         # "accent" violet (dark.json vars)
      user_message_text: :light_blue, # userMessageBg's blue carried as fg (I05 recorded)
      tool_output: :gray,             # "toolOutput" muted
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
      thinkingText: :light_blue,  # dark.json:26 okhsl(226 7% 65%) — light member of the blue pair
      scrollbarTrack: :blue,      # dark.json:28 okhsl(237 7% 33%) — dark member of the blue pair
      scrollbarThumb: :light_blue, # dark.json:29 okhsl(232 7% 65%) — light member of the blue pair
    }.freeze

    def test_token_table_carries_the_pi_transcription
      assert_equal EXPECTED, Theme::TOKENS
    end

    def test_lookup_returns_the_token_color
      assert_equal :red, Theme[:error]
      assert_nil Theme[:text], "the default text color is the terminal default"
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
      assert_nil Theme.md_fg(nil), "an unstyled span stays unstyled"
    end

    # The I05 FG map is absorbed: every role the chat surface renders has a
    # theme token (no color literals left in the surface).
    def test_surface_roles_resolve_through_the_theme
      assert_equal Theme[:user_message_text], :light_blue
      assert_equal Theme[:tool_output], Theme[:muted]
      assert_equal Theme[:dim], :dark_gray
      assert_equal Theme[:warning], :yellow
      assert_equal Theme[:error], :red
    end

    # The I13 promotions (dark.json:26-29, blue-tinted family — NOT the
    # interim dim/muted the scrollbar rode on).
    def test_scrollbar_and_reasoning_tokens_carry_pis_blue_tinted_values
      assert_equal :light_blue, Theme[:thinkingText]
      assert_equal :blue, Theme[:scrollbarTrack]
      assert_equal :light_blue, Theme[:scrollbarThumb]
      refute_equal Theme[:dim], Theme[:scrollbarTrack]
      refute_equal Theme[:muted], Theme[:scrollbarThumb]
    end
  end
end
