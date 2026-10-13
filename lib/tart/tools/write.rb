# frozen_string_literal: true

require_relative "safe_execute"
require_relative "support/edit_diff"

module Tart
  module Tools
    # The write tool (port of pi's write.ts): content is written verbatim —
    # no newline, whitespace, or encoding normalization at any write boundary
    # (BRIEF §5 verbatim-parity), except the §5 trailing-whitespace toggle
    # (default off). Creates parent directories automatically.
    class Write < RubyLLM::Tool
      include SafeExecute

      pi_name "write"

      DESCRIPTION = "Write content to a file. Creates the file if it doesn't exist, overwrites if it does. " \
        "Automatically creates parent directories."

      PARAMETERS_SCHEMA = {
        type: "object",
        properties: {
          "path" => {type: "string", description: "Path to the file to write (relative or absolute)"},
          "content" => {type: "string", description: "Content to write to the file"}
        },
        required: ["path", "content"]
      }.freeze

      attr_reader :cwd, :details

      # @param strip_trailing_whitespace [Boolean] §5 toggle (default off):
      #   strip trailing spaces/tabs from each line of the committed bytes.
      def initialize(cwd:, strip_trailing_whitespace: false)
        @cwd = cwd
        @strip_trailing_whitespace = strip_trailing_whitespace
        @details = nil
      end

      description DESCRIPTION

      parameters PARAMETERS_SCHEMA.dup

      # @return [String] pi's success text, or {error:} on failure.
      def execute(path:, content:)
        safe_execute do
          failure = validate_input(path:, content:)
          return failure if failure

          absolute_path = PathUtils.resolve_to_cwd(path, @cwd)
          FileMutationQueue.with(absolute_path) do
            RubyLLM::Support::Cancellation.check
            dir = File.dirname(absolute_path)
            FileUtils.mkdir_p(dir)
            RubyLLM::Support::Cancellation.check

            # Verbatim: bytes in, bytes out — no trailing-newline fixup. The
            # §5 toggle is the sole write-boundary normalization, and ships off.
            content = EditDiff.strip_trailing_whitespace(content) if @strip_trailing_whitespace
            File.binwrite(absolute_path, content)
            RubyLLM::Support::Cancellation.check

            @details = {bytes_written: content.bytesize}
            "Successfully wrote to #{path}"
          end
        end
      end
    end
  end
end
