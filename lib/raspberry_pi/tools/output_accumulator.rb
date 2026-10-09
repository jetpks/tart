# frozen_string_literal: true

require "securerandom"

module RaspberryPi
  module Tools
    # Incrementally tracks streaming output with bounded memory (port of
    # pi's output-accumulator.ts): appends raw chunks, keeps only a decoded
    # tail for snapshots, and spills the full raw output into a temp file
    # once any limit is crossed.
    class OutputAccumulator
      Snapshot = Struct.new(:content, :truncation, :full_output_path, keyword_init: true)
      FullOutput = Struct.new(:content, :truncated, keyword_init: true)

      def initialize(max_lines: Truncate::DEFAULT_MAX_LINES, max_bytes: Truncate::DEFAULT_MAX_BYTES,
                     temp_file_prefix: "raspberry-pi-output")
        @max_lines = max_lines
        @max_bytes = max_bytes
        @max_rolling_bytes = [max_bytes * 2, 1].max
        @temp_file_prefix = temp_file_prefix
        @raw_chunks = []
        @tail_text = +""
        @tail_bytes = 0
        @tail_starts_at_line_boundary = true
        @total_raw_bytes = 0
        @total_decoded_bytes = 0
        @completed_lines = 0
        @total_lines = 0
        @current_line_bytes = 0
        @has_open_line = false
        @finished = false
        @temp_file_path = nil
        @mutex = Mutex.new
      end

      def append(data)
        raise "Cannot append to a finished output accumulator" if @finished

        @mutex.synchronize do
          @total_raw_bytes += data.bytesize
          append_decoded_text(data.force_encoding(Encoding::UTF_8).scrub)

          if @temp_file_path
            File.open(@temp_file_path, "ab") { |f| f.write(data) }
          elsif should_use_temp_file?
            ensure_temp_file
            File.open(@temp_file_path, "ab") { |f| f.write(data) }
          elsif !data.empty?
            @raw_chunks << data
          end
        end
      end

      def finish
        @mutex.synchronize do
          @finished = true
          ensure_temp_file if should_use_temp_file?
        end
      end

      def snapshot(persist_if_truncated: false)
        @mutex.synchronize do
          tail_truncation = Truncate.truncate_tail(snapshot_text, max_lines: @max_lines, max_bytes: @max_bytes)
          truncated = @total_lines > @max_lines || @total_decoded_bytes > @max_bytes
          truncated_by = if truncated
            tail_truncation.truncated_by || (@total_decoded_bytes > @max_bytes ? "bytes" : "lines")
          end
          truncation = tail_truncation.dup.tap do |t|
            t.truncated = truncated
            t.truncated_by = truncated_by
            t.total_lines = @total_lines
            t.total_bytes = @total_decoded_bytes
            t.max_lines = @max_lines
            t.max_bytes = @max_bytes
          end

          ensure_temp_file if persist_if_truncated && truncation.truncated
          Snapshot.new(content: truncation.content, truncation:, full_output_path: @temp_file_path)
        end
      end

      # The complete output. Call after #finish. Output longer than max_bytes
      # keeps its first and last max_bytes/2 around an omission marker.
      def read_full_output(max_bytes)
        @mutex.synchronize do
          unless @temp_file_path
            return FullOutput.new(content: @raw_chunks.join.force_encoding(Encoding::UTF_8), truncated: false)
          end

          size = File.size(@temp_file_path)
          content = File.binread(@temp_file_path).force_encoding(Encoding::UTF_8)
          return FullOutput.new(content:, truncated: false) if size <= max_bytes

          head_bytes = max_bytes / 2
          tail_bytes = max_bytes - head_bytes
          head = content.byteslice(0, head_bytes).scrub
          tail_byteslice = content.byteslice(size - tail_bytes, tail_bytes)
          tail_start = 0
          tail_start += 1 while tail_start < tail_byteslice.bytesize && continuation_byte?(tail_byteslice, tail_start)
          tail = tail_byteslice.byteslice(tail_start, tail_byteslice.bytesize - tail_start).scrub
          omitted = size - head_bytes - tail_bytes
          FullOutput.new(content: "#{head}\n\n[... #{omitted} bytes omitted ...]\n\n#{tail}", truncated: true)
        end
      end

      def last_line_bytes
        @current_line_bytes
      end

      def temp_file_path
        @temp_file_path
      end

      # Removes the spill file if one was never needed by the caller.
      def close_temp_file
        @mutex.synchronize do
          return unless @temp_file_path

          File.delete(@temp_file_path)
        rescue StandardError
          nil
        ensure
          @temp_file_path = nil
        end
      end

      private

      def continuation_byte?(buf, index)
        (buf.getbyte(index) & 0xc0) == 0x80
      end

      def append_decoded_text(text)
        return if text.empty?

        bytes = text.bytesize
        @total_decoded_bytes += bytes
        @tail_text << text
        @tail_bytes += bytes
        trim_tail if @tail_bytes > @max_rolling_bytes * 2

        newlines = text.count("\n")
        last_newline = text.rindex("\n")
        if newlines.zero?
          @current_line_bytes += bytes
          @has_open_line = true
        else
          @completed_lines += newlines
          tail = text[(last_newline + 1)..]
          @current_line_bytes = tail.bytesize
          @has_open_line = !tail.empty?
        end
        @total_lines = @completed_lines + (@has_open_line ? 1 : 0)
      end

      def trim_tail
        buffer = @tail_text.dup.force_encoding(Encoding::BINARY)
        return if buffer.bytesize <= @max_rolling_bytes

        start = buffer.bytesize - @max_rolling_bytes
        start += 1 while start < buffer.bytesize && continuation_byte?(buffer, start)
        @tail_starts_at_line_boundary = start.zero? ? @tail_starts_at_line_boundary : buffer.getbyte(start - 1) == 0x0a
        @tail_text = buffer.byteslice(start, buffer.bytesize - start).force_encoding(Encoding::UTF_8).scrub
        @tail_bytes = @tail_text.bytesize
      end

      def snapshot_text
        return @tail_text if @tail_starts_at_line_boundary

        first_newline = @tail_text.index("\n")
        first_newline.nil? ? @tail_text : @tail_text[(first_newline + 1)..]
      end

      def should_use_temp_file?
        @total_raw_bytes > @max_bytes || @total_decoded_bytes > @max_bytes || @total_lines > @max_lines
      end

      def ensure_temp_file
        return if @temp_file_path

        @temp_file_path = File.join(Dir.tmpdir, "#{@temp_file_prefix}-#{Process.pid}-#{SecureRandom.hex(4)}.log")
        File.binwrite(@temp_file_path, @raw_chunks.join)
        @raw_chunks = []
      end
    end
  end
end
