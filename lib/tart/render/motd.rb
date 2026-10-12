# frozen_string_literal: true

module Tart
  module Render
    # The MOTD/identity content builders extracted from the chat surface
    # (I24 wave 4 — the boot/new header block and the loaded-resource
    # sections). Stateless: module functions, zero ivars, no Chat
    # dependency — every input is threaded by the caller ({Chat#enqueue_motd}
    # gathers from its own constructor state).
    module Motd
      # The owner's ascii-art collection (tart-mode's mark) — one random
      # piece per MOTD render (boot and /new). pi-mode renders pi's actual
      # half-block mark instead ({pi_mark}).
      LOGOS_DIR = File.expand_path("logos", __dir__)

      # The MOTD hints line — the PORT's real keys only (pi's `!` bash
      # mode, escape-to-clear, ctrl+c-twice and the thinking/model cycles
      # have no port binding; cut, itemized).
      HINTS_LINE = "ctrl+c interrupt/quit · ctrl+d exit (empty) · / commands · pgup/pgdn scroll".freeze

      # pi-mode's built-in header text (pi interactive-mode.ts:1045-1053 —
      # compactInstructions joined with muted " · ", compactOnboarding,
      # onboarding). The keybindings behind escape-to-clear, `!` bash and
      # the ctrl+o expand are cut (itemized) — the hint TEXT renders for
      # byte parity, per the identity contract.
      # The compact hint row as (key, description) pairs — pi keyHint's
      # shape (keybinding-hints.ts:42-44): the key in dim, the description
      # in muted with the " · " separator riding its run (the -e capture's
      # byte proof; the system-theme-era whole-line dim was the artifact).
      PI_HINTS = [
        ["escape", "interrupt"],
        ["ctrl+c/ctrl+d", "clear/exit"],
        ["/", "commands"],
        ["!", "bash"],
        ["ctrl+o", "more"],
      ].freeze
      PI_NOTICE_LINE = "Press ctrl+o to show full startup help and loaded resources.".freeze
      PI_ONBOARDING_LINE = "Pi can explain its own features and look up its docs. Ask it how to use or extend Pi.".freeze

      module_function

      # pi keyHint (keybinding-hints.ts:42-44) over {PI_HINTS}: dim key +
      # muted description, the separator inside every description run but
      # the last.
      def pi_hint_spans
        PI_HINTS.flat_map.with_index do |(key, description), index|
          tail = index == PI_HINTS.length - 1 ? " #{description}" : " #{description} · "
          [TUI.span(key, fg: Theme[:dim]), TUI.span(tail, fg: Theme[:muted])]
        end
      end

      # One random art piece's lines (empty collection → no logo lines).
      def motd_logo_lines
        file = Dir[File.join(LOGOS_DIR, "*.txt")].sample
        file ? File.readlines(file, chomp: true) : []
      end

      # The tart FAMILY's header: the owner's art collection, the identity
      # name + version line, the port's hints line — every content row
      # through the {Panel::OUTPUT_PAD} rule. The resource sections render
      # below for both identities ({sections}). The wordmark is the
      # boot-resolved face (Identity.current — chat.rb's frozen call
      # carries no identity argument): tart renders "tart", foo "foo",
      # always with Tart::VERSION.
      def tart_header_lines(width, name = Identity.current)
        content_width = width - Panel::OUTPUT_PAD.length * 2
        lines = motd_logo_lines.map { |line| TUI.line("#{Panel::OUTPUT_PAD}#{line}") }
        lines << TUI.line([TUI.span(Panel::OUTPUT_PAD), TUI.span(name), TUI.span(" v#{Tart::VERSION}", fg: Theme[:dim])])
        lines.concat(Text.wrap(HINTS_LINE, content_width).map { |row| TUI.line("#{Panel::OUTPUT_PAD}#{row}", fg: Theme[:dim]) })
        lines
      end

      # pi-mode's built-in header (interactive-mode.ts:1028-1063 +
      # pi-logo.ts): the 2-line half-block mark with the version on the
      # mark's first line and the hints on its second, the ctrl+o notice,
      # a blank (the header text's "\\n\\n"), the onboarding line. The
      # mark's brand colors are fixed (pi-logo.ts:9); Apple Terminal gets
      # the wordmark fallback (supportsPiLogo — it misrenders half
      # blocks). The expand machinery behind the notice is cut, itemized.
      def pi_header_lines
        top, bottom = pi_mark
        # The separating space renders PLAIN (pi: the mark's spans, a
        # plain space, THEN the dim hints span — the -e capture's byte
        # proof: the port dimmed the space).
        hints = pi_hint_spans
        [
          TUI.line([TUI.span(Panel::OUTPUT_PAD), *top, TUI.span(" "), TUI.span("v#{Identity::ORACLE_VERSION}", fg: Theme[:dim])]),
          TUI.line([TUI.span(Panel::OUTPUT_PAD), *bottom, TUI.span(" "), *hints]),
          TUI.line([TUI.span(Panel::OUTPUT_PAD), TUI.span(PI_NOTICE_LINE, fg: Theme[:dim])]),
          Panel.blank_line,
          TUI.line([TUI.span(Panel::OUTPUT_PAD), TUI.span(PI_ONBOARDING_LINE, fg: Theme[:dim])])
        ]
      end

      # pi piLogoLines (pi-logo.ts:26-30): 4 cells wide, 2 lines tall —
      # the top line coral-on-blue, then coral, then empty; the bottom
      # blue, empty, yellow. Returns [first-line spans, second-line
      # spans]; the wordmark fallback's second line is empty (the hints
      # ride alone).
      def pi_mark
        if apple_terminal?
          [[TUI.span("P", fg: Theme[:logoCoral]), TUI.span("i", fg: Theme[:logoYellow])], []]
        else
          top = [
            TUI.span("▀", fg: Theme[:logoCoral], bg: Theme[:logoBlue]),
            TUI.span("▀█", fg: Theme[:logoCoral]),
            TUI.span(" ")
          ]
          bottom = [TUI.span("█▀", fg: Theme[:logoBlue]), TUI.span(" "), TUI.span("█", fg: Theme[:logoYellow])]
          [top, bottom]
        end
      end

      # pi isAppleTerminalSession (pi-tui terminal.ts:44-45): darwin +
      # TERM_PROGRAM.
      def apple_terminal?
        RUBY_PLATFORM.include?("darwin") && ENV["TERM_PROGRAM"] == "Apple_Terminal"
      end

      # The loaded-resource sections (pi showLoadedResources): [Context] —
      # the config sources the port actually loads, existing files only,
      # registration order (pi's contextCompactList, sort: false);
      # [Skills] — the loaded skill names, sorted; [Prompts] — the loaded
      # prompt templates as /name, sorted (pi promptCompactList :1896);
      # [Extensions] — the loaded MCP server names, sorted. One wrapped
      # dim compact list each (pi formatCompactList :1791-1797). Sections
      # with no entries are omitted, as in pi. The caller threads the
      # gathered pieces: +context+ the candidate config paths (filtered
      # to existing files here), +skills+ the loaded skill names,
      # +prompts+ the loaded prompt templates, +extensions+ the MCP
      # server names.
      def sections(width, context:, skills:, prompts:, extensions:)
        sections = []
        context = context.select { |path| File.file?(path) }
        unless context.empty?
          sections << ["[Context]", dim_compact_list(context, width)]
        end
        unless skills.empty?
          sections << ["[Skills]", dim_compact_list(skills, width)]
        end
        prompts = prompts.map { |template| "/#{template.name}" }.sort
        unless prompts.empty?
          sections << ["[Prompts]", dim_compact_list(prompts, width)]
        end
        extensions = extensions.sort
        unless extensions.empty?
          sections << ["[Extensions]", dim_compact_list(extensions, width)]
        end
        sections
      end

      # The config files the port loads for +cwd+ (Settings.load's user +
      # project pair and the MCP config; settings.rb:12-14,
      # mcp/config.rb:16). Paths injectable through +settings_root+ so
      # tests never touch ~/.tart.
      def context_sources(settings_root, cwd)
        mcp = ENV["TART_MCP_CONFIG"] || File.join(settings_root, "mcp.json")
        [
          File.join(settings_root, Settings::ROOT_KEY),
          File.join(cwd, Settings::CONFIG_DIR, Settings::ROOT_KEY),
          mcp
        ]
      end

      # The MOTD's [Skills] names: the wired completion source's skill
      # entries (SlashSource carries exactly the launcher's loaded skills).
      def motd_skill_names(source)
        return [] unless source

        source.items.filter_map { |item|
          item[:value].delete_prefix("skill:") if item[:value].start_with?("skill:")
        }.sort
      end

      # pi formatCompactList (:1791-1797): trimmed entries joined ", ",
      # two-space indent, dim — word-wrapped to the content width, every
      # row through the {OUTPUT_PAD} rule. (The sort, when wanted, happens
      # at the call site: pi's [Context] list passes sort: false —
      # registration order.)
      def dim_compact_list(entries, width)
        Text.wrap("  #{entries.join(", ")}", width).map { |row| TUI.line("#{Panel::OUTPUT_PAD}#{row}", fg: Theme[:dim]) }
      end
    end
  end
end
