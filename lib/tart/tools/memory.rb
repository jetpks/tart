# frozen_string_literal: true

require "fileutils"
require "ruby_llm"

require_relative "safe_execute"

module Tart
  module Tools
    # The memory tool (port of the owner's jetpks/pi-extensions memory.ts,
    # 173 lines @ ca12eb5 — I47 Grounds §4 is the contract table): the
    # save/read/list surface over the per-project memory store, results
    # plain Strings (OQ-7 — pi's isError flag has no port channel; the
    # texts are byte-identical). Declared LAST on the wire (registered
    # tools append after built-ins + MCP) with NO <tools> snippet row (no
    # promptSnippet — custom tools without one are omitted,
    # extensions/types.ts:572-587).
    class Memory < RubyLLM::Tool
      include SafeExecute

      pi_name "memory"

      DESCRIPTION = "Persistent per-project memory. Save durable facts, preferences, and corrections worth carrying " \
        "to future sessions — never secrets, never one-off task state. Topic files are read on demand."

      # The pinned TypeBox → JSON Schema declaration (generated against
      # pi's typebox 1.3.27, Grounds §4): property order action/topic/text
      # and the anyOf consts preserved byte-exact — the memory-module gate
      # JSON.generates the wire declaration against this object.
      PARAMETERS_SCHEMA = {
        type: "object",
        required: ["action"],
        properties: {
          "action" => {
            "anyOf" => [
              {"type" => "string", "const" => "save"},
              {"type" => "string", "const" => "read"},
              {"type" => "string", "const" => "list"}
            ],
            "description" => "save: store text under topic; read: return a topic file; list: return the index"
          },
          "topic" => {"type" => "string", "description" => "Topic name, e.g. deploy (required for save/read)"},
          "text" => {"type" => "string", "description" => "Text to remember (save only)"}
        }
      }.freeze

      attr_reader :cwd

      # @param cwd [String] the project cwd (the store's project key walks
      #   to the git root from here).
      # @param home [String, nil] the memory home; nil = the resolved
      #   default (<IDENTITY>_MEMORY_HOME env else ~/.tart/memory).
      # @param identity [String] the resolved face whose env namespace the
      #   home tier reads ({Tools::Bash}'s idiom).
      def initialize(cwd:, home: nil, identity: Identity::DEFAULT)
        @cwd = cwd
        @home = home
        @identity = identity
      end

      description DESCRIPTION

      parameters PARAMETERS_SCHEMA.dup

      def execute(action: nil, topic: nil, text: nil)
        safe_execute do
          action = action.to_s
          # memory.ts execute: the needs-a-topic guard precedes every
          # non-list action (the raw action interpolates, pi's string).
          return "The memory tool #{action} action needs a topic." if action != "list" && topic.to_s.strip.empty?

          if action == "save"
            return "The memory tool save action needs text to remember." if text.to_s.strip.empty?

            resolved = resolve_topic(topic.to_s)
            return resolved if resolved.is_a?(String)

            file, slug, dir = resolved
            FileUtils.mkdir_p(dir)
            # memory.ts save bytes: the ISO8601 frontmatter + trimmed text.
            File.write(file, "---\nmodified: #{Time.now.utc.iso8601(3)}\n---\n\n#{text.strip}\n")
            upsert_index_line(dir, slug, topic.to_s.strip, text)
            return %(Saved memory topic "#{topic}" (#{slug}.md).)
          end

          if action == "read"
            resolved = resolve_topic(topic.to_s)
            return resolved if resolved.is_a?(String)

            file, slug, = resolved
            return %(No memory saved for topic "#{topic}" (#{slug}.md). Use the memory tool list action to see saved topics.) unless File.file?(file)

            return File.read(file)
          end

          index = index_path
          return "No project memory yet. Save some with the memory tool save action." unless File.file?(index)

          File.read(index)
        end
      end

      private

      # memory.ts resolveTopicFile: absolute and `..`-escaping topics are
      # rejected outright, then the slug charset gate, then the
      # resolved-path containment check. The error Strings are the five
      # pinned texts (Grounds §4). A String return IS the error result.
      def resolve_topic(topic)
        if topic.start_with?("/") || topic.split("/").include?("..")
          return %(Invalid topic "#{topic}": topics are plain names inside the project memory directory, not paths.)
        end

        slug = slugify(topic)
        unless slug.match?(/\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\z/)
          return %(Invalid topic "#{topic}": it must be a plain name like "deploy" (letters, numbers, dashes).)
        end

        dir = store.project_dir
        file = File.join(dir, "#{slug}.md")
        # The slug charset admits no separators, so containment cannot fail
        # in practice — the check stays as the real gate (memory.ts's own
        # comment).
        unless file.start_with?(dir + File::SEPARATOR)
          return %(Invalid topic "#{topic}": it must stay inside the project memory directory.)
        end

        [file, slug, dir]
      end

      # memory.ts slugify: lowercase, [^a-z0-9]+ → "-", dash-trimmed.
      def slugify(topic)
        topic.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")
      end

      # memory.ts upsertIndexLine: kept rows are the existing non-empty
      # rows not containing `](<slug>.md)`, the new line appended, the
      # file written with a trailing newline. The index line's summary is
      # the first non-blank line of the RAW text (`…`-truncated past 120
      # chars — 119 + the ellipsis).
      def upsert_index_line(dir, slug, topic, text)
        file = File.join(dir, Tart::Memory::INDEX_FILE)
        existing = File.file?(file) ? File.read(file) : ""
        kept = existing.split("\n").reject { |line| line.strip.empty? || line.include?("](#{slug}.md)") }
        kept << "- [#{topic}](#{slug}.md): #{first_line(text)}"
        FileUtils.mkdir_p(dir)
        File.write(file, "#{kept.join("\n")}\n")
      end

      def first_line(text)
        line = text.split("\n").find { |candidate| !candidate.strip.empty? } || ""
        line.length > Tart::Memory::SUMMARY_MAX_CHARS ? "#{line[0, Tart::Memory::SUMMARY_MAX_CHARS - 1]}…" : line
      end

      def index_path
        File.join(store.project_dir, Tart::Memory::INDEX_FILE)
      end

      # The store (home resolved once: the <IDENTITY>_MEMORY_HOME env
      # tier, else ~/.tart/memory — the agent root).
      def store
        @store ||= Tart::Memory::Store.new(
          home: @home || ENV[Identity.env_key(@identity, "MEMORY_HOME")] || File.join(Dir.home, ".tart", "memory"),
          cwd: @cwd
        )
      end
    end
  end
end
