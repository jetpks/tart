# frozen_string_literal: true

require_relative "../compaction"
require_relative "bridge"
require_relative "session"
require_relative "status"
require_relative "system_prompt"

module RaspberryPi
  module Agent
    # The agent loop (port of pi's agent-loop.ts runAgentLoop/runLoop shape,
    # mapped onto ruby_llm 2.1 and the I02 kernel).
    #
    # pi's shape, preserved:
    # - outer loop: continues while queued user (steering/follow-up) messages
    #   arrive after the agent would stop;
    # - inner loop: model turn, then tool-call batches (ruby_llm's
    #   pending-tool-call execution on #step), until the model answers
    #   without tool calls;
    # - an aborted turn emits turn_end/agent_end and stops.
    #
    # Kernel mapping: the loop runs as the work block (task subtree) on
    # {Core::Loop}; a kernel interrupt (Ctrl+C or the INT trap net) cancels
    # the in-flight turn — the waiting fiber gets Async::Cancel, the chat is
    # cancelled (tools kill their subprocess groups at the next checkpoint),
    # and the cancel propagates.
    #
    # Events (minimal surface, pi's AgentEvent vocabulary plus a compaction
    # event): :agent_start, :turn_start, :message_start, :message_update
    # (streamed chunks), :message_end, :tool_execution_start,
    # :tool_execution_end, :turn_end, :compaction, :agent_end.
    #
    # Compaction (pi's auto-compaction, agent-session.ts:3007-3219): after
    # a completed turn, provider-reported context usage over the model's
    # context window minus the reserve compacts ("threshold"); a step that
    # fails with RubyLLM::ContextLengthExceededError omits the attempt (the
    # gem never appends the failed response), compacts and retries the turn
    # once ("overflow", latched — a second consecutive overflow surfaces as
    # the error). The compaction entry goes to the session recorder; the
    # chat history is replaced in place with [summary message, kept tail].
    class Loop
      # @param chat [RubyLLM::Chat] configured for the endpoint (model,
      #   provider, protocol).
      # @param tools [Hash{String => RubyLLM::Tool}] the gated loadout
      #   ({Tools::Registry.build}); disabled tools are never registered.
      # @param system_prompt [String, nil] set as the chat's instructions.
      # @param on_event [Proc, nil] called with each event Hash.
      # @param approval [Proc, nil] the injectable approval callback: called
      #   on the kernel fiber (interruptible) with each
      #   +RubyLLM::ToolCall+ that requires approval; +true+ approves,
      #   +false+ denies. Only consulted for tools that gate.
      # @param recorder [Session::Recorder, nil] the optional session
      #   recorder (pi's SessionManager, message subset): every message this
      #   run adds is appended to the session file in order; +nil+ = off.
      # @param seed_messages [Array<Hash, RubyLLM::Message>] prior context
      #   messages to seed the chat with before the run (resume:
      #   Agent::Session.context_messages) — the model sees them on the
      #   wire, they are never re-recorded as new messages.
      # @param context_window [Integer, nil] the model's context window,
      #   overriding the resolution order RASPBERRY_PI_CONTEXT_WINDOW →
      #   chat.model.context_window → nil (nil/<= 0 disables the threshold
      #   trigger only; the overflow trigger always fires).
      # @param compaction [Hash, Compaction::Settings, nil] compaction
      #   settings ({enabled:, reserve_tokens:, keep_recent_tokens:});
      #   nil = pi's defaults (enabled, reserve 16384, keep-recent 20000).
      def initialize(chat:, tools:, system_prompt: nil, on_event: nil, approval: nil,
        recorder: nil, seed_messages: [], context_window: nil, compaction: nil)
        @chat = chat
        @tools = tools
        @on_event = on_event
        @approval = approval
        @recorder = recorder
        @context_window = context_window
        @compaction_settings = Compaction::Settings.resolve(compaction)
        @overflow_recovery_attempted = false
        @entry_ids = {}.compare_by_identity
        @new_messages = []
        @sink = nil
        @stream_started = false
        @steering_queue = Queue.new
        @last_error = nil
        @interrupted = false

        @chat.with_tools(*tools.values) unless tools.empty?
        @chat.with_instructions(system_prompt) if system_prompt
        seed_messages.each { |message| @chat.add_message(message) }
        install_chat_callbacks
      end

      # Queues a user message. While the agent runs, it is consumed at the
      # next turn boundary (pi's steering queue); queued messages left after
      # the loop would stop continue it (pi's follow-up queue) — one queue,
      # pi's two consumption points.
      def push_message(text)
        @steering_queue << text
        self
      end

      # @return [Boolean] whether steering messages are queued but not yet
      #   consumed (thread-safe; the chat surface checks it on agent_end to
      #   close the submit/stop race).
      def queued_messages?
        !@steering_queue.empty?
      end

      # Runs the agent to completion of the prompt and every queued message.
      # Must be called on the kernel reactor fiber (as the Core::Loop work
      # block): every model/tool step is bridged to a worker thread and this
      # fiber waits interruptibly.
      #
      # @return [Array<RubyLLM::Message>] the messages added by this run.
      def run(prompt = nil)
        @new_messages = []
        @last_error = nil
        @interrupted = false
        emit(type: :agent_start)

        begin
          run_loop(prompt)
        rescue Async::Cancel
          @interrupted = true
          emit(type: :turn_end, interrupted: true)
          emit(type: :agent_end, interrupted: true, messages: new_messages)
          raise
        end

        emit(type: :agent_end, interrupted: false, messages: new_messages) unless @last_error
        new_messages
      end

      # @return [Boolean] whether a kernel interrupt cancelled the run.
      def interrupted?
        @interrupted
      end

      # @return [RubyLLM::Error, StandardError, nil] the error that stopped
      #   the last run, if any (pi's stopReason "error").
      def last_error
        @last_error
      end

      # @return [Array<RubyLLM::Message>] messages added by the last run.
      def new_messages
        @new_messages.dup
      end

      private

      # Session recording (pi SessionManager.appendMessage): the recorder
      # appends each new message as a message entry, in conversation order.
      # The entry id is kept for the message so a later compaction can name
      # its first-kept entry (pi's firstKeptEntryId).
      def record(message)
        entry_id = @recorder&.append_message(message)
        @entry_ids[message] = entry_id if entry_id
        entry_id
      end

      def run_loop(prompt)
        # Outer loop (pi): keep going while queued messages keep arriving.
        # pi also polls the steering queue at loop start (agent-loop.ts:175:
        # "user may have typed while waiting"); the port consumes pre-run
        # queued messages there only when no prompt opens the run — with a
        # prompt they are consumed at the first turn boundary (I03-locked:
        # test_queued_message_continues_the_outer_loop, two requests), a
        # recorded parity deviation.
        first = true
        loop do
          emit(type: :turn_start)
          if first && prompt
            add_user_message(prompt)
          else
            steering_messages.each { |text| add_user_message(text) }
          end
          first = false
          inner_loop
          break if steering_messages.empty?
        end
      end

      # Inner loop (pi): model turn, then tool-call batches, until the model
      # answers without tool calls and no steering messages wait.
      def inner_loop
        loop do
          message = step_via_bridge
          next if handle_pause
          next if recover_overflow?

          # The error check precedes the nil-message break: a step the worker
          # failed before producing a message (e.g. the request itself 400s)
          # must surface through the error path, not stop silently.
          return if stopped_on_error?
          break if message.nil?

          if message.role == :tool
            next # tool batch executed; the model responds on the next step
          elsif @chat.complete?
            pending = steering_messages
            if pending.empty?
              emit(type: :turn_end, message:)
              run_threshold_compaction
              break
            end

            pending.each { |text| add_user_message(text) }
          end
          # Assistant message with tool calls: the batch executes on the
          # next step.
        end
      end

      # pi _checkCompaction's overflow branch (agent-session.ts:3007-3047):
      # a context-overflow step failure compacts and retries the turn once;
      # the second consecutive overflow surfaces as the error
      # (_overflowRecoveryAttempted, :3040). The latch resets on a clean
      # assistant response (:1168-1171). The gem never appends a failed
      # response to chat.messages (chat.rb: provider_completion raises
      # before record_generated_message), so the overflowing attempt is
      # already omitted. False here lets stopped_on_error? surface it.
      def recover_overflow?
        return false unless @last_error.is_a?(RubyLLM::ContextLengthExceededError)
        return false if @overflow_recovery_attempted

        @overflow_recovery_attempted = true
        return false unless run_compaction(reason: :overflow)

        @last_error = nil
        true
      end

      # pi _checkCompaction Case 3 (agent-session.ts:3079-3083): after a
      # completed turn, provider-reported usage vs the model's context
      # window and the reserve.
      def run_threshold_compaction
        return unless threshold_exceeded?

        run_compaction(reason: :threshold)
      end

      def threshold_exceeded?
        window = resolved_context_window
        return false unless window.is_a?(Integer) && window.positive?

        estimate = Compaction.estimate_context_tokens(@chat.messages)
        Compaction.should_compact?(estimate[:tokens], window, @compaction_settings)
      end

      # Explicit kwarg → RASPBERRY_PI_CONTEXT_WINDOW → chat.model.context_
      # window → nil. The gem's assume_model_exists resolution lands on
      # Model.default, which carries no context_window (models.rb:210,
      # model.rb:65-75) — nil disables the threshold trigger only.
      def resolved_context_window
        return @context_window if @context_window

        env = ENV["RASPBERRY_PI_CONTEXT_WINDOW"]
        return Integer(env, 10) if env&.match(/\A\d+\z/)

        @chat.model&.context_window
      end

      # pi _runAutoCompaction (agent-session.ts:3097-3219) on the flat chat
      # history: prepare → summarize (the standalone one-shot call) →
      # replace the history with [summary message, kept tail] → record the
      # compaction entry → emit the compaction event. Returns whether a
      # compaction happened.
      def run_compaction(reason:)
        preparation = Compaction.prepare(@chat.messages, @compaction_settings)
        return false unless preparation

        summary = summarize(preparation)
        return false unless summary

        lists = Compaction.compute_file_lists(
          Compaction.extract_file_ops(preparation.messages_to_summarize)
        )
        summary += Compaction.format_file_operations(lists[:read_files], lists[:modified_files])

        keep_from = preparation.first_kept_index
        system_messages = @chat.messages.select { |message| message.role == :system }
        kept = @chat.messages[keep_from..] || []
        summary_message = @chat.add_message(role: :user, content: compaction_summary_content(summary))
        @chat.messages = [*system_messages, summary_message, *kept]

        @recorder&.append_compaction(
          summary:,
          first_kept_entry_id: @entry_ids[kept.first],
          tokens_before: preparation.tokens_before,
          # pi CompactionDetails (compaction.ts:37-40).
          details: {"readFiles" => lists[:read_files], "modifiedFiles" => lists[:modified_files]},
        )
        emit(type: :compaction, reason:, tokens_before: preparation.tokens_before, summary:)
        true
      end

      def compaction_summary_content(summary)
        "#{Compaction::COMPACTION_SUMMARY_PREFIX}#{summary}#{Compaction::COMPACTION_SUMMARY_SUFFIX}"
      end

      # The standalone summarization call (pi generateSummaryWithUsage on
      # buildSummarizationContext, compaction.ts:637-647 + :671-741): a
      # fresh one-shot chat on the same context/endpoint — system =
      # SUMMARIZATION_SYSTEM_PROMPT, one user message carrying the serialized
      # conversation; not the chat history, no tools. max_tokens =
      # min(floor(0.8 * reserve_tokens), model max) (:683-686); the gem's
      # model.max_output_tokens is the model max (model.rb:36). Run through
      # the Bridge like every blocking LLM call so a kernel interrupt
      # cancels it. nil (compaction aborted) when the call fails.
      def summarize(preparation)
        prompt = Compaction.summarization_prompt(preparation.messages_to_summarize,
          previous_summary: preparation.previous_summary)
        result = nil
        summary_chat = nil
        bridge = Bridge.new
        bridge.on_cancel { summary_chat&.cancel }
        terminal = bridge.run(lambda { |_sink|
          summary_chat = build_summary_chat
          result = summary_chat.generate(prompt)
        }) { |_item| }
        return nil if terminal.is_a?(Hash) && terminal[:type] == :error

        result.content
      end

      def build_summary_chat
        chat = @chat.context.chat(model: @chat.model&.id, provider: @chat.provider&.slug,
                                  assume_model_exists: true)
        chat.with_instructions(Compaction::SUMMARIZATION_SYSTEM_PROMPT)
        chat.with_max_output_tokens(summarization_max_tokens)
        chat
      end

      def summarization_max_tokens
        reserve = @compaction_settings.reserve_tokens
        model_max = @chat.model&.max_output_tokens
        cap = model_max.is_a?(Integer) && model_max.positive? ? model_max : Float::INFINITY
        [(reserve * 0.8).floor, cap].min
      end

      # One ruby_llm #step on the worker thread. Returns the step's message
      # (assistant message or tool result), or nil when the step produced no
      # message (approval pause, chat pause).
      def step_via_bridge
        bridge = Bridge.new
        bridge.on_cancel { @chat.cancel }
        @last_message = nil
        @stream_started = false
        terminal = bridge.run(work_callable) { |item| handle_item(item) }
        @sink = nil
        record_terminal_error(terminal)
        @last_message
      end

      def work_callable
        lambda { |sink|
          @sink = sink
          message = @chat.step do |chunk|
            sink.call({type: :chunk, chunk:})
          end
          sink.call({type: :step, message:}) if message
        }
      end

      # @return [Boolean] whether the loop must pause for an approval
      #   decision (recorded here, on the kernel fiber).
      def handle_pause
        return false unless @chat.waiting? && @chat.awaiting_approval?

        @chat.pending_approvals.each do |tool_call|
          decision = @approval ? @approval.call(tool_call) : false
          decision ? @chat.approve(tool_call) : @chat.deny(tool_call)
        end
        true
      end

      def record_terminal_error(terminal)
        return unless terminal.is_a?(Hash) && terminal[:type] == :error

        @last_error = terminal[:error]
        message = @last_message
        emit(type: :message_end, message:, error: true) if message&.role == :assistant
      end

      def stopped_on_error?
        return false unless @last_error

        emit(type: :turn_end, message: @last_message, error: true)
        emit(type: :agent_end, interrupted: false, error: @last_error, messages: new_messages)
        true
      end

      # Drains queued steering messages (thread-safe consumer side).
      def steering_messages
        messages = []
        loop do
          begin
            messages << @steering_queue.pop(true)
          rescue ThreadError
            break
          end
        end
        messages
      end

      def add_user_message(text)
        message = @chat.add_message(role: :user, content: text)
        @new_messages << message
        emit(type: :message_start, message:)
        emit(type: :message_end, message:)
        record(message)
        message
      end

      def install_chat_callbacks
        @chat.before_tool_call do |tool_call|
          # ruby_llm calls after_tool_result with the result only (chat.rb:
          # run_callbacks(:after_tool_result, result)); pair the call back by
          # fiber/thread-local — before and after run in the same execution
          # context, per call, in both of ToolConcurrency's modes.
          Thread.current[:raspberry_pi_tool_call] = tool_call
          @sink&.call({type: :tool_execution_start, tool_call:})
        end
        @chat.after_tool_result do |result|
          @sink&.call({type: :tool_execution_end,
                       tool_call: Thread.current[:raspberry_pi_tool_call], result:})
        end
        @chat.after_message do |message|
          # Tool result messages appear atomically; streamed assistant
          # messages get their events from the chunk flow and step handling.
          @sink&.call({type: :tool_message, message:}) if message.role == :tool
        end
      end

      def handle_item(item)
        case item[:type]
        when :chunk
          chunk = item[:chunk]
          unless @stream_started
            @stream_started = true
            emit(type: :message_start, message: chunk)
          end
          emit(type: :message_update, chunk:)
        when :step
          @stream_started = false
          message = item[:message]
          @last_message = message
          # A clean assistant response resets the overflow-recovery latch
          # (pi agent-session.ts:1168-1171).
          @overflow_recovery_attempted = false if message.role == :assistant
          # Tool results are recorded by the :tool_message item (ruby_llm's
          # after_message); the step's own return would double-count them.
          unless message.role == :tool
            strip_thinking_replay(message)
            @new_messages << message
            emit(type: :message_end, message:) if message.role == :assistant
            record(message)
          end
        when :tool_message
          @new_messages << item[:message]
          emit(type: :message_start, message: item[:message])
          emit(type: :message_end, message: item[:message])
          record(item[:message])
        when :tool_execution_start
          emit(type: :tool_execution_start, tool_call: item[:tool_call])
        when :tool_execution_end
          emit(type: :tool_execution_end, tool_call: item[:tool_call], result: item[:result])
        end
      end

      def emit(event)
        @on_event&.call(event)
      end

      # ruby_llm 2.1 replays an assistant reply's thinking on every later
      # request (protocols/chat_completions/chat.rb format_thinking: both
      # `reasoning` and `reasoning_content`), which strict OpenAI-compatible
      # endpoints reject with a schema 400 (fireworks: "Extra inputs are not
      # permitted, field: 'messages[n].reasoning'") — killing every follow-up
      # turn after a thinking reply. pi, by contrast, replays the reasoning
      # field the deltas carried: chat-completions endpoints map deltas to
      # thinking blocks keyed by signature ∈ {reasoning, reasoning_content,
      # reasoning_text} (packages/ai/src/api/openai-completions.ts:611-627),
      # then send the joined thinking back as assistantMsg[signature] — unless
      # encrypted reasoning_details are preserved (:1340-1351). The port
      # suppresses it outright (deviation itemized in the iteration record).
      # Mirrors the gem's own without_native_content
      # idiom (message.rb:140-146: instance_variable_set on a live message);
      # narrower than calling without_native_content, which would also strip
      # tool-call thought signatures (message.rb:316-321).
      def strip_thinking_replay(message)
        return unless message.role == :assistant

        message.instance_variable_set(:@thinking, nil)
        message.instance_variable_set(:@raw_reasoning, nil)
      end
    end
  end
end
