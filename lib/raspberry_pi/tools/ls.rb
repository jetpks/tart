# frozen_string_literal: true

require_relative "safe_execute"

module RaspberryPi
  module Tools
    # The ls tool (port of pi's ls.ts): directory listing sorted
    # case-insensitively, '/' suffix for directories, dotfiles included,
    # truncated to 500 entries or 50KB.
    class Ls < RubyLLM::Tool
      include SafeExecute

      pi_name "ls"

      DEFAULT_LIMIT = 500

      DESCRIPTION = "List directory contents. Returns entries sorted alphabetically, with '/' suffix for " \
        "directories. Includes dotfiles. Output is truncated to 500 entries or 50KB (whichever is hit first)."

      PARAMETERS_SCHEMA = {
        type: "object",
        properties: {
          "path" => {type: "string", description: "Directory to list (default: current directory)"},
          "limit" => {type: "number", description: "Maximum number of entries to return (default: 500)"}
        }
      }.freeze

      attr_reader :cwd, :details

      def initialize(cwd:)
        @cwd = cwd
        @details = nil
      end

      description DESCRIPTION

      parameters PARAMETERS_SCHEMA.dup

      # @return [String] newline-joined entries, or {error:} on failure.
      def execute(path: nil, limit: nil)
        safe_execute do
          RubyLLM::Support::Cancellation.check
          dir_path = PathUtils.resolve_to_cwd(path || ".", @cwd)
          raise ArgumentError, "Path not found: #{dir_path}" unless File.exist?(dir_path)
          raise ArgumentError, "Not a directory: #{dir_path}" unless File.directory?(dir_path)

          effective_limit = limit || DEFAULT_LIMIT
          entries = begin
            Dir.children(dir_path)
          rescue StandardError => e
            raise ArgumentError, "Cannot read directory: #{e.message}"
          end
          entries.sort_by!(&:downcase)

          results = []
          entry_limit_reached = false
          entries.each do |entry|
            if results.length >= effective_limit
              entry_limit_reached = true
              break
            end
            full_path = File.join(dir_path, entry)
            begin
              suffix = File.directory?(full_path) ? "/" : ""
            rescue StandardError
              next # Skip entries we cannot stat.
            end
            results << entry + suffix
          end

          return "(empty directory)" if results.empty?

          raw_output = results.join("\n")
          truncation = Truncate.truncate_head(raw_output, max_lines: Float::MAX.to_i)
          output = truncation.content
          notices = []
          @details = {}
          if entry_limit_reached
            notices << "#{effective_limit} entries limit reached. Use limit=#{effective_limit * 2} for more"
            @details[:entry_limit_reached] = effective_limit
          end
          if truncation.truncated
            notices << "#{Truncate.format_size(Truncate::DEFAULT_MAX_BYTES)} limit reached"
            @details[:truncation] = truncation.to_h
          end
          output += "\n\n[#{notices.join('. ')}]" unless notices.empty?
          output
        end
      end
    end
  end
end
