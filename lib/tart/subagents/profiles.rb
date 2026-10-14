# frozen_string_literal: true

require_relative "../skills"
require_relative "../schemas/subagents"

module Tart
  module Subagents
    # The agent-profile layer (I49 Spec §1): `agents/**/*.md` files — YAML
    # frontmatter over a system-prompt body — discovered from two tiers
    # (user `<agent root>/agents`, project `<cwd>/.tart/agents`; pi's
    # recursive same-name rule with the higher tier winning) and merged
    # over the frozen BUILTIN_AGENTS table at the spawn lookup seam.
    #
    # Pure functions over disk, NO caching: resolution is per-spawn (Grounds
    # D1 — an edited profile takes effect on the next spawn). A malformed
    # file produces a warning diagnostic and is skipped — discovery NEVER
    # raises (the skills/prompts diagnostic precedent).
    module Profiles
      # The skills/prompts diagnostic shape (type/message/path).
      Result = Struct.new(:profiles, :diagnostics, keyword_init: true)

      # The project tier's config dir (the prompts' `.tart/prompts`
      # precedent; pi getConfigDirName per project).
      PROJECT_DIR = File.join(".tart", "agents").freeze

      module_function

      # Scan both tiers recursively and parse every candidate. Returns the
      # discovered profile spec Hashes (the I48 builtin-entry shape plus
      # model/source) and the warning diagnostics.
      def discover(cwd:, root: Agent::Session.default_root, env: ENV)
        profiles = {}
        diagnostics = []
        # User tier FIRST, project tier SECOND — the later (project) write
        # wins the same-name collision (Spec §1 precedence project > user).
        [[File.join(root, "agents"), :user], [File.expand_path(PROJECT_DIR, cwd), :project]].each do |dir, source|
          each_profile_file(dir) do |path|
            spec, error = build_profile(path, source)
            if error
              diagnostics << Skills::Diagnostic.new(type: "warning", message: error, path: path)
              next
            end
            profiles[spec[:name]] = spec
          end
        end
        Result.new(profiles: profiles.values, diagnostics:)
      end

      # The merged name → spec table: BUILTIN_AGENTS (each entry +
      # `source: :builtin`, `model: nil`) overlaid user-then-project.
      def resolve_table(cwd:, root: Agent::Session.default_root, env: ENV)
        table = BUILTIN_AGENTS.each_with_object({}) do |(name, spec), hash|
          hash[name] = spec.merge(source: :builtin, model: nil)
        end
        discover(cwd:, root:, env:).profiles.each { |spec| table[spec[:name]] = spec }
        table
      end

      # The spec Hash for one agent name, or the unknown-agent ArgumentError
      # (pi formatUnknownAgentError's close-match shape over the MERGED
      # table — builtins + discovered).
      def resolve(name, cwd:, root: Agent::Session.default_root, env: ENV)
        table = resolve_table(cwd:, root:, env:)
        table.fetch(name.to_s) do
          raise ArgumentError, unknown_agent_message(name.to_s, table.keys)
        end
      end

      # pi formatUnknownAgentError :100-117 adapted (the port names the
      # merged listing, not pi's consulted-directory evidence): the
      # `Did you mean` sentence is omitted when no close match exists.
      def unknown_agent_message(name, names)
        suggestion = closest_match(name, names)
        listing = "Available agents: #{names.sort.join(", ")}."
        if suggestion
          "unknown agent #{name.inspect}. Did you mean '#{suggestion}'? #{listing}"
        else
          "unknown agent #{name.inspect}. #{listing}"
        end
      end

      # --- pi shared/edit-distance.js, ported for the close-match rule ---

      # pi closestMatch: the closest candidate that is a likely typo of the
      # requested name, compared case-insensitively — Levenshtein distance
      # within `max(1, candidate.length / 4)` OR a single adjacent
      # transposition; ties break by distance then locale order.
      def closest_match(requested, candidates)
        lower = requested.downcase
        candidates.filter_map do |candidate|
          lowered = candidate.downcase
          distance = edit_distance(lower, lowered)
          next nil unless distance <= [1, lowered.length / 4].max || adjacent_transposition?(lower, lowered)

          [candidate, distance]
        end.min_by { |candidate, distance| [distance, candidate] }&.first
      end

      def edit_distance(left, right)
        previous = (0..right.length).to_a
        left.each_char.with_index(1) do |left_char, left_index|
          diagonal = previous[0]
          previous[0] = left_index
          right.each_char.with_index(1) do |right_char, right_index|
            above = previous[right_index]
            previous[right_index] = left_char == right_char ? diagonal : [diagonal, above, previous[right_index - 1]].min + 1
            diagonal = above
          end
        end
        previous[right.length]
      end

      def adjacent_transposition?(left, right)
        return false if left.length != right.length

        mismatch = left.chars.find_index.with_index { |char, index| char != right[index] }
        mismatch >= 0 && left[mismatch] == right[mismatch + 1] &&
          left[mismatch + 1] == right[mismatch] && left[(mismatch + 2)..] == right[(mismatch + 2)..]
      end

      # --- parse + validate (never raises) ---

      def each_profile_file(dir)
        return unless File.directory?(dir)

        # The glob (no FNM_DOTMATCH) already skips dotfiles and dot-
        # directories INSIDE the scan root — including hidden dirs — and
        # non-.md files; the basename guard documents the rule.
        Dir.glob(File.join(dir, "**", "*.md")).sort.each do |path|
          next unless File.file?(path)
          next if File.basename(path).start_with?(".")

          yield path
        end
      end

      # One file → [spec Hash, nil] or [nil, error-message] (the caller
      # renders the warning diagnostic). The frontmatter name wins over the
      # file stem (pi: the runtime name is the frontmatter's); context maps
      # to the builtin table's SYMBOLS (:fresh/:fork — the Manager's fork
      # check reads spec[:context] == :fork).
      def build_profile(path, source)
        frontmatter, body = Skills.parse_frontmatter(File.read(path))
        return [nil, "invalid YAML frontmatter"] unless frontmatter.is_a?(Hash)

        contract = Schemas::Subagents::PROFILE_CONTRACT.call(frontmatter)
        unless contract.success?
          return [nil, contract.errors.to_a.map { |error| error.respond_to?(:text) ? error.text : error.to_s }
                         .join("; ")]
        end
        return [nil, "system prompt body is empty"] if body.to_s.strip.empty?

        name = frontmatter["name"] || File.basename(path, ".md")
        [spec_hash(name, frontmatter, body, source), nil]
      rescue StandardError => e
        [nil, e.message]
      end

      def spec_hash(name, frontmatter, body, source)
        tools = tools_list(frontmatter["tools"])
        {
          name:, description: frontmatter["description"] || "", tools:,
          thinking: frontmatter["thinking"],
          context: frontmatter["context"] == "fork" ? :fork : :fresh,
          system_prompt: body, model: frontmatter["model"], source:
        }
      end

      # Shape already validated by the contract; an omitted tools line
      # means the full builtin seven (Spec §2 — an explicit list preserves
      # its order, the I41 wire-order rule).
      def tools_list(value)
        return Tools::ALL if value.nil?

        list = value.is_a?(String) ? value.split(",") : Array(value)
        list.map(&:strip).reject(&:empty?)
      end
    end
  end
end
