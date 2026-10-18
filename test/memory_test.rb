# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"
require "json"

module Tart
  # The memory module (I47 — AC2, memory.ts @ ca12eb5 verbatim; Grounds §4
  # is the contract table): slug rules, the five topic error strings, save
  # file bytes, index upsert, read/list, the recall bounds, the wire
  # declaration bytes, the guidelines bullets, the settings gate, and the
  # env tiers. The gate `memory-module` drives the same surface.
  class MemoryTest < Test
    def setup
      @home = Dir.mktmpdir("tart-mem-home-")
      @cwd = Dir.mktmpdir("tart-mem-cwd-")
      @tool = Tools::Memory.new(cwd: @cwd, home: @home)
      @dir = File.join(@home, File.basename(@cwd))
    end

    def teardown
      FileUtils.rm_rf(@home)
      FileUtils.rm_rf(@cwd)
    end

    def index_path
      File.join(@dir, "MEMORY.md")
    end

    def with_memory_home(home)
      ENV["PI_MEMORY_HOME"] = home
      yield
    ensure
      ENV.delete("PI_MEMORY_HOME")
    end

    def write_index(content)
      FileUtils.mkdir_p(@dir)
      File.write(index_path, content)
    end

    # --- slugify (memory.ts slugify) ---

    def test_slugify_table
      {
        "Deploy Ops!" => "deploy-ops",
        "API notes" => "api-notes",
        "  trim  " => "trim",
        "dots.and-dashes" => "dots-and-dashes",
        "über" => "ber",
        "!!!!" => ""
      }.each do |topic, slug|
        assert_equal slug, @tool.send(:slugify, topic), topic
      end
    end

    # --- the five topic errors (byte-exact) ---

    def test_absolute_topic_error
      assert_equal %(Invalid topic "/etc/x": topics are plain names inside the project memory directory, not paths.),
        @tool.call(action: "save", topic: "/etc/x", text: "x")
    end

    def test_dotdot_topic_error
      assert_equal %(Invalid topic "../evil": topics are plain names inside the project memory directory, not paths.),
        @tool.call(action: "save", topic: "../evil", text: "x")
    end

    def test_bad_slug_error
      assert_equal %(Invalid topic "!!!": it must be a plain name like "deploy" (letters, numbers, dashes).),
        @tool.call(action: "save", topic: "!!!", text: "x")
    end

    def test_missing_topic_errors_carry_the_action
      assert_equal "The memory tool save action needs a topic.", @tool.call(action: "save", topic: "  ")
      assert_equal "The memory tool read action needs a topic.", @tool.call(action: "read")
    end

    def test_save_without_text_error
      assert_equal "The memory tool save action needs text to remember.", @tool.call(action: "save", topic: "x")
    end

    # --- save: file bytes + index upsert ---

    def test_save_writes_the_pinned_file_and_index_bytes
      result = @tool.call(action: "save", topic: "Deploy Ops!",
        text: "deploys via herdr pipeline, stage first\nsecond line")

      assert_equal %(Saved memory topic "Deploy Ops!" (deploy-ops.md).), result
      saved = File.read(File.join(@dir, "deploy-ops.md"))
      assert_match(/\A---\nmodified: \d{4}-\d{2}-\d{2}T[^\n]+\n---\n\ndeploys via herdr pipeline, stage first\nsecond line\n\z/, saved)
      assert_equal "- [Deploy Ops!](deploy-ops.md): deploys via herdr pipeline, stage first\n", File.read(index_path)
    end

    def test_index_upsert_dedups_and_keeps_order
      @tool.call(action: "save", topic: "a", text: "first a")
      @tool.call(action: "save", topic: "b", text: "the b line")
      @tool.call(action: "save", topic: "a", text: "second a\nthe summary is the first non-blank line")

      assert_equal <<~INDEX, File.read(index_path)
        - [b](b.md): the b line
        - [a](a.md): second a
      INDEX
    end

    def test_index_summary_truncates_at_120_chars_with_the_ellipsis
      long = "x" * 200
      @tool.call(action: "save", topic: "long", text: "#{long}\n")

      assert_equal "- [long](long.md): #{'x' * 119}…\n", File.read(index_path)
    end

    # --- read / list ---

    def test_read_returns_the_file_bytes_and_the_missing_string
      @tool.call(action: "save", topic: "deploy", text: "stage first")

      assert_equal File.read(File.join(@dir, "deploy.md")), @tool.call(action: "read", topic: "deploy")
      assert_equal %(No memory saved for topic "nope" (nope.md). Use the memory tool list action to see saved topics.),
        @tool.call(action: "read", topic: "nope")
    end

    def test_list_returns_the_index_and_the_empty_string
      @tool.call(action: "save", topic: "deploy", text: "stage first")
      index = File.read(index_path)

      assert_equal index, @tool.call(action: "list")
      FileUtils.rm_rf(@dir)
      assert_equal "No project memory yet. Save some with the memory tool save action.", @tool.call(action: "list")
    end

    # --- recall bounds (Store#recall_content) ---

    def test_recall_is_nil_without_an_index
      assert_nil Memory::Store.new(home: @home, cwd: @cwd).recall_content
    end

    def test_recall_joins_header_index_and_truncation_notice_at_the_line_bound
      write_index((1..205).map { |i| "- [t#{i}](t#{i}.md): line #{i}" }.join("\n") << "\n")
      content = Memory::Store.new(home: @home, cwd: @cwd).recall_content
      lines = content.lines

      assert_equal 202, lines.size, "the header + the first 200 lines + the notice"
      assert_equal "#{Memory::RECALL_HEADER}\n", lines[0]
      assert_equal "- [t1](t1.md): line 1\n", lines[1]
      assert_equal "- [t200](t200.md): line 200\n", lines[200]
      assert_equal "#{Memory::TRUNCATION_NOTICE}\n", lines[-1]
    end

    def test_recall_without_truncation_has_no_notice
      write_index("- [a](a.md): one\n- [b](b.md): two\n")
      content = Memory::Store.new(home: @home, cwd: @cwd).recall_content

      assert_equal "#{Memory::RECALL_HEADER}\n- [a](a.md): one\n- [b](b.md): two\n", content
    end

    # The byte bound's pinned observable (the frozen memory-module gate):
    # three ~10KB index lines recall exactly ONE of them, whole lines only,
    # with the truncation notice last. See Store#bound_index's deviation
    # comment (PHASE 0 item 1) — the TS running sum would keep two.
    def test_byte_bound_keeps_whole_lines_only
      big = (1..3).map { |i| "- [b#{i}](b#{i}.md): #{'x' * 10_000}" }
      write_index(big.join("\n") << "\n")
      content = Memory::Store.new(home: @home, cwd: @cwd).recall_content

      assert_equal 3, content.lines.size
      assert_equal "#{Memory::TRUNCATION_NOTICE}\n", content.lines[-1]
    end

    # --- the project key (git-root walk, basename fallback) ---

    def test_project_key_walks_to_the_git_root_and_falls_back_to_the_basename
      assert_equal File.basename(@cwd), Memory::Store.new(home: @home, cwd: @cwd).project_key

      worktree = File.join(@cwd, "nested", "deep")
      FileUtils.mkdir_p(worktree)
      FileUtils.touch(File.join(@cwd, ".git")) # the worktree .git FILE
      assert_equal File.basename(@cwd), Memory::Store.new(home: @home, cwd: worktree).project_key,
        "a .git FILE (worktree) anchors the walk too"
    end

    # --- the wire declaration (byte-exact TypeBox JSON) ---

    def test_declaration_bytes_match_pis_typebox_output
      tool = Tools::Memory.new(cwd: @cwd)
      expected = {
        "type" => "function",
        "function" => {
          "name" => "memory",
          "description" => "Persistent per-project memory. Save durable facts, preferences, and corrections worth " \
            "carrying to future sessions — never secrets, never one-off task state. Topic files are read on demand.",
          "parameters" => {
            "type" => "object",
            "required" => ["action"],
            "properties" => {
              "action" => {
                "anyOf" => [
                  {"type" => "string", "const" => "save"},
                  {"type" => "string", "const" => "read"},
                  {"type" => "string", "const" => "list"}
                ],
                "description" => "save: store text under topic; read: return a topic file; list: return the index"
              },
              "topic" => {"type" => "string", "description" => "Topic name, e.g. deploy (required for save/read)"},
              "text" => {"type" => "string", "description" => "Text to remember (save only)"}
            }
          }
        }
      }

      assert_equal expected, JSON.parse(JSON.generate(tool_for_memory_declaration(tool)))
    end

    # The chat_completions wire shape (tool_for) against the gem's readers.
    def tool_for_memory_declaration(tool)
      {
        "type" => "function",
        "function" => {
          "name" => tool.name,
          "description" => tool.description,
          "parameters" => JSON.parse(JSON.generate(tool.parameters_schema))
        }
      }
    end

    # --- the prompt guidelines ---

    def test_prompt_guidelines_are_the_two_memoryts_bullets
      assert_equal [
        "Use the memory tool to save durable facts, user preferences, and corrections worth carrying to future " \
          "sessions — never secrets and never one-off task state.",
        "Use the memory tool list/read actions to recall saved topics on demand instead of guessing what was " \
          "remembered."
      ], Memory::PROMPT_GUIDELINES
    end

    # --- the settings gate + env tiers ---

    def test_settings_gate_defaults_off_with_the_memory_env_suffix
      assert_equal false, Settings::DEFAULTS["memory"]
      assert_equal "MEMORY", Settings::RESOLUTION_ENV["memory"]
    end

    def test_env_tiers_speak_the_identity_namespace
      settings = {}
      env = {"PI_MEMORY" => "1"}
      assert_equal "1", Settings.resolve_setting("memory", settings, identity: "pi", env:)
      assert_equal false, Settings.resolve_setting("memory", settings, identity: "tart", env:),
        "tart reads TART_MEMORY, not PI_MEMORY (the DEFAULTS tier answers)"
      assert_equal false, Settings.resolve_setting("memory", settings, identity: "pi", env: {}),
        "the DEFAULTS tier is false"
    end

    def test_load_gains_no_unknown_key_diagnostic_for_memory
      result = Settings.load(cwd: @cwd, root: @home)
      assert_empty result.diagnostics
    end

    # --- register: the session_start handler + the tool ---

    def test_register_wires_the_recall_and_the_tool
      hooks = Hooks.new
      # I69 move: EXPLICIT pi identity — the staged PI_MEMORY_HOME tier is
      # the pi-parity opt-in's namespace (the default resolved tart).
      ENV["PI_MEMORY_HOME"] = @home
      Memory.register(hooks: hooks, identity: "pi")
      write_index("- [a](a.md): one\n")

      hooks.emit({"type" => "session_start", "reason" => "startup"},
        context: {cwd: @cwd, mode: "tui"})

      pending = hooks.pending_next_turn
      assert_equal 1, pending.size
      assert_equal({custom_type: "memory-recall", content: "#{Memory::RECALL_HEADER}\n- [a](a.md): one\n",
                    display: true}, pending.first)
      assert_includes hooks.registered_tools.map(&:name), "memory"
    ensure
      ENV.delete("PI_MEMORY_HOME")
    end

    def test_register_recall_noops_without_an_index
      hooks = Hooks.new
      Memory.register(hooks: hooks)

      hooks.emit({"type" => "session_start", "reason" => "startup"}, context: {cwd: @cwd, mode: "tui"})

      assert_empty hooks.pending_next_turn
    end
  end
end
