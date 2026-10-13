# frozen_string_literal: true

require_relative "safe_execute"

module Tart
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

      # Cadence of the coordinator's deadline/cancellation checkpoints while a
      # command runs. Exit detection is evented (see spawn_and_stream); this
      # bounds only how fast a timeout -TERM fires and an interrupt is
      # observed (pi checks signal.aborted between events).
      CHECKPOINT_INTERVAL = 0.05

      # The session-env suffixes the TOOL path scrubs + exposes (pi's five,
      # docs/environment-variables.md "Shell Tool Session Environment");
      # the child keys are <IDENTITY>_<SUFFIX> under the resolved face.
      SESSION_ENV_SUFFIXES = %w[SESSION_ID SESSION_FILE PROVIDER MODEL REASONING_LEVEL].freeze

      attr_reader :cwd, :details

      # The raw execution outcome (pi bash-executor.ts BashResult shape —
      # the fields the !-prefix executor reports; the tool's contract is
      # the model-facing text on top of the same core).
      BashOutcome = Struct.new(:content, :exit_code, :cancelled, :truncation, :full_output_path,
                               keyword_init: true)

      # @param cwd [String] working directory.
      # @param identity [String] the resolved face — the child env keys ride
      #   its namespace (pi PI_*, tart TART_*, foo FOO_*).
      # @param session_env [Hash{String => Proc}] SUFFIX → reader, resolved
      #   AT SPAWN (pi resolves per command start — a mid-session model
      #   switch or level change reaches the next command); a nil reader
      #   value leaves its var unset. The launcher wires the live readers
      #   ({Tools::Registry.build} threads it here).
      def initialize(cwd:, identity: Identity::DEFAULT, session_env: {})
        @cwd = cwd
        @identity = identity
        @session_env = session_env
        @details = nil
      end

      description DESCRIPTION

      parameters PARAMETERS_SCHEMA.dup

      # The user-bash executor (pi bash-executor.ts executeBashWithOperations
      # — the !-prefix executor over the same spawn core as the tool):
      # pi's BashResult assembly — sanitized (the port strips \r; pi also
      # strips ANSI, cut — no ansi utility, itemized), exit code,
      # cancellation — NO model-facing notice, NO error wrapping (a
      # non-zero exit REPORTS, it does not raise into an error result;
      # bash-executor.ts:146-158). No timeout: pi's user bash runs until
      # done or esc-cancelled. An aborted command still returns the
      # output it produced so far (bash-executor.ts:135-141).
      #
      # @param on_chunk [Proc, nil] +call(text)+ per pipe read, the text
      #   CR-REMOVED — the same rule the returned content applies, applied
      #   per chunk (pi executeBashWithOperations fires onChunk with the
      #   sanitized text, bash-executor.ts:96-98; the port's sanitize is
      #   the CR strip alone — ANSI stays the itemized cut, so mid-flight
      #   bytes agree with the settled ones). pi's executor skips empty
      #   sanitized text; the port's strip-only rule makes an empty call a
      #   no-op downstream, so the seam fires per read unconditionally.
      #   Fires from the reader threads — push-only work (the bridge
      #   queue), never render state.
      def run_user(command, on_chunk: nil)
        raise Errno::ENOENT, "Working directory does not exist: #{@cwd}\nCannot execute bash commands." unless
          File.exist?(@cwd)

        # The accumulator is owned HERE (not inside the spawn helper) so a
        # cancellation — the raise arrives while the helper's frame is
        # live — still leaves the partial output reachable: the aborted
        # command returns the output it produced so far
        # (bash-executor.ts:135-141). The spawn core's rescue has already
        # killed the process group on the way out.
        output = OutputAccumulator.new(temp_file_prefix: "tart-bash")
        cancelled = false
        outcome =
          begin
            spawn_and_stream(command, output, nil, on_chunk:)
          rescue RubyLLM::CancelledError, Async::Cancel
            cancelled = true
            {exit_code: nil}
          end
        snapshot = finish_output(output)
        BashOutcome.new(content: snapshot.content.to_s.gsub("\r", ""), exit_code: outcome[:exit_code],
                        cancelled:, truncation: snapshot.truncation,
                        full_output_path: snapshot.full_output_path)
      end

      # @return [String] combined output (pi's model-facing text), or
      #   {error:} on failure — including timeout and non-zero exit, which pi
      #   reports as error results with a status line appended.
      def execute(command:, timeout: nil)
        safe_execute do
          timeout_seconds = resolve_timeout(timeout)
          raise Errno::ENOENT, "Working directory does not exist: #{@cwd}\nCannot execute bash commands." unless
            File.exist?(@cwd)

          started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          output, outcome = spawn_and_accumulate(command, timeout_seconds)
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

      # Spawns, streams to completion (or cancellation/timeout), and
      # returns the accumulator with the raw outcome — the caller finishes
      # and snapshots (the tool's model-facing assembly and the user-bash
      # executor's BashResult assembly differ).
      def spawn_and_accumulate(command, timeout_seconds)
        output = OutputAccumulator.new(temp_file_prefix: "tart-bash")
        # No on_chunk: the model-facing execute render is the I34 pending
        # block — pi's tool path streams no chunk callback either.
        outcome = spawn_and_stream(command, output, timeout_seconds, env: session_env_for_spawn)
        [output, outcome]
      end

      def resolve_timeout(timeout)
        return if timeout.nil?
        raise ArgumentError, "Invalid timeout: must be a finite number of seconds" unless
          timeout.is_a?(Numeric) && timeout.finite? && timeout.positive?

        timeout
      end

      # pi resolveSpawnContext (bash.ts:186-208): a COPY of the parent env
      # with THIS identity's five keys scrubbed FIRST — inherited parent
      # values never leak, even when a reader nils; the scrub is
      # prefix-scoped (pi deletes only its own five PI_*, so a port nested
      # in a real pi parent still sees the parent's PI_*). Then each truthy
      # reader value sets <IDENTITY>_<SUFFIX>. run_user never calls this
      # (pi's user-bash executor passes no env and never scrubs).
      def session_env_for_spawn
        env = ENV.to_h
        SESSION_ENV_SUFFIXES.each { |suffix| env.delete(Identity.env_key(@identity, suffix)) }
        @session_env.each do |suffix, reader|
          value = reader.call
          env[Identity.env_key(@identity, suffix)] = value if value
        end
        env
      end

      def spawn_and_stream(command, output, timeout_seconds, on_chunk: nil, env: nil)
        out_rd, out_wr = IO.pipe
        err_rd, err_wr = IO.pipe
        pid = nil
        reaper = nil
        timed_out = false

        begin
          if env
            # The tool path: the composed hash IS the child env —
            # unsetenv_others makes the scrub real (no inherited copy
            # bleeds through).
            pid = Process.spawn(env, "/bin/bash", "-c", command, chdir: @cwd, pgroup: true,
                                in: File::NULL, out: out_wr, err: out_wr, unsetenv_others: true)
          else
            # Plain inheritance: run_user (pi's user-bash executor, no env).
            pid = Process.spawn("/bin/bash", "-c", command, chdir: @cwd, pgroup: true,
                                in: File::NULL, out: out_wr, err: out_wr)
          end
          out_wr.close
          err_wr.close

          # One reader per output pipe (pi: one fiber per pipe).
          readers = [Thread.new { drain_pipe(out_rd, output, on_chunk) },
                     Thread.new { drain_pipe(err_rd, output, on_chunk) }]

          deadline = timeout_seconds && Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_seconds

          # Evented exit detection (pi's child "exit" event, bash.ts:112 —
          # Node learns of exit without polling). Ruby has no evented child
          # exit, so the idiomatic analog: a dedicated reaper thread does a
          # BLOCKING Process.waitpid2 and hands the status over a Queue — the
          # pop below returns the moment the child exits, so fast commands pay
          # no poll quantum. The bounded pop keeps the deadline and
          # cancellation checkpoints ticking while the command runs
          # (cancellation is cooperative: the checkpoint raises in this
          # thread, so the wait must yield).
          completed = Queue.new
          reaper = Thread.new { completed << Process.waitpid2(pid)[1] }
          status = nil
          term_sent = false
          killed = false
          loop do
            # Cancellation checkpoint: an interrupted turn kills the whole
            # process group (pi checks signal.aborted between events).
            RubyLLM::Support::Cancellation.check
            status = completed.pop(timeout: CHECKPOINT_INTERVAL)
            break if status

            now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            next unless deadline && now >= deadline
            unless term_sent
              timed_out = true
              term_sent = true
              # I03 backlog carry-in: -TERM exactly once, then a single -KILL
              # once the grace elapses (the escalation is what ends the
              # command).
              kill_process_group(pid, "TERM")
            end
            next if killed || now <= deadline + TERM_GRACE_SECONDS

            killed = true
            kill_process_group(pid, "KILL")
          end
          readers.each(&:join)
          RubyLLM::Support::Cancellation.check

          exit_code = status.termsig ? 128 + status.termsig : status.exitstatus
          {exit_code:, timed_out:, cancelled: false}
        rescue RubyLLM::CancelledError, Async::Cancel
          # Interrupted mid-command: kill the whole group with a single -KILL
          # and let cancellation propagate. The reaper thread reaps — this
          # thread must not waitpid2 the pid itself (the reaper owns it; a
          # second wait would raise ECHILD). Both cancellation classes:
          # the agent-loop cancel rides RubyLLM's checkpoint error; the
          # user-bash escape cancels the reactor task itself (Task#stop —
          # Async::Cancel at the fiber's next yield), same group kill.
          kill_process_group(pid, "KILL") if pid
          reaper&.join(TERM_GRACE_SECONDS)
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

      def drain_pipe(io, output, on_chunk)
        loop do
          io.wait_readable(0.1) or next
          data = io.read_nonblock(65_536, exception: false)
          break if data.nil? # EOF

          output.append(data)
          # The chunk seam (pi onChunk per pipe data event): CR-REMOVED —
          # commutes with the string-buffer join and with tail-truncation's
          # line accounting, so mid-flight rows agree with the settled block.
          on_chunk&.call(data.gsub("\r", ""))
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
