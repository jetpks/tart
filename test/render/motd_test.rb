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
        row = Motd.pi_header_lines(expanded: true)[2]
        assert_equal Theme[:dim], row.spans[1].style.fg, "the key renders dim"
        assert_equal Theme[:muted], row.spans[2].style.fg, "the description renders muted"
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

      def pi_header_rows(expanded:)
        Motd.pi_header_lines(expanded:).map { |row| row.spans.map(&:content).join }
      end
    end
  end
end
