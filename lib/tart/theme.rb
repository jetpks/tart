# frozen_string_literal: true

module Tart
  # The theme token table (AC3) — pi's default dark theme transcribed onto
  # the port's terminal vocabulary (theme-tokens.ts names; dark.json values).
  #
  # Values are symbol-or-hex: the CONTENT-path tokens (body prose, the user
  # echo, tool output, thinking) carry their true colors as hex strings —
  # pi renders them truecolor (theme.ts foregroundAnsi over Color::Rgb);
  # the gem's Style accepts hex directly (ext style.rs:20-33 → Color::Rgb).
  # The hex constants are PRECOMPUTED with pi's own converter (pi-tui
  # parseColor/colorToHex over okhsl, run live); NON-content tokens (footer,
  # borders, autocomplete, scrollbar) keep their 16-color analogs this
  # iteration (itemized reduction).
  #
  # Pure data + lookup: no LLM, no terminal session (AC3 — test-proven
  # standalone). A future theme selector replaces this one table.
  module Theme
    # pi token (theme-tokens.ts / dark.json) → the color the port renders.
    # nil = the terminal default.
    TOKENS = {
      # dark.json:6 "text" — the PROSE family resolves to the TERMINAL
      # DEFAULT (theme.ts:226-229: a ""/reference value lands in
      # defaultForegroundTokens → resolved to the terminal's real fg at
      # render — the -e capture's plain emission; the port's #dee0e1 pin
      # captured the var, missing the resolution). nil = the default.
      text: nil,
      # "dim" (dark.json:24, I14 item 9) — RESERVED: pi renders the dim
      # tokens as the ESC[2m DIM ATTRIBUTE, not a color (theme.ts:299/337
      # — dimTokens → dim: true, reset 22;39); the instrument's -e capture
      # proves it (the port's :gray guess was the pre-instrument analog).
      # TUI.span/style map fg: :dim → modifiers [:dim], no fg.
      dim: :dim,
      # "muted" — ALSO a dimToken in pi (the -e capture: the hint rows\n      # render [2m whole — muted and dim are the same attribute).
      muted: :dim,
      # "borderMuted" — pi's borders render the DIM attribute (the -e
      # capture: the editor borders are [2m).
      border: :dim,
      warning: :yellow,         # "warning" yellow — interrupts, context >70% (Chat::FG[:interrupted])
      error: :red,              # "error" red — errors, context >90% (Chat::FG[:error])
      accent: :light_magenta,   # "accent" violet — the port's violet analog (markdown.rb mdCode)
      # dark.json:32-33: userMessageText = "text", userMessageBg = "blueBg"
      # — the ECHO resolves to the terminal default (the capture's plain
      # emission — user-message.ts:49-50's callbacks render defaults).
      user_message_text: nil,
      user_message_bg: nil,
      # "toolOutput" renders the DIM ATTRIBUTE (the -e capture: pi"s output/Took rows are [2m, not the #9da5a9 pin).
      tool_output: :dim,
      # dark.json:71 "bashMode" okhsl(159 64% 65%) → #5eb286 (pi's own
      # converter) — the bash tool block's `$ <command>` header (I17);
      # pi's system-theme "green" (system-theme.ts:112) is the 16-color
      # fallback, not the dark value the port renders.
      # "bashMode" — the header is BOLD + DEFAULT fg (the capture: pi"s $ row is [1m[0m only).
      bashMode: nil,
      # dark.json:40 "toolTitle" = the "text" token → the terminal
      # default (the resolution, above — the I18 tool headers render
      # bold-with-default-fg).
      toolTitle: nil,
      md_heading: :yellow,      # dark.json:42
      md_link: :light_blue,     # dark.json:43 "mdLink" blue → :light_blue (markdown.rb)
      md_link_url: :gray,       # dark.json:44 muted
      md_code: :light_magenta,  # dark.json:45 violet
      md_code_block: :green,    # dark.json:46
      md_code_block_border: :gray, # dark.json:47 muted
      md_quote: :gray,          # dark.json:48 muted
      md_quote_border: :gray,   # dark.json:49 muted
      md_hr: :gray,             # dark.json:50 muted
      md_list_bullet: :light_magenta, # dark.json:51 violet
      thinkingText: "#96a0a4",  # dark.json:26 "thinkingText" okhsl(226 7% 65%) → #96a0a4 (pi's own converter)
      scrollbarTrack: :blue,      # dark.json:28 "scrollbarTrack" okhsl(237 7% 33%) — the dark member of the blue pair (transcript gutter track, Chat::scrollbar_glyphs)
      scrollbarThumb: :light_blue, # dark.json:29 "scrollbarThumb" okhsl(232 7% 65%) — the light member of the blue pair (transcript gutter thumb, Chat::scrollbar_glyphs)
      # The pi logo's brand colors (pi-logo.ts:5-7 — fixed RGB across
      # themes, direct rgbColor, not okhsl → the hex IS the spec).
      logoCoral: "#e48a7a",       # rgb(228,138,122) (pi-logo.ts:5)
      logoBlue: "#4f8eb3",        # rgb(79,142,179) (pi-logo.ts:6)
      logoYellow: "#eab65d",      # rgb(234,182,93) (pi-logo.ts:7)
    }.freeze

    # The markdown converter (Render::Markdown::FG, read-only) emits raw
    # color symbols; the surface routes every markdown span's fg through
    # {md_fg} so the token table stays the single source of color truth.
    # The converter's symbols are themselves the I06 dark-theme
    # transcription, so the mapping is value-identical today (the gray
    # roles — link_url/code_block_border/quote/quote_border/hr — share one
    # value, so they resolve through md_quote; recorded).
    MD_SOURCE = {
      yellow: :md_heading,
      light_blue: :md_link,
      light_magenta: :md_code,
      green: :md_code_block,
      gray: :md_quote,
    }.freeze

    class << self
      # @return the color for a pi token name (Symbol), nil for the
      #   terminal default.
      def [](token)
        TOKENS.fetch(token)
      end

      # @return the theme color behind a markdown converter fg symbol; nil
      #   (plain prose) routes to the "text" token — pi renders prose in
      #   the text token's true color (dark.json:6) — and unknown symbols
      #   pass through untouched.
      def md_fg(symbol)
        token = symbol.nil? ? :text : MD_SOURCE.fetch(symbol, symbol)
        TOKENS.key?(token) ? TOKENS[token] : symbol
      end
    end
  end
end
