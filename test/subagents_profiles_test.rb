# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/mock_llm_server"
require "tmpdir"
require "fileutils"
require "json"

module Tart
  # The I49 profile-layer unit battery (Specification §8): discovery (both
  # tiers, recursive, dotfile/non-md ignored, project-wins precedence, the
  # builtin overlay), the profile contract's accept/reject table, the
  # diagnostics discipline (malformed → warning + skip, NEVER a raise),
  # resolve/resolve_table/unknown-agent, and hermeticity (staged root +
  # cwd; discovery is read-only). Hermetic: staged HOME-shaped roots only.
  class SubagentsProfilesTest < Test
    def setup
      @home = Dir.mktmpdir("i49-profiles-home-")
      @cwd = Dir.mktmpdir("i49-profiles-cwd-")
      @root = File.join(@home, ".tart")
    end

    def teardown
      FileUtils.rm_rf(@home)
      FileUtils.rm_rf(@cwd)
    end

    # --- discovery ---

    def test_discover_scans_both_tiers_recursively_and_ignores_noise
      write_profile("user", "alpha.md", name: "alpha", body: "Alpha body.")
      write_profile("user", "nested/dir/beta.md", name: "beta", body: "Beta body.")
      write_profile("user", ".hidden.md", name: "hidden", body: "Hidden body.")
      write_profile("user", "nested/.also-hidden.md", name: "also_hidden", body: "Hidden body.")
      write_profile("user", "notes.txt", raw: "not a profile\n")
      write_profile("project", "gamma.md", name: "gamma", body: "Gamma body.")

      result = Subagents::Profiles.discover(cwd: @cwd, root: @root, env: ENV)

      assert_empty result.diagnostics
      assert_equal %w[alpha beta gamma], result.profiles.map { |spec| spec[:name] }.sort
      assert result.profiles.all? { |spec| spec[:system_prompt].end_with?("body.") }
    end

    def test_project_tier_wins_same_name_and_sources_are_recorded
      write_profile("user", "scout.md", name: "scout", description: "user scout", body: "User body.")
      write_profile("project", "scout.md", description: "project scout", body: "Project body.")

      table = Subagents::Profiles.resolve_table(cwd: @cwd, root: @root, env: ENV)

      scout = table["scout"]
      assert_equal :project, scout[:source]
      assert_equal "project scout", scout[:description]
      assert_equal "Project body.", scout[:system_prompt]
    end

    def test_resolve_table_overlays_the_frozen_builtin_table
      table = Subagents::Profiles.resolve_table(cwd: @cwd, root: @root, env: ENV)

      assert_equal %w[oracle reviewer worker], table.keys.sort
      %w[oracle reviewer worker].each do |name|
        assert_equal :builtin, table[name][:source]
        assert_nil table[name][:model]
        # The frozen entries ride byte-identical (their I48 pins hold).
        assert_equal Subagents::BUILTIN_AGENTS[name][:system_prompt], table[name][:system_prompt]
        assert_equal Subagents::BUILTIN_AGENTS[name][:tools], table[name][:tools]
      end

      # A profile overlay keeps the builtins and adds the discovered name.
      write_profile("user", "scout.md", name: "scout", body: "Scout body.")
      merged = Subagents::Profiles.resolve_table(cwd: @cwd, root: @root, env: ENV)
      assert_equal %w[oracle reviewer scout worker], merged.keys.sort
      assert_equal :user, merged["scout"][:source]
    end

    # --- the contract's accept table ---

    def test_profile_defaults_and_the_spec_hash_shape
      write_profile("user", "plain.md", body: "Plain body.")

      spec = Subagents::Profiles.resolve("plain", cwd: @cwd, root: @root, env: ENV)

      assert_equal "plain", spec[:name], "the name defaults to the file stem"
      assert_equal "", spec[:description]
      assert_equal %w[read edit write bash find grep ls], spec[:tools], "omitted tools = the builtin seven"
      assert_nil spec[:thinking]
      assert_equal :fresh, spec[:context]
      assert_equal "Plain body.", spec[:system_prompt]
      assert_nil spec[:model]
      assert_equal :user, spec[:source]
      assert_equal %i[name description tools thinking context system_prompt model source], spec.keys
    end

    def test_frontmatter_name_wins_over_the_stem_and_must_be_a_safe_token
      write_profile("user", "stem-name.md", name: "frontmatter.name-1", body: "Body.")

      spec = Subagents::Profiles.resolve("frontmatter.name-1", cwd: @cwd, root: @root, env: ENV)
      assert_equal "frontmatter.name-1", spec[:name]

      write_profile("user", "bad.md", name: "bad name!", body: "Body.")
      diagnostic = Subagents::Profiles.discover(cwd: @cwd, root: @root, env: ENV).diagnostics
                          .find { |d| d.path.end_with?("bad.md") }
      refute_nil diagnostic
      assert_equal "warning", diagnostic.type
      assert_includes diagnostic.message, "must be a safe file name"
      assert_raises(ArgumentError) { Subagents::Profiles.resolve("bad", cwd: @cwd, root: @root, env: ENV) }
    end

    def test_tools_comma_form_array_form_order_and_unknown_tool_error
      write_profile("user", "comma.md", tools: "grep, read , bash", body: "Body.")
      spec = Subagents::Profiles.resolve("comma", cwd: @cwd, root: @root, env: ENV)
      assert_equal %w[grep read bash], spec[:tools], "the comma form splits and preserves order"

      write_profile("user", "array.md", raw: <<~MD, )
        ---
        tools:
          - grep
          - read
        ---

        Body.
      MD
      spec = Subagents::Profiles.resolve("array", cwd: @cwd, root: @root, env: ENV)
      assert_equal %w[grep read], spec[:tools], "the array form passes through in order"

      write_profile("user", "unknown.md", tools: "read, sabotage", body: "Body.")
      diagnostic = Subagents::Profiles.discover(cwd: @cwd, root: @root, env: ENV).diagnostics
                          .find { |d| d.path.end_with?("unknown.md") }
      assert_equal "unknown tool sabotage (valid tools: bash, contact_supervisor, edit, find, grep, ls, read, write)",
                   diagnostic.message
    end

    def test_model_validated_by_resolve_model_semantics_verbatim
      write_profile("user", "model.md", model: "zai/glm-5.3:high", body: "Body.")
      spec = Subagents::Profiles.resolve("model", cwd: @cwd, root: @root, env: ENV)
      assert_equal "zai/glm-5.3:high", spec[:model]

      write_profile("user", "badmodel.md", model: "zai/glm-5.3:ultra", body: "Body.")
      diagnostic = Subagents::Profiles.discover(cwd: @cwd, root: @root, env: ENV).diagnostics
                          .find { |d| d.path.end_with?("badmodel.md") }
      # The resolve_model error text VERBATIM (Spec §2) — the same raise
      # the spawn path would produce.
      expected = begin
        Subagents.resolve_model("zai/glm-5.3:ultra", catalog: nil, fallback: nil)
        nil
      rescue ArgumentError => e
        e.message
      end
      refute_nil expected
      assert_equal expected, diagnostic.message

      write_profile("user", "noshape.md", model: "no-slash", body: "Body.")
      diagnostic = Subagents::Profiles.discover(cwd: @cwd, root: @root, env: ENV).diagnostics
                          .find { |d| d.path.end_with?("noshape.md") }
      assert_includes diagnostic.message, "model must be provider/id"
    end

    def test_thinking_ladder_and_context_vocabulary
      write_profile("user", "thinking.md", thinking: "xhigh", context: "fork", body: "Body.")
      spec = Subagents::Profiles.resolve("thinking", cwd: @cwd, root: @root, env: ENV)
      assert_equal "xhigh", spec[:thinking]
      assert_equal :fork, spec[:context], "context maps to the builtin table's symbols"

      write_profile("user", "badthinking.md", thinking: "ultra", body: "Body.")
      write_profile("user", "badcontext.md", context: "inherited", body: "Body.")
      diagnostics = Subagents::Profiles.discover(cwd: @cwd, root: @root, env: ENV).diagnostics
      assert_includes diagnostics.find { |d| d.path.end_with?("badthinking.md") }.message,
                      "must be one of off, minimal, low, medium, high, xhigh, max"
      assert_includes diagnostics.find { |d| d.path.end_with?("badcontext.md") }.message,
                      'must be "fresh" or "fork"'
    end

    def test_unknown_keys_are_tolerated_and_ignored
      write_profile("user", "extrakeys.md", raw: <<~MD)
        ---
        name: extrakeys
        description: owner vocabulary
        systemPromptMode: replace
        inheritProjectContext: true
        allowNestedSubagents: true
        aliases: [a, b]
        acceptanceRole: reviewer
        machine: local
        ---

        Extra-keys body.
      MD

      spec = Subagents::Profiles.resolve("extrakeys", cwd: @cwd, root: @root, env: ENV)
      assert_equal "owner vocabulary", spec[:description]
      assert_equal "Extra-keys body.", spec[:system_prompt]
    end

    # --- the diagnostics discipline ---

    def test_malformed_files_diagnose_and_skip_never_raise
      FileUtils.mkdir_p(File.join(@root, "agents"))
      File.write(File.join(@root, "agents", "badyaml.md"),
                 "---\nname: [unclosed\n---\n\nBody.\n")
      write_profile("user", "emptybody.md", name: "emptybody")
      write_profile("user", "emptyfrontmatter.md", raw: "---\n---\n\n   \n")

      result = Subagents::Profiles.discover(cwd: @cwd, root: @root, env: ENV)

      paths = result.diagnostics.map { |d| File.basename(d.path) }
      assert_equal %w[badyaml.md emptybody.md emptyfrontmatter.md], paths.sort
      assert result.diagnostics.all? { |d| d.type == "warning" }
      assert_empty result.profiles.map { |spec| spec[:name] } & %w[badyaml emptybody emptyfrontmatter]
    end

    def test_discover_on_missing_dirs_is_empty_never_raises
      result = Subagents::Profiles.discover(cwd: @cwd, root: @root, env: ENV)
      assert_empty result.profiles
      assert_empty result.diagnostics
    end

    # --- resolve / unknown agent ---

    def test_resolve_returns_the_merged_table_spec
      write_profile("user", "scout.md", name: "scout", body: "Scout body.")
      spec = Subagents::Profiles.resolve("scout", cwd: @cwd, root: @root, env: ENV)
      assert_equal "Scout body.", spec[:system_prompt]
      builtin = Subagents::Profiles.resolve("oracle", cwd: @cwd, root: @root, env: ENV)
      assert_equal :builtin, builtin[:source]
      assert_equal Subagents::BUILTIN_AGENTS["oracle"], builtin.except(:source, :model)
    end

    def test_unknown_agent_error_shape_close_match_and_merged_listing
      write_profile("user", "researcher.md", name: "researcher", body: "Body.")

      error = assert_raises(ArgumentError) do
        Subagents::Profiles.resolve("researchr", cwd: @cwd, root: @root, env: ENV)
      end
      assert_includes error.message, "Did you mean 'researcher'?"
      assert_includes error.message,
                       "Available agents: oracle, researcher, reviewer, worker."

      error = assert_raises(ArgumentError) do
        Subagents::Profiles.resolve("zzzzzzzzzz", cwd: @cwd, root: @root, env: ENV)
      end
      assert_includes error.message, 'unknown agent "zzzzzzzzzz".'
      assert_includes error.message, "Available agents:"
      refute_includes error.message, "Did you mean", "no close match: the sentence is omitted"

      # A single adjacent transposition is a close match (pi's rule).
      error = assert_raises(ArgumentError) do
        Subagents::Profiles.resolve("wrker", cwd: @cwd, root: @root, env: ENV)
      end
      assert_includes error.message, "Did you mean 'worker'?"
    end

    # --- hermeticity ---

    def test_discovery_is_read_only_over_staged_roots
      before = Dir.children(@home).sort
      write_profile("user", "scout.md", name: "scout", body: "Body.")
      Subagents::Profiles.resolve_table(cwd: @cwd, root: @root, env: ENV)
      Subagents::Profiles.resolve("scout", cwd: @cwd, root: @root, env: ENV)
      assert_equal (before + [".tart"]).sort, Dir.children(@home).sort, "nothing written outside the staged tree"
      assert_empty Dir.glob(File.join(@root, "**", "*")).select { |path| File.file?(path) && !path.end_with?(".md") }
    end

    # --- the spawn-seam model routing (manager integration) ---

    def test_spawned_profile_runs_are_hermetic_under_the_staged_root
      # The Manager's default root is Agent::Session.default_root — the
      # spawn seam passes the MANAGER's root explicitly, so a staged root
      # keeps discovery off the real HOME.
      write_profile("user", "scout.md", name: "scout", model: "mock/scout-model", body: "Scout body.")
      @server = MockLLMServer.new.start
      @server.script([{type: :stream, content: "scout child done"}])
      manager = Subagents::Manager.new(cwd: @cwd, home: File.join(@home, "subagents"),
                                       env: {"PATH" => ENV["PATH"], "HOME" => @home,
                                             "PI_API_KEY" => "test-key", "PI_API_BASE" => @server.url},
                                       identity: "pi", hooks: Hooks.new, root: @root)
      run = manager.spawn_run(agent: "scout", task: "t", async: true, timeout_ms: 0, tool_timeout_ms: 0)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 20
      until manager.runs.first[:state] != :running || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep 0.1
      end
      assert_equal :completed, manager.runs.first[:state]
      assert run[:dir].start_with?(File.join(@home, "subagents"))
      _, env = manager.spawn_argv_and_env(run)
      assert_equal "scout-model", env["PI_MODEL"]
      assert_equal File.join(run[:dir], "control"), env["PI_SUPERVISOR_CHANNEL"]
    ensure
      manager&.shutdown
      @server&.stop
    end

    private

    def write_profile(tier, relative, name: nil, description: nil, tools: nil, model: nil,
                      thinking: nil, context: nil, body: nil, raw: nil)
      base = tier == "user" ? File.join(@root, "agents") : File.join(@cwd, ".tart", "agents")
      path = File.join(base, relative)
      FileUtils.mkdir_p(File.dirname(path))
      content = raw
      if content.nil?
        lines = ["---"]
        lines << "name: #{name}" if name
        lines << "description: #{description}" if description
        lines << "tools: #{tools}" if tools
        lines << "model: #{model}" if model
        lines << "thinking: #{thinking}" if thinking
        lines << "context: #{context}" if context
        lines << "---"
        content = "#{lines.join("\n")}\n\n#{body}\n"
      end
      File.write(path, content)
      path
    end
  end
end
