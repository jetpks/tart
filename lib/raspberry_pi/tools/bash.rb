# frozen_string_literal: true

require_relative "safe_execute"

module RaspberryPi
  module Tools
    # The bash tool (port of pi's bash.ts). Spawns the command in its own
    # process group (`pgroup: true`), streams stdout and stderr — one reader
    # thread per pipe, the Ruby analog of pi's per-pipe fiber — and kills
    # timed-out or aborted commands by negative-pid -TERM escalating to
    # -KILL, reaping every pid. Output is truncated to the last 2000 lines or
    # 50KB (whichever is hit first); full output spills to a temp file.
    class Bash < RubyLLM::Tool
      include SafeExecute

      pi_name "bash"

      DESCRIPTION = "Execute a bash command in the current working directory. Returns stdout and stderr. " \
        "Output is truncated to last 2000 lines or 50KB (whichever is hit first). If truncated, full output " \
        "is saved to a temp file. Optionally provide a timeout in seconds."

      PARAMETERS_SCHEMA = {
        type: "object",
        properties: {
          "command" => {type: "string", description: "Shell command to execute"},
          "timeout" => {type: "number", description: "Timeout in seconds (optional, no default timeout)"}
        },
        required: ["command"]
      }.freeze

      # Grace after -TERM before escalating to -KILL (pi's killProcessTree is
      # single-phase -KILL; the two-phase kill is this spec's AC4 mandate,
      # raised as a parity deviation).
      TERM_GRACE_SECONDS = 5.0

      attr_reader :cwd, :details

      def initialize(cwd:)
        @cwd = cwd
        @details = nil
      end

      description DESCRIPTION

      parameters PARAMETERS_SCHEMA.dup

      # @return [String] combined output (pi's model-facing text), or
      #   {error:} on failure — including timeout and non-zero exit, which pi
      #   reports as error results with a status line appended.
      def execute(command:, timeout: nil)
        safe_execute do
          timeout_seconds = resolve_timeout(timeout)
          raise Errno::ENOENT, "Working directory does not exist: #{@cwd}\nCannot execute bash commands." unless
            File.exist?(@cwd)

          output = OutputAccumulator.new(temp_file_prefix: "raspberry-pi-bash")
          started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          outcome = spawn_and_stream(command, output, timeout_seconds)
          wall_time_seconds = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at).round(1)
          snapshot = finish_output(output)

          exit_code = outcome[:exit_code]
          text = format_output(snapshot, output, "(no output)")

          if outcome[:timed_out]
            return {error: append_status(text, "Command timed out after #{timeout} seconds")}
          end
          if outcome[:cancelled]
            return {error: append_status(text, "Command aborted")}
          end

          @details = {}
          @details[:truncation] = snapshot.truncation.to_h if snapshot.truncation.truncated
          @details[:full_output_path] = snapshot.full_output_path
          @details[:exit_code] = exit_code
          @details[:wall_time_seconds] = wall_time_seconds
          if exit_code.nil?
            return {error: append_status(text, "Command terminated without an exit code")}
          end
          if exit_code != 0
            return {error: append_status(text, "Command exited with code #{exit_code}")}
          end

          text
        end
      end

      private

      def resolve_timeout(timeout)
        return if timeout.nil?
        raise ArgumentError, "Invalid timeout: must be a finite number of seconds" unless
          timeout.is_a?(Numeric) && timeout.finite? && timeout.positive?

        timeout
      end

      def spawn_and_stream(command, output, timeout_seconds)
        out_rd, out_wr = IO.pipe
        err_rd, err_wr = IO.pipe
        pid = nil
        timed_out = false

        begin
          pid = Process.spawn("/bin/bash", "-c", command, chdir: @cwd, pgroup: true,
                              in: File::NULL, out: out_wr, err: out_wr)
          out_wr.close
          err_wr.close

          # One reader per output pipe (pi: one fiber per pipe).
          readers = [Thread.new { drain_pipe(out_rd, output) }, Thread.new { drain_pipe(err_rd, output) }]

          deadline = timeout_seconds && Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_seconds
          status = nil
          loop do
            # Cancellation checkpoint: an interrupted turn kills the whole
            # process group (pi checks signal.aborted between events).
            RubyLLM::Support::Cancellation.check
            now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            if deadline && now >= deadline
              timed_out = true
              kill_process_group(pid, "TERM")
              kill_process_group(pid, "KILL") if now > deadline + TERM_GRACE_SECONDS
            end
            _, status = Process.waitpid2(pid, Process::WNOHANG)
            break if status

            sleep 0.05
          end
          readers.each(&:join)
          RubyLLM::Support::Cancellation.check

          exit_code = status.termsig ? 128 + status.termsig : status.exitstatus
          {exit_code:, timed_out:, cancelled: false}
        rescue RubyLLM::CancelledError
          # Interrupted mid-command: kill the whole group (TERM then, on the
          # grace elapsing, KILL), reap, and let cancellation propagate.
          kill_process_group(pid, "TERM") if pid
          kill_process_group(pid, "KILL") if pid
          Process.waitpid2(pid) if pid
          raise
        ensure
          readers&.each { |t| t.join(1) rescue nil }
          out_rd.close rescue nil
          err_rd.close rescue nil
        end
      end

      # Negative-pid kill hits the whole group; fall back to the child alone
      # if the group is gone (pi's killProcessTree fallback, signal per AC4).
      def kill_process_group(pid, signal)
        Process.kill("-#{signal}", pid)
      rescue Errno::ESRCH, Errno::EPERM
        begin
          Process.kill(signal, pid)
        rescue Errno::ESRCH, Errno::EPERM
          nil
        end
      end

      def drain_pipe(io, output)
        loop do
          io.wait_readable(0.1) or next
          data = io.read_nonblock(65_536, exception: false)
          break if data.nil? # EOF

          output.append(data)
        end
      rescue StandardError
        nil
      ensure
        io.close rescue nil
      end

      def finish_output(output)
        output.finish
        # The temp spill file persists (pi keeps it: the model-facing notice
        # points at the full-output path).
        output.snapshot(persist_if_truncated: true)
      end

      # pi's formatOutput: tail-truncated output gets a showing-lines notice
      # with the full-output path.
      def format_output(snapshot, output, empty_text)
        truncation = snapshot.truncation
        text = snapshot.content.empty? ? empty_text : snapshot.content
        return text unless truncation.truncated

        start_line = truncation.total_lines - truncation.output_lines + 1
        end_line = truncation.total_lines
        notice = if truncation.last_line_partial
          last_line_size = Truncate.format_size(output.last_line_bytes)
          "[Showing last #{Truncate.format_size(truncation.output_bytes)} of line #{end_line} " \
            "(line is #{last_line_size}). Full output: #{snapshot.full_output_path}]"
        elsif truncation.truncated_by == "lines"
          "[Showing lines #{start_line}-#{end_line} of #{truncation.total_lines}. " \
            "Full output: #{snapshot.full_output_path}]"
        else
          "[Showing lines #{start_line}-#{end_line} of #{truncation.total_lines} " \
            "(#{Truncate.format_size(Truncate::DEFAULT_MAX_BYTES)} limit). Full output: #{snapshot.full_output_path}]"
        end
        "#{text}\n\n#{notice}"
      end

      def append_status(text, status)
        text.empty? ? status : "#{text}\n\n#{status}"
      end
    end
  end
end
