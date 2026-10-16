# frozen_string_literal: true

require_relative "safe_execute"

module Tart
  module Tools
    # The read tool (port of pi's read.ts): bytes verbatim — trailing
    # whitespace, BOM, and line endings round-trip untouched. Output is
    # truncated to 2000 lines or 50KB (whichever is hit first), never
    # returning partial lines.
    class Read < Fast::Completions::Tool
      include SafeExecute

      pi_name "read"

      DESCRIPTION = "Read the contents of a file. Supports text files and images (jpg, png, gif, webp, bmp). " \
        "Images are sent as attachments. For text files, output is truncated to 2000 lines or 50KB " \
        "(whichever is hit first). Use offset/limit for large files. When you need the full file, " \
        "continue with offset until complete."

      # STRING-KEYED THROUGHOUT (I64): the gem's strict engine reads string
      # keys (pi's JS node["type"] shape) — a symbol-keyed root makes the
      # "prefer" declaration SILENTLY INERT (the resolver falls back loose
      # with zero errors). Serialization-neutral: JSON.generate emits
      # identical bytes for either key form, so the non-strict wire holds.
      PARAMETERS_SCHEMA = {
        "type" => "object",
        "properties" => {
          "path" => {"type" => "string", "description" => "Path to the file to read (relative or absolute)"},
          "offset" => {"type" => "number", "description" => "Line number to start reading from (1-indexed)"},
          "limit" => {"type" => "number", "description" => "Maximum number of lines to read"}
        },
        "required" => ["path"]
      }.freeze

      attr_reader :cwd, :details

      # @param cwd [String] working directory for relative paths.
      # @param auto_resize_images [Boolean] parity placeholder: pi resizes
      #   images before sending; the port emits them unresized (recorded
      #   deviation, BRIEF §5).
      def initialize(cwd:, auto_resize_images: true)
        @cwd = cwd
        @auto_resize_images = auto_resize_images
        @details = nil
      end

      description DESCRIPTION

      parameters PARAMETERS_SCHEMA.dup

      # pi read.ts :101 — one of EXACTLY four core tools pi tags with
      # constrainedSampling; the strict engine rewrites `parameters` and
      # ships `strict: true` on a strict-capable dialect (I64).
      constrained_sampling({"type" => "json_schema", "strict" => "prefer"})

      # @return [String] the model-facing text, or {error:} on failure.
      def execute(path:, offset: nil, limit: nil)
        safe_execute do
          failure = validate_input(path:, offset:, limit:)
          return failure if failure

          Fast::Completions::Cancellation.check
          absolute_path = PathUtils.resolve_read_path(path, @cwd)
          mime_type = Mime.detect_from_file(absolute_path)
          return execute_image(absolute_path, mime_type, path) if mime_type

          execute_text(absolute_path, path, offset, limit)
        end
      end

      private

      def execute_image(absolute_path, mime_type, path)
        data = File.binread(absolute_path)
        Fast::Completions::Cancellation.check
        # pi resizes here (sharp); the port sends the original bytes (recorded
        # deviation). The note text matches pi's non-failure image read.
        note = "Read image file [#{mime_type}]"
        @details = {image: {mime_type:, bytes: data.bytesize, path:}}
        note
      end

      def execute_text(absolute_path, path, offset, limit)
        text_content = File.binread(absolute_path).force_encoding(Encoding::UTF_8).scrub
        all_lines = text_content.split("\n", -1)
        total_file_lines = all_lines.length
        # 1-indexed input to 0-indexed array access.
        start_line = offset ? [0, offset - 1].max : 0
        start_line_display = start_line + 1
        if start_line >= all_lines.length
          raise ArgumentError, "Offset #{offset} is beyond end of file (#{all_lines.length} lines total)"
        end

        user_limited_lines = nil
        selected_content = if limit
          end_line = [start_line + limit, all_lines.length].min
          user_limited_lines = end_line - start_line
          all_lines[start_line...end_line].join("\n")
        else
          all_lines[start_line..].join("\n")
        end

        truncation = Truncate.truncate_head(selected_content)
        output_text = if truncation.first_line_exceeds_limit
          first_line_size = Truncate.format_size(all_lines[start_line].bytesize)
          "[Line #{start_line_display} is #{first_line_size}, exceeds #{Truncate.format_size(Truncate::DEFAULT_MAX_BYTES)} " \
            "limit. Use bash: sed -n '#{start_line_display}p' #{path} | head -c #{Truncate::DEFAULT_MAX_BYTES}]"
        elsif truncation.truncated
          end_line_display = start_line_display + truncation.output_lines - 1
          next_offset = end_line_display + 1
          notice = if truncation.truncated_by == "lines"
            "[Showing lines #{start_line_display}-#{end_line_display} of #{total_file_lines}. " \
              "Use offset=#{next_offset} to continue.]"
          else
            "[Showing lines #{start_line_display}-#{end_line_display} of #{total_file_lines} " \
              "(#{Truncate.format_size(Truncate::DEFAULT_MAX_BYTES)} limit). Use offset=#{next_offset} to continue.]"
          end
          "#{truncation.content}\n\n#{notice}"
        elsif user_limited_lines && start_line + user_limited_lines < all_lines.length
          remaining = all_lines.length - (start_line + user_limited_lines)
          next_offset = start_line + user_limited_lines + 1
          "#{truncation.content}\n\n[#{remaining} more lines in file. Use offset=#{next_offset} to continue.]"
        else
          truncation.content
        end

        @details = {truncation: truncation.to_h}
        output_text
      end
    end
  end
end
