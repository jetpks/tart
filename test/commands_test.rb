# frozen_string_literal: true

require_relative "test_helper"
require "fileutils"
require "tmpdir"

module Tart
  # Slash commands (AC3): the frozen builtin set, pi's expansion block
  # (byte-identical, agent-session.ts:2152-2175), dispatch semantics, and
  # unknown-command passthrough. No TUI: the surface dependencies are
  # plain callables, the way bin/tart wires them.
  class CommandsTest < Test
    def setup
      @dir = Dir.mktmpdir("tart-commands-")
      @root = Dir.mktmpdir("tart-commands-root-")
      @skills = load_skills
      @calls = {output: [], spawn: [], reset: 0, quit: 0}
      @agent = stub_agent
      @handler = Commands::Handler.new(
        skills: @skills,
        settings: Settings::DEFAULTS.merge("defaultModel" => "m"),
        output: ->(text) { @calls[:output] << text },
        spawn: ->(&block) { @calls[:spawn] << block; block.call },
        agent: -> { @agent },
        reset: -> { @calls[:reset] += 1 },
        quit: -> { @calls[:quit] += 1 }
      )
    end

    def teardown
      FileUtils.rm_rf(@dir)
      FileUtils.rm_rf(@root)
    end

    def skill_file
      File.join(@dir, ".tart", "skills", "greet", "SKILL.md")
    end

    def load_skills
      FileUtils.mkpath(File.dirname(skill_file))
      File.write(skill_file, "---\nname: greet\ndescription: Says hello\n---\nHello body line.")
      # claude_dir: a nonexistent fixture path — the default (~/.claude/skills,
      # owner ruling 2026-10-10) would leak the real home into the test.
      Skills.load(cwd: @dir, root: @root, claude_dir: File.join(@root, "claude-skills")).skills
    end

    # Minimal loop double: dispatch_compact calls #compact and the surface
    # renders the result — the real seam is proven in AgentLoopTest/
    # ChatTest; this tests the command layer's wiring.
    def stub_agent
      Object.new.tap do |agent|
        agent.define_singleton_method(:compact) { @compacted = true }
        agent.define_singleton_method(:compacted?) { @compacted }
      end
    end

    # --- the frozen builtin set ---

    def test_builtin_set_is_exactly_the_frozen_commands
      assert_equal %w[new compact resume skills settings thinking help quit], Commands::BUILTINS.keys
    end

    # --- /thinking (pi handleThinkingCommand :5145) ---

    # An arg sets the exact level through the thinking callable; unknown
    # levels error with pi's showError text and never call through.
    def test_thinking_dispatch_sets_and_validates
      levels = []
      handler = Commands::Handler.new(
        skills: @skills, settings: {}, output: ->(text) { @calls[:output] << text },
        spawn: ->(&block) { block.call }, agent: -> { @agent }, reset: -> {},
        thinking: ->(arg) { levels << arg }, quit: -> {}
      )

      assert handler.dispatch("/thinking high")
      assert_equal ["high"], levels, "the exact level sets"
      assert handler.dispatch("/thinking nope")
      assert_equal ["high"], levels, "an unknown level never calls through"
      assert @calls[:output].last.include?("Unknown thinking level \"nope\". Available levels: off, minimal"),
        "the error carries pi's showError text"
    end

    # The bare command cycles (pi's app.thinking.cycle — the port has no
    # selector UI, itemized).
    def test_thinking_dispatch_bare_cycles
      levels = []
      handler = Commands::Handler.new(
        skills: @skills, settings: {}, output: ->(text) { @calls[:output] << text },
        spawn: ->(&block) { block.call }, agent: -> { @agent }, reset: -> {},
        thinking: ->(arg) { levels << arg }, quit: -> {}
      )

      assert handler.dispatch("/thinking")
      assert_equal [:cycle], levels, "the bare command cycles"
    end

    # /resume (item 2, pi slash-commands.ts:41 + interactive-mode.ts
    # :3335-3338): dispatch opens the picker through the resume callable —
    # never falls through to the model.
    def test_resume_dispatch_opens_the_picker
      @handler = Commands::Handler.new(
        skills: @skills, settings: {}, output: ->(text) { @calls[:output] << text },
        spawn: ->(&block) { block.call }, agent: -> { @agent }, reset: -> {},
        resume: -> { @calls[:resume] = true }, quit: -> {}
      )
      assert @handler.dispatch("/resume")
      assert @calls[:resume], "the resume callable fired"

      @calls[:resume] = nil
      @handler.dispatch("/resume all")
      assert_nil @calls[:resume], "pi matches /resume exactly (interactive-mode.ts:3335)"
    end

    def test_resume_without_the_seam_is_a_noop
      assert @handler.dispatch("/resume"), "dispatched (not a model passthrough)"
      assert_empty @calls[:output]
    end

    # --- match shapes (pi: /new /quit exact, /compact takes args) ---

    def test_builtin_match_shapes
      assert_equal "new", Commands.builtin_name("/new")
      assert_nil Commands.builtin_name("/new extra"), "pi matches /new exactly"
      assert_equal "compact", Commands.builtin_name("/compact keep the plan")
      assert_equal "quit", Commands.builtin_name("/quit")
      assert_nil Commands.builtin_name("/quit now"), "pi matches /quit exactly"
      assert_nil Commands.builtin_name("/nope")
      assert_nil Commands.builtin_name("/skill:greet"), "skill invocations are not builtins"
    end

    # --- dispatch ---

    def test_quit_new_and_compact_dispatch
      @handler.dispatch("/quit")
      assert_equal 1, @calls[:quit]

      @handler.dispatch("/new")
      assert_equal 1, @calls[:reset]

      @handler.dispatch("/compact")
      assert_equal 1, @calls[:spawn].size
      assert @agent.compacted?, "the spawned task compacts the current agent"
    end

    def test_compact_reports_the_outcome_through_the_output_callable
      agent = Object.new.tap do |a|
        a.define_singleton_method(:compact) { false }
      end
      handler = Commands::Handler.new(
        skills: @skills, settings: {}, output: ->(text) { @calls[:output] << text },
        spawn: ->(&block) { block.call }, agent: -> { agent }, reset: -> {}, quit: -> {}
      )
      handler.dispatch("/compact")

      assert_equal ["nothing to compact (session too small)"], @calls[:output]
    end

    def test_skills_settings_and_help_render_through_the_output_callable
      @handler.dispatch("/skills")
      assert_equal 1, @calls[:output].size
      assert_includes @calls[:output].last, "greet: Says hello"

      @handler.dispatch("/settings")
      assert_includes @calls[:output].last, "defaultModel"

      @handler.dispatch("/help")
      Commands::BUILTINS.each_key { |name| assert_includes @calls[:output].last, "/#{name}" }

      assert_empty @calls[:spawn]
      assert_equal 0, @calls[:quit] + @calls[:reset]
    end

    # --- skill expansion (pi agent-session.ts:2152-2175) ---

    def test_expansion_matches_pis_block_byte_for_byte
      expanded = @handler.expand_skill("/skill:greet some args ")

      assert_equal(
        "<skill name=\"greet\" location=\"#{skill_file}\">\n" \
        "References are relative to #{File.dirname(skill_file)}.\n\nHello body line.\n</skill>\n\nsome args",
        expanded
      )
    end

    def test_expansion_without_args_omits_the_trailing_blank_line
      assert_equal(
        "<skill name=\"greet\" location=\"#{skill_file}\">\n" \
        "References are relative to #{File.dirname(skill_file)}.\n\nHello body line.\n</skill>",
        @handler.expand_skill("/skill:greet")
      )
    end

    def test_unknown_skill_passes_through_as_plain_text
      assert_equal "/skill:missing args", @handler.expand_skill("/skill:missing args")
      assert_equal "/skill:missing", @handler.expand_skill("/skill:missing")
    end

    def test_non_skill_text_passes_through_untouched
      assert_equal "plain words", @handler.expand_skill("plain words")
      assert_equal "/skills", @handler.expand_skill("/skills")
    end

    def test_expansion_reads_the_file_fresh_and_strips_frontmatter
      File.write(skill_file, "---\nname: greet\ndescription: Updated\n---\nNew body.")
      assert_includes @handler.expand_skill("/skill:greet"), "New body."
      refute_includes @handler.expand_skill("/skill:greet"), "description: Updated"
    end

    def test_expansion_read_failure_returns_the_original_text
      File.delete(skill_file)
      assert_equal "/skill:greet", @handler.expand_skill("/skill:greet")
    end
  end
end
