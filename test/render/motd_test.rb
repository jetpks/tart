# frozen_string_literal: true

require_relative "../test_helper"

module Tart
  module Render
    # The MOTD builders' expanded bodies (I33): pi's expanded startup
    # header (the live-oracle capture), the tart family's one-row-per-key
    # expanded header, and the resource sections' expanded shapes — the
    # display paths, the scope groups, and the pi-tui wrap the expanded
    # rows run. Builder-level pins; the flip/lifecycle wiring lives in
    # chat_test.
    class MotdTest < Test
      def setup
        @dir = Dir.mktmpdir("tart-motd-")
      end

      def teardown
        FileUtils.rm_rf(@dir)
      end

      # pi expandedInstructions (interactive-mode.ts:1020-1043) — the
      # live-oracle capture (tmp/probe-expanded-plain, boot → C-o →
      # settle): hint 1 rides the mark's second line, hints 2–19 one per
      # row in the keyHint shape (dim key + muted description, one left-
      # pad column), the darwin option+ rewrites, a blank, onboarding.
      # The notice line renders ONLY collapsed.
      def test_pi_header_expands_to_the_full_hint_list
        rows = pi_header_rows(expanded: true)
        assert_equal " ▀▀█  v#{Identity::ORACLE_VERSION}", rows[0], "the mark's first line carries the version"
        assert_equal " █▀ █ escape to interrupt", rows[1], "hint 1 rides the mark's second line"
        assert_equal " ctrl+c to clear", rows[2]
        assert_equal " ctrl+c twice to exit", rows[3]
        assert_equal " ctrl+d to exit (empty)", rows[4]
        assert_equal " ctrl+z to suspend", rows[5]
        assert_equal " ctrl+k to delete to end", rows[6]
        assert_equal " shift+tab to cycle thinking level", rows[7]
        assert_equal " ctrl+p/shift+ctrl+p to cycle models", rows[8]
        assert_equal " ctrl+l to select model", rows[9]
        assert_equal " ctrl+o to expand tools", rows[10]
        assert_equal " ctrl+t to expand thinking", rows[11]
        assert_equal " ctrl+g for external editor", rows[12]
        assert_equal " / for commands", rows[13]
        assert_equal " ! to run bash", rows[14]
        assert_equal " !! to run bash (no context)", rows[15]
        assert_equal " option+enter to queue follow-up", rows[16], "the darwin alt→option rewrite"
        assert_equal " option+up to edit all queued messages", rows[17]
        assert_equal " ctrl+v to paste files on macOS, images, or text", rows[18]
        assert_equal " drop files to attach", rows[19]
        assert_equal "", rows[20], "the header text's blank row"
        assert_equal " #{Motd::PI_ONBOARDING_LINE}", rows[21], "the onboarding line closes the header"
        assert_equal 22, rows.size
        refute_includes rows.join("\n"), "startup help", "the notice renders only collapsed"
      end

      # The collapsed bytes are frozen (the s1 guard): mark + compact
      # hints, the notice, blank, onboarding.
      def test_pi_header_collapses_to_the_pinned_bytes
        rows = pi_header_rows(expanded: false)
        assert_equal 5, rows.size
        assert_equal " ▀▀█  v#{Identity::ORACLE_VERSION}", rows[0]
        assert_includes rows[1], "escape interrupt", "the compact hints line"
        assert_equal " #{Motd::PI_NOTICE_LINE}", rows[2], "the ctrl+o notice"
        assert_equal "", rows[3]
        assert_equal " #{Motd::PI_ONBOARDING_LINE}", rows[4]
      end

      # The hint rows carry the keyHint styles (keybinding-hints.ts:42-44):
      # the key dim, the description muted.
      def test_pi_expanded_hint_rows_render_the_keyhint_styles
        row = Motd.pi_header_lines(expanded: true, width: 120)[2]
        assert_equal Theme[:dim], row.spans[1].style.fg, "the key renders dim"
        assert_equal Theme[:muted], row.spans[2].style.fg, "the description renders muted"
      end

      # I56 AC2: the wrapped header rows reproduce the live-pi artifact
      # bytes EXACTLY at the pinned widths — 50 (the whitespace-break
      # class: the separator's leading space rides the continuation), 52
      # (the separator-carrying class: `…clear/exit ·` / `␣/ commands…`)
      # and 80 (the word-break class: `…! bash ·` / `␣ctrl+o more`).
      # Plain bytes from tmp/resize-calib/stage3/pi-w{50,52,80}.txt (the
      # oracle table, cross-checked against a deno run of pi's own
      # wrapTextWithAnsi); rows below the header (the reply/footer area)
      # are not part of the pin.
      def test_pi_header_rows_wrap_to_the_live_oracle_bytes_at_pinned_widths
        assert_equal [
          " ▀▀█  v#{Identity::ORACLE_VERSION}",
          " █▀ █ escape interrupt · ctrl+c/ctrl+d clear/exit",
          "  · / commands · ! bash · ctrl+o more",
          " Press ctrl+o to show full startup help and",
          " loaded resources.",
          "",
          " Pi can explain its own features and look up its",
          " docs. Ask it how to use or extend Pi."
        ], pi_header_rows(expanded: false, width: 50), "w50: the whitespace-break class"

        assert_equal [
          " ▀▀█  v#{Identity::ORACLE_VERSION}",
          " █▀ █ escape interrupt · ctrl+c/ctrl+d clear/exit ·",
          " / commands · ! bash · ctrl+o more",
          " Press ctrl+o to show full startup help and loaded",
          " resources.",
          "",
          " Pi can explain its own features and look up its",
          " docs. Ask it how to use or extend Pi."
        ], pi_header_rows(expanded: false, width: 52), "w52: the separator-carrying class"

        assert_equal [
          " ▀▀█  v#{Identity::ORACLE_VERSION}",
          " █▀ █ escape interrupt · ctrl+c/ctrl+d clear/exit · / commands · ! bash ·",
          " ctrl+o more",
          " Press ctrl+o to show full startup help and loaded resources.",
          "",
          " Pi can explain its own features and look up its docs. Ask it how to use or",
          " extend Pi."
        ], pi_header_rows(expanded: false, width: 80), "w80: the word-break class"
      end

      # The wrapped continuation's EFFECTIVE runs match the -e artifact
      # (pi-w50.styled row 3): the pad renders unstyled, the separator's
      # leading space rides the muted ` · ` run (pi's re-issued SGR —
      # utils.ts:941), the keys re-open dim. At a fitting width the row is
      # ONE span run per source segment, byte-identical to the frozen
      # 120-col shape.
      def test_pi_header_rows_wrap_keeps_the_continuation_style_runs
        row = Motd.pi_header_lines(expanded: false, width: 50)[2].spans
        assert_equal " ", row[0].content
        assert_nil row[0].style, "the pad renders unstyled"
        assert_equal " · ", row[1].content, "the separator's leading space rides the continuation"
        assert_equal Theme[:muted], row[1].style.fg, "the muted run re-opens at the separator"
        assert_equal ["/", " commands", " · ", "!"], row.values_at(2, 3, 4, 5).map(&:content)
        assert_equal Theme[:dim], row[2].style.fg, "the key re-opens dim"

        row80 = Motd.pi_header_lines(expanded: false, width: 80)[2].spans
        assert_equal [" ", "ctrl+o", " more"], row80.map(&:content), "the word-led continuation"
        assert_equal Theme[:dim], row80[1].style.fg

        onboard = Motd.pi_header_lines(expanded: false, width: 80)[6].spans
        assert_equal [" ", "extend Pi."], onboard.map(&:content), "the wrapped onboarding pair"
      end

      # I56 AC3: the ladder — the WIDEST piece by max-row CELL width whose
      # pad + widest row fits the width; the 40-cell tie breaks name-asc
      # (mono-12 over rebel). From the MEASURED table (ladder.txt,
      # regenerated with TUI.text_width): 120 → slant-relief (66),
      # 43 → twisted (42, fits its width exactly), 42 → mono-12 (40; the
      # measured tie over rebel), 35 → soft (32).
      def test_ladder_picks_the_widest_fitting_piece_per_width
        assert_equal logo("slant-relief"), Motd.motd_logo_lines(120, wordmark: "tart")
        assert_equal logo("twisted"), Motd.motd_logo_lines(43, wordmark: "tart"),
          "twisted fits 43 exactly (42 + one pad)"
        assert_equal logo("mono-12"), Motd.motd_logo_lines(42, wordmark: "tart"),
          "the 40-cell tie breaks name-ascending: mono-12 over rebel"
        assert_equal logo("soft"), Motd.motd_logo_lines(35, wordmark: "tart")
      end

      # Below the smallest piece (tmplr, 6 cells + pad = 7) the ladder
      # floors at the WORDMARK row — the identity name, one row.
      def test_ladder_wordmark_floor_below_the_smallest_piece
        assert_equal ["tart"], Motd.motd_logo_lines(6, wordmark: "tart")
        assert_equal ["tart"], Motd.motd_logo_lines(1, wordmark: "tart")
        assert_equal ["mike"], Motd.motd_logo_lines(6, wordmark: "mike"), "the wordmark is the caller's identity name"
        assert_equal logo("tmplr"), Motd.motd_logo_lines(7, wordmark: "tart"), "the smallest piece fits 7"
      end

      # The tart family's expanded header: one row per REAL bound key
      # (chat.rb's routing), same keyHint visual shape; the name threads
      # explicitly (I33 AC5).
      def test_tart_header_expands_to_one_row_per_bound_key
        rows = Motd.tart_header_lines(60, "tart", expanded: true).map { |row| row.spans.map(&:content).join }
        version_i = rows.index { |row| row.include?("tart v#{Tart::VERSION}") }
        refute_nil version_i, "the art + version lead"
        assert_equal " enter to send", rows[version_i + 1]
        assert_equal " escape to interrupt", rows[version_i + 2]
        assert_equal " ctrl+c twice to exit", rows[version_i + 4]
        assert_equal " ctrl+o to expand tools", rows[version_i + 6]
        assert_equal " / for commands", rows[version_i + 15]
        assert_equal " !! to run bash (no context)", rows[version_i + 17]
        assert_equal version_i + 1 + Motd::TART_EXPANDED_HINTS.size, rows.size, "one row per key after the version"
      end

      # The collapsed tart header keeps its frozen hints line.
      def test_tart_header_collapsed_keeps_the_compact_hints_line
        rows = Motd.tart_header_lines(60, "tart", expanded: false).map { |row| row.spans.map(&:content).join }
        assert_includes rows.last, "pgup/pgdn scroll", "the compact hints line (HINTS_LINE, byte-frozen)"
        refute_includes rows.join("\n"), "to yank", "no expanded rows leak into the collapsed header"
      end

      # [Context] expanded: the full display paths one per line, dim,
      # home→~ contracted (pi formatDisplayPath), NO output pad (the
      # section components are paddingX 0).
      def test_context_section_expands_to_display_paths
        first = File.join(@dir, "AGENTS.md")
        second = File.join(@dir, "notes.md")
        File.write(first, "x")
        File.write(second, "x")
        section = Motd.sections(120, context: [first, second], skills: [], prompts: [], extensions: [],
          user_root: @dir, project_root: @dir).first

        assert_equal "[Context]", section.name
        assert section.leading_blank, "pi's contextFiles branch adds the leading Spacer"
        rows = section.expanded_rows.map { |row| row.spans.map(&:content).join }
        assert_equal "  #{first}", rows[0], "the full display path, two-space indent, one per line"
        assert_equal "  #{second}", rows[1]
        assert_equal Theme[:dim], section.expanded_rows[0].spans[0].style.fg
      end

      # pi formatDisplayPath (:1389-1399) — the home prefix contracts to ~.
      def test_display_path_contracts_the_home_prefix
        assert_equal "~/notes.md", Motd.display_path(File.join(Dir.home, "notes.md"))
        assert_equal "/elsewhere/notes.md", Motd.display_path("/elsewhere/notes.md")
      end

      # [Skills]/[Prompts] expanded: scope groups in pi's order (project →
      # user → path), an accent label row then dim indented entries sorted
      # by path; [Prompts] entries render as /name.
      def test_sections_expand_to_scope_groups
        user_skill = Skills::Skill.new(name: "zulu", description: "d", file_path: "/u/.tart/skills/zulu.md",
          base_dir: "/u/.tart/skills", disable_model_invocation: false)
        project_skill = Skills::Skill.new(name: "alpha", description: "d", file_path: "/p/.tart/skills/alpha.md",
          base_dir: "/p/.tart/skills", disable_model_invocation: false)
        stray_skill = Skills::Skill.new(name: "mike", description: "d", file_path: "/tmp/elsewhere/mike.md",
          base_dir: "/tmp/elsewhere", disable_model_invocation: false)
        template = Prompts::Template.new(name: "council", description: "d", content: "b",
          file_path: "/p/.tart/prompts/council.md")

        skills_section = Motd.sections(120, context: [], skills: [stray_skill, user_skill, project_skill],
          prompts: [], extensions: [], user_root: "/u/.tart", project_root: "/p/.tart")[0]
        rows = skills_section.expanded_rows.map { |row| row.spans.map(&:content).join }
        assert_equal "  project", rows[0], "project first (pi :1655-1657)"
        assert_equal "    /p/.tart/skills/alpha.md", rows[1]
        assert_equal "  user", rows[2]
        assert_equal "    /u/.tart/skills/zulu.md", rows[3]
        assert_equal "  path", rows[4]
        assert_equal "    /tmp/elsewhere/mike.md", rows[5]
        assert_nil skills_section.expanded_rows[0].spans[0].style&.fg,
          "the label row's indent renders UNSTYLED (pi's two SGR runs)"
        assert_equal Theme[:accent], skills_section.expanded_rows[0].spans[1].style.fg, "the scope name renders accent"
        assert_equal Theme[:dim], skills_section.expanded_rows[1].spans[0].style.fg, "the entries render dim"

        prompts_section = Motd.sections(120, context: [], skills: [], prompts: [template], extensions: [],
          user_root: "/u/.tart", project_root: "/p/.tart")[0]
        prompt_rows = prompts_section.expanded_rows.map { |row| row.spans.map(&:content).join }
        assert_equal "  project", prompt_rows[0]
        assert_equal "    /council", prompt_rows[1], "the template renders as /name (pi :1881-1896)"
      end

      # --- I70: the prompt-scope PACKAGE tier (the builtin workflow
      # --- templates, file_path: nil — the crash cure, default-on's
      # --- [Prompts] shape; the oracle capture tmp/probe-subag).

      # A nil-file_path builtin template classifies into pi's user scope
      # under the port's own package label: the accent group label, the
      # mdLink package label row (two spans, indent UNSTYLED), then the
      # six /name member rows (ONE dim span incl. the 6-space indent),
      # name-sorted. The collapsed compact list shape is unchanged.
      def test_nil_path_prompt_templates_render_the_package_tier
        section = Motd.sections(120, context: [], skills: [], prompts: Subagents::WORKFLOW_TEMPLATES,
          extensions: [], user_root: "/u/.tart", project_root: "/p/.tart")[0]
        rows = section.expanded_rows.map { |row| row.spans.map(&:content).join }
        assert_equal "  user", rows[0], "pi's installed-package scope is user"
        assert_equal "    subagents", rows[1], "the port's package label (pi reads npm:pi-subagents)"
        assert_equal %w[/council /gather-context-and-clarify /parallel-cleanup /parallel-research /parallel-review
                        /review-loop], rows[2..].map(&:strip), "the six members name-sorted"
        assert_nil section.expanded_rows[0].spans[0].style&.fg, "the group label's indent renders UNSTYLED"
        assert_equal Theme[:accent], section.expanded_rows[0].spans[1].style.fg, "the group label renders accent"
        assert_nil section.expanded_rows[1].spans[0].style&.fg, "the package label's indent renders UNSTYLED"
        assert_equal Theme[:md_link], section.expanded_rows[1].spans[1].style.fg, "the package label renders md_link"
        member = section.expanded_rows[2]
        assert_equal 1, member.spans.size, "the member row is ONE span — the indent rides the dim run"
        assert_equal "      /council", member.spans[0].content, "6-space indent + display inside one dim span"
        assert_equal Theme[:dim], member.spans[0].style.fg
        collapsed = section.collapsed_rows.map { |row| row.spans.map(&:content).join }.join
        %w[/council /gather-context-and-clarify /parallel-cleanup /parallel-research /parallel-review /review-loop].each do |name|
          assert_includes collapsed, name, "the collapsed compact list carries #{name}"
        end
      end

      # Mixed tiers: file-backed templates keep today's plain path rows
      # (project → user groups, path-sorted, dim) BEFORE the user group's
      # package sub-list.
      def test_mixed_prompt_tiers_keep_the_plain_path_rows
        user = Prompts::Template.new(name: "zulu", description: "d", argument_hint: nil, content: "b",
          file_path: "/u/.tart/prompts/zulu.md")
        project = Prompts::Template.new(name: "alpha", description: "d", argument_hint: nil, content: "b",
          file_path: "/p/.tart/prompts/alpha.md")
        section = Motd.sections(120, context: [], skills: [],
          prompts: Subagents::WORKFLOW_TEMPLATES + [user, project], extensions: [],
          user_root: "/u/.tart", project_root: "/p/.tart")[0]
        rows = section.expanded_rows.map { |row| row.spans.map(&:content).join }
        assert_equal ["  project", "    /alpha", "  user", "    /zulu", "    subagents",
          "      /council", "      /gather-context-and-clarify", "      /parallel-cleanup",
          "      /parallel-research", "      /parallel-review", "      /review-loop"], rows,
          "plain path rows render EXACTLY as today, then the package sub-list"
        assert_equal Theme[:dim], section.expanded_rows[1].spans[0].style.fg, "the plain path rows stay dim"
      end

      # The nil-crash class stays dead: a nil file_path NEVER reaches
      # scope_group/under? (the base defect: NoMethodError at motd.rb:306),
      # and the rows build at a narrow width through the wrap.
      def test_nil_path_templates_never_crash_the_scope_path
        entries = Motd.prompt_scope_entries(Subagents::WORKFLOW_TEMPLATES, user_root: "/u/.tart", project_root: "/p/.tart")
        assert entries.all? { |entry| entry[:group] == "user" && entry[:package] == "subagents" && entry[:path].nil? }
        rows = Motd.scope_group_rows(entries, 40)
        assert_equal 8, rows.size, "label + package label + six members, no crash at width 40"
      end

      # [Extensions] stays compact in BOTH states (pi's default
      # expandedBody IS the collapsed body — addLoadedSection :1810): the
      # port's extensions are names, not paths.
      def test_extensions_section_keeps_the_compact_body_expanded
        section = Motd.sections(120, context: [], skills: [], prompts: [], extensions: %w[notify memory],
          user_root: @dir, project_root: @dir)[0]
        assert_equal "[Extensions]", section.name
        assert_equal section.collapsed_rows, section.expanded_rows
        assert_equal ["memory", "notify"], section.expanded_rows.first.spans.map(&:content).join.strip.split(", ")
      end

      # pi-tui wrapSingleLine (utils.ts:925-995): a "    <long path>" row
      # renders as a BLANK row (the trimmed indent), then width-cell rows
      # at column 0 (the s9 base-run capture).
      def test_resource_rows_wrap_pi_style
        long_path = "/#{("a" * 9 + "/") * 14}g.md" # > 120 cells
        rows = Motd.wrap_resource_row("    #{long_path}", 120)
        assert_equal "", rows[0], "the indent trims to its own blank row"
        assert_equal 120, TUI.text_width(rows[1]), "the long word hard-breaks at exactly width"
        assert_equal long_path, rows[1] + rows[2], "the rows rejoin to the path (no indent)"
      end

      def test_resource_rows_pass_short_lines_through
        assert_equal ["  project"], Motd.wrap_resource_row("  project", 120)
        assert_equal [""], Motd.wrap_resource_row("", 120)
      end

      private

      def pi_header_rows(expanded:, width: 120)
        Motd.pi_header_lines(expanded:, width:).map { |row| row.spans.map(&:content).join }
      end

      # One logo piece's raw lines (the ladder's return shape).
      def logo(name)
        File.readlines(File.join(Motd::LOGOS_DIR, "#{name}.txt"), chomp: true)
      end
    end
  end
end
