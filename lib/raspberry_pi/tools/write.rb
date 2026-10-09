# frozen_string_literal: true

require_relative "safe_execute"

module RaspberryPi
  module Tools
    # The write tool (port of pi's write.ts): content is written verbatim —
    # no newline, whitespace, or encoding normalization at any write boundary
    # (BRIEF §5 verbatim-parity). Creates parent directories automatically.
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

      def initialize(cwd:)
        @cwd = cwd
        @details = nil
      end

      description DESCRIPTION

      parameters PARAMETERS_SCHEMA.dup

      # @return [String] pi's success text, or {error:} on failure.
      def execute(path:, content:)
        safe_execute do
          absolute_path = PathUtils.resolve_to_cwd(path, @cwd)
          FileMutationQueue.with(absolute_path) do
            RubyLLM::Support::Cancellation.check
            dir = File.dirname(absolute_path)
            FileUtils.mkdir_p(dir)
            RubyLLM::Support::Cancellation.check

            # Verbatim: bytes in, bytes out. No trailing-newline fixup here —
            # the §5 normalization is post-parity work, explicitly out of scope.
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
