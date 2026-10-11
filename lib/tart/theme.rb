# frozen_string_literal: true

module Tart
  # The theme token table — pi's DARK theme, the owner's daily-driver
  # configuration (~/.pi/agent/settings.json "theme": "dark"), every value
  # resolved to a concrete hex with pi's own converter (packages/tui/src/
  # colors.ts parseColor/colorToRgb over the okhsl strings, run live —
  # the numbers are recorded per token).
  #
  # CALIBRATION (2026-10-11 rig correction): the rig's staged pi now boots
  # "theme": "dark" (parity/runner.rb stage_pi_agent) — a fresh staged HOME
  # otherwise runs the SYSTEM theme, which under tmux (no OSC palette
  # report) degenerates to indexedColors' 16-slot fallback (accent
  # 38;5;5, neutrals as the [2m dim attribute). The earlier :dim-attribute
  # and terminal-default mappings were artifacts of that wrong target;
  # dark has NO dimTokens (options.dim is passed only by createSystemTheme,
  # theme.ts:547) — dim/muted/borderMuted/toolOutput are truecolor colors.
  #
  # Mode-aware emission (pi colors.ts colorAnsi): a truecolor terminal
  # (COLORTERM truecolor/24bit) renders the hex as 38;2;r;g;b; a 256-color
  # terminal downgrades through pi's cube/gray math (rgbToAnsi256,
  # colors.ts:279-297 — ported below) and the table answers Xterm indexes.
  #
  # Pure data + lookup: no LLM, no terminal session (AC3 — test-proven
  # standalone). A future theme selector replaces this one table.
  module Theme
    # pi token (theme-tokens.ts / dark.json) → the resolved color the port
    # renders. Hex values are pi's own okhsl→rgb conversion of the dark
    # theme's values (dark.json vars + literals).
    TOKENS = {
      # dark.json:6 text = okhsl(234 3% 89%) — the prose family (NOT the
      # terminal default; that finding was the system-theme artifact).
      text: "#dee0e1",
      # dark.json:24 dim = okhsl(229 8% 56%) — a truecolor color (the
      # footer, the hint keywords, the version line; NO [2m under dark).
      dim: "#7e888e",
      # dark.json:7/:23 muted = okhsl(229 6% 67%) — the hint descriptions,
      # the Took row, toolOutput's value.
      muted: "#9da5a9",
      # dark.json:14 border = okhsl(231 57% 65%) — the picker border, the
      # reload box (DynamicBorder); the EDITOR border is thinking-level
      # (see thinking_* below, pi updateEditorBorderColor).
      border: "#5fa8cc",
      warning: "#cd9a22",         # dark.json:22 yellow var
      error: "#ea7f81",           # dark.json:21 red var
      accent: "#a798d7",          # dark.json:16 violet var
      # dark.json:32-33: userMessageText = text, userMessageBg = blueBg
      # — the echo panel (a full-width bg block, markdown.ts
      # applyBackgroundToLine).
      user_message_text: "#dee0e1",
      user_message_bg: "#213b49",
      # dark.json:34-36: customMessageBg = okhsl(295 42% 24%),
      # customMessageText = muted var, customMessageLabel = violet var —
      # the skill-invocation panel (skill-invocation-message.ts Box(1,1)).
      custom_message_bg: "#3a3055",
      custom_message_text: "#9da5a9",
      custom_message_label: "#a798d7",
      # dark.json:41 toolOutput = muted var
      tool_output: "#9da5a9",
      # dark.json:40 toolTitle = text — the tool call headers (bold).
      toolTitle: "#dee0e1",
      # dark.json:77 bashMode = okhsl(159 64% 65%) — the user-bash (!)
      # block's header/border and the editor border in bash mode.
      bashMode: "#5eb286",
      # The tool-block bg panels (tool-execution.ts Box(1,1) bgFn):
      # pending while partial, error/success on the result.
      tool_pending_bg: "#34383a",  # dark.json:36 okhsl(229 5% 24%)
      tool_success_bg: "#254131",  # dark.json:37 okhsl(158 46% 25%)
      tool_error_bg: "#5b282a",    # dark.json:38 okhsl(19 54% 25%)
      # The editor border by thinking level (pi getThinkingBorderColor —
      # updateEditorBorderColor: bashMode in bash mode, else the session's
      # level || "off"). The rig's mock (reasoning: false) settles at
      # thinking_off #6c767b — the capture's 108;118;123 border rows.
      thinking_off: "#6c767b",      # dark.json:66 okhsl(229 8% 49%)
      thinking_minimal: "#68808d",  # dark.json:67
      thinking_low: "#5489a4",      # dark.json:68
      thinking_medium: "#6185cc",  # dark.json:69
      thinking_high: "#9776e5",    # dark.json:70
      thinking_xhigh: "#de54c1",   # dark.json:71
      thinking_max: "#fe5462",     # dark.json:72
      md_heading: "#cd9a22",        # dark.json:42 yellow var
      md_link: "#69add0",           # dark.json:43 blue var
      md_link_url: "#9da5a9",       # dark.json:44 muted var
      md_code: "#a798d7",           # dark.json:45 violet var
      md_code_block: "#68b78d",     # dark.json:46 green var
      md_code_block_border: "#9da5a9", # dark.json:47 muted var
      md_quote: "#9da5a9",          # dark.json:48 muted var
      md_quote_border: "#9da5a9",   # dark.json:49 muted var
      md_hr: "#9da5a9",             # dark.json:50 muted var
      md_list_bullet: "#a798d7",    # dark.json:51 violet var
      thinkingText: "#96a0a4",  # dark.json:26 okhsl(226 7% 65%)
      scrollbarTrack: "#484e52", # dark.json:28 okhsl(237 7% 33%)
      scrollbarThumb: "#97a0a5", # dark.json:29 okhsl(232 7% 65%)
      # The pi logo's brand colors (pi-logo.ts:5-7 — fixed RGB across
      # themes, direct rgbColor, not okhsl → the hex IS the spec).
      logoCoral: "#e48a7a",       # rgb(228,138,122) (pi-logo.ts:5)
      logoBlue: "#4f8eb3",        # rgb(79,142,179) (pi-logo.ts:6)
      logoYellow: "#eab65d",      # rgb(234,182,93) (pi-logo.ts:7)
    }.freeze

    # The markdown converter (Render::Markdown::FG, read-only) emits raw
    # color symbols; the surface routes every markdown span's fg through
    # {md_fg} so the token table stays the single source of color truth.
    # The converter's symbols are the I06 dark-theme transcription, so the
    # mapping is value-identical today (the gray roles — link_url/
    # code_block_border/quote/quote_border/hr — share one value, so they
    # resolve through md_quote; recorded).
    MD_SOURCE = {
      yellow: :md_heading,
      light_blue: :md_link,
      light_magenta: :md_code,
      green: :md_code_block,
      gray: :md_quote,
    }.freeze

    # pi colors.ts:170-183 — the 6x6x6 cube levels and the 24-step gray
    # ramp (8 + 10n) the 256-color downgrade snaps to.
    CUBE_VALUES = [0, 95, 135, 175, 215, 255].freeze
    GRAY_VALUES = (0...24).map { |index| 8 + index * 10 }.freeze
    # pi getTerminalColorMode (terminal-image.ts:178) over the COLORTERM
    # hint: truecolor/24bit → truecolor, anything else → 256color.
    TRUECOLOR_COLORTERM = %w[truecolor 24bit].freeze

    class << self
      # @return the color for a pi token name (Symbol): the hex on a
      #   truecolor terminal, the Xterm index (Integer) on 256-color.
      def [](token)
        color = TOKENS.fetch(token)
        truecolor? ? color : indexed[token]
      end

      # @return the theme color behind a markdown converter fg symbol.
      #   nil (plain prose) stays nil — the TERMINAL DEFAULT: pi's markdown
      #   theme (theme.ts:1022-1031 getMarkdownTheme) has no callback for
      #   plain text, so assistant prose renders default even under dark
      #   (the -e capture's plain reply row); the text token colors the
      #   USER ECHO + tool titles via their own call sites. Unknown
      #   symbols pass through untouched.
      def md_fg(symbol)
        return nil if symbol.nil?

        token = MD_SOURCE.fetch(symbol, symbol)
        TOKENS.key?(token) ? self[token] : symbol
      end

      # @return [Boolean] whether the terminal reports truecolor (pi's
      #   two-mode resolution; the downgrade math below is the else).
      def truecolor?
        TRUECOLOR_COLORTERM.include?(ENV.fetch("COLORTERM", ""))
      end

      private

      # The 256-color table, resolved once per token (memoized).
      def indexed
        @indexed ||= TOKENS.transform_values { |hex| hex_to_ansi256(hex) }
      end

      # pi colors.ts:279-297 rgbToAnsi256: snap each channel to the cube,
      # prefer the gray ramp when the color is near-neutral and closer.
      def hex_to_ansi256(hex)
        channels = hex.delete_prefix("#").scan(/../).map { |pair| pair.to_i(16) }
        r, g, b = channels
        r_index, g_index, b_index = channels.map { |c| closest_index(CUBE_VALUES, c) }
        cube = [CUBE_VALUES[r_index], CUBE_VALUES[g_index], CUBE_VALUES[b_index]]
        cube_index = 16 + 36 * r_index + 6 * g_index + b_index

        gray = (0.299 * r + 0.587 * g + 0.114 * b).round
        gray_offset = closest_index(GRAY_VALUES, gray)
        gray_value = GRAY_VALUES[gray_offset]
        spread = channels.max - channels.min
        if spread < 10 && color_distance(channels, [gray_value] * 3) < color_distance(channels, cube)
          232 + gray_offset
        else
          cube_index
        end
      end

      # pi colors.ts:272-277 colorDistance — the luminance weights on the
      # SQUARED channel deltas.
      def color_distance((r1, g1, b1), (r2, g2, b2))
        (r1 - r2)**2 * 0.299 + (g1 - g2)**2 * 0.587 + (b1 - b2)**2 * 0.114
      end

      # pi colors.ts:259-270 findClosest — the nearest value's index
      # (first wins ties, like the JS scan).
      def closest_index(values, target)
        best = 0
        best_distance = Float::INFINITY
        values.each_with_index do |value, index|
          distance = (value - target).abs
          next unless distance < best_distance

          best = index
          best_distance = distance
        end
        best
      end
    end
  end
end
