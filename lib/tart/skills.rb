# frozen_string_literal: true

require "yaml"
require_relative "agent/session"

module Tart
  module Skills
    # Skill loading and prompt formatting (port of pi's core/skills.ts +
    # utils/frontmatter.ts, reduced to the port's discovery surface).
    #
    # Discovery (pi loadSkillsFromDir :177-281): user skills from
    # <root>/skills (pi: agentDir/skills), then ~/.claude/skills (owner
    # ruling 2026-10-10: the owner's pi surfaces its skills from there —
    # a second user source, first-loaded-wins against <root>/skills),
    # project skills from <cwd>/.tart/skills (pi: cwd/.pi/skills) — user
    # first, project second.
    # Per directory: a SKILL.md makes it a skill root (loaded, no recursion
    # below it); otherwise subdirectories recurse (dotfiles and
    # node_modules skipped) and bare .md children of the top directory
    # load (name = the directory name).
    #
    # Frontmatter rules (pi validateName :62-86 / validateDescription
    # :88-95 / loadSkillFromFile :284-353): name falls back to the parent
    # directory name; description is required; oversize/invalid values are
    # warnings — the skill still loads unless the description is missing
    # or blank. Malformed YAML is a diagnostic, not a crash (:296-303).
    # disable-model-invocation hides a skill from the prompt listing while
    # keeping it user-invocable via /skill:<name>.
    #
    # Composition (pi loadSkills :425-456): first-loaded wins (user before
    # project); a name collision emits a collision diagnostic; files
    # already loaded through a symlink are skipped silently by realpath.
    #
    # Sanctioned cut (recorded deviation): pi filters skill discovery
    # through .gitignore/.ignore/.fdignore (the npm `ignore` package,
    # skills.ts:9,14-77); Ruby's stdlib has no equivalent, so the port does
    # no ignore-file filtering. pi's resource-loader path expansion and
    # --skill flags are out of scope.
    MAX_NAME_LENGTH = 64
    MAX_DESCRIPTION_LENGTH = 1024

    NAME_PATTERN = /\A[a-z0-9-]+\z/.freeze
    READERS = %w[read bash].freeze

    Skill = Struct.new(:name, :description, :file_path, :base_dir, :disable_model_invocation, keyword_init: true)

    # pi ResourceDiagnostic (diagnostics.ts): {type, message, path}; the
    # collision diagnostic carries the winner/loser paths (:441-450).
    Diagnostic = Struct.new(:type, :message, :path, :collision, keyword_init: true)

    Result = Struct.new(:skills, :diagnostics, keyword_init: true)

    module_function

    def load(cwd:, root: Agent::Session.default_root, claude_dir: File.join(Dir.home, ".claude", "skills"))
      merged = merge(
        merge(
          load_from_dir(File.join(root, "skills"), "user"),
          load_from_dir(claude_dir, "user")
        ),
        load_from_dir(File.join(cwd, ".tart", "skills"), "project")
      )
      Result.new(skills: merged[:skills], diagnostics: merged[:diagnostics])
    end

    # pi addSkills (:432-456): realpath dedup first (silent), then name
    # collision (diagnostic; first-loaded wins, second is dropped).
    def merge(primary, secondary)
      skills = []
      diagnostics = []
      by_name = {}
      real_paths = {}

      [primary, secondary].each do |part|
        diagnostics.concat(part[:diagnostics])
        part[:skills].each do |skill|
          real_path = File.realpath(skill.file_path)
          next if real_paths.key?(real_path)

          existing = by_name[skill.name]
          if existing
            diagnostics << Diagnostic.new(
              type: "collision", message: "name \"#{skill.name}\" collision", path: skill.file_path,
              collision: {resource_type: "skill", name: skill.name, winner_path: existing.file_path,
                          loser_path: skill.file_path}
            )
          else
            by_name[skill.name] = skill
            real_paths[real_path] = true
            skills << skill
          end
        end
      end

      {skills:, diagnostics:}
    end

    # pi loadSkillsFromDir (:177-281).
    def load_from_dir(dir, source, include_root_files: true)
      skills = []
      diagnostics = []
      return {skills:, diagnostics:} unless File.directory?(dir)

      if readable_file?(File.join(dir, "SKILL.md"))
        loaded = load_skill_file(File.join(dir, "SKILL.md"), source)
        skills.concat(loaded[:skills])
        diagnostics.concat(loaded[:diagnostics])
        return {skills:, diagnostics:}
      end

      Dir.children(dir).each do |name|
        next if name.start_with?(".") || name == "node_modules"

        full_path = File.join(dir, name)
        if readable_dir?(full_path)
          sub = load_from_dir(full_path, source, include_root_files: false)
          skills.concat(sub[:skills])
          diagnostics.concat(sub[:diagnostics])
        elsif include_root_files && name.end_with?(".md") && readable_file?(full_path)
          loaded = load_skill_file(full_path, source, declared: false)
          skills.concat(loaded[:skills])
          diagnostics.concat(loaded[:diagnostics])
        end
      end

      {skills:, diagnostics:}
    end

    # pi loadSkillFromFile (:284-353): warnings never block loading unless
    # the description is missing or blank; malformed YAML in a declared
    # SKILL.md is a warning, in a bare .md a silent skip.
    def load_skill_file(file_path, source, declared: true)
      diagnostics = []
      frontmatter, _body = parse_frontmatter(File.read(file_path))

      description = frontmatter["description"]
      has_description = description.is_a?(String) && !description.strip.empty?
      return {skills: [], diagnostics: []} if !declared && !has_description

      validate_description(description).each do |error|
        diagnostics << Diagnostic.new(type: "warning", message: error, path: file_path)
      end

      name = frontmatter["name"].is_a?(String) && !frontmatter["name"].empty? ? frontmatter["name"] : File.basename(File.dirname(file_path))
      validate_name(name).each do |error|
        diagnostics << Diagnostic.new(type: "warning", message: error, path: file_path)
      end

      return {skills: [], diagnostics:} unless has_description

      {skills: [Skill.new(
        name:, description:, file_path:, base_dir: File.dirname(file_path),
        disable_model_invocation: frontmatter["disable-model-invocation"] == true
      )], diagnostics:}
    rescue StandardError => e
      diagnostics << Diagnostic.new(type: "warning", message: e.message, path: file_path) if declared
      {skills: [], diagnostics:}
    end

    # pi validateName (:62-86).
    def validate_name(name)
      errors = []
      errors << "name exceeds #{MAX_NAME_LENGTH} characters (#{name.length})" if name.length > MAX_NAME_LENGTH
      unless name.match?(NAME_PATTERN)
        errors << "name contains invalid characters (must be lowercase a-z, 0-9, hyphens only)"
      end
      errors << "name must not start or end with a hyphen" if name.start_with?("-") || name.end_with?("-")
      errors << "name must not contain consecutive hyphens" if name.include?("--")
      errors
    end

    # pi validateDescription (:88-95).
    def validate_description(description)
      if !description.is_a?(String) || description.strip.empty?
        ["description is required"]
      elsif description.length > MAX_DESCRIPTION_LENGTH
        ["description exceeds #{MAX_DESCRIPTION_LENGTH} characters (#{description.length})"]
      else
        []
      end
    end

    # pi utils/frontmatter.ts parseFrontmatter: `---` open, `\n---` close,
    # BOM stripped, newlines normalized; no frontmatter → whole content is
    # the body. Returns [frontmatter-hash, body].
    def parse_frontmatter(content)
      normalized = content.dup.sub(/\A\xEF\xBB\xBF/, "").gsub("\r\n", "\n").gsub("\r", "\n")
      return [{}, normalized] unless normalized.start_with?("---")

      end_index = normalized.index("\n---", 3)
      return [{}, normalized] if end_index.nil?

      parsed = YAML.safe_load(normalized[4...end_index], aliases: true)
      [parsed.is_a?(Hash) ? parsed : {}, normalized[(end_index + 4)..].strip]
    end

    # pi stripFrontmatter (frontmatter.ts:40).
    def strip_frontmatter(content)
      parse_frontmatter(content)[1]
    end

    # pi formatSkillsForPrompt (:358-394) — byte-identical transcription.
    # Skills with disable-model-invocation are excluded from the listing;
    # +file_read_tool+ names the tool that loads skill files ("read" /
    # "bash") or "indirect" for a reader reachable only through another
    # tool (no tool named).
    def format_skills_for_prompt(skills, file_read_tool = "read")
      visible = skills.reject(&:disable_model_invocation)
      return "" if visible.empty?

      lines = [
        "\n\nThe following skills provide specialized instructions for specific tasks.",
        case file_read_tool
        when "read" then "Use the read tool to load a skill's file when the task matches its description."
        when "bash" then "Use bash to load a skill's file when the task matches its description."
        else "Load a skill's file when the task matches its description."
        end,
        "When a skill file references a relative path, resolve it against the skill directory " \
          "(parent of SKILL.md / dirname of the path) and use that absolute path in tool commands.",
        "",
        "<available_skills>"
      ]
      visible.each do |skill|
        lines << "  <skill>"
        lines << "    <name>#{escape_xml(skill.name)}</name>"
        lines << "    <description>#{escape_xml(skill.description)}</description>"
        lines << "    <location>#{escape_xml(skill.file_path)}</location>"
        lines << "  </skill>"
      end
      lines << "</available_skills>"
      lines.join("\n")
    end

    # pi escapeXml (skills.ts:396-402).
    def escape_xml(str)
      str.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;").gsub('"', "&quot;").gsub("'", "&apos;")
    end

    # pi system-prompt.ts:175-178: the reader gate for the <skills> section
    # — a declared read/bash tool names itself; a selected-but-hidden one
    # is "indirect"; none, no section (the port has no hidden-tool list,
    # so declared == selected and "indirect" is unreachable by construction).
    def skill_file_read_tool(selected_tools)
      READERS.find { |name| selected_tools.include?(name) } ||
        (READERS.any? { |name| selected_tools.include?(name) } ? "indirect" : nil)
    end

    def readable_file?(path)
      File.stat(path).file?
    rescue StandardError
      false
    end

    def readable_dir?(path)
      File.stat(path).directory?
    rescue StandardError
      false
    end
  end
end
