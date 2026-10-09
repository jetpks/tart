# frozen_string_literal: true

module RaspberryPi
  module Tools
    # Shared truncation utilities for tool outputs (port of pi's truncate.ts).
    #
    # Truncation is based on two independent limits — whichever is hit first wins:
    # a line limit (default 2000 lines) and a byte limit (default 50KB). Never
    # returns partial lines, except the bash tail-truncation edge case.
    module Truncate
      DEFAULT_MAX_LINES = 2000
      DEFAULT_MAX_BYTES = 50 * 1024 # 50KB
      GREP_MAX_LINE_LENGTH = 500 # Max chars per grep match line

      # The result of a truncation, mirroring pi's TruncationResult field-for-field.
      Result = Struct.new(
        :content, :truncated, :truncated_by, :total_lines, :total_bytes,
        :output_lines, :output_bytes, :last_line_partial, :first_line_exceeds_limit,
        :max_lines, :max_bytes, keyword_init: true
      )

      module_function

      # Format bytes as human-readable size (pi's formatSize).
      def format_size(bytes)
        return "#{bytes}B" if bytes < 1024
        return "#{(bytes / 1024.0).round(1)}KB" if bytes < 1024 * 1024

        "#{(bytes / (1024.0 * 1024)).round(1)}MB"
      end

      # Lines as pi's splitLinesForCounting counts them: a trailing newline
      # does not open an extra empty line.
      def split_lines_for_counting(content)
        return [] if content.empty?

        lines = content.split("\n", -1)
        lines.pop if content.end_with?("\n")
        lines
      end

      # Truncate content from the head (keep first N lines/bytes), as pi's
      # truncateHead. Never returns partial lines; if the first line alone
      # exceeds the byte limit, returns empty content with
      # first_line_exceeds_limit.
      def truncate_head(content, max_lines: DEFAULT_MAX_LINES, max_bytes: DEFAULT_MAX_BYTES)
        total_bytes = content.bytesize
        lines = split_lines_for_counting(content)
        total_lines = lines.length

        if total_lines <= max_lines && total_bytes <= max_bytes
          return Result.new(
            content:, truncated: false, truncated_by: nil, total_lines:, total_bytes:,
            output_lines: total_lines, output_bytes: total_bytes,
            last_line_partial: false, first_line_exceeds_limit: false, max_lines:, max_bytes:
          )
        end

        first_line_bytes = lines[0].bytesize
        if first_line_bytes > max_bytes
          return Result.new(
            content: "", truncated: true, truncated_by: "bytes", total_lines:, total_bytes:,
            output_lines: 0, output_bytes: 0, last_line_partial: false,
            first_line_exceeds_limit: true, max_lines:, max_bytes:
          )
        end

        output = []
        output_bytes_count = 0
        truncated_by = "lines"
        lines.each_with_index do |line, i|
          break if i >= max_lines

          line_bytes = line.bytesize + (i.positive? ? 1 : 0)
          if output_bytes_count + line_bytes > max_bytes
            truncated_by = "bytes"
            break
          end
          output << line
          output_bytes_count += line_bytes
        end
        truncated_by = "lines" if output.length >= max_lines && output_bytes_count <= max_bytes

        output_content = output.join("\n")
        Result.new(
          content: output_content, truncated: true, truncated_by:, total_lines:, total_bytes:,
          output_lines: output.length, output_bytes: output_content.bytesize,
          last_line_partial: false, first_line_exceeds_limit: false, max_lines:, max_bytes:
        )
      end

      # Truncate content from the tail (keep last N lines/bytes), as pi's
      # truncateTail. May return a partial first line if the last line of the
      # original content exceeds the byte limit.
      def truncate_tail(content, max_lines: DEFAULT_MAX_LINES, max_bytes: DEFAULT_MAX_BYTES)
        total_bytes = content.bytesize
        lines = split_lines_for_counting(content)
        total_lines = lines.length

        if total_lines <= max_lines && total_bytes <= max_bytes
          return Result.new(
            content:, truncated: false, truncated_by: nil, total_lines:, total_bytes:,
            output_lines: total_lines, output_bytes: total_bytes,
            last_line_partial: false, first_line_exceeds_limit: false, max_lines:, max_bytes:
          )
        end

        output = []
        output_bytes_count = 0
        truncated_by = "lines"
        last_line_partial = false

        lines.reverse_each do |line|
          break if output.length >= max_lines

          line_bytes = line.bytesize + (output.empty? ? 0 : 1)
          if output_bytes_count + line_bytes > max_bytes
            truncated_by = "bytes"
            # Edge case: no lines collected yet and this line exceeds maxBytes —
            # take the end of the line (partial).
            if output.empty?
              truncated_line = truncate_string_to_bytes_from_end(line, max_bytes)
              output.unshift(truncated_line)
              output_bytes_count = truncated_line.bytesize
              last_line_partial = true
            end
            break
          end
          output.unshift(line)
          output_bytes_count += line_bytes
        end
        truncated_by = "lines" if output.length >= max_lines && output_bytes_count <= max_bytes

        output_content = output.join("\n")
        Result.new(
          content: output_content, truncated: true, truncated_by:, total_lines:, total_bytes:,
          output_lines: output.length, output_bytes: output_content.bytesize,
          last_line_partial:, first_line_exceeds_limit: false, max_lines:, max_bytes:
        )
      end

      # Truncate a string to fit within a byte limit from the end, cutting only
      # at UTF-8 character boundaries (pi's truncateStringToBytesFromEnd).
      def truncate_string_to_bytes_from_end(str, max_bytes)
        buf = str.dup.force_encoding(Encoding::BINARY)
        return str if buf.bytesize <= max_bytes

        start = buf.bytesize - max_bytes
        start += 1 while start < buf.bytesize && continuation_byte?(buf, start)
        buf.byteslice(start, buf.bytesize - start).force_encoding(Encoding::UTF_8)
      end

      # Truncate a single line to max characters, adding a [truncated] suffix
      # (pi's truncateLine, used for grep match lines).
      def truncate_line(line, max_chars = GREP_MAX_LINE_LENGTH)
        return {text: line, was_truncated: false} if line.length <= max_chars

        {text: "#{line.slice(0, max_chars)}... [truncated]", was_truncated: true}
      end

      # Keep the start and end of content, half of max_bytes each, and replace
      # the middle with a "…N chars truncated…" marker (pi's truncateMiddle).
      def truncate_middle(content, max_bytes)
        buf = content.dup.force_encoding(Encoding::BINARY)
        total_lines = split_lines_for_counting(content).length
        return {content:, truncated: false, removed_chars: 0, total_bytes: buf.bytesize, total_lines: total_lines} if
          buf.bytesize <= max_bytes

        head_end = floor_boundary(buf, max_bytes / 2)
        tail_start = ceil_boundary(buf, buf.bytesize - (max_bytes - max_bytes / 2))
        head = slice_utf8(buf, 0, head_end)
        tail = slice_utf8(buf, tail_start, buf.bytesize)
        removed_chars = slice_utf8(buf, head_end, tail_start).length
        {
          content: "#{head}…#{removed_chars} chars truncated…#{tail}",
          truncated: true, removed_chars:, total_bytes: buf.bytesize, total_lines: total_lines
        }
      end

      def continuation_byte?(buf, index)
        (buf.getbyte(index) & 0xc0) == 0x80
      end

      # Move head_end left onto a character start boundary.
      def floor_boundary(buf, index)
        index -= 1 while index.positive? && continuation_byte?(buf, index)
        index
      end

      # Move tail_start right onto a character start boundary.
      def ceil_boundary(buf, index)
        index += 1 while index < buf.bytesize && continuation_byte?(buf, index)
        index
      end

      def slice_utf8(buf, from, to)
        buf.byteslice(from, to - from).force_encoding(Encoding::UTF_8)
      end
    end
  end
end
