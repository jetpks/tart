# frozen_string_literal: true

module Tart
  module Render
    # The MOTD/identity content builders extracted from the chat surface
    # (I24 wave 4 — the boot/new header block and the loaded-resource
    # sections). Stateless: module functions, zero ivars, no Chat
    # dependency — every input is threaded by the caller ({Chat#enqueue_motd}
    # gathers from its own constructor state). I33: both headers and the
    # resource sections carry collapsed AND expanded bodies — the ctrl+o
    # flip rebuilds them in place (pi ExpandableText).
    module Motd
      # The owner's ascii-art collection (tart-mode's mark) — one random
      # piece per MOTD render (boot and /new). pi-mode renders pi's actual
      # half-block mark instead ({pi_mark}).
      LOGOS_DIR = File.expand_path("logos", __dir__)

      # The MOTD hints line — the PORT's real keys only (the collapsed
      # compact row; byte-frozen — the expanded list below enumerates the
      # full routing). Spelled before UserBash/the menus shipped, so it
      # carries fewer keys than the port actually binds.
      HINTS_LINE = "ctrl+c interrupt/quit · ctrl+d exit (empty) · / commands · pgup/pgdn scroll".freeze

      # pi-mode's built-in header text (pi interactive-mode.ts:1045-1053 —
      # compactInstructions joined with muted " · ", compactOnboarding,
      # onboarding). The compact hint row as (key, description) pairs —
      # pi keyHint's shape (keybinding-hints.ts:42-44): the key in dim,
      # the description in muted with the " · " separator riding its run
      # (the -e capture's byte proof; the system-theme-era whole-line dim
      # was the artifact).
      PI_HINTS = [
        ["escape", "interrupt"],
        ["ctrl+c/ctrl+d", "clear/exit"],
        ["/", "commands"],
        ["!", "bash"],
        ["ctrl+o", "more"],
      ].freeze
      PI_NOTICE_LINE = "Press ctrl+o to show full startup help and loaded resources.".freeze
      PI_ONBOARDING_LINE = "Pi can explain its own features and look up its docs. Ask it how to use or extend Pi.".freeze

      # pi expandedInstructions (interactive-mode.ts:1020-1043) as
      # (key, description) pairs — one per row expanded, hint 1 riding the
      # mark's second line. Keys are the oracle's keybindings.ts:26-78 +
      # tui keybindings.ts:120-145 defaults with the darwin alt→option
      # rewrite (keybinding-hints.ts:15) applied; the live-oracle capture
      # (I33 probe, tmp/probe-expanded-plain) pins every row.
      PI_EXPANDED_HINTS = [
        ["escape", "to interrupt"],
        ["ctrl+c", "to clear"],
        ["ctrl+c twice", "to exit"],
        ["ctrl+d", "to exit (empty)"],
        ["ctrl+z", "to suspend"],
        ["ctrl+k", "to delete to end"],
        ["shift+tab", "to cycle thinking level"],
        ["ctrl+p/shift+ctrl+p", "to cycle models"],
        ["ctrl+l", "to select model"],
        ["ctrl+o", "to expand tools"],
        ["ctrl+t", "to expand thinking"],
        ["ctrl+g", "for external editor"],
        ["/", "for commands"],
        ["!", "to run bash"],
        ["!!", "to run bash (no context)"],
        ["option+enter", "to queue follow-up"],
        ["option+up", "to edit all queued messages"],
        ["ctrl+v", "to paste files on macOS, images, or text"],
        ["drop files", "to attach"],
      ].freeze

      # The tart FAMILY's expanded header: the port's REAL bound keys, one
      # per row in the keyHint shape, enumerated from chat.rb's actual key
      # routing (edit_input): enter submit, escape interrupt, ctrl+c
      # clear + double-press exit, ctrl+d exit-empty, ctrl+o expand,
      # ctrl+l model menu, ctrl+s menu set-as-default, shift+tab thinking
      # cycle, ctrl+x copy, page_up/page_down scroll, ctrl+u/ctrl+k kill
      # ring, ctrl+y/alt+y yank, the "/" command dispatch (submit), and
      # the "!" / "!!" bash modes (UserBash.parse). Identity is
      # presentation-only: the flip behaves identically either way.
      TART_EXPANDED_HINTS = [
        ["enter", "to send"],
        ["escape", "to interrupt"],
        ["ctrl+c", "to clear"],
        ["ctrl+c twice", "to exit"],
        ["ctrl+d", "to exit (empty)"],
        ["ctrl+o", "to expand tools"],
        ["ctrl+l", "to select model"],
        ["ctrl+s", "to save as default"],
        ["shift+tab", "to cycle thinking level"],
        ["ctrl+x", "to copy"],
        ["pgup/pgdn", "to scroll"],
        ["ctrl+u/ctrl+k", "to delete to line start/end"],
        ["ctrl+y", "to yank"],
        ["alt+y", "to yank pop"],
        ["/", "for commands"],
        ["!", "to run bash"],
        ["!!", "to run bash (no context)"],
      ].freeze

      # One loaded-resource section: the header row text, the collapsed
      # compact rows (the byte-frozen I24 shape), the expanded rows, and
      # whether pi renders the section's LEADING Spacer (the contextFiles
      # branch only — interactive-mode.ts:1852-1853). Every section also
      # carries its trailing Spacer (addLoadedSection :1814).
      Section = Struct.new(:name, :collapsed_rows, :expanded_rows, :leading_blank)

      module_function

      # pi keyHint (keybinding-hints.ts:42-44) as one row: dim key + muted
      # description, one left-pad column.
      def key_hint_row(key, description)
        TUI.line([TUI.span(Panel::OUTPUT_PAD), TUI.span(key, fg: Theme[:dim]), TUI.span(" #{description}", fg: Theme[:muted])])
      end

      # pi keyHint over {PI_HINTS}: dim key + muted description, the
      # separator inside every description run but the last.
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
      # name + version line, then the hints — the compact line collapsed,
      # one row per bound key expanded ({TART_EXPANDED_HINTS}). The face
      # threads explicitly from Chat's @identity (I33 — the frozen call
      # carries no identity argument at base): tart renders "tart", foo
      # "foo", always with Tart::VERSION.
      def tart_header_lines(width, name, expanded:, logo_lines: motd_logo_lines)
        content_width = width - Panel::OUTPUT_PAD.length * 2
        lines = logo_lines.map { |line| TUI.line("#{Panel::OUTPUT_PAD}#{line}") }
        lines << TUI.line([TUI.span(Panel::OUTPUT_PAD), TUI.span(name), TUI.span(" v#{Tart::VERSION}", fg: Theme[:dim])])
        lines.concat(expanded ? TART_EXPANDED_HINTS.map { |key, description| key_hint_row(key, description) }
                              : Text.wrap(HINTS_LINE, content_width).map { |row| TUI.line("#{Panel::OUTPUT_PAD}#{row}", fg: Theme[:dim]) })
        lines
      end

      # pi-mode's built-in header (interactive-mode.ts:1028-1063 +
      # pi-logo.ts): collapsed — the 2-line half-block mark with the
      # version on the mark's first line and the compact hints on its
      # second, the ctrl+o notice, a blank (the header text's "\n\n"),
      # the onboarding line; expanded (interactive-mode.ts:1020-1043) —
      # mark + hint 1, hints 2–19 one per row, blank, onboarding. THE
      # NOTICE RENDERS ONLY COLLAPSED (the live-oracle capture). The
      # mark's brand colors are fixed (pi-logo.ts:9); Apple Terminal gets
      # the wordmark fallback (supportsPiLogo — it misrenders half
      # blocks). The separating space renders PLAIN (pi: the mark's spans,
      # a plain space, THEN the dim hints span — the -e capture's byte
      # proof: the port dimmed the space).
      def pi_header_lines(expanded:)
        top, bottom = pi_mark
        rows = [TUI.line([TUI.span(Panel::OUTPUT_PAD), *top, TUI.span(" "), TUI.span("v#{Identity::ORACLE_VERSION}", fg: Theme[:dim])])]
        rows << if expanded
          first_key, first_description = PI_EXPANDED_HINTS.first
          TUI.line([TUI.span(Panel::OUTPUT_PAD), *bottom, TUI.span(" "),
            TUI.span(first_key, fg: Theme[:dim]),
            TUI.span(" #{first_description}", fg: Theme[:muted])])
        else
          TUI.line([TUI.span(Panel::OUTPUT_PAD), *bottom, TUI.span(" "), *pi_hint_spans])
        end
        rows.concat(PI_EXPANDED_HINTS.drop(1).map { |key, description| key_hint_row(key, description) }) if expanded
        rows << TUI.line([TUI.span(Panel::OUTPUT_PAD), TUI.span(PI_NOTICE_LINE, fg: Theme[:dim])]) unless expanded
        rows << Panel.blank_line
        rows << TUI.line([TUI.span(Panel::OUTPUT_PAD), TUI.span(PI_ONBOARDING_LINE, fg: Theme[:dim])])
        rows
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

      # The loaded-resource sections (pi showLoadedResources): collapsed —
      # the compact lists (the byte-frozen I24 shape: formatCompactList
      # :1791-1797, sorted except [Context]); expanded — pi's full shapes:
      # [Context] the display paths one per line (:1844-1857, dim, two-
      # space indent, home→~ contracted, registration order); [Skills]/
      # [Prompts] the scope groups (buildScopeGroups/formatScopeGroups
      # :1624-1693 — project → user → path, an accent label row then dim
      # indented entries sorted by path; [Prompts] entries as /name).
      # [Extensions] stays compact in BOTH states: the port's extensions
      # are MCP server NAMES, not paths — formatExtensionDisplayPath has
      # no input, and pi's default expandedBody IS the collapsed body
      # (addLoadedSection :1810). Width is the FULL viewport width: the
      # compact lists wrap at the content width (their rows carry the
      # {OUTPUT_PAD}); the expanded rows are paddingX-0 components in pi
      # (ExpandableText(..., 0, 0), addLoadedSection :1810) — no pad,
      # wrapped at the full width through {wrap_resource_row}. The caller
      # threads the gathered pieces: +context+ the candidate config paths
      # (filtered to existing files here), +skills+ the loaded Skill
      # structs, +prompts+ the loaded prompt templates, +extensions+ the
      # MCP server names, +user_root+/+project_root+ the discovery roots
      # the scope groups classify by ({scope_group}).
      def sections(width, context:, skills:, prompts:, extensions:, user_root:, project_root:)
        sections = []
        context = context.select { |path| File.file?(path) }
        unless context.empty?
          sections << Section.new("[Context]",
            dim_compact_list(context, width - Panel::OUTPUT_PAD.length * 2),
            dim_path_rows(context.map { |path| "  #{display_path(path)}" }, width), true)
        end
        unless skills.empty?
          sections << Section.new("[Skills]",
            dim_compact_list(skills.map(&:name).sort, width - Panel::OUTPUT_PAD.length * 2),
            scope_group_rows(skill_scope_entries(skills, user_root:, project_root:), width), false)
        end
        unless prompts.empty?
          sections << Section.new("[Prompts]",
            dim_compact_list(prompts.map { |template| "/#{template.name}" }.sort, width - Panel::OUTPUT_PAD.length * 2),
            scope_group_rows(prompt_scope_entries(prompts, user_root:, project_root:), width), false)
        end
        unless extensions.empty?
          extensions = extensions.sort
          compact = dim_compact_list(extensions, width - Panel::OUTPUT_PAD.length * 2)
          sections << Section.new("[Extensions]", compact, compact, false)
        end
        sections
      end

      # pi getScopeGroup (:1610-1619) over the port's discovery roots —
      # the structs carry no source metadata (skills.rb/prompts.rb are
      # frozen seams), so the scope classifies by path: the cwd config
      # dir is project scope, the settings root (and the ~/.claude
      # migration dir — skills.rb's second user source) user scope,
      # anything else pi's "path".
      def scope_group(path, user_root:, project_root:)
        return "project" if under?(path, project_root)
        return "user" if under?(path, user_root) || under?(path, File.join(Dir.home, ".claude", "skills"))

        "path"
      end

      def under?(path, root)
        path.start_with?("#{root}#{File::SEPARATOR}")
      end

      def skill_scope_entries(skills, user_root:, project_root:)
        skills.map do |skill|
          {path: skill.file_path, display: display_path(skill.file_path),
           group: scope_group(skill.file_path, user_root:, project_root:)}
        end
      end

      def prompt_scope_entries(prompts, user_root:, project_root:)
        prompts.map do |template|
          {path: template.file_path, display: "/#{template.name}",
           group: scope_group(template.file_path, user_root:, project_root:)}
        end
      end

      # pi buildScopeGroups (:1624-1659) + formatScopeGroups (:1661-1693):
      # group order project → user → path (:1655-1657), each non-empty
      # group an accent scope-label row (2-space indent) then dim
      # indented entries sorted by path within the group. Every row
      # through {wrap_resource_row} (pi's Text word-wrap — the staged
      # path rows reproduce its byte shape, the s9 instrument).
      def scope_group_rows(entries, width)
        rows = []
        %w[project user path].each do |group|
          members = entries.select { |entry| entry[:group] == group }.sort_by { |entry| entry[:path] }
          next if members.empty?

          # pi renders the label row's indent UNSTYLED and the scope name
          # accent (formatScopeGroups :1670 — `  ${theme.fg("accent", group.scope)}`:
          # two SGR runs; the rig's style pass compares runs).
          rows << TUI.line([TUI.span("  "), TUI.span(group, fg: Theme[:accent])])
          members.each do |entry|
            rows.concat(wrap_resource_row("    #{entry[:display]}", width).map { |row| TUI.line(row, fg: Theme[:dim]) })
          end
        end
        rows
      end

      # The [Context] expanded rows: dim, one display path per line
      # (interactive-mode.ts:1844-1857 — formatDisplayPath, NOT the
      # compact list's cwd-relative form).
      def dim_path_rows(lines, width)
        lines.flat_map { |line| wrap_resource_row(line, width).map { |row| TUI.line(row, fg: Theme[:dim]) } }
      end

      # pi formatDisplayPath (:1389-1399): the home prefix contracts to ~.
      def display_path(path)
        home = Dir.home
        path.start_with?(home) ? "~#{path.delete_prefix(home)}" : path
      end

      # pi-tui wrapSingleLine (tui utils.ts:925-995) — the wrap the
      # section Text components run (ExpandableText paddingX 0, so the
      # content width is the full viewport). Word wrap with the break
      # line trailing-trimmed, continuations never start with whitespace,
      # and over-long words hard-broken at exactly +width+ (breakLongWord
      # :1022-1062). The port's {Text.wrap} is its own idiom (the indent
      # rides row 1); the expanded section rows must reproduce pi's byte
      # shape — a "    <long path>" row renders as a BLANK row (the
      # trimmed indent), then width-cell rows at column 0 (the s9
      # base-run capture).
      def wrap_resource_row(text, width)
        return [text] if text.empty? || TUI.text_width(text) <= width

        rows = []
        current = +""
        text.scan(/\s+|\S+/).each do |token|
          if TUI.text_width(token) > width && !token.strip.empty?
            rows << current.rstrip unless current.empty?
            broken = break_long_word(token, width)
            rows.concat(broken[0..-2])
            current = +broken.last
          elsif TUI.text_width(current) + TUI.text_width(token) > width && !current.empty?
            rows << current.rstrip
            current = token.strip.empty? ? +"" : +token
          else
            current << token
          end
        end
        rows << current unless current.empty?
        rows
      end

      # pi-tui breakLongWord (utils.ts:1022-1062): width-cell rows.
      def break_long_word(word, width)
        rows = []
        current = +""
        current_width = 0
        word.chars.each do |char|
          char_width = TUI.text_width(char)
          if current_width + char_width > width
            rows << current
            current = +""
            current_width = 0
          end
          current << char
          current_width += char_width
        end
        rows << current unless current.empty?
        rows
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
