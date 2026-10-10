# frozen_string_literal: true

module Tart
  module Agent
    # System prompt construction (port of pi's system-prompt.ts).
    #
    # The composed prompt is pi's verbatim: an untagged `preamble` section,
    # then `<tools>`, `<rules>`, `<docs>`, optional `<addendum>`,
    # `<project_context>`, and a `<cwd>` section wrapped in tags of their
    # name. Dynamic segments (recorded for the report): the selected-tools
    # snippet list, the rule bullets (conditional on the bash/grep/find/ls
    # loadout plus per-tool guideline bullets), the pi docs paths, and the
    # cwd. Skills are out of scope this iteration (recorded deviation: pi's
    # `<skills>` section is never emitted).
    module SystemPrompt
      DEFAULT_SELECTED_TOOLS = %w[read bash edit write].freeze

      # Tool snippets and guideline bullets, from pi's tools
      # (*ToolSystemPromptContribution).
      TOOL_SNIPPETS = {
        "read" => "Read file contents",
        "write" => "Create or overwrite files",
        "edit" => "Make precise file edits with exact text replacement, including multiple disjoint edits in one call",
        "bash" => "Execute bash commands (ls, grep, find, etc.)",
        "find" => "Find files by glob pattern (respects .gitignore)",
        "grep" => "Search file contents for patterns (respects .gitignore)",
        "ls" => "List directory contents"
      }.freeze

      TOOL_GUIDELINES = {
        "read" => ["Use read to examine files instead of cat or sed."],
        "write" => ["Use write only for new files or complete rewrites."],
        "edit" => [
          "Use edit for precise changes (edits[].oldText must match exactly)",
          "When changing multiple separate locations in one file, use one edit call with multiple entries in " \
            "edits[] instead of multiple edit calls",
          "Each edits[].oldText is matched against the original file, not after earlier edits are applied. " \
            "Do not emit overlapping or nested edits. Merge nearby changes into one edit.",
          "Keep edits[].oldText as small as possible while still being unique in the file. Do not pad with " \
            "large unchanged regions."
        ],
        "bash" => ["You can inspect PI_* environment variables for current model and session details."]
      }.freeze

      PREAMBLE = "You are an expert coding assistant operating inside pi, a coding agent harness. You help " \
        "users by reading files, executing commands, editing code, and writing new files."

      module_function

      # Ordered section hash (pi's buildSystemPromptSections, minus skills).
      # +docs_paths+ replaces pi's getReadmePath/getDocsPath/getExamplesPath
      # dynamic segment.
      def sections(selected_tools: DEFAULT_SELECTED_TOOLS, append_system_prompt: "", cwd:,
                   context_files: [], docs_paths: nil)
        declared = selected_tools

        result = {}
        result[:preamble] = PREAMBLE
        visible_tools = declared.select { |name| TOOL_SNIPPETS[name] }
        tools = visible_tools.empty? ? "(none)" : visible_tools.map { |name| "- #{name}: #{TOOL_SNIPPETS[name]}" }.join("\n")
        result[:tools] = "#{tools}\n\nIn addition to the tools above, you may have access to other custom tools " \
          "depending on the project."
        result[:rules] = build_rules(declared)
        readme, docs, examples = docs_paths
        result[:docs] = "Pi documentation (read only when the user asks about pi itself, its SDK, extensions, " \
          "themes, skills, or TUI):\n" \
          "- Main documentation: #{readme}\n" \
          "- Additional docs: #{docs}\n" \
          "- Examples: #{examples} (extensions, custom tools, SDK)\n" \
          "- When reading pi docs or examples, resolve docs/... under Additional docs and examples/... under " \
          "Examples, not the current working directory\n" \
          "- When asked about: extensions (docs/extensions.md, examples/extensions/), themes (docs/themes.md), " \
          "skills (docs/skills.md), prompt templates (docs/prompt-templates.md), TUI components (docs/tui.md), " \
          "keybindings (docs/keybindings.md), SDK integrations (docs/sdk.md), custom providers " \
          "(docs/custom-provider.md), adding models (docs/models.md), pi packages (docs/packages.md), " \
          "environment variables (docs/environment-variables.md), MCP servers (docs/mcp.md), codemode scripts " \
          "and non-LLM models such as classifiers and image models (docs/codemode.md)\n" \
          "- When working on pi topics, read the docs and examples, and follow .md cross-references before " \
          "implementing\n" \
          "- Always read pi .md files completely and follow links to related docs (e.g., tui.md for TUI API details)"
        result[:addendum] = append_system_prompt unless append_system_prompt.empty?
        unless context_files.empty?
          result[:project_context] = [
            "Project-specific instructions and guidelines:",
            *context_files.map { |file| "<project_instructions path=\"#{file[:path]}\">\n#{file[:content]}\n</project_instructions>" }
          ].join("\n\n")
        end
        result[:cwd] = cwd.tr("\\", "/")

        result.each_with_object({}) do |(name, content), out|
          out[name] = name == :preamble ? content : "<#{name}>\n#{content}\n</#{name}>"
        end
      end

      # The rule bullets (pi's buildRules): trimmed, deduped, order kept.
      def build_rules(selected_tools)
        rules = []
        seen = []
        add = lambda do |rule|
          normalized = rule.strip
          return if normalized.empty? || seen.include?(normalized)

          seen << normalized
          rules << normalized
        end

        has_bash = selected_tools.include?("bash")
        has_grep = selected_tools.include?("grep")
        has_find = selected_tools.include?("find")
        has_ls = selected_tools.include?("ls")

        add.call("Use bash for file operations like ls, rg, find") if has_bash && !has_grep && !has_find && !has_ls

        selected_tools.each do |name|
          (TOOL_GUIDELINES[name] || []).each { |rule| add.call(rule) }
        end
        add.call("Be concise in your responses")
        add.call("Show file paths clearly when working with files")
        rules.map { |rule| "- #{rule}" }.join("\n")
      end

      # The complete prompt text (pi's buildSystemPrompt →
      # getSystemMessageText): the already-tagged sections in order, joined
      # by a blank line, empty parts dropped. Sections wraps each
      # non-preamble section in its tag exactly once.
      def build(selected_tools: DEFAULT_SELECTED_TOOLS, append_system_prompt: "", cwd:, context_files: [],
                docs_paths: nil)
        ordered = sections(selected_tools:, append_system_prompt:, cwd:, context_files:, docs_paths:)
        ordered.values.reject { |content| content.nil? || content.empty? }.join("\n\n")
      end
    end
  end
end
