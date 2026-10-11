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
      text: nil,                      # dark.json:6 "text" — the TERMINAL DEFAULT (pi's default-token resolution, theme.ts:226-229)
      dim: :dim,                      # "dim" — RESERVED: the ESC[2m attribute (pi dimTokens, theme.ts:299)
      muted: :dim,                    # "muted" — ALSO a dimToken (the -e capture: the hint rows render [2m)
      border: :dim,                   # "borderMuted" — pi's borders render the DIM attribute (the -e capture)
      warning: :yellow,               # "warning" yellow
      error: :red,                    # "error" red
      accent: :light_magenta,         # "accent" violet (dark.json vars)
      user_message_text: nil,         # dark.json:32 — = text → the terminal default
      user_message_bg: nil,           # dark.json:13/:33 — blueBg → the terminal default (the capture's plain emission)
      tool_output: :dim,              # "toolOutput" — renders the DIM attribute (the -e capture: pi's output rows are [2m)
      bashMode: nil,                  # "bashMode" — the header is bold + DEFAULT fg (the -e capture: [1m[0m only)
      toolTitle: nil,                 # dark.json:40 toolTitle = text → the terminal default (the I18 headers render bold-default)
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
      logoCoral: "#e48a7a",       # rgb(228,138,122) — pi-logo.ts:5 (fixed RGB, direct hex)
      logoBlue: "#4f8eb3",        # rgb(79,142,179) — pi-logo.ts:6
      logoYellow: "#eab65d",      # rgb(234,182,93) — pi-logo.ts:7
    }.freeze

    def test_token_table_carries_the_pi_transcription
      assert_equal EXPECTED, Theme::TOKENS
    end

    def test_lookup_returns_the_token_color
      assert_equal :red, Theme[:error]
      assert_nil Theme[:text], "body prose carries the TERMINAL DEFAULT (pi's default-token resolution; the -e capture's plain emission)"
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
      # toolOutput and muted render the same DIM attribute (the -e capture).
      # RESERVED: pi renders the dim tokens as the ESC[2m attribute (theme.ts:299
      # dimTokens — the -e capture proves it); the port's :gray guess was the
      # pre-instrument analog.
      assert_equal :dim, Theme[:dim], "the dim token is the dim ATTRIBUTE (pi's dimTokens)"
      assert_equal Theme[:warning], :yellow
      assert_equal Theme[:error], :red
      assert_equal Theme[:text], Theme[:toolTitle], "pi toolTitle = text (dark.json:40) — the I18 tool headers"
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
