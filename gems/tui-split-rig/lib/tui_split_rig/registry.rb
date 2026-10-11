# frozen_string_literal: true

require "yaml"

module TuiSplitRig
  # The difference registry: DATA, not code. Each class is a name plus a
  # regex source; a difference line is sanctioned if it matches the first
  # class whose pattern matches it. Lines matching no class are
  # unknown-candidate lines — the parity program's work list. The rig must
  # stay SHARP: no sanctioned MOTD/logo/version/glyph classes; today's
  # known divergences must surface as candidates.
  #
  # YAML shape (see registry.yml):
  #   classes:
  #     - name: staged-sandbox-path
  #       pattern: 'sandbox/(pi|tart)-run-\d+'
  #     - name: cursor-row-style          # style_only: matches ONLY the
  #       pattern: '^$'                   # style pass (never the text diff)
  #       style_only: true
  class Registry
    Rule = Struct.new(:name, :pattern, :style_only)

    def self.load(path)
      raise Error, "#{path}: no such registry file" unless File.readable?(path)

      data = YAML.safe_load_file(path, aliases: false)
      raise Error, "#{path}: not a mapping" unless data.is_a?(Hash)

      classes = data.fetch("classes", [])
      raise Error, "#{path}: 'classes' must be a list" unless classes.is_a?(Array)

      rules = classes.map do |entry|
        raise Error, "#{path}: each class needs 'name' and 'pattern'" unless entry.is_a?(Hash) && entry["name"] && entry["pattern"]

        begin
          Rule.new(entry.fetch("name"), Regexp.new(entry.fetch("pattern")), entry["style_only"] == true)
        rescue RegexpError => e
          raise Error, "#{path}: bad pattern for #{entry['name']}: #{e.message}"
        end
      end
      new(rules)
    rescue Psych::SyntaxError, ArgumentError => e
      raise Error, "#{path}: invalid YAML (#{e.message})"
    end

    def initialize(rules)
      @rules = rules
    end

    # First match wins. Returns the class name or nil (unknown-candidate).
    # The TEXT pass skips style_only classes; the SGR pass (+style_only_context:+)
    # consults everything — patterns too broad to sanction a TEXT line
    # (an empty line's cursor-row SGR shape) but right for a style one.
    def classify(line, style_only_context: false)
      rule = @rules.find do |r|
        next false if !style_only_context && r.style_only

        r.pattern.match?(line)
      end
      rule&.name
    end

    attr_reader :rules
  end
end
