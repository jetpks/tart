# frozen_string_literal: true

module Tart
  module Render
    # The !-prefix user-bash execution state machine extracted from the
    # chat surface (I24 wave 4 — pi handleBashCommand :6987 over the
    # BashExecutionComponent, backlog C): the single-flight gate, the
    # escape-cancel state (the tool's cancellation checkpoint flag + the
    # task stop), and the deferred bashExecution records (pi's
    # _pendingBashMessages, flushed on agent_end). The Chat coordinator
    # injects the seams at construction (the {Picker#on_select} /
    # {Selection#line_reader} precedent): the kernel (execution + the
    # request_draw arm), the busy reader (Chat's busy? — the record-deferral
    # gate), and the completion sinks — the block render
    # ({Chat#enqueue_user_bash_block}), the session record (the agent's
    # record_bash_execution), and the warning/error scrollback lines.
    # Unsynchronized by design (de-bridged I50): run/cancel arrive on the
    # frame-loop fiber, and the whole execution — tool run, chunk drainer,
    # terminal render — runs on the ONE kernel task's reactor fibers.
    class UserBash
      # pi handleSubmit :3347-3356 — "!" runs whole-line bash, "!!" runs it
      # excluded from the model context; the bare prefix (no command) is
      # plain text. Returns [command, excluded] or nil.
      def self.parse(text)
        return unless text.start_with?("!")

        excluded = text.start_with?("!!")
        command = text[(excluded ? 2 : 1)..].to_s.strip
        return if command.empty?

        [command, excluded]
      end

      # @param kernel [Core::Loop] the kernel: the worker task's +async+
      #   arm, the task's +stop+, and the completion's +request_draw+.
      # @param busy_reader [Proc] +call+ → Boolean (the coordinator's
      #   busy? — the record defers while a turn runs).
      # @param block_sink [Proc] +call(command, fields, excluded)+ — the
      #   block's transcript render on completion.
      # @param record_sink [Proc] +call(message)+ — the session record
      #   (the agent's record_bash_execution; late-bound — the agent is
      #   wired after construction).
      # @param line_sink [Proc] +call(text, fg:)+ — the single-flight
      #   warning and the worker-error line.
      # @param stream_start_sink [Proc, nil] +call(command, excluded)+ — the
      #   running block's birth, fired BEFORE the task spawns (pi adds the
      #   component to its container before execution starts,
      #   handleBashCommand :7000-7012).
      # @param stream_chunk_sink [Proc, nil] +call(text)+ — each chunk,
      #   delivered by the drainer on the kernel task's reactor fiber (the
      #   pipe-drain reader threads only push onto the chunk Queue;
      #   Grounds §3 probe5).
      # @param stream_end_sink [Proc, nil] +call+ — the explicit clear,
      #   fired exactly once at EVERY terminal path (the outcome arm, the
      #   cancelled-outcome arm, the worker-error arm — all at finish's
      #   entry, so the rare terminal-without-outcome shape clears too).
      #   Never implicit in a render sink.
      def initialize(kernel:, busy_reader:, block_sink:, record_sink:, line_sink:,
        stream_start_sink: nil, stream_chunk_sink: nil, stream_end_sink: nil)
        @kernel = kernel
        @busy_reader = busy_reader
        @block_sink = block_sink
        @record_sink = record_sink
        @line_sink = line_sink
        @stream_start_sink = stream_start_sink
        @stream_chunk_sink = stream_chunk_sink
        @stream_end_sink = stream_end_sink
        # The in-flight execution: the running task (single-flight — pi's
        # isBashRunning gate), the escape-cancel checkpoint flag, and the
        # terminal facts the task records for finish (the outcome, or a
        # worker error) + the deferred records while a turn runs (pi's
        # _pendingBashMessages).
        @task = nil
        @cancel_flag = false
        @slot = {}
        @command = nil
        @excluded = false
        @pending = []
      end

      # @return [Boolean] whether an execution is in flight (the escape
      #   routing's guard).
      def running?
        !@task.nil?
      end

      # The user-bash execution (pi handleBashCommand :6987): one at a time
      # (pi's isBashRunning gate — the warning is pi's showWarning text).
      # The tool runs INLINE on the kernel task's reactor fiber (the
      # de-bridged I50 shape — the tool's waits are cooperative, probe5),
      # and the block renders on completion; the RECORD defers to agent_end
      # while a turn runs (pi's _pendingBashMessages — the entry must not
      # interleave a tool sequence in the record). The RUNNING block lives
      # from BEFORE execution (pi :7000-7012 — the component added to the
      # container, then requestRender) and streams its chunks as they land
      # (pi executeBash's chunkCb :7050-7057); the sinks are Chat's seams —
      # this class owns no render state.
      def run(command, excluded)
        if @task
          @line_sink.call("A bash command is already running. Press Esc to cancel it first.",
            fg: Theme[:warning])
          return
        end
        tool = Tools::Bash.new(cwd: Dir.pwd)
        @command = command
        @excluded = excluded
        # The running block's birth, before the task spawns (pi :7000-7012).
        @stream_start_sink&.call(command, excluded)
        @cancel_flag = false
        @slot = {}
        # Chunks cross from the tool's pipe-drain reader threads via a plain
        # ::Queue (probe5: the pops are cooperative on a reactor fiber, and
        # the cross-thread pushes wake the drainer); the drainer — a sibling
        # task on THIS kernel task — is the only fiber that touches render
        # state. ONE finish path renders every terminal: the outcome arm
        # (including the escape-cancelled partial outcome — the Cancel lands
        # inside run_user's waits and its dual-class rescue produces the
        # cancelled outcome), the worker-error arm (a StandardError that
        # escapes run_user, e.g. the ENOENT cwd raise), and the rare
        # terminal-without-outcome shape (the clear alone).
        @task = @kernel.async do
          chunks = Queue.new
          drainer = Async::Task.current.async do
            while (item = chunks.pop) != :done
              @stream_chunk_sink&.call(item)
            end
          end
          begin
            # D10 — the Esc belt: the gem ships Cancellation.check
            # (task-cancelled) with no watch/flag pairing. The belt is a
            # tart-local flag→task bridge: a watchdog child polls the flag
            # and cancels THIS task, so the Async::Cancel lands inside
            # run_user's cooperative waits exactly where the replaced
            # client's fiber-local raise used to — and the tool's gem
            # checkpoints (task-cancelled) cover the boundaries between
            # waits. Same observable, both escape pins and the I50
            # drainer-wait Cancel guards hold.
            worker = Async::Task.current
            watchdog = Async::Task.current.async do
              sleep 0.02 until @cancel_flag
              worker.cancel
            end
            raise Fast::Completions::CancelledError, "user bash cancelled" if @cancel_flag

            begin
              @slot[:outcome] = tool.run_user(command, on_chunk: ->(text) { chunks << text })
            ensure
              watchdog.stop
            end
          rescue StandardError => e
            # The worker-error arm (invariant (c)): recorded here, rendered
            # by finish as the error line. A CancelledError never lands here
            # (run_user owns the cancelled shape — the partial outcome).
            @slot[:error] = e unless e.is_a?(Fast::Completions::CancelledError)
          ensure
            chunks << :done
            begin
              drainer.wait
            rescue Async::Cancel
              # The cancel landed at the drainer wait (the command finished
              # inside the cancel's shadow, not inside run_user's waits):
              # the stopped drainer leaves chunks queued — drain them here,
              # still finish (no chunk or terminal render is lost), then
              # honor the cancel.
              chunks.pop until chunks.empty?
              finish
              raise
            end
            finish
          end
        end
      end

      # The escape-cancel (pi abortBash): flip the tool's checkpoint flag
      # (the belt — the tool aborts at its next Cancellation.check) and stop
      # the kernel task — the Async::Cancel lands inside run_user's waits,
      # the tool's dual-class rescue produces the cancelled partial outcome,
      # and the task's own finish renders it. NOTHING else: no render, no
      # record, no wait — the unwind owns the terminal.
      def cancel
        @cancel_flag = true
        @task.stop
      end

      # The agent_end flush (pi's agent-end _pendingBashMessages flush).
      def flush_pending
        @pending.each { |message| @record_sink.call(message) }
        @pending.clear
      end

      private

      # The task's single terminal: every arm renders here, on the kernel
      # task's fiber — the outcome (including the escape-cancelled partial
      # outcome), else the worker error line, else the clear alone (the rare
      # terminal-without-outcome shape).
      def finish
        @task = nil
        # The explicit clear — once per run, BEFORE the completed rows
        # enqueue (AC2: the live rows and the completed block never share
        # a frame).
        @stream_end_sink&.call
        if (outcome = @slot[:outcome])
          @block_sink.call(@command, fields(outcome), @excluded)
          record(build_record(@command, outcome, excluded: @excluded))
        elsif (error = @slot[:error])
          @line_sink.call("bash: #{error.message}", fg: Theme[:error])
        end
        @kernel.request_draw
      end

      # The record defers while a turn runs (pi's _pendingBashMessages);
      # idle executions record immediately.
      def record(message)
        if @busy_reader.call
          @pending << message
        else
          @record_sink.call(message)
        end
      end

      # The block's primitive fields off the executor's outcome (the live
      # and replay compositions share them — pi's setComplete arguments,
      # bash-execution.ts:108-121).
      def fields(outcome)
        {content: outcome.content, exit_code: outcome.exit_code, cancelled: outcome.cancelled,
         truncated: outcome.truncation&.truncated == true,
         full_output_path: outcome.truncation&.truncated == true ? outcome.full_output_path : nil}
      end

      def build_record(command, outcome, excluded:)
        record_fields = fields(outcome)
        Agent::Session.bash_execution_message(
          command:, output: record_fields[:content], exit_code: record_fields[:exit_code],
          cancelled: record_fields[:cancelled], truncated: outcome.truncation&.truncated == true,
          full_output_path: outcome.full_output_path,
          exclude_from_context: excluded
        )
      end
    end
  end
end
