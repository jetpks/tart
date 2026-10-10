# frozen_string_literal: true

require_relative "bridge"
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
    # Events (minimal surface, pi's AgentEvent vocabulary): :agent_start,
    # :turn_start, :message_start, :message_update (streamed chunks),
    # :message_end, :tool_execution_start, :tool_execution_end, :turn_end,
    # :agent_end.
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
      def initialize(chat:, tools:, system_prompt: nil, on_event: nil, approval: nil)
        @chat = chat
        @tools = tools
        @on_event = on_event
        @approval = approval
        @new_messages = []
        @sink = nil
        @stream_started = false
        @steering_queue = Queue.new
        @last_error = nil
        @interrupted = false

        @chat.with_tools(*tools.values) unless tools.empty?
        @chat.with_instructions(system_prompt) if system_prompt
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
              break
            end

            pending.each { |text| add_user_message(text) }
          end
          # Assistant message with tool calls: the batch executes on the
          # next step.
        end
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
          # Tool results are recorded by the :tool_message item (ruby_llm's
          # after_message); the step's own return would double-count them.
          unless message.role == :tool
            strip_thinking_replay(message)
            @new_messages << message
            emit(type: :message_end, message:) if message.role == :assistant
          end
        when :tool_message
          @new_messages << item[:message]
          emit(type: :message_start, message: item[:message])
          emit(type: :message_end, message: item[:message])
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
      # turn after a thinking reply. pi does not build replay from reasoning
      # deltas either way (packages/ai/src/api/openai-completions.ts
      # convertMessages); the port suppresses it outright (deviation itemized
      # in the iteration record). Mirrors the gem's own without_native_content
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
