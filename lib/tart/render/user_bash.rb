# frozen_string_literal: true

module Tart
  module Render
    # The !-prefix user-bash execution state machine extracted from the
    # chat surface (I24 wave 4 — pi handleBashCommand :6987 over the
    # BashExecutionComponent, backlog C): the single-flight gate, the
    # escape-cancel handshake state (the worker's cancellation checkpoint
    # flag, the reactor-side slot the worker fills), and the deferred
    # bashExecution records (pi's _pendingBashMessages, flushed on
    # agent_end). The Chat coordinator injects the seams at construction
    # (the {Picker#on_select} / {Selection#line_reader} precedent): the
    # kernel (execution + the request_draw arm), the busy reader (Chat's
    # busy? — the record-deferral gate), and the completion sinks — the
    # block render ({Chat#enqueue_user_bash_block}), the session record
    # (the agent's record_bash_execution), and the warning/error
    # scrollback lines. Unsynchronized by design: exactly the base's
    # thread assignments survive (run/cancel arrive on the frame-loop
    # fiber, the completion runs inside the kernel task).
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
      # @param stream_chunk_sink [Proc, nil] +call(text)+ — each bridged
      #   chunk, delivered on the reactor fiber (the bridge yields there;
      #   Grounds 5 — the reader threads only push queue items).
      # @param stream_end_sink [Proc, nil] +call+ — the explicit clear,
      #   fired exactly once at EVERY terminal path (the outcome arm, the
      #   worker-error arm — both at finish's entry, so the rare
      #   terminal-without-outcome shape clears too — and cancel). Never
      #   implicit in a render sink.
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
        # isBashRunning gate), the escape-cancel handshake state, and the
        # deferred records while a turn runs (pi's _pendingBashMessages).
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
      # The tool run BRIDGES to a worker thread (Agent::Bridge — the tool's
      # pop-loop blocks its thread; the reactor must keep drawing), and the
      # block renders on completion; the RECORD defers to agent_end while
      # a turn runs (pi's _pendingBashMessages — the entry must not
      # interleave a tool sequence in the record). The RUNNING block lives
      # from BEFORE execution (pi :7000-7012 — the component added to the
      # container, then requestRender) and streams its chunks over the
      # bridge queue (pi executeBash's chunkCb :7050-7057); the sinks are
      # Chat's seams — this class owns no render state.
      def run(command, excluded)
        if @task
          @line_sink.call("A bash command is already running. Press Esc to cancel it first.",
            fg: Theme[:warning])
          return
        end
        tool = Tools::Bash.new(cwd: Dir.pwd)
        # The escape-cancel handshake: the flag flips the worker's
        # cancellation checkpoint (the tool aborts at its next 50 ms
        # check — the group kill + partial-output outcome are the tool's
        # own {Tools::Bash#run_user} rescue), the task stop kills the
        # reactor-side wait, and the handler renders from the slot the
        # worker filled (read after the bridge's bounded join).
        @command = command
        @excluded = excluded
        # The running block's birth, before the task spawns (pi :7000-7012).
        @stream_start_sink&.call(command, excluded)
        @cancel_flag = false
        @slot = {}
        @task = @kernel.async do
          terminal = Agent::Bridge.new
            .on_cancel { @cancel_flag = true }
            .run(lambda do |sink|
              RubyLLM::Support::Cancellation.watch(
                -> { raise RubyLLM::CancelledError if @cancel_flag }
              ) do
                # The chunk seam: the tool's reader threads push onto the
                # bridge's thread-safe queue; the queue pops HERE on the
                # reactor and the yield block forwards (Grounds 5) — no
                # render state crosses a thread.
                outcome = tool.run_user(command, on_chunk: ->(text) { sink.call({chunk: text}) })
                @slot[:outcome] = outcome
                sink.call({})
              end
            end) { |item| @stream_chunk_sink&.call(item[:chunk]) if item[:chunk] }
          finish(terminal)
        end
      end

      # The escape-cancel (pi abortBash): flip the worker's checkpoint
      # flag, stop the reactor-side wait (the bridge joins the worker
      # bounded — its cancelled outcome, partial output included, lands
      # in the slot), then render from the slot after a bounded yield
      # loop (this handler runs in the frame-loop fiber — sleep yields).
      def cancel
        @cancel_flag = true
        @task.stop
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
        sleep 0.05 while @slot.empty? && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        outcome = @slot[:outcome]
        # The explicit clear before the block enqueues (the live rows and
        # the completed block never share a frame) — cancel is this run's
        # sole terminal path (the stopped task's finish never runs).
        @stream_end_sink&.call
        @task = nil
        @block_sink.call(@command,
          outcome ? fields(outcome) : {content: "", exit_code: nil, cancelled: true,
                                       truncated: false, full_output_path: nil},
          @excluded)
        record(build_record(@command,
          outcome || Tools::Bash::BashOutcome.new(content: "", exit_code: nil, cancelled: true,
                                                  truncation: nil, full_output_path: nil),
          excluded: @excluded))
        @kernel.request_draw
      end

      # The agent_end flush (pi's agent-end _pendingBashMessages flush).
      def flush_pending
        @pending.each { |message| @record_sink.call(message) }
        @pending.clear
      end

      private

      # The worker's terminal: the outcome rendered + recorded; a worker
      # error surfaces as an error line (the ENOENT class — no block).
      def finish(terminal)
        @task = nil
        # The explicit clear — once per run, BEFORE the completed rows
        # enqueue (AC2: the live rows and the completed block never share
        # a frame). Covers the outcome arm, the worker-error arm, and the
        # terminal-without-outcome shape alike; cancel clears its own path
        # (this method never runs there — the stopped task dies at the
        # bridge's pop).
        @stream_end_sink&.call
        if (outcome = @slot[:outcome])
          @block_sink.call(@command, fields(outcome), @excluded)
          record(build_record(@command, outcome, excluded: @excluded))
        elsif terminal&.dig(:type) == :error
          @line_sink.call("bash: #{terminal[:error].message}", fg: Theme[:error])
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
