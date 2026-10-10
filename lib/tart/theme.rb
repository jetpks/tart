# frozen_string_literal: true

module Tart
  # The theme token table (AC3) — pi's default dark theme transcribed onto
  # the port's terminal vocabulary (theme-tokens.ts names; dark.json values
  # mapped to the gem's ANSI color symbols the port's terminal renders).
  #
  # The port renders fg-only styled spans through the TUI seam (no bg slots,
  # no capability detection — reduced, itemized in the I11 report), so a
  # token carries the house ANSI analog of its pi value and a cut token is
  # simply absent. Rendered output for every token the I05/I06 layers pinned
  # is unchanged (the analogs ARE the values those layers established).
  #
  # Pure data + lookup: no LLM, no terminal session (AC3 — test-proven
  # standalone). A future theme selector replaces this one table.
  module Theme
    # pi token (theme-tokens.ts / dark.json) → the fg color the port renders.
    # nil = the terminal default (pi's "text" renders as the empty color).
    TOKENS = {
      text: nil,                # dark.json "text" → default prose
      dim: :dark_gray,          # "dim" okhsl(229 8% 56%) — status/footer (Chat::FG[:status], I05)
      muted: :gray,             # "muted" okhsl(229 6% 67%) — tool output (Chat::FG[:tool], I05)
      border: :gray,            # "borderMuted" okhsl(229 8% 53%) — the port's one border style
      warning: :yellow,         # "warning" yellow — interrupts, context >70% (Chat::FG[:interrupted])
      error: :red,              # "error" red — errors, context >90% (Chat::FG[:error])
      accent: :light_magenta,   # "accent" violet — the port's violet analog (markdown.rb mdCode)
      user_message_text: :light_blue, # carries userMessageBg's blue distinction as fg (I05 recorded: pi userMessageText is "text" on a blue background; fg is the closest analog)
      tool_output: :gray,       # "toolOutput" muted
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

      # @return [Symbol, nil] the theme color behind a markdown converter fg
      #   symbol; unknown symbols pass through untouched.
      def md_fg(symbol)
        token = MD_SOURCE.fetch(symbol, symbol)
        TOKENS.key?(token) ? TOKENS[token] : symbol
      end
    end
  end
end
