# frozen_string_literal: true

require_relative "skills"

module Tart
  module Prompts
    # Prompt templates (port of pi's core/prompt-templates.ts): markdown
    # files the user invokes as /name commands.
    #
    # Discovery (pi loadPromptTemplates :206-260): user templates from
    # <root>/prompts (pi: agentDir/prompts), project templates from
    # <cwd>/.tart/prompts (pi: cwd/.pi/prompts) — user first, project
    # second, first-loaded wins on a name collision (the Skills merge
    # rule, minus the collision diagnostic — pi's resource loader dedups
    # templates by name silently at the path level). Per directory: the
    # top-level .md files only (non-recursive, :158-196), name = the
    # filename stem (:131).
    #
    # Frontmatter (pi loadTemplateFromFile :116-154): description falls
    # back to the first non-empty body line (truncated to 60 chars);
    # argument-hint is optional; the body is the template content.
    # Malformed YAML is a diagnostic, not a crash (:122-127).
    #
    # Expansion (pi expandPromptTemplate :512-527): "/name args" resolves
    # the template by name and substitutes the args into its content;
    # unknown names pass through as plain text. Args parse bash-style
    # (parseCommandArgs :17-54 — quoted strings stay whole); the
    # substitution placeholders are $1..$N, $@ / $ARGUMENTS (all args),
    # ${N:-default}, ${@:-default} / ${ARGUMENTS:-default}, and the
    # bash-style slices ${@:N} / ${@:N:L} (substituteArgs :62-92).
    Template = Struct.new(:name, :description, :argument_hint, :content, :file_path, keyword_init: true)

    Diagnostic = Struct.new(:type, :message, :path, keyword_init: true)

    Result = Struct.new(:templates, :diagnostics, keyword_init: true)

    # pi substituteArgs' placeholder regex (:66-69), verbatim.
    ARGS_PATTERN =
      /\$\{(\d+|ARGUMENTS|@):-([^}]*)\}|\$\{@:(\d+)(?::(\d+))?\}|\$(ARGUMENTS|@|\d+)/.freeze

    module_function

    def load(cwd:, root: Agent::Session.default_root)
      templates = []
      diagnostics = []
      by_name = {}
      [File.join(root, "prompts"), File.join(cwd, ".tart", "prompts")].each do |dir|
        load_from_dir(dir).each do |result|
          diagnostics.concat(result[:diagnostics])
          template = result[:template]
          next if template.nil? || by_name.key?(template.name)

          by_name[template.name] = true
          templates << template
        end
      end
      # Name-sorted like the skills catalog (the oracle's prompt list is
      # alphabetical — the [Prompts] display and the autocomplete order).
      Result.new(templates: templates.sort_by(&:name), diagnostics:)
    end

    # pi loadTemplatesFromDir (:158-196): non-recursive top-level .md
    # scan; the read failure inside load_template_file is the diagnostic
    # path, so unreadable files attempt the load.
    def load_from_dir(dir)
      return [] unless File.directory?(dir)

      Dir.children(dir).filter_map do |name|
        next if name.start_with?(".") || !name.end_with?(".md")

        path = File.join(dir, name)
        File.file?(path) ? load_template_file(path) : nil
      end
    end

    # pi loadTemplateFromFile (:116-154): read failure or malformed YAML
    # is a warning diagnostic (the template drops); the body is the
    # content, the name the stem.
    def load_template_file(file_path)
      raw = File.read(file_path)
      frontmatter, body = Skills.parse_frontmatter(raw)
      description = frontmatter["description"].is_a?(String) ? frontmatter["description"] : ""
      if description.strip.empty?
        first_line = body.lines.find { |line| !line.strip.empty? }
        description = first_line ? first_line.strip[0, 60].+(first_line.strip.length > 60 ? "..." : "") : ""
      end
      hint = frontmatter["argument-hint"].is_a?(String) ? frontmatter["argument-hint"] : nil
      template = Template.new(
        name: File.basename(file_path).delete_suffix(".md"),
        description:, argument_hint: hint, content: body, file_path:
      )
      {template:, diagnostics: []}
    rescue StandardError
      {template: nil, diagnostics: [Diagnostic.new(type: "warning", message: "failed to read prompt template file",
        path: file_path)]}
    end

    # pi expandPromptTemplate (:512-527): "/name args" over the template
    # catalog; anything else (no slash, unknown name, no match shape)
    # passes through untouched.
    def expand(text, templates)
      return text unless text.start_with?("/")

      match = text.match(%r{\A/([^\s]+)(?:\s+([\s\S]*))?\z})
      return text unless match

      template = templates.find { |candidate| candidate.name == match[1] }
      return text unless template

      substitute(template.content, parse_command_args(match[2].to_s))
    end

    # pi parseCommandArgs (:17-54): bash-style splitting — quoted runs
    # (single or double) stay whole, quotes drop.
    def parse_command_args(args_string)
      args = []
      current = +""
      quote = nil
      args_string.each_char do |char|
        if quote
          quoted = char == quote
          quote = nil if quoted
          current << char unless quoted
        elsif char == '"' || char == "'"
          quote = char
        elsif char.match?(/\s/)
          args << current unless current.empty?
          current = +""
        else
          current << char
        end
      end
      args << current unless current.empty?
      args
    end

    # pi substituteArgs (:62-92).
    def substitute(content, args)
      all_args = args.join(" ")
      content.gsub(ARGS_PATTERN) do
        default_target = Regexp.last_match(1)
        default_value = Regexp.last_match(2)
        slice_start = Regexp.last_match(3)
        slice_length = Regexp.last_match(4)
        simple = Regexp.last_match(5)
        if default_target
          value = %w[@ ARGUMENTS].include?(default_target) ? all_args : args[Integer(default_target, 10) - 1]
          next value.to_s.empty? ? default_value : value
        end
        if slice_start
          start = [Integer(slice_start, 10) - 1, 0].max
          next slice_length ? args.slice(start, Integer(slice_length, 10)).join(" ") : args[start..].join(" ")
        end
        next all_args if simple == "ARGUMENTS" || simple == "@"

        args[Integer(simple, 10) - 1].to_s
      end
    end

  end
end
