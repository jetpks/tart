# frozen_string_literal: true

module Tart
  module Render
    # The real completion source (bin/tart-wired): the builtin slash
    # commands plus /skill:<name> entries plus the prompt templates —
    # pi's command list (CombinedAutocompleteProvider; skills registered
    # as "skill:<name>" at coding-agent interactive-mode.ts:809-818,
    # templates as bare names :787-791, plain descriptions —
    # pi's [sourceTag] prefixes are extension/path-source metadata the
    # port has no equivalent of, recorded). Items-only: the list owns
    # the fuzzy filter (mapping judgment — the port's provider seam is
    # static, no async).
    class SlashSource
      def initialize(commands:, skills:, prompts: [])
        @commands = commands
        @skills = skills
        @prompts = prompts
      end

      def items
        @commands.map { |name, meta| {value: name, label: name, description: meta[:description]} } +
          @skills.map { |skill| {value: "skill:#{skill.name}", label: "skill:#{skill.name}", description: skill.description} } +
          @prompts.map { |template| {value: template.name, label: template.name, description: template.description} }
      end
    end
  end
end
