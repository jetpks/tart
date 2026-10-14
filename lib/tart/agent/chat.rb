# frozen_string_literal: true

require "async"
require "json"
require_relative "../models"
require_relative "message"

module Tart
  module Agent
    # The conversation object (Specification §1): tart's ONE chat, wrapping
    # {Fast::Completions::Client#stream} — the mount point Grounds D1 chose
    # over the gem's serial Chat. Owns the wire-model facts (D6: the
    # dialect rides the model, never a payload seam), the history of
    # {Message}s, the batch executor (§2), and the event→chunk adapter (§3
    # — the render's frozen chunk contract).
    #
    # Cancel semantics (Grounds D3 + probe P1): the gem froze
    # Cancel→CancelledError at ITS boundary; the step body converts every
    # gem CancelledError back to Async::Cancel — the loop's ladder and
    # run()'s interrupted bookkeeping stay keyed on Cancel. No latch, no
    # #cancel: the replaced client's belt dies here.
    class Chat
      # The event→chunk adapter's duck (§3): the render contract reads
      # +content+ (the streamed text delta) and +thinking&.text+ — nothing
      # else (render/chat.rb is untouched).
      Chunk = Struct.new(:content, :thinking)

      # The chat-facing model view (id/window/facts reads — the boot and
      # switch seams read these). The gem's Model carries an Integer
      # context_window by contract; tart's nil-window rule (the threshold
      # trigger disables at nil, pi's `contextWindow ?? 0`) reads the
      # 0-window placeholder as nil at this seam.
      ModelFacts = Struct.new(:id, :reasoning, :context_window, :max_tokens,
                              :thinking_level_map, keyword_init: true)

      attr_reader :client, :model_id, :provider_key, :endpoint

      # @param client [Fast::Completions::Client] built by the caller
      #   (bin/tart build_chat / TestChat.build).
      # @param model_id [String] the wire model id.
      # @param provider_key [String, nil] metadata (the gem Model's
      #   provider — same-model replay comparison only).
      # @param endpoint [Hash, nil] {api_key:, api_base:} — the parent
      #   endpoint facts the subagents Manager threads to its children.
      def initialize(client:, model_id:, provider_key: nil, endpoint: nil)
        @client = client
        @model_id = model_id
        @provider_key = provider_key
        @endpoint = endpoint
        @instructions = nil
        @messages = []
        @tools = []
        @thinking_level = nil
        @max_output_tokens = nil
        @before_tool_call_hooks = []
        @after_tool_result_hooks = []
        @after_message_hooks = []
        # Placeholder facts until the loop's apply_facts lands the real
        # ones: a non-reasoning, window-less model — every boot read
        # (footer_data's facts/window chain) sees today's resolution tiers.
        apply_facts(model_reasoning: false, thinking_level_map: nil, compat: nil, context_window: nil)
      end

      # ── construction chain (the replaced client's builder surface, 1:1) ──────

      def with_instructions(text)
        @instructions = text
        # The history VIEW leads with the instructions as the system message
        # (the replaced client kept them IN the history — the compaction
        # estimate and cut-point math the pins calibrate against include
        # them). The store stays wire-clean: {gem_messages} renders the
        # instructions through the request's instructions field, never
        # twice; the writer strips this exact instance back out.
        @instructions_message = text.nil? || text.empty? ? nil : Message.system(text)
        self
      end

      def with_tools(*tools)
        @tools = tools
        self
      end

      # Chainable. Accepts a {Message} or a ContextMessage#to_h seed Hash
      # (the resume projection).
      def add_message(message_or_hash)
        message = normalize_message(message_or_hash)
        @messages << message
        self
      end

      def messages
        [@instructions_message, *@messages].compact
      end

      # The WRITER — compaction's history rewrite
      # ([*system, summary message, *kept tail]); the reader's leading
      # instructions instance is stripped back out (identity — a rewritten
      # array is always reader-shaped).
      def messages=(array)
        @messages = array.reject { |message| @instructions_message&.equal?(message) }
      end

      # The registered tool instances keyed by wire name (the compaction
      # estimate's keyed shape — {name => tool}, declaration
      # order).
      def tools
        @tools.to_h { |tool| [tool.name.to_s, tool] }
      end

      # The model view (window/facts reads) — see {ModelFacts}.
      def model
        @facts
      end

      def thinking_level=(level)
        @thinking_level = level
      end

      # The compaction one-shot's output cap.
      def with_max_output_tokens(count)
        @max_output_tokens = count
        self
      end

      # The step contract: false while the conversation cannot
      # finish without a model response — a trailing user/tool message, or
      # an assistant whose tool calls are unanswered.
      def complete?
        last = messages.reverse_each.find { |message| message.role != :system }
        case last&.role
        when nil then true
        when :user, :tool then false
        else last.tool_calls.empty?
        end
      end

      # The hook seams (the loop registers its event mapping here —
      # registration order, multiple blocks).
      def before_tool_call(&block)
        @before_tool_call_hooks << block
        self
      end

      def after_tool_result(&block)
        @after_tool_result_hooks << block
        self
      end

      # Fires when a tool-result message appends (the loop's :tool_message
      # emission point — the replaced client's after_message, reduced to the one
      # observable the loop reads).
      def after_message(&block)
        @after_message_hooks << block
        self
      end

      # (Re)builds the wire model from the resolved facts (D6/D7) — the
      # loop calls this at construction and on {Agent::Loop#switch_model}.
      # Idempotent; +model_id:/+provider_key:+ only when the switch hands
      # new ones. +context_window+ arrives through the loop's resolution
      # chain; an unresolvable window rides the gem as 0 (pi's
      # `contextWindow ?? 0`) and reads nil back off {model}.
      def apply_facts(model_reasoning:, thinking_level_map:, compat:, context_window:,
                      max_tokens: nil, model_id: nil, provider_key: nil)
        @model_id = model_id if model_id
        @provider_key = provider_key if provider_key
        @model_reasoning = model_reasoning == true
        @thinking_level_map = thinking_level_map
        @compat = compat
        window = context_window.is_a?(Integer) ? context_window : 0
        @model = Models.wire_model(model_id: @model_id, provider_key: @provider_key,
          reasoning: model_reasoning == true, context_window: window,
          max_tokens: max_tokens, thinking_level_map: thinking_level_map,
          compat: compat)
        @facts = ModelFacts.new(
          id: @model.id, reasoning: @model.reasoning,
          context_window: window.positive? ? window : nil,
          max_tokens: @model.max_tokens.positive? ? @model.max_tokens : nil,
          thinking_level_map: thinking_level_map,
        )
        self
      end

      # The compaction one-shot factory (Specification §5): same client,
      # same wire model + facts, the summarization instructions and output
      # cap — NO seam, NO private-API reach. The session's thinking level
      # rides (pi compaction.ts:605-607 — the dialect branch carries it).
      def summary_chat(instructions:, max_output_tokens:)
        chat = Chat.new(client: @client, model_id: @model_id, provider_key: @provider_key,
                        endpoint: @endpoint)
        chat.apply_facts(model_reasoning: @model_reasoning, thinking_level_map: @thinking_level_map,
          compat: @compat, context_window: @facts.context_window)
        chat.with_instructions(instructions)
        chat.with_max_output_tokens(max_output_tokens)
        chat.thinking_level = @thinking_level
        chat
      end

      # ── the step (the frozen loop contract) ────────────────────────────

      # One model turn. Streams the request (feeding the block the §3
      # chunks); on a tool_use finish → runs the §2 batch executor and
      # returns the LAST tool-result Message; otherwise appends and returns
      # the final assistant. The step never appends the assistant twice.
      #
      # Every gem CancelledError — the stream's or a tool checkpoint's —
      # re-raises as Async::Cancel (D3: the loop's ladder owns the shape).
      def step
        return nil if complete?

        reason = nil
        assistant = @client.stream(model: @model, messages: gem_messages,
          instructions: @instructions, tools: @tools, thinking: @thinking_level&.to_sym,
          max_tokens: @max_output_tokens) do |event|
            reason = event.reason if event.type == :done
            chunk = chunk_for_event(event)
            yield chunk if block_given? && chunk
          end

        calls = assistant_tool_calls(assistant).map do |block|
          ToolCall.new(id: block[:id], name: block[:name], arguments: block[:arguments])
        end
        @messages << from_gem_assistant(assistant, reason)
        if calls.any?
          # The batch's assistant rides its own append hook (the loop's
          # recording point — the step's return is the LAST tool result
          # under the frozen contract, so this append is the only signal).
          batch_assistant = @messages.last
          @after_message_hooks.each { |hook| hook.call(batch_assistant) }
          results = run_tool_batch(calls)
          results.each { |result| append_tool_result(result) }
          return results.last
        end

        @messages.last
      rescue Fast::Completions::CancelledError
        raise Async::Cancel, "fast-completions stream cancelled"
      end

      private

      # ── the batch executor (§2) ───────────────────────────────────

      # Children of the TURN task (Async::Task.current.async per call —
      # concurrent on the reactor, the I50 overlap shape); results append
      # in CALL order. The join re-raises Async::Cancel immediately — it
      # never waits out natural completion (the probe6 ARM A residual
      # closes here) and never launders a child error.
      def run_tool_batch(calls)
        parent = Async::Task.current
        children = calls.map do |tool_call|
          parent.async { execute_tool_call(tool_call) }
        end
        children.map(&:wait)
      end

      def execute_tool_call(tool_call)
        # The gem checkpoint: raises when the turn task is cancelled (the
        # D10 task-keyed belt — no flag pairing anywhere).
        Fast::Completions::Cancellation.check
        tool = @tools.find { |candidate| candidate.name == tool_call.name }
        return error_tool_result(tool_call, "Tool not found: #{tool_call.name}") unless tool

        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @before_tool_call_hooks.each { |hook| hook.call(tool_call) }
        result = tool.call(**tool_call.arguments, tool_call: tool_call)
        duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
        @after_tool_result_hooks.each { |hook| hook.call(tool_call, result, duration:) }
        # The details side channel rides the recorded/replayed message, not
        # the wire (I57 P3 — the wire tool message stays exactly
        # {role, content, tool_call_id}; the conversion reads content only).
        Message.tool(tool_call_id: tool_call.id, content: result_content(result), details: tool_call.details)
      end

      def append_tool_result(result)
        @messages << result
        @after_message_hooks.each { |hook| hook.call(result) }
      end

      def error_tool_result(tool_call, text)
        Message.tool(tool_call_id: tool_call.id, content: JSON.generate({error: text}))
      end

      # The result rendering contract: Strings pass verbatim; Hash/Array
      # serialize; anything else stringifies.
      def result_content(result)
        case result
        when String then result
        when Hash, Array then JSON.generate(result)
        else result.to_s
        end
      end

      # ── the event→chunk adapter (§3) ──────────────────────────────

      # Only the two delta types yield chunks; every other event type is
      # stream-internal (render/chat.rb's contract is frozen).
      def chunk_for_event(event)
        case event.type
        when :text_delta then Chunk.new(event.delta, nil)
        when :thinking_delta then Chunk.new(nil, Thinking.new(text: event.delta))
        end
      end

      def assistant_tool_calls(gem_message)
        gem_message.content.select { |block| block[:type] == :tool_call }
      end

      # ── the wire conversions (D5) ─────────────────────────────────

      def gem_messages
        @messages.map { |message| to_gem_message(message) }
      end

      def to_gem_message(message)
        case message.role
        when :user then Fast::Completions::Message.user(message.content.to_s)
        when :system then Fast::Completions::Message.system(message.content.to_s)
        when :tool
          Fast::Completions::Message.tool_result(tool_call_id: message.tool_call_id,
            content: message.content.to_s)
        when :assistant then to_gem_assistant(message)
        end
      end

      # Thinking blocks replay with the signature the provider's deltas
      # carried (the I36 protocol — recorded seeds hold it as
      # "reasoning_content"; the || supplies it for map-less seeds). The
      # provider/model stamps make the replay SAME-model (the gem's
      # transform keeps signed thinking blocks only then).
      def to_gem_assistant(message)
        blocks = []
        blocks << {type: :text, text: message.content} if message.content.is_a?(String) && !message.content.empty?
        if message.thinking&.text
          blocks << {type: :thinking, thinking: message.thinking.text,
                     signature: message.thinking.signature || "reasoning_content"}
        end
        message.tool_calls.each_value do |call|
          blocks << {type: :tool_call, id: call.id, name: call.name, arguments: call.arguments}
        end
        Fast::Completions::Message.new(role: :assistant, content: blocks,
          provider: @model.provider, model: @model.id, api: "openai-completions")
      end

      def from_gem_assistant(gem_message, reason)
        text = gem_message.content.select { |block| block[:type] == :text }
          .map { |block| block[:text].to_s }.join
        thinking_block = gem_message.content.find { |block| block[:type] == :thinking }
        thinking = if thinking_block
          Thinking.new(text: thinking_block[:thinking], signature: thinking_block[:signature])
        end
        tool_calls = assistant_tool_calls(gem_message).to_h do |block|
          [block[:id], ToolCall.new(id: block[:id], name: block[:name],
            arguments: canonical_arguments(block[:arguments]))]
        end
        # The recorded assistant content speaks "" for no text (the
        # recorded serializer's shape — the empty string, never null).
        Message.new(role: :assistant, content: text,
          tool_calls: tool_calls, thinking:, tokens: gem_message.usage,
          finish_reason: reason, provider: gem_message.provider, model: gem_message.model)
      end

      # The recorded/replayed tool-call arguments carry the replaced
      # client's canonical form: keys sorted (shorter-first, deep) — the
      # recorded bytes and the replay wire bytes speak the sorted shape.
      def canonical_arguments(value)
        case value
        when Hash
          value.sort_by { |key, _| [key.to_s.bytesize, key.to_s] }
            .to_h { |key, nested| [key, canonical_arguments(nested)] }
        when Array then value.map { |item| canonical_arguments(item) }
        else value
        end
      end

      def normalize_message(message_or_hash)
        return message_or_hash if message_or_hash.is_a?(Message)

        Message.from_seed_hash(message_or_hash)
      end
    end
  end
end
