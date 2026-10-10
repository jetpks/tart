# frozen_string_literal: true

require_relative "test_helper"

module Tart
  # The ported system prompt (pi's system-prompt.ts): sections wrapped once
  # in their tags, preamble untagged, dynamic segments interpolated.
  class SystemPromptTest < Test
    DOCS = ["/pkg/README.md", "/pkg/docs", "/pkg/examples"].freeze

    def test_build_matches_pis_composed_prompt
      expected = <<~PROMPT
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
        - Main documentation: /pkg/README.md
        - Additional docs: /pkg/docs
        - Examples: /pkg/examples (extensions, custom tools, SDK)
        - When reading pi docs or examples, resolve docs/... under Additional docs and examples/... under Examples, not the current working directory
        - When asked about: extensions (docs/extensions.md, examples/extensions/), themes (docs/themes.md), skills (docs/skills.md), prompt templates (docs/prompt-templates.md), TUI components (docs/tui.md), keybindings (docs/keybindings.md), SDK integrations (docs/sdk.md), custom providers (docs/custom-provider.md), adding models (docs/models.md), pi packages (docs/packages.md), environment variables (docs/environment-variables.md), MCP servers (docs/mcp.md), codemode scripts and non-LLM models such as classifiers and image models (docs/codemode.md)
        - When working on pi topics, read the docs and examples, and follow .md cross-references before implementing
        - Always read pi .md files completely and follow links to related docs (e.g., tui.md for TUI API details)
        </docs>

        <cwd>
        /tmp/project
        </cwd>
      PROMPT

      assert_equal expected.chomp, Agent::SystemPrompt.build(cwd: "/tmp/project", docs_paths: DOCS)
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
  end
end
