# frozen_string_literal: true

require_relative "test_helper"

module Tart
  # The theme token table: pure data + lookup, no LLM, no tty — the
  # table is pi's DARK theme (the owner's daily-driver setting) with
  # every value resolved by pi's own converter (packages/tui/src/colors.ts
  # parseColor/colorToRgb over the okhsl strings, run live; the numbers
  # are recorded per token). The 2026-10-11 rig correction: the staged pi
  # boots "theme": "dark" — the earlier :dim-attribute and terminal-default
  # mappings were artifacts of the SYSTEM theme the unstaged pi ran.
  class ThemeTest < Test
    # Every token the port's surface renders, with its pi dark.json source
    # and the resolved color. Values verified against the -e captures
    # (accent 167;152;215, userMessageBg 33;59;73, toolSuccessBg 37;65;49,
    # dim 126;136;142, muted 157;165;169, border-by-level 108;118;123).
    EXPECTED = {
      text: "#dee0e1",            # dark.json:6 okhsl(234 3% 89%)
      dim: "#7e888e",             # dark.json:24 okhsl(229 8% 56%) — a COLOR (no dimTokens under dark)
      muted: "#9da5a9",           # dark.json:7/:23 okhsl(229 6% 67%)
      border: "#5fa8cc",          # dark.json:14 okhsl(231 57% 65%)
      warning: "#cd9a22",         # dark.json:22 yellow var
      error: "#ea7f81",           # dark.json:21 red var
      accent: "#a798d7",          # dark.json:16 violet var
      user_message_text: "#dee0e1", # dark.json:32 = text
      user_message_bg: "#213b49",   # dark.json:33 blueBg okhsl(233 41% 24%)
      custom_message_bg: "#3a3055", # dark.json:34 okhsl(295 42% 24%) — the skill panel
      custom_message_text: "#9da5a9", # dark.json:35 muted var
      custom_message_label: "#a798d7", # dark.json:36 violet var
      tool_output: "#9da5a9",     # dark.json:41 muted var
      toolTitle: "#dee0e1",       # dark.json:40 = text
      bashMode: "#5eb286",        # dark.json:77 okhsl(159 64% 65%)
      tool_pending_bg: "#34383a", # dark.json:36 okhsl(229 5% 24%)
      tool_success_bg: "#254131", # dark.json:37 okhsl(158 46% 25%)
      tool_error_bg: "#5b282a",   # dark.json:38 okhsl(19 54% 25%)
      thinking_off: "#6c767b",    # dark.json:66 — the editor border at level off
      thinking_minimal: "#68808d", # dark.json:67
      thinking_low: "#5489a4",    # dark.json:68
      thinking_medium: "#6185cc", # dark.json:69
      thinking_high: "#9776e5",   # dark.json:70
      thinking_xhigh: "#de54c1",  # dark.json:71
      thinking_max: "#fe5462",    # dark.json:72
      md_heading: "#cd9a22",      # dark.json:42 yellow var
      md_link: "#69add0",         # dark.json:43 blue var
      md_link_url: "#9da5a9",     # dark.json:44 muted var
      md_code: "#a798d7",         # dark.json:45 violet var
      md_code_block: "#68b78d",   # dark.json:46 green var
      md_code_block_border: "#9da5a9", # dark.json:47 muted var
      md_quote: "#9da5a9",        # dark.json:48 muted var
      md_quote_border: "#9da5a9", # dark.json:49 muted var
      md_hr: "#9da5a9",           # dark.json:50 muted var
      md_list_bullet: "#a798d7",  # dark.json:51 violet var
      thinkingText: "#96a0a4",    # dark.json:26 okhsl(226 7% 65%)
      scrollbarTrack: "#484e52",  # dark.json:28 okhsl(237 7% 33%)
      scrollbarThumb: "#97a0a5",  # dark.json:29 okhsl(232 7% 65%)
      logoCoral: "#e48a7a",       # pi-logo.ts:5 (fixed RGB across themes)
      logoBlue: "#4f8eb3",        # pi-logo.ts:6
      logoYellow: "#eab65d",      # pi-logo.ts:7
    }.freeze

    def test_token_table_carries_the_pi_dark_transcription
      assert_equal EXPECTED, Theme::TOKENS
    end

    def test_lookup_returns_the_resolved_color
      with_colorterm("truecolor") do
        assert_equal "#ea7f81", Theme[:error]
        assert_equal "#a798d7", Theme[:accent]
        assert_raises(KeyError) { Theme[:not_a_token] }
      end
    end

    # pi colorAnsi (colors.ts:299-307): a 256-color terminal renders the
    # Xterm-index downgrades, not the hex — the port resolves per token
    # through pi's own cube/gray math (rgbToAnsi256, colors.ts:279-297).
    def test_lookup_downgrades_to_xterm_indexes_on_256_color_terminals
      with_colorterm("") do
        Theme::TOKENS.each_key { |token| assert_kind_of Integer, Theme[token], "#{token} downgrades" }
        # error #ea7f81 → cube slot 174 (r 234→215[4], g 127→135[2],
        # b 129→135[2]); muted #9da5a9 → cube slot 145 (every channel
        # →175[3]; spread 12 stays on the cube, off the gray ramp).
        assert_equal 174, Theme[:error]
        assert_equal 145, Theme[:muted]
      end
    end

    def test_truecolor_detection_follows_colorterm
      with_colorterm("truecolor") { assert Theme.truecolor? }
      with_colorterm("24bit") { assert Theme.truecolor? }
      with_colorterm("") { refute Theme.truecolor? }
      with_colorterm("256color") { refute Theme.truecolor? }
    end

    def test_markdown_fg_routes_through_the_table
      with_colorterm("truecolor") do
        assert_equal Theme[:md_heading], Theme.md_fg(:yellow)
        assert_equal Theme[:md_link], Theme.md_fg(:light_blue)
        assert_equal Theme[:md_code], Theme.md_fg(:light_magenta)
        assert_equal Theme[:md_code_block], Theme.md_fg(:green)
        assert_equal Theme[:md_quote], Theme.md_fg(:gray)
      end
    end

    def test_markdown_fg_prose_stays_the_terminal_default
      assert_nil Theme.md_fg(nil),
        "pi getMarkdownTheme (theme.ts:1022-1031) has no prose callback — assistant prose renders the terminal default under dark too"
    end

    def test_markdown_fg_passes_unknown_symbols_through
      assert_equal :custom, Theme.md_fg(:custom)
    end

    # The roles the old system-theme calibration misread, re-pinned against
    # the dark target: the echo panel, the tool-title family, the
    # thinking-level border ladder.
    def test_surface_roles_resolve_through_the_theme
      assert_equal Theme[:text], Theme[:user_message_text], "pi userMessageText = text (dark.json:32)"
      assert_equal Theme[:text], Theme[:toolTitle], "pi toolTitle = text (dark.json:40)"
      assert_equal Theme[:muted], Theme[:tool_output], "pi toolOutput = muted var (dark.json:41)"
      assert_equal "#7e888e", Theme[:dim], "the dim token is a COLOR (dark has no dimTokens — theme.ts:547 is the only options.dim call site)"
    end

    def test_thinking_level_ladder_covers_pi_getthinkingbordercolor
      %i[thinking_off thinking_minimal thinking_low thinking_medium
         thinking_high thinking_xhigh thinking_max].each { |token| Theme[token] }
      assert_equal "#6c767b", Theme[:thinking_off], "the rig mock's settled border (108;118;123)"
      assert_equal "#9776e5", Theme[:thinking_high], "the owner's level-high tab"
    end

    private

    # ENV-stubbed COLORTERM with restore — the resolution must not depend
    # on the ambient terminal.
    def with_colorterm(value)
      previous = ENV["COLORTERM"]
      ENV["COLORTERM"] = value
      yield
    ensure
      ENV["COLORTERM"] = previous
    end
  end
end
