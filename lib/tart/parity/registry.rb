# frozen_string_literal: true

require "yaml"

module Tart
  module Parity
    # The difference registry: DATA, not code. Each class is a name plus a
    # regex source; a difference line is sanctioned if it matches the first
    # class whose pattern matches it. Lines matching no class are
    # unknown-candidate lines — the parity program's work list. The rig must
    # stay SHARP: no sanctioned MOTD/logo/version/glyph classes; today's
    # known divergences must surface as candidates.
    #
    # YAML shape (see parity/registry.yml):
    #   classes:
    #     - name: staged-sandbox-path
    #       pattern: 'sandbox/(pi|tart)-run-\d+'
    class Registry
      Rule = Struct.new(:name, :pattern) # @return [Regexp]

      def self.load(path)
        raise Error, "#{path}: no such registry file" unless File.readable?(path)

        data = YAML.safe_load_file(path, aliases: false)
        raise Error, "#{path}: not a mapping" unless data.is_a?(Hash)

        classes = data.fetch("classes", [])
        raise Error, "#{path}: 'classes' must be a list" unless classes.is_a?(Array)

        rules = classes.map do |entry|
          raise Error, "#{path}: each class needs 'name' and 'pattern'" unless entry.is_a?(Hash) && entry["name"] && entry["pattern"]

          begin
            Rule.new(entry.fetch("name"), Regexp.new(entry.fetch("pattern")))
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
      def classify(line)
        rule = @rules.find { |r| r.pattern.match?(line) }
        rule&.name
      end

      attr_reader :rules
    end
  end
end
