# frozen_string_literal: true

require_relative "test_helper"
require "fileutils"
require "tmpdir"

module Tart
  # Prompt templates (pi core/prompt-templates.ts): discovery, frontmatter
  # rules, expansion + argument substitution — inputs & outputs on the
  # module's public seam.
  class PromptsTest < Test
    def setup
      @dir = Dir.mktmpdir("tart-prompts-")
      @root = Dir.mktmpdir("tart-prompts-root-")
    end

    def teardown
      FileUtils.rm_rf(@dir)
      FileUtils.rm_rf(@root)
    end

    def write_template(dir, name, content)
      FileUtils.mkpath(dir)
      path = File.join(dir, "#{name}.md")
      File.write(path, content)
      path
    end

    # pi loadPromptTemplates: user first, project second; name = the
    # filename stem; description falls back to the first body line
    # (truncated at 60); argument-hint rides when declared. Discovery
    # order within a directory follows the filesystem (unpinned); the
    # user/project split is what's pinned.
    def test_loads_templates_from_user_then_project_dirs
      write_template(File.join(@root, "prompts"), "council",
        "---\ndescription: Convene the council\nargument-hint: <topic>\n---\nBody one.")
      write_template(File.join(@dir, ".tart", "prompts"), "review", "Review this:\n$@")

      result = Prompts.load(cwd: @dir, root: @root)

      assert_equal %w[council review], result.templates.map(&:name), "user first, project second"
      council = result.templates.first
      assert_equal "Convene the council", council.description
      assert_equal "<topic>", council.argument_hint
      assert_equal "Body one.", council.content
      review = result.templates[1]
      assert_equal "Review this:", review.description, "the first body line is the fallback description"
      assert_equal "Review this:\n$@", review.content, "the body is the content, frontmatter aside"
    end

    # pi loadTemplateFromFile :141-151: the description truncates at 60
    # chars with an ellipsis; no argument-hint → nil.
    def test_description_fallback_truncates
      write_template(File.join(@root, "prompts"), "long", "#{"x" * 70}\nsecond")

      template = Prompts.load(cwd: @dir, root: @root).templates.first

      assert_equal "x" * 60 + "...", template.description
      assert_nil template.argument_hint, "no argument-hint → nil"
    end

    # Name collision: first-loaded wins (the Skills merge rule), silent.
    def test_name_collision_first_loaded_wins
      write_template(File.join(@root, "prompts"), "dupe", "user body")
      write_template(File.join(@dir, ".tart", "prompts"), "dupe", "project body")

      result = Prompts.load(cwd: @dir, root: @root)

      assert_equal 1, result.templates.size
      assert_equal "user body", result.templates.first.content
      assert_empty result.diagnostics
    end

    # Non-.md files, dotfiles, and subdirectories never load (pi
    # loadTemplatesFromDir's non-recursive top-level .md scan).
    def test_ignores_non_template_entries
      FileUtils.mkpath(File.join(@root, "prompts", "nested"))
      File.write(File.join(@root, "prompts", "nested", "deep.md"), "no")
      File.write(File.join(@root, "prompts", "notes.txt"), "no")
      File.write(File.join(@root, "prompts", ".hidden.md"), "no")

      assert_empty Prompts.load(cwd: @dir, root: @root).templates
    end

    # A malformed file is a warning diagnostic, not a crash (pi
    # loadTemplateFromFile :122-127).
    def test_unreadable_template_is_a_diagnostic
      path = write_template(File.join(@root, "prompts"), "bad", "body")
      FileUtils.chmod(0o000, path)

      result = Prompts.load(cwd: @dir, root: @root)

      assert_empty result.templates
      assert_equal 1, result.diagnostics.size
      assert_equal "warning", result.diagnostics.first.type
    ensure
      FileUtils.chmod(0o644, path)
    end

    # pi expandPromptTemplate :512-527: /name resolves, args substitute,
    # unknown names pass through untouched.
    def test_expand_resolves_templates_and_passes_unknown_through
      template = Prompts::Template.new(name: "review", description: "", content: "Review: $@", file_path: "/x")
      templates = [template]

      assert_equal "Review: the login flow", Prompts.expand("/review the login flow", templates)
      assert_equal "Review: ", Prompts.expand("/review", templates), "no args → empty substitution"
      assert_equal "/missing args", Prompts.expand("/missing args", templates), "unknown → plain text"
      assert_equal "not a command", Prompts.expand("not a command", templates), "no slash → plain text"
    end

    # pi substituteArgs (:62-92): positional, all-args, defaults, slices.
    def test_substitute_placeholders
      assert_equal "a b", Prompts.substitute("$1 $2", %w[a b])
      assert_equal "a b", Prompts.substitute("$@", %w[a b])
      assert_equal "a b", Prompts.substitute("$ARGUMENTS", %w[a b])
      assert_equal "b", Prompts.substitute("${1:-fallback}", %w[b]), "a present arg wins over the default"
      assert_equal "fallback", Prompts.substitute("${1:-fallback}", []), "missing arg → the default"
      assert_equal "a b", Prompts.substitute("${@:-fallback}", %w[a b])
      assert_equal "fallback", Prompts.substitute("${@:-fallback}", []), "empty all-args → the default"
      assert_equal "b c", Prompts.substitute("${@:2}", %w[a b c]), "the slice from Nth on"
      assert_equal "b c", Prompts.substitute("${@:2:2}", %w[a b c]), "L args from Nth"
    end

    # pi parseCommandArgs (:17-54): bash-style quoted splitting — quoted
    # runs stay whole (quotes drop), adjacent quoted runs coalesce.
    def test_parse_command_args_respects_quotes
      assert_equal %w[a b], Prompts.parse_command_args("a b")
      assert_equal ["a b", "c"], Prompts.parse_command_args("\"a b\" c")
      assert_equal ["its fine", "extra"], Prompts.parse_command_args("'it''s fine' extra")
      assert_equal [], Prompts.parse_command_args("")
    end
  end
end
