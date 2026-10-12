# frozen_string_literal: true

require_relative "test_helper"
require "fileutils"
require "tmpdir"

module Tart
  # Skill loading + prompt formatting (AC1): filesystem fixtures only, no
  # LLM; discovery, frontmatter rules, diagnostics, collisions, symlink
  # dedup, disable-model-invocation, and the byte-identical
  # <available_skills> block (pi core/skills.ts:358-394). Hermetic: tmp
  # dirs only, ~/.tart never touched.
  class SkillsTest < Test
    def setup
      @root = Dir.mktmpdir("tart-skills-user-") # the fake ~/.tart root
      @cwd = Dir.mktmpdir("tart-skills-project-")
    end

    def teardown
      FileUtils.rm_rf(@root)
      FileUtils.rm_rf(@cwd)
    end

    def user_dir = File.join(@root, "skills")
    def project_dir = File.join(@cwd, ".tart", "skills")
    # The sandboxed ~/.claude/skills fixture root (the owner ruling
    # 2026-10-10's second user source) — never the real ~/.claude.
    def claude_dir = File.join(@root, "claude-skills")

    def write_skill(dir, name, frontmatter, body = "Do the thing.", file: "SKILL.md")
      dir = File.join(dir, name) unless name.nil?
      FileUtils.mkpath(dir)
      content = frontmatter ? "---\n#{frontmatter}\n---\n#{body}" : body
      File.write(File.join(dir, file), content)
    end

    def skill(name) = load_skills[:skills].find { |s| s.name == name }
    def load_skills = Skills.load(cwd: @cwd, root: @root, claude_dir: claude_dir)

    # --- discovery ---

    def test_loads_user_then_project_skills
      write_skill(user_dir, "greet", "description: Says hello")
      write_skill(project_dir, "deploy", "description: Deploys the app")

      loaded = load_skills
      # user-before-project decides the collision winner; the CATALOG
      # itself is name-sorted (the oracle's autocomplete order — /ar
      # selects architect, 2026-10-11 live probe).
      assert_equal %w[deploy greet], loaded.skills.map(&:name)
      assert_empty loaded.diagnostics
    end

    def test_catalog_is_name_sorted
      write_skill(user_dir, "zeta", "description: z")
      write_skill(user_dir, "alpha", "description: a")
      write_skill(project_dir, "mid", "description: m")

      assert_equal %w[alpha mid zeta], load_skills.skills.map(&:name)
    end

    def test_skill_md_root_does_not_recurse_and_subdirs_recurse
      write_skill(user_dir, "top", "description: Top skill", "---\nignored: nested SKILL.md is not a skill\n")
      FileUtils.mkpath(File.join(user_dir, "top", "nested"))
      File.write(File.join(user_dir, "top", "nested", "SKILL.md"), "---\ndescription: buried\n---\nx")
      write_skill(user_dir, "group/inner", "description: Inner skill")

      names = load_skills.skills.map(&:name)
      assert_includes names, "top"
      refute_includes names, "nested", "a SKILL.md root must not recurse below itself"
      assert_includes names, "inner"
    end

    def test_bare_skill_md_at_the_skills_dir_root_loads
      FileUtils.mkpath(user_dir)
      File.write(File.join(user_dir, "SKILL.md"), "---\ndescription: Root skill\n---\nbody")
      File.write(File.join(user_dir, "loose.md"), "---\ndescription: Loose skill\n---\nbody")

      # The SKILL.md root loads and the walk stops there (no recursion into
      # the root's other children); the name falls back to the directory.
      skills = load_skills.skills
      assert_equal 1, skills.size
      assert_equal File.basename(user_dir), skills.first.name
      assert_equal File.join(user_dir, "SKILL.md"), skills.first.file_path
    end

    def test_dotfile_dirs_and_node_modules_are_skipped
      write_skill(user_dir, ".hidden/hidden", "description: Hidden")
      write_skill(user_dir, "node_modules/dep", "description: Dep")

      assert_empty load_skills.skills
    end

    # --- frontmatter rules ---

    def test_name_falls_back_to_the_directory_name
      write_skill(user_dir, "fallback", "description: Only a description")
      assert_equal "fallback", skill("fallback").name
    end

    def test_missing_description_drops_the_skill_with_a_warning
      write_skill(user_dir, "nodesc", "name: nodesc")
      loaded = load_skills

      assert_empty loaded.skills
      assert_equal "description is required", loaded.diagnostics.first.message
      assert_equal File.join(user_dir, "nodesc", "SKILL.md"), loaded.diagnostics.first.path
    end

    def test_oversize_description_warns_but_still_loads
      write_skill(user_dir, "big", "description: #{'d' * 1025}")
      loaded = load_skills

      assert_equal "big", loaded.skills.first.name
      assert_equal "description exceeds 1024 characters (1025)", loaded.diagnostics.first.message
    end

    def test_oversize_name_warns_but_still_loads
      write_skill(user_dir, "d" * 65, "description: Long name")
      loaded = load_skills

      assert_equal "d" * 65, loaded.skills.first.name
      assert_equal "name exceeds 64 characters (65)", loaded.diagnostics.first.message
    end

    def test_invalid_name_characters_warn_but_still_load
      write_skill(user_dir, "Bad_Name", "description: Odd name")
      loaded = load_skills

      assert_equal "Bad_Name", loaded.skills.first.name
      assert_includes loaded.diagnostics.first.message, "invalid characters"
    end

    def test_malformed_yaml_is_a_diagnostic_not_a_crash
      FileUtils.mkpath(File.join(user_dir, "broken"))
      File.write(File.join(user_dir, "broken", "SKILL.md"), "---\ndescription: [unclosed\n---\nbody")
      loaded = load_skills

      assert_empty loaded.skills
      assert loaded.diagnostics.first.message.length > 0
      assert_equal "warning", loaded.diagnostics.first.type
    end

    def test_bare_md_without_description_is_skipped_silently
      FileUtils.mkpath(user_dir)
      File.write(File.join(user_dir, "plain.md"), "just text, no frontmatter")
      loaded = load_skills

      assert_empty loaded.skills
      assert_empty loaded.diagnostics
    end

    def test_disable_model_invocation_loads_but_hides_from_the_prompt
      write_skill(user_dir, "manual", "description: Manual only\ndisable-model-invocation: true")

      loaded = load_skills
      assert_equal 1, loaded.skills.size, "still loaded (user-invocable)"
      assert_empty Skills.format_skills_for_prompt(loaded.skills)
    end

    # --- composition ---

    def test_first_loaded_wins_and_the_collision_names_the_loser
      write_skill(user_dir, "dupe", "description: User wins")
      write_skill(project_dir, "dupe", "description: Project loses")
      loaded = load_skills

      assert_equal 1, loaded.skills.size
      assert_equal "User wins", loaded.skills.first.description
      collision = loaded.diagnostics.find { |d| d.type == "collision" }
      assert_equal 'name "dupe" collision', collision.message
      assert_equal File.join(project_dir, "dupe", "SKILL.md"), collision.path
      assert_equal File.join(user_dir, "dupe", "SKILL.md"), collision.collision[:winner_path]
    end

    def test_symlinked_duplicate_is_skipped_silently
      write_skill(user_dir, "real", "description: The real one")
      FileUtils.mkpath(project_dir)
      File.symlink(File.join(user_dir, "real", "SKILL.md"), File.join(project_dir, "SKILL.md"))

      loaded = load_skills
      assert_equal 1, loaded.skills.size
      assert_empty loaded.diagnostics
    end

    def test_missing_directories_load_nothing
      assert_empty Skills.load(cwd: @cwd, root: @root, claude_dir: claude_dir).skills
    end

    # --- the ~/.claude/skills user source (owner ruling 2026-10-10) ---

    def test_claude_skills_dir_loads_as_a_user_source
      write_skill(claude_dir, "architect", "description: Runs the loop")

      loaded = load_skills
      assert_equal %w[architect], loaded.skills.map(&:name)
      assert_empty loaded.diagnostics
    end

    def test_user_root_precedes_claude_skills_and_project
      write_skill(user_dir, "dupe", "description: Root wins")
      write_skill(claude_dir, "dupe", "description: Claude loses")
      write_skill(project_dir, "dupe", "description: Project loses too")
      loaded = load_skills

      assert_equal 1, loaded.skills.size, "first-loaded wins across all three sources"
      assert_equal "Root wins", loaded.skills.first.description
      collision = loaded.diagnostics.find { |d| d.type == "collision" }
      assert_equal File.join(claude_dir, "dupe", "SKILL.md"), collision.collision[:loser_path]
    end

    def test_claude_skills_precede_project
      write_skill(claude_dir, "dupe", "description: Claude wins")
      write_skill(project_dir, "dupe", "description: Project loses")
      loaded = load_skills

      assert_equal "Claude wins", loaded.skills.first.description
    end

    def test_realpath_dedup_spans_claude_and_user_sources
      write_skill(user_dir, "real", "description: The real one")
      FileUtils.mkpath(claude_dir)
      File.symlink(File.join(user_dir, "real", "SKILL.md"), File.join(claude_dir, "SKILL.md"))

      loaded = load_skills
      assert_equal 1, loaded.skills.size
      assert_empty loaded.diagnostics
    end

    # --- prompt formatting (byte-identical, pi skills.ts:358-394) ---

    def test_format_matches_pis_block_byte_for_byte
      FileUtils.mkpath(File.join(user_dir, "sc"))
      File.write(File.join(user_dir, "sc", "SKILL.md"), "---\nname: sc\ndescription: Say \"hi\" & <bye>\n---\nbody")
      loaded = Skills.load(cwd: @cwd, root: @root, claude_dir: claude_dir)

      expected = <<~BLOCK.chomp
        The following skills provide specialized instructions for specific tasks.
        Use the read tool to load a skill's file when the task matches its description.
        When a skill file references a relative path, resolve it against the skill directory (parent of SKILL.md / dirname of the path) and use that absolute path in tool commands.

        <available_skills>
          <skill>
            <name>sc</name>
            <description>Say &quot;hi&quot; &amp; &lt;bye&gt;</description>
            <location>#{File.join(user_dir, "sc", "SKILL.md")}</location>
          </skill>
        </available_skills>
      BLOCK

      assert_equal expected, Skills.format_skills_for_prompt(loaded.skills, "read").strip
      # Byte-identity includes pi's leading blank lines (joined "\n\n"…
      # block opens with two).
      assert_match(/\A\n\n/, Skills.format_skills_for_prompt(loaded.skills, "read"))
    end

    def test_format_names_bash_or_no_tool_per_pis_variants
      skill = Skills::Skill.new(name: "s", description: "d", file_path: "/p/SKILL.md",
                                base_dir: "/p", disable_model_invocation: false)

      assert_includes Skills.format_skills_for_prompt([skill], "bash"), "Use bash to load a skill's file"
      assert_includes Skills.format_skills_for_prompt([skill], "indirect"), "Load a skill's file when the task matches"
    end
  end
end
