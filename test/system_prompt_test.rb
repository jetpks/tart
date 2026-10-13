# frozen_string_literal: true

require_relative "test_helper"

module Tart
  # The ported system prompt (pi's system-prompt.ts): sections wrapped once
  # in their tags, preamble untagged, dynamic segments interpolated. The
  # pi-mode byte-parity golden (AC2) is DERIVED FROM PI'S CAPTURED REQUEST
  # (repos/tart/tmp/parity-gate-s8/run-1/pi-requests.jsonl, request 1's
  # system message; the <cwd> section normalized to CWD_PLACEHOLDER) —
  # never from the port's own output (the edit-goldens doctrine). Also
  # here: the identity templating (I32) and the project-context
  # discovery pair ({ContextFiles.load} → the <project_context> section,
  # AC3 — pi resource-loader.ts:182-273).
  class SystemPromptTest < Test
    # The captured <docs> triple — pi's realpath'd install on the parity
    # target machine ({SystemPrompt.pi_docs_paths} resolves to exactly
    # these; pinned separately below).
    DOCS = ["/Users/eric/.local/share/mise/installs/node/24.18.0/lib/node_modules/@earendil-works/pi-coding-agent/README.md",
            "/Users/eric/.local/share/mise/installs/node/24.18.0/lib/node_modules/@earendil-works/pi-coding-agent/docs",
            "/Users/eric/.local/share/mise/installs/node/24.18.0/lib/node_modules/@earendil-works/pi-coding-agent/examples"].freeze

    # pi's captured system message (4-tool loadout, bare sandbox: no
    # <project_context>, no <skills>), cwd section normalized.
    PI_CAPTURE = <<~PROMPT
      You are an expert coding assistant operating inside pi, a coding agent harness. You help users by reading files, executing commands, editing code, and writing new files.

      <tools>
      - read: Read file contents
      - bash: Execute bash commands (ls, grep, find, etc.)
      - edit: Make precise file edits with exact text replacement, including multiple disjoint edits in one call
      - write: Create or overwrite files

      In addition to the tools above, you may have access to other custom tools depending on the project.
      </tools>

      <rules>
      - Use bash for file operations like ls, rg, find
      - Use read to examine files instead of cat or sed.
      - You can inspect PI_* environment variables for current model and session details.
      - Use edit for precise changes (edits[].oldText must match exactly)
      - When changing multiple separate locations in one file, use one edit call with multiple entries in edits[] instead of multiple edit calls
      - Each edits[].oldText is matched against the original file, not after earlier edits are applied. Do not emit overlapping or nested edits. Merge nearby changes into one edit.
      - Keep edits[].oldText as small as possible while still being unique in the file. Do not pad with large unchanged regions.
      - Use write only for new files or complete rewrites.
      - Be concise in your responses
      - Show file paths clearly when working with files
      </rules>

      <docs>
      Pi documentation (read only when the user asks about pi itself, its SDK, extensions, themes, skills, or TUI):
      - Main documentation: /Users/eric/.local/share/mise/installs/node/24.18.0/lib/node_modules/@earendil-works/pi-coding-agent/README.md
      - Additional docs: /Users/eric/.local/share/mise/installs/node/24.18.0/lib/node_modules/@earendil-works/pi-coding-agent/docs
      - Examples: /Users/eric/.local/share/mise/installs/node/24.18.0/lib/node_modules/@earendil-works/pi-coding-agent/examples (extensions, custom tools, SDK)
      - When reading pi docs or examples, resolve docs/... under Additional docs and examples/... under Examples, not the current working directory
      - When asked about: extensions (docs/extensions.md, examples/extensions/), themes (docs/themes.md), skills (docs/skills.md), prompt templates (docs/prompt-templates.md), TUI components (docs/tui.md), keybindings (docs/keybindings.md), SDK integrations (docs/sdk.md), custom providers (docs/custom-provider.md), adding models (docs/models.md), pi packages (docs/packages.md), environment variables (docs/environment-variables.md), MCP servers (docs/mcp.md), codemode scripts and non-LLM models such as classifiers and image models (docs/codemode.md)
      - When working on pi topics, read the docs and examples, and follow .md cross-references before implementing
      - Always read pi .md files completely and follow links to related docs (e.g., tui.md for TUI API details)
      </docs>

      <cwd>
      CWD_PLACEHOLDER
      </cwd>
    PROMPT

    # pi's captured <tools> section at the default-4 loadout (see the
    # derivation note on the test below).
    GOLDEN_TOOLS = <<~TOOLS.chomp
      - read: Read file contents
      - bash: Execute bash commands (ls, grep, find, etc.)
      - edit: Make precise file edits with exact text replacement, including multiple disjoint edits in one call
      - write: Create or overwrite files

      In addition to the tools above, you may have access to other custom tools depending on the project.
    TOOLS

    # pi's captured <rules> section at the default-4 loadout — the
    # loadout-conditional bullet first, then the per-tool guidelines in
    # DEFAULT_TOOL_NAMES order (see the derivation note on the test below).
    GOLDEN_RULES = <<~RULES.chomp
      - Use bash for file operations like ls, rg, find
      - Use read to examine files instead of cat or sed.
      - You can inspect PI_* environment variables for current model and session details.
      - Use edit for precise changes (edits[].oldText must match exactly)
      - When changing multiple separate locations in one file, use one edit call with multiple entries in edits[] instead of multiple edit calls
      - Each edits[].oldText is matched against the original file, not after earlier edits are applied. Do not emit overlapping or nested edits. Merge nearby changes into one edit.
      - Keep edits[].oldText as small as possible while still being unique in the file. Do not pad with large unchanged regions.
      - Use write only for new files or complete rewrites.
      - Be concise in your responses
      - Show file paths clearly when working with files
    RULES

    # AC2: the composed prompt IS pi's captured system message, byte for
    # byte, at the same tool loadout, cwd normalized.
    def test_pi_mode_composition_is_byte_identical_to_pis_captured_request
      built = Agent::SystemPrompt.build(selected_tools: %w[read bash edit write],
        cwd: "CWD_PLACEHOLDER", docs_paths: DOCS)
      assert_equal PI_CAPTURE.chomp, built
    end

    # I41 (AC2): the DEFAULT loadout's <tools>/<rules> sections are pi's
    # captured bytes VERBATIM — DERIVED FROM PI'S CAPTURED REQUEST (the
    # I32 doctrine, never the port's own output): the oracle app's own
    # bytes (tmp/i41-base-s8_zero_usage_compaction/run-1/
    # pi-requests.jsonl, request 1 — Grounds 1's fresh capture),
    # cross-checked against pi's sources (edit.ts:44 snippet, bash.ts:46).
    # The loadout-bearing bytes this pin protects: the loadout-conditional
    # bullet FIRST and the read → bash → edit → write guideline order
    # (pi's DEFAULT_TOOL_NAMES order, settings-manager.ts:82 — the order
    # the wire tools array follows too).
    def test_default_loadout_sections_are_pis_captured_bytes
      built = Agent::SystemPrompt.build(selected_tools: Settings.selected_tools({}),
        cwd: "/p", docs_paths: DOCS)
      assert_equal GOLDEN_TOOLS, built[/<tools>\n(.*?)\n<\/tools>/m, 1]
      assert_equal GOLDEN_RULES, built[/<rules>\n(.*?)\n<\/rules>/m, 1]
    end

    # The <docs> resolver reproduces pi's getPackageDir walk (config.ts
    # :443-457): realpath the pi on PATH, up to the package.json — on the
    # parity target this lands byte-identical on the capture's paths.
    def test_pi_docs_paths_resolve_pis_install
      docs = Agent::SystemPrompt.pi_docs_paths
      assert_equal "/Users/eric/.local/share/mise/installs/node/24.18.0/lib/node_modules/@earendil-works/pi-coding-agent/README.md", docs[0],
        "pi's realpath'd install (the capture's paths)"
      assert File.file?(docs[0]) && File.directory?(docs[1]) && File.directory?(docs[2])
      # pi's package layout: the walk bottoms at the package.json that
      # carries the package name.
      assert_equal "@earendil-works/pi-coding-agent", JSON.parse(File.read(File.join(File.dirname(docs[0]), "package.json")))["name"]
    end

    # --- the identity templating (I32 AC1/AC2) ---

    def test_preamble_and_bash_env_rule_follow_the_identity
      pi = Agent::SystemPrompt.build(cwd: "/p", docs_paths: DOCS)
      assert_includes pi, "operating inside pi, a coding agent harness"
      assert_includes pi, "You can inspect PI_* environment variables",
        "pi mode is byte-identical to pi's bash.ts:47 bullet"

      foo = Agent::SystemPrompt.build(cwd: "/p", docs_paths: DOCS, identity: "foo")
      assert_includes foo, "operating inside foo, a coding agent harness"
      assert_includes foo, "You can inspect FOO_* environment variables"

      tart = Agent::SystemPrompt.build(cwd: "/p", docs_paths: DOCS, identity: "tart")
      assert_includes tart, "operating inside tart, a coding agent harness"
      assert_includes tart, "You can inspect TART_* environment variables"
    end

    def test_dynamic_segments
      built = Agent::SystemPrompt.build(
        cwd: "/tmp/p", append_system_prompt: "Be terse.",
        context_files: [{path: "AGENTS.md", content: "Use tabs."}], docs_paths: DOCS
      )
      assert_includes built, "<addendum>\nBe terse.\n</addendum>"
      assert_includes built, "<project_instructions path=\"AGENTS.md\">\nUse tabs.\n</project_instructions>"
      assert built.end_with?("<cwd>\n/tmp/p\n</cwd>")
      # Section tags appear exactly once (wrapped by sections, not build).
      assert_equal 1, built.scan("<rules>").length
      assert_equal 0, built.scan("<rules><rules>").length
    end

    def test_rules_are_deduped_and_conditional_on_loadout
      # bash without grep/find/ls adds the file-operations rule; with grep it
      # does not. pi's addRule dedups repeats.
      with_bash = Agent::SystemPrompt.build_rules(%w[bash])
      assert_includes with_bash, "- Use bash for file operations like ls, rg, find"
      with_grep = Agent::SystemPrompt.build_rules(%w[bash grep])
      refute_includes with_grep, "Use bash for file operations"
      duplicated = Agent::SystemPrompt.build_rules(%w[read read])
      assert_equal 1, duplicated.scan("Use read to examine files").length
    end

    # --- the <skills> section (pi system-prompt.ts:175-182; additive —
    # with no skills the composed prompt is byte-identical to today's) ---

    def skill(name = "sc", disable: false)
      Skills::Skill.new(name:, description: "d", file_path: "/p/SKILL.md", base_dir: "/p",
                        disable_model_invocation: disable)
    end

    def test_skills_section_sits_between_project_context_and_cwd
      built = Agent::SystemPrompt.build(
        cwd: "/tmp/p", docs_paths: DOCS,
        context_files: [{path: "AGENTS.md", content: "x"}], skills: [skill]
      )
      skills_at = built.index("<skills>")
      context_at = built.index("<project_instructions")
      cwd_at = built.index("<cwd>")

      assert context_at < skills_at && skills_at < cwd_at, "pi's section order"
      assert_includes built, "Use the read tool to load a skill's file"
      assert_includes built, "    <name>sc</name>"
      assert_includes built, "    <location>/p/SKILL.md</location>"
    end

    def test_skills_section_names_bash_when_read_is_absent
      built = Agent::SystemPrompt.build(cwd: "/tmp/p", docs_paths: DOCS,
                                        selected_tools: %w[bash write], skills: [skill])
      assert_includes built, "Use bash to load a skill's file"
    end

    def test_skills_section_requires_a_reader_tool
      built = Agent::SystemPrompt.build(cwd: "/tmp/p", docs_paths: DOCS,
                                        selected_tools: %w[write], skills: [skill])
      refute_includes built, "<skills>", "pi: no read/bash reader reachable, no section"
    end

    def test_model_invocation_disabled_skills_emit_nothing_when_alone
      built = Agent::SystemPrompt.build(cwd: "/tmp/p", docs_paths: DOCS, skills: [skill(disable: true)])
      refute_includes built, "<skills>",
        "pi: formatSkillsForPrompt returns \"\" for an all-invisible listing"
    end

    # --- the project-context discovery pair (AC3, pi resource-loader.ts
    # :182-273): {ContextFiles.load} feeds <project_context> ---(

    def test_candidates_match_in_pis_order_per_directory
      dir = Dir.mktmpdir("tart-ctx-")
      File.write(File.join(dir, "AGENTS.md"), "agents")
      File.write(File.join(dir, "CLAUDE.md"), "claude")
      assert_equal "agents", Agent::ContextFiles.from_dir(dir)[:content], "AGENTS.md over CLAUDE.md"

      File.write(File.join(dir, "AGENTS.override.md"), "override")
      assert_equal "override", Agent::ContextFiles.from_dir(dir)[:content], "AGENTS.override.md first"

      FileUtils.rm(File.join(dir, "AGENTS.override.md"))
      FileUtils.rm(File.join(dir, "AGENTS.md"))
      assert_equal "claude", Agent::ContextFiles.from_dir(dir)[:content]
    ensure
      FileUtils.rm_rf(dir)
    end

    def test_load_walks_ancestors_root_most_first_with_the_global_agent_file_first
      home = Dir.mktmpdir("tart-ctx-home-")
      root = Dir.mktmpdir("tart-ctx-root-")
      nested = File.join(root, "a", "b")
      FileUtils.mkpath(nested)
      File.write(File.join(nested, "AGENTS.md"), "leaf")
      File.write(File.join(root, "AGENTS.md"), "root")
      File.write(File.join(home, "AGENTS.md"), "global")

      files = Agent::ContextFiles.load(cwd: nested, agent_dir: home)
      assert_equal ["global", "root", "leaf"], files.map { |f| f[:content] }
      assert_equal File.join(home, "AGENTS.md"), files[0][:path]
    ensure
      FileUtils.rm_rf(home)
      FileUtils.rm_rf(root)
    end

    def test_a_deduped_directory_loads_once
      root = Dir.mktmpdir("tart-ctx-root-")
      nested = File.join(root, "a")
      FileUtils.mkpath(nested)
      File.write(File.join(root, "AGENTS.md"), "once")

      files = Agent::ContextFiles.load(cwd: nested, agent_dir: root)
      # The root file loads once: the agent-dir copy and the walk hit are
      # the same path (pi seenPaths).
      assert_equal ["once"], files.map { |f| f[:content] }
    ensure
      FileUtils.rm_rf(root)
    end

    # The linked-worktree shadow (pi findShadowedContextFile :211-230): a
    # worktree under a checked-out main repo does NOT load the main
    # repo's copy — both occupy one logical repository scope.
    def test_worktree_shadows_the_main_repo_context_file
      proj = Dir.mktmpdir("tart-ctx-proj-")
      git = File.join(proj, ".git")
      worktree = File.join(proj, "wt")
      FileUtils.mkpath([File.join(git, "worktrees", "wt"), worktree])
      File.write(File.join(git, "HEAD"), "ref: refs/heads/main\n")
      File.write(File.join(git, "worktrees", "wt", "HEAD"), "ref: refs/heads/feat\n")
      File.write(File.join(git, "worktrees", "wt", "commondir"), "../..\n")
      File.write(File.join(worktree, ".git"), "gitdir: #{File.join(git, 'worktrees', 'wt')}\n")
      File.write(File.join(proj, "AGENTS.md"), "main")
      File.write(File.join(worktree, "AGENTS.md"), "worktree")

      files = Agent::ContextFiles.load(cwd: worktree, agent_dir: Dir.mktmpdir("tart-ctx-agent-"))
      assert_equal ["worktree"], files.map { |f| f[:content] },
        "the worktree's own copy loads; the main repo's copy is shadowed"

      # Control: the main repo itself keeps its file (ordinary repo).
      assert_equal ["main"],
        Agent::ContextFiles.load(cwd: proj, agent_dir: Dir.mktmpdir("tart-ctx-agent2-")).map { |f| f[:content] }
    ensure
      FileUtils.rm_rf(proj)
    end

    def test_context_files_inject_as_project_context_and_none_emits_no_section
      built = Agent::SystemPrompt.build(cwd: "/p", docs_paths: DOCS,
        context_files: [{path: "/r/AGENTS.md", content: "Use tabs."}])
      assert_includes built, "Project-specific instructions and guidelines:"
      assert_includes built, "<project_instructions path=\"/r/AGENTS.md\">\nUse tabs.\n</project_instructions>"

      bare = Agent::SystemPrompt.build(cwd: "/p", docs_paths: DOCS)
      refute_includes bare, "project_context"
      assert_equal [], Agent::ContextFiles.load(cwd: Dir.mktmpdir("tart-ctx-bare-"), agent_dir: Dir.mktmpdir("tart-ctx-bare2-"))
    end
  end
end
