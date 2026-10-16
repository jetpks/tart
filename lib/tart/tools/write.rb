# frozen_string_literal: true

require_relative "safe_execute"
require_relative "support/edit_diff"

module Tart
  module Tools
    # The write tool (port of pi's write.ts): content is written verbatim —
    # no newline, whitespace, or encoding normalization at any write boundary
    # (BRIEF §5 verbatim-parity), except the §5 trailing-whitespace toggle
    # (default off). Creates parent directories automatically.
    class Write < Fast::Completions::Tool
      include SafeExecute

      pi_name "write"

      DESCRIPTION = "Write content to a file. Creates the file if it doesn't exist, overwrites if it does. " \
        "Automatically creates parent directories."

      # STRING-KEYED THROUGHOUT (I64): the gem's strict engine reads string
      # keys (pi's JS node["type"] shape) — a symbol-keyed root makes the
      # "prefer" declaration SILENTLY INERT (the resolver falls back loose
      # with zero errors). Serialization-neutral: JSON.generate emits
      # identical bytes for either key form, so the non-strict wire holds.
      PARAMETERS_SCHEMA = {
        "type" => "object",
        "properties" => {
          "path" => {"type" => "string", "description" => "Path to the file to write (relative or absolute)"},
          "content" => {"type" => "string", "description" => "Content to write to the file"}
        },
        "required" => ["path", "content"]
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

      # pi write.ts :57 — one of EXACTLY four core tools pi tags with
      # constrainedSampling; the strict engine rewrites `parameters` and
      # ships `strict: true` on a strict-capable dialect (I64).
      constrained_sampling({"type" => "json_schema", "strict" => "prefer"})

      # @return [String] pi's success text, or {error:} on failure.
      def execute(path:, content:)
        safe_execute do
          failure = validate_input(path:, content:)
          return failure if failure

          absolute_path = PathUtils.resolve_to_cwd(path, @cwd)
          FileMutationQueue.with(absolute_path) do
            Fast::Completions::Cancellation.check
            dir = File.dirname(absolute_path)
            FileUtils.mkdir_p(dir)
            Fast::Completions::Cancellation.check

            # Verbatim: bytes in, bytes out — no trailing-newline fixup. The
            # §5 toggle is the sole write-boundary normalization, and ships off.
            content = EditDiff.strip_trailing_whitespace(content) if @strip_trailing_whitespace
            File.binwrite(absolute_path, content)
            Fast::Completions::Cancellation.check

            @details = {bytes_written: content.bytesize}
            "Successfully wrote to #{path}"
          end
        end
      end
    end
  end
end
