# frozen_string_literal: true

require_relative "../skills"
require_relative "context_files"

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
    # cwd. The `<skills>` section (pi system-prompt.ts:175-182) exists only
    # when skills are loaded AND a reader tool (read/bash) is available:
    # with no skills the composed prompt is byte-identical to the pre-skills
    # port (the goldens depend on it).
    module SystemPrompt
      DEFAULT_SELECTED_TOOLS = %w[read bash edit write].freeze

      # pi's installed package (the <docs> paths point at it — owner
      # ruling 2026-10-12: pi's paths stay). Resolved like pi's own
      # getPackageDir (config.ts): realpath the `pi` on PATH, walk up to
      # the package.json carrying this name.
      PI_PACKAGE = "@earendil-works/pi-coding-agent"

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
        # The %s takes the identity's env namespace (pi bash.ts:47 — pi
        # mode renders PI_* byte-identically, tart TART_*, foo FOO_*).
        "bash" => ["You can inspect %s* environment variables for current model and session details."]
      }.freeze

      # pi system-prompt.ts:144-145 — the identity name templates in
      # ("inside foo", owner ruling 1); pi mode is byte-identical.
      PREAMBLE = "You are an expert coding assistant operating inside %s, a coding agent harness. You help " \
        "users by reading files, executing commands, editing code, and writing new files."

      module_function

      # Ordered section hash (pi's buildSystemPromptSections); +skills+ is
      # additive — empty (the default) emits no `<skills>` section.
      # +docs_paths+ carries pi's getReadmePath/getDocsPath/getExamplesPath
      # triple ({pi_docs_paths}); nil (pi's install not found — pi itself
      # can never be in that state) emits no `<docs>` section.
      # +prompt_guidelines+ (I47 — pi system-prompt.ts:121, the custom
      # tools' promptGuidelines bullets) joins <rules> AFTER the per-tool
      # guideline bullets and BEFORE "Be concise…"; empty (the default) =
      # today's bytes.
      def sections(selected_tools: DEFAULT_SELECTED_TOOLS, append_system_prompt: "", cwd:,
                   context_files: [], docs_paths: nil, skills: [], identity: Identity::DEFAULT,
                   prompt_guidelines: [])
        declared = selected_tools

        result = {}
        result[:preamble] = format(PREAMBLE, identity)
        visible_tools = declared.select { |name| TOOL_SNIPPETS[name] }
        tools = visible_tools.empty? ? "(none)" : visible_tools.map { |name| "- #{name}: #{TOOL_SNIPPETS[name]}" }.join("\n")
        result[:tools] = "#{tools}\n\nIn addition to the tools above, you may have access to other custom tools " \
          "depending on the project."
        result[:rules] = build_rules(declared, identity, prompt_guidelines:)
        if docs_paths
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
        end
        result[:addendum] = append_system_prompt unless append_system_prompt.empty?
        unless context_files.empty?
          result[:project_context] = [
            "Project-specific instructions and guidelines:",
            *context_files.map { |file| "<project_instructions path=\"#{file[:path]}\">\n#{file[:content]}\n</project_instructions>" }
          ].join("\n\n")
        end
        # pi system-prompt.ts:178-182: reader-gated; an all-invisible
        # listing (every skill disable-model-invocation) emits nothing.
        reader = Skills.skill_file_read_tool(declared)
        if reader && !skills.empty?
          skills_prompt = Skills.format_skills_for_prompt(skills, reader).strip
          result[:skills] = skills_prompt unless skills_prompt.empty?
        end
        result[:cwd] = cwd.tr("\\", "/")

        result.each_with_object({}) do |(name, content), out|
          out[name] = name == :preamble ? content : "<#{name}>\n#{content}\n</#{name}>"
        end
      end

      # The rule bullets (pi's buildRules): trimmed, deduped, order kept.
      # Tool guideline bullets format their %s holes with the identity's
      # env namespace (pi mode → PI_*). +prompt_guidelines+ (I47 — the
      # memory module's two bullets) appends after the per-tool bullets
      # and before "Be concise…" (pi system-prompt.ts:121); the same
      # trim/dedup discipline rides the +add+ lambda.
      def build_rules(selected_tools, identity = Identity::DEFAULT, prompt_guidelines: [])
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
          (TOOL_GUIDELINES[name] || []).each { |rule| add.call(format(rule, Identity.env_prefix(identity))) }
        end
        prompt_guidelines.each { |rule| add.call(rule) }
        add.call("Be concise in your responses")
        add.call("Show file paths clearly when working with files")
        rules.map { |rule| "- #{rule}" }.join("\n")
      end

      # The complete prompt text (pi's buildSystemPrompt →
      # getSystemMessageText): the already-tagged sections in order, joined
      # by a blank line, empty parts dropped. Sections wraps each
      # non-preamble section in its tag exactly once.
      def build(selected_tools: DEFAULT_SELECTED_TOOLS, append_system_prompt: "", cwd:, context_files: [],
                docs_paths: nil, skills: [], identity: Identity::DEFAULT, prompt_guidelines: [])
        ordered = sections(selected_tools:, append_system_prompt:, cwd:, context_files:, docs_paths:,
                           skills:, identity:, prompt_guidelines:)
        ordered.values.reject { |content| content.nil? || content.empty? }.join("\n\n")
      end

      # pi's <docs> triple (config.ts getReadmePath/getDocsPath/
      # getExamplesPath :443-457): resolve(join(packageDir, ...)). nil when
      # the package can't be located ({pi_package_dir}).
      def pi_docs_paths(pi_bin: nil)
        dir = pi_package_dir(pi_bin:)
        dir && [File.join(dir, "README.md"), File.join(dir, "docs"), File.join(dir, "examples")]
      end

      # pi getPackageDir (config.ts:107-114): realpath the running entry —
      # the `pi` on PATH, a symlink into the package — and walk up to the
      # directory whose package.json carries pi's name. The realpath also
      # settles mise-style alias dirs (…/node/latest/bin/pi →
      # …/node/24.18.0/…), matching the paths pi itself renders. nil when
      # `pi` is absent or the walk bottoms out.
      def pi_package_dir(pi_bin: nil)
        pi_bin ||= ENV["PATH"].to_s.split(File::PATH_SEPARATOR).lazy
                              .map { |dir| File.join(dir, "pi") }
                              .find { |candidate| File.file?(candidate) && File.executable?(candidate) }
        return nil unless pi_bin

        real = File.realpath(pi_bin)
        dir = File.dirname(real)
        loop do
          package_json = File.join(dir, "package.json")
          return dir if File.file?(package_json) && parse_package_name(package_json) == PI_PACKAGE

          parent = File.dirname(dir)
          return nil if parent == dir

          dir = parent
        end
      rescue Errno::ENOENT
        nil
      end

      def parse_package_name(path)
        JSON.parse(File.read(path))["name"]
      rescue JSON::ParserError, StandardError
        nil
      end
    end
  end
end
