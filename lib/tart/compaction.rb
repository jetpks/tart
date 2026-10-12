# frozen_string_literal: true

require "json"
require "set"

module Tart
  # Context compaction for long sessions (port of pi's
  # packages/coding-agent/src/core/compaction: "Pure functions for
  # compaction logic", compaction.ts:1-6 — the session I/O stays in
  # Agent::Session, the trigger wiring in Agent::Loop).
  #
  # The one LLM seam is the summarization call: a standalone one-shot chat
  # (system = SUMMARIZATION_SYSTEM_PROMPT, a single user message carrying
  # the serialized conversation — not the chat history, no tools), exactly
  # pi's buildSummarizationContext (compaction.ts:637-647).
  module Compaction
    # pi CompactionSettings + DEFAULT_COMPACTION_SETTINGS (compaction.ts:79-89).
    Settings = Struct.new(:enabled, :reserve_tokens, :keep_recent_tokens, keyword_init: true) do
      DEFAULTS = {enabled: true, reserve_tokens: 16_384, keep_recent_tokens: 20_000}.freeze

      # nil = pi's defaults; a Hash overrides the given keys.
      def self.resolve(value)
        case value
        when nil then new(**DEFAULTS)
        when self then value
        when Hash then new(**DEFAULTS.merge(value.slice(*DEFAULTS.keys)))
        else raise ArgumentError, "compaction settings must be nil, a Hash, or Settings: #{value.inspect}"
        end
      end
    end

    # utils.ts:103.
    TOOL_RESULT_MAX_CHARS = 2000

    # pi's CompactionEntry summary wrapper (messages.ts:11-19), projected
    # onto a user message (convertToLlm's compactionSummary branch,
    # messages.ts:176-184 — ruby_llm has no compactionSummary role).
    COMPACTION_SUMMARY_PREFIX = "The conversation history before this point was compacted into the following summary:\n\n<summary>\n"
    COMPACTION_SUMMARY_SUFFIX = "\n</summary>"

    # utils.ts:161-163.
    SUMMARIZATION_SYSTEM_PROMPT = <<~PROMPT.chomp
      You are a context summarization assistant. Your task is to read a conversation between a user and an AI assistant, then produce a structured summary following the exact format specified.

      Do NOT continue the conversation. Do NOT respond to any questions in the conversation. ONLY output the structured summary.
    PROMPT

    # compaction.ts:537-560.
    SUMMARIZATION_PROMPT = <<~PROMPT.chomp
      The messages above are a conversation to summarize. Create a structured context checkpoint summary that another LLM will use to continue the work.

      Use this EXACT format:

      ## Goal
      [What is the user trying to accomplish? Can be multiple items if the session covers different tasks.]

      ## Constraints & Preferences
      - [Any constraints, preferences, or requirements mentioned by user]
      - [Or "(none)" if none were mentioned]

      ## Progress
      ### Done
      - [x] [Completed tasks/changes]

      ### In Progress
      - [ ] [Current work]

      ### Blocked
      - [Issues preventing progress, if any]

      ## Key Decisions
      - **[Decision]**: [Brief rationale]

      ## Next Steps
      1. [Ordered list of what should happen next]

      ## Critical Context
      - [Any data, examples, or references needed to continue]
      - [Or "(none)" if not applicable]

      Keep each section concise. Preserve exact file paths, function names, and error messages.
    PROMPT

    # compaction.ts:543-558 (UPDATE_SUMMARIZATION_INSTRUCTIONS) wrapped by
    # :562-564.
    UPDATE_SUMMARIZATION_INSTRUCTIONS = <<~PROMPT.chomp
      Update the existing structured summary with new information. RULES:
      - PRESERVE all existing information from the previous summary
      - ADD new progress, decisions, and context from the new messages
      - UPDATE the Progress section: move items from "In Progress" to "Done" when completed
      - UPDATE "Next Steps" based on what was accomplished
      - PRESERVE exact file paths, function names, and error messages
      - If something is no longer relevant, you may remove it

      Use this EXACT format:

      ## Goal
      [Preserve existing goals, add new ones if the task expanded]

      ## Constraints & Preferences
      - [Preserve existing, add new ones discovered]

      ## Progress
      ### Done
      - [x] [Include previously done items AND newly completed items]

      ### In Progress
      - [ ] [Current work - update based on progress]

      ### Blocked
      - [Current blockers - remove if resolved]

      ## Key Decisions
      - **[Decision]**: [Brief rationale] (preserve all previous, add new)

      ## Next Steps
      1. [Update based on current state]

      ## Critical Context
      - [Preserve important context, add new if needed]

      Keep each section concise. Preserve exact file paths, function names, and error messages.
    PROMPT

    # compaction.ts:562-564.
    UPDATE_SUMMARIZATION_PROMPT = <<~PROMPT.chomp
      The messages above are NEW conversation messages to incorporate into the existing summary provided in <previous-summary> tags.

      #{UPDATE_SUMMARIZATION_INSTRUCTIONS}
    PROMPT

    # compaction.ts:985-993.
    TURN_PREFIX_SUMMARIZATION_PROMPT = <<~PROMPT.chomp
      The messages above are earlier context from an ongoing conversation. Later messages are stored separately and do not need to be reconstructed.

      Create a concise checkpoint of the user's request and the progress shown above. This checkpoint will be placed before the later messages so the conversation can continue with the necessary context.

      ## Original Request
      [What did the user ask for?]

      ## Progress So Far
      - [Key decisions and work completed in these messages]

      ## Context Needed to Continue
      - [Information from these messages needed to understand the later work]

      Only summarize information explicitly present above. Do not infer or recreate later messages.
    PROMPT

    # The cut decision over the flat message list. +usage+ and
    # +estimated_tokens_after+ stay nil through #prepare — the loop
    # populates them at the pi-equivalent points (the summarization call's
    # own usage; the post-compaction re-estimate — pi's CompactionResult,
    # compaction.ts:103-113, populated in agent-session.ts:2848-2871).
    Preparation = Struct.new(:first_kept_index, :messages_to_summarize, :tokens_before, :previous_summary,
      :usage, :estimated_tokens_after, keyword_init: true)

    module_function

    # ==========================================================================
    # Token accounting
    # ==========================================================================

    # pi calculateContextTokens (compaction.ts:138-140):
    # totalTokens || input + output + cacheRead + cacheWrite. The gem's
    # Tokens carries no total accessor (tokens.rb READERS :35-37), so the
    # component sum is the whole formula; unreported counts are nil.
    def calculate_context_tokens(tokens)
      [tokens.input, tokens.output, tokens.cache_read, tokens.cache_write].compact.sum
    end

    # pi estimateContextTokens (compaction.ts:196-225): provider-usage-backed
    # through the last valid assistant usage, chars/4 estimates for the
    # messages after it; all-estimate when no usage is in the history.
    # +tools+ (the chat's registered tools, ruby_llm Chat#tools) feeds the
    # all-estimate arm only: on the usage-backed path the provider's report
    # covers the standing context, pi's system arm included.
    def estimate_context_tokens(messages, tools: nil)
      usage_index = messages.rindex { |message| assistant_usage(message) }
      return full_estimate(messages, tools:) unless usage_index

      usage_tokens = calculate_context_tokens(assistant_usage(messages[usage_index]))
      trailing = messages[(usage_index + 1)..].to_a.sum { |message| estimate_tokens(message) }
      {tokens: usage_tokens + trailing, usage_tokens:, trailing_tokens: trailing, last_usage_index: usage_index}
    end

    # pi getAssistantUsage (compaction.ts:144-158): skips messages without
    # valid (non-nil, non-all-zero) usage. pi's aborted/error stop-reason
    # skip is unobservable here and itemized as cut: the gem raises instead
    # of appending failed/aborted responses (chat.rb provider_completion →
    # record_generated_message only runs on success, chat.rb:1006/:1213;
    # cancel raises CancelledError at raise_if_cancelled! inside it :1221),
    # and Message#finish_reason (message.rb:63, :115) never carries
    # :aborted/:error — a skip on those values would guard nothing.
    def assistant_usage(message)
      return nil unless message.respond_to?(:role) && message.role == :assistant

      tokens = message.tokens
      return nil if tokens.nil? || calculate_context_tokens(tokens) <= 0

      tokens
    end

    # The all-estimate arm grows the tools component (pi estimateTokens'
    # system arm, #estimate_tools_tokens), counted once per context.
    def full_estimate(messages, tools: nil)
      estimated = messages.sum { |message| estimate_tokens(message) } + estimate_tools_tokens(tools)
      {tokens: estimated, usage_tokens: 0, trailing_tokens: estimated, last_usage_index: nil}
    end

    # pi counts the tool definitions on the estimate's system arm
    # (compaction.ts:302-311): the context's system message carries
    # toolsAdded — the tool definitions (createInitialSystemMessage,
    # normalizeContext) — and its estimate is content + sections +
    # JSON.stringify(toolsAdded).length, so pi's chars/4 estimate covers
    # the full wire request. The port's tools live on the chat, not in a
    # message (ruby_llm Chat#with_tools): the estimate arms add the same
    # component from the chat's tools — one component per context, never
    # per message — over the definitions the request sends ({name,
    # description, parameters}: the chat_completions function payload
    # minus the framing wrapper, pi's toolsAdded shape).
    def estimate_tools_tokens(tools)
      return 0 if tools.nil? || tools.empty?

      definitions = tools.map do |_, tool|
        {name: tool.name, description: tool.description, parameters: tool.parameters_schema}
      end
      (JSON.generate(definitions).length / 4.0).ceil
    end

    # pi _checkCompaction Case 3's context-token selection (agent-session.ts:
    # 3050-3090): the just-completed assistant message's DIRECT usage first;
    # zero/absent usage falls back to the estimate over the messages (pi's
    # other fallback condition — an error stop-reason — is unreachable on
    # the port: the gem raises instead of appending a failed response, see
    # assistant_usage). +pre_compaction_messages+ (the loop's identity set —
    # the standing equivalent of pi's timestamp-vs-compaction-entry check,
    # agent-session.ts:3063-3075) is consulted ONLY inside the fallback: a
    # direct usage is the just-completed message's own, fresh by
    # construction. Returns nil when the stale guard trips (pi's
    # `return false` — no compaction this turn).
    def trigger_tokens(messages, message, pre_compaction_messages: nil, tools: nil)
      direct = message&.tokens ? calculate_context_tokens(message.tokens) : 0
      return direct if direct.positive?

      estimate = estimate_context_tokens(messages, tools:)
      usage_message = estimate[:last_usage_index] && messages[estimate[:last_usage_index]]
      return nil if usage_message && pre_compaction_messages&.key?(usage_message)

      estimate[:tokens]
    end

    # pi shouldCompact (compaction.ts:292-296), plus the caller-side
    # contextWindow guard (agent-session.ts:768-771: <= 0 returns false) —
    # nil (unresolvable window) disables the threshold trigger the same way.
    # The overflow trigger never consults this (pi's overflow path does not).
    def should_compact?(context_tokens, context_window, settings)
      return false unless settings.enabled
      return false unless context_window.is_a?(Integer) && context_window.positive?

      context_tokens > context_window - settings.reserve_tokens
    end

    # ==========================================================================
    # Estimation
    # ==========================================================================

    # pi estimateTokens (compaction.ts:258-296), chars/4 heuristic, mapped
    # onto ruby_llm message shapes: user/system/tool content; assistant
    # text + thinking + tool calls (name + JSON arguments). The port's live
    # context holds none of pi's bashExecution/custom/branchSummary/
    # compactionSummary roles (pi-internal).
    def estimate_tokens(message)
      chars =
        case message.role
        when :assistant
          chars = content_chars(message.content)
          chars += message.thinking.text.length if message.thinking&.text
          message.tool_calls&.each_value do |call|
            chars += call.name.to_s.length + JSON.generate(call.arguments).length
          end
          chars
        else
          content_chars(message.content)
        end
      (chars / 4.0).ceil
    end

    def content_chars(content)
      content.is_a?(String) ? content.length : 0
    end

    # ==========================================================================
    # Cut point
    # ==========================================================================

    # pi findCutPoint (compaction.ts:418-470) over the port's flat message
    # list: walk backwards from newest accumulating estimate_tokens; when
    # the budget (keep_recent_tokens) is exceeded, cut at the closest valid
    # cut point at or past that message. Valid cut points are user or
    # assistant messages — never a tool result, so a tool message is never
    # orphaned from its preceding assistant tool-call message (it follows
    # it in the array and is kept with it). Returns the index of the first
    # message to keep, or nil when nothing can be cut (keep everything —
    # the caller then skips compaction, as pi's prepareCompaction does).
    def find_cut_point(messages, keep_recent_tokens)
      cut_points = messages.each_index.select { |i| cut_point_message?(messages[i]) }
      return nil if cut_points.empty?

      accumulated = 0
      cut_index = cut_points.first
      messages.each_index.reverse_each do |i|
        message_tokens = estimate_tokens(messages[i])
        next if message_tokens.zero?

        accumulated += message_tokens
        next unless accumulated >= keep_recent_tokens

        # Prefer the closest valid cut point at or after this message; if
        # trailing tool results exceed the budget by themselves, keep their
        # preceding assistant tool call instead (pi :449-452).
        cut_index = cut_points.find { |candidate| candidate >= i } || cut_points.last
        break
      end
      cut_index
    end

    # pi isCutPointMessage (:336-355) restricted to the port's live roles:
    # user and assistant (toolResult → tool, never; system is prompt state
    # and not a cut point in the flat list either).
    def cut_point_message?(message)
      %i[user assistant].include?(message.role)
    end

    # ==========================================================================
    # File operations
    # ==========================================================================

    # pi extractFileOpsFromMessage (utils.ts:36-65) restricted to the port's
    # shapes: file ops come from an assistant message's tool calls; a tool
    # result message carries no nestedCalls in the port (codemode is out of
    # scope). read/write/edit only, keyed by the `path` argument.
    def extract_file_ops(messages)
      ops = {read: Set.new, written: Set.new, edited: Set.new}
      messages.each do |message|
        next unless message.respond_to?(:role) && message.role == :assistant

        message.tool_calls&.each_value { |call| add_file_op(call.name, call.arguments, ops) }
      end
      ops
    end

    def add_file_op(name, arguments, ops)
      path = arguments.is_a?(Hash) ? (arguments[:path] || arguments["path"]) : nil
      return unless path.is_a?(String) && !path.empty?

      case name.to_s
      when "read" then ops[:read] << path
      when "write" then ops[:written] << path
      when "edit" then ops[:edited] << path
      end
    end

    # pi computeFileLists (utils.ts:67-75): files only read (never modified),
    # sorted; modified (written ∪ edited), sorted.
    def compute_file_lists(ops)
      modified = (ops[:edited] | ops[:written]).to_a.sort
      read_only = (ops[:read].to_a - modified).sort
      {read_files: read_only, modified_files: modified}
    end

    # pi formatFileOperations (utils.ts:77-95).
    def format_file_operations(read_files, modified_files)
      sections = []
      sections << "<read-files>\n#{read_files.join("\n")}\n</read-files>" if read_files.any?
      sections << "<modified-files>\n#{modified_files.join("\n")}\n</modified-files>" if modified_files.any?
      return "" if sections.empty?

      "\n\n#{sections.join("\n\n")}"
    end

    # ==========================================================================
    # Serialization
    # ==========================================================================

    # pi serializeConversation (utils.ts:110-153), mapped onto ruby_llm
    # message shapes: content strings, ToolCall#name/#arguments (pi's
    # `k=${JSON.stringify(v)}`), thinking via Message#thinking. System
    # messages are prompt state, not conversation (pi's convertToLlm).
    def serialize_conversation(messages)
      parts = []
      messages.each do |message|
        case message.role
        when :user
          parts << "[User]: #{message.content}" if content?(message)
        when :assistant
          thinking = message.thinking&.text
          parts << "[Assistant thinking]: #{thinking}" if thinking
          parts << "[Assistant]: #{message.content}" if content?(message)
          calls = tool_call_strings(message)
          parts << "[Assistant tool calls]: #{calls.join('; ')}" unless calls.empty?
        when :tool
          if content?(message)
            parts << "[Tool result]: #{truncate_for_summary(message.content, TOOL_RESULT_MAX_CHARS)}"
          end
        end
      end
      parts.join("\n\n")
    end

    def content?(message)
      message.content.is_a?(String) && !message.content.empty?
    end

    # pi :134-141: `name(k=JSON.stringify(v), ...)` joined with "; ".
    def tool_call_strings(message)
      return [] unless message.tool_calls

      message.tool_calls.filter_map do |_id, call|
        next unless call.name

        args = call.arguments.map { |key, value| "#{key}=#{JSON.generate(value)}" }.join(", ")
        "#{call.name}(#{args})"
      end
    end

    # pi truncateForSummary (utils.ts:108-113).
    def truncate_for_summary(text, max_chars)
      return text if text.length <= max_chars

      truncated_chars = text.length - max_chars
      "#{text[0, max_chars]}\n\n[... #{truncated_chars} more characters truncated]"
    end

    # ==========================================================================
    # Summarization prompt
    # ==========================================================================

    # pi generateSummaryWithUsage's prompt assembly (compaction.ts:695-701):
    # <conversation>-wrapped serialization, optional <previous-summary>, then
    # the update prompt when a previous summary exists, else the initial one.
    def summarization_prompt(messages, previous_summary: nil)
      prompt = "<conversation>\n#{serialize_conversation(messages)}\n</conversation>\n\n"
      if previous_summary
        prompt += "<previous-summary>\n#{previous_summary}\n</previous-summary>\n\n"
        prompt + UPDATE_SUMMARIZATION_PROMPT
      else
        prompt + SUMMARIZATION_PROMPT
      end
    end

    # ==========================================================================
    # Preparation
    # ==========================================================================

    # pi prepareCompaction (compaction.ts:890-950) reduced to the flat
    # message list: the cut point over the chat history, tokens before, and
    # the messages to summarize (system messages are prompt state, not
    # conversation — pi's getMessagesFromProjectedEntryForCompaction skips
    # them, compaction.ts:117-122). nil when there is nothing to summarize
    # (pi's "messagesToSummarize.length === 0 → undefined"). +tools+ is
    # the chat's registered tools — tokens_before stays "the context the
    # summarization replaces" (the full wire context, tools included).
    def prepare(messages, settings, previous_summary: nil, tools: nil)
      first_kept_index = find_cut_point(messages, settings.keep_recent_tokens)
      return nil if first_kept_index.nil? || first_kept_index.zero?

      summarize = messages[0...first_kept_index].reject { |message| message.role == :system }
      return nil if summarize.empty?

      Preparation.new(
        first_kept_index:,
        messages_to_summarize: summarize,
        tokens_before: estimate_context_tokens(messages, tools:)[:tokens],
        previous_summary:,
      )
    end
  end
end
