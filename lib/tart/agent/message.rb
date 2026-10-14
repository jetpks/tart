# frozen_string_literal: true

module Tart
  module Agent
    # The loop-facing tool-call duck (pi's ToolCall shape — the recorded
    # ToolCall-shape preserved): the hooks, the ToolGate, the batch
    # executor, and the tests all construct it. +arguments+ keeps the
    # parsed Hash the provider sent (insertion order — the replay bytes).
    # +details+ (I57, nil default) is the per-call display side channel the
    # edit tool fills at execution (pi's EditToolDetails riding the result
    # object) — never on the wire, never recorded on non-edit calls.
    ToolCall = Struct.new(:id, :name, :arguments, :details, keyword_init: true)

    # The recorded token counts duck (the replaced client's Tokens reader
    # surface the footer/compaction math consumes). Unreported counts are
    # +nil+; live messages carry the gem's Usage directly (same readers,
    # +total_tokens+ native — Grounds OQ-9), this struct serves the
    # reseed-from-recorded path and the test factories.
    Tokens = Struct.new(:input, :output, :cache_read, :cache_write, :thinking,
                        :total_tokens, keyword_init: true)

    # The streamed-thinking duck (the render's chunk contract reads
    # +thinking&.text+; +signature+ is the replay protocol's field name).
    Thinking = Struct.new(:text, :signature, keyword_init: true)

    # The loop-facing message adapter (Grounds D5): tart's history, the
    # recorder's serialization, and the compaction math all speak THIS
    # shape; the gem's Message crosses only at the Chat's wire boundary.
    #
    # The recorded surface (+to_h+) is the replaced client's empirical bytes —
    # the session files on disk are frozen that way and resume reads them:
    # a user entry is {"role","content"}; a tool result {"role",
    # "tool_call_id","content"}; an assistant {"role","content","tool_calls"
    # ({} when none),"finish_reason","input_tokens","output_tokens",
    # "cache_write_tokens"} — the token keys follow the recorded nil/0
    # conventions (unreported input/output drop, cache_write persists as a
    # reported zero, cache_read/thinking omit when zero) and
    # thinking/thinking_signature ride when present.
    class Message
      ROLES = %i[user assistant system tool].freeze

      # The wire finish reasons, the recorded spellings (the recorded bytes).
      FINISH_REASONS = {stop: "stop", length: "length", tool_use: "tool_calls"}.freeze

      attr_reader :role, :content, :tool_calls, :tool_call_id, :thinking, :tokens,
                  :finish_reason, :provider, :model, :details

      # @param role [Symbol] one of {ROLES}.
      # @param content [String, nil] the text (assistant nil = tool-calls-only).
      # @param tool_calls [Hash{String => ToolCall}] keyed by call id,
      #   provider order ({} for plain text assistants).
      # @param tool_call_id [String, nil] the answered call id (role :tool).
      # @param thinking [Thinking, nil] the reply's reasoning text + the
      #   replay field name it streamed under.
      # @param tokens [Fast::Completions::Usage, Tokens, nil] the provider
      #   usage (assistant turns; nil = unreported).
      # @param finish_reason [String, Symbol, nil] the stop reason — a
      #   recorded String spelling or a gem symbol (normalized on read).
      # @param details [Hash, nil] the tool result's display side channel
      #   (I57 — pi session-manager records it on the toolResult message;
      #   NEVER sent to the LLM — the context projection drops the key and
      #   the wire conversion reads content only). Nil on every non-edit
      #   result: the recorded byte-shape gains no key.
      def initialize(role:, content: nil, tool_calls: {}, tool_call_id: nil,
                     thinking: nil, thinking_signature: nil, tokens: nil,
                     finish_reason: nil, provider: nil, model: nil, details: nil)
        unless ROLES.include?(role)
          raise ArgumentError, "role must be one of #{ROLES.inspect}, got #{role.inspect}"
        end

        @role = role
        @content = content
        @tool_calls = (tool_calls || {}).freeze
        @tool_call_id = tool_call_id
        @thinking = normalize_thinking(thinking, thinking_signature)
        @tokens = tokens
        @finish_reason = normalize_finish_reason(finish_reason)
        @provider = provider
        @model = model
        @details = details
        freeze
      end

      # The gem-style constructors the test factories and the Chat's
      # conversions use (keyword-init parity with the recorded shape).
      def self.user(content) = new(role: :user, content: content)

      def self.system(content) = new(role: :system, content: content)

      def self.tool(tool_call_id:, content:, details: nil)
        new(role: :tool, tool_call_id: tool_call_id, content: content, details: details)
      end

      # The recorded-hash projection — the recorder's bytes (the empirical
      # shape, Grounds D5). Key order is the recorded serializer's own
      # serialization order (the resumed bytes read back verbatim).
      def to_h
        case role
        when :assistant then assistant_to_h
        when :tool then tool_to_h
        else {role: role.to_s, content:}
        end
      end

      # The resume seed: a ContextMessage#to_h projection (symbol keys,
      # the recorded body verbatim) back into a Message. The recorded
      # token keys rebuild the duck; a seed is never re-recorded.
      def self.from_seed_hash(hash)
        fields = hash.transform_keys(&:to_sym)
        message = new(
          role: fields.fetch(:role).to_sym,
          content: fields[:content],
          tool_calls: normalize_seed_tool_calls(fields[:tool_calls]),
          tool_call_id: fields[:tool_call_id],
          thinking: fields[:thinking],
          thinking_signature: fields[:thinking_signature],
          tokens: Tokens.new(
            input: fields[:input_tokens], output: fields[:output_tokens],
            cache_read: fields[:cache_read_tokens], cache_write: fields[:cache_write_tokens],
            thinking: fields[:thinking_tokens]
          ),
          finish_reason: fields[:finish_reason],
        )
        message
      end

      # The replay reseed's token duck (the recorded hash → the footer's
      # reader surface; the render calls this on every replayed assistant).
      def self.tokens_from(recorded)
        Tokens.new(
          input: recorded["input_tokens"], output: recorded["output_tokens"],
          cache_read: recorded["cache_read_tokens"], cache_write: recorded["cache_write_tokens"],
          thinking: recorded["thinking_tokens"]
        )
      end

      def user? = role == :user
      def assistant? = role == :assistant
      def system? = role == :system
      def tool? = role == :tool

      # The stop-reason readback: tool-calling assistants read
      # :tool_use off their calls (the loop's batch dispatch keys on it).
      def tool_call? = role == :assistant && !tool_calls.empty?

      private

      # The tool entry: the frozen three-key shape {role, content,
      # tool_call_id}; +details+ appends ONLY when present (I57 — the edit
      # tool's display diff; every existing recorded byte is unchanged).
      def tool_to_h
        out = {role: "tool", content:, tool_call_id:}
        out[:details] = details if details
        out
      end

      # The assistant entry: the frozen no-tool-calls pin is
      # {"role","content","tool_calls"=>{},"finish_reason","input_tokens",
      # "output_tokens","cache_write_tokens"} (Specification §8) — the
      # nil/0 conventions below reproduce the recorded parser defaults
      # (unreported prompt/completion drop; cache_write persists as the
      # reported zero it defaults to; cache_read/thinking omit at zero).
      def assistant_to_h
        out = {role: "assistant", content:, tool_calls: tool_calls.to_h { |id, call| [id, call_to_h(call)] }}
        out[:thinking] = thinking.text if thinking&.text
        out[:thinking_signature] = thinking.signature if thinking&.signature
        out[:finish_reason] = finish_reason if finish_reason
        merge_usage(out)
        out
      end

      def call_to_h(call)
        {id: call.id, name: call.name, arguments: call.arguments}
      end

      # Nothing reported → nothing persisted (a no-usage turn records no
      # token keys, the recorded all-unreported shape).
      def merge_usage(out)
        usage = tokens
        return unless usage

        reported = [usage.input, usage.output, usage.cache_read, usage.cache_write].any?(&:positive?)
        return unless reported

        out[:input_tokens] = usage.input if usage.input&.positive?
        out[:output_tokens] = usage.output if usage.output&.positive?
        out[:cache_read_tokens] = usage.cache_read if usage.cache_read&.positive?
        # The recorded chat_completions parser defaults the cache WRITE to 0
        # (never nil) — the reported-zero persists even when the provider
        # sent no cache fields (the AC's frozen pin carries it).
        out[:cache_write_tokens] = usage.cache_write || 0
        out[:thinking_tokens] = usage.reasoning if usage.respond_to?(:reasoning) && usage.reasoning&.positive?
      end

      def normalize_thinking(text, signature)
        return nil unless text.is_a?(String) || (text.respond_to?(:text) && text&.text)

        return text if text.respond_to?(:text)

        Thinking.new(text: text, signature: signature || "reasoning_content")
      end

      def normalize_finish_reason(reason)
        case reason
        when nil then nil
        when String then reason
        when Symbol then FINISH_REASONS.fetch(reason, reason.to_s)
        else reason
        end
      end

      def self.normalize_seed_tool_calls(calls)
        (calls || {}).to_h do |id, call|
          [id, call.is_a?(ToolCall) ? call : ToolCall.new(
            id: call[:id] || call["id"] || id,
            name: call[:name] || call["name"],
            arguments: call[:arguments] || call["arguments"] || {},
          )]
        end
      end
    end
  end
end
