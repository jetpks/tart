# frozen_string_literal: true

require_relative "test_helper"

module Tart
  # The compaction pure functions (AC1): token estimation, provider-usage
  # accounting, the threshold predicate, cut-point selection that never
  # orphans a tool result from its tool call, file-op extraction/formatting,
  # and the serialization/prompt assembly — all with no LLM.
  class CompactionTest < Test
    def test_settings_resolve_to_pis_defaults_and_hash_overrides
      settings = Compaction::Settings.resolve(nil)
      assert settings.enabled
      assert_equal 16_384, settings.reserve_tokens
      assert_equal 20_000, settings.keep_recent_tokens

      disabled = Compaction::Settings.resolve(enabled: false)
      refute disabled.enabled
      assert_equal 16_384, disabled.reserve_tokens
    end

    def test_calculate_context_tokens_sums_the_gems_tokens_accessors
      tokens = RubyLLM::Tokens.new(input: 100, output: 20, cache_read: 7, cache_write: 3)
      assert_equal 130, Compaction.calculate_context_tokens(tokens)
      assert_equal 0, Compaction.calculate_context_tokens(RubyLLM::Tokens.new)
    end

    def test_estimate_context_tokens_uses_last_assistant_usage_plus_trailing_estimate
      used = RubyLLM::Message.new(role: :assistant, content: "a", tokens: RubyLLM::Tokens.new(input: 50, output: 10))
      messages = [
        llm_message(:user, "hello"),
        used,
        llm_message(:tool, "x" * 40), # 10 tokens by the chars/4 heuristic
        llm_message(:assistant, "done"),
      ]

      estimate = Compaction.estimate_context_tokens(messages)
      assert_equal 60, estimate[:usage_tokens]
      assert_equal 11, estimate[:trailing_tokens] # ("x" * 40) => 10 + "done" => 1
      assert_equal 71, estimate[:tokens]
      assert_equal 1, estimate[:last_usage_index]
    end

    def test_estimate_context_tokens_all_estimate_without_usage
      messages = [llm_message(:user, "x" * 40), llm_message(:assistant, "y" * 8)]
      estimate = Compaction.estimate_context_tokens(messages)
      assert_equal 12, estimate[:tokens]
      assert_nil estimate[:last_usage_index]
    end

    def test_estimate_tokens_covers_assistant_thinking_and_tool_call_arguments
      call = RubyLLM::ToolCall.new(id: "call_1", name: "read", arguments: {path: "a.rb"})
      assistant = RubyLLM::Message.new(role: :assistant, content: "abcd", thinking: "efgh",
                                       tool_calls: {"call_1" => call})
      # 4 (text) + 4 (thinking) + 4 (name) + 16 (JSON args) = 28 chars / 4.
      assert_equal 7, Compaction.estimate_tokens(assistant)
      assert_equal 3, Compaction.estimate_tokens(llm_message(:tool, "x" * 10))
      assert_equal 2, Compaction.estimate_tokens(llm_message(:user, "x" * 5))
    end

    # pi _checkCompaction Case 3's selection (agent-session.ts:3050-3090),
    # the three paths: the direct usage first; the zero/absent-usage
    # fallback to the estimate; the stale pre-compaction guard INSIDE the
    # fallback only.
    def test_trigger_tokens_reads_the_just_completed_messages_direct_usage_first
      used = RubyLLM::Message.new(role: :assistant, content: "done",
        tokens: RubyLLM::Tokens.new(input: 120, output: 10))
      messages = [llm_message(:user, "x" * 40), used]

      # The direct usage wins even when the same message sits in the stale
      # set — it is the just-completed turn's own usage, fresh by
      # construction (pi skips the timestamp guard on the direct branch).
      assert_equal 130, Compaction.trigger_tokens(messages, used,
        pre_compaction_messages: identity_set(used))
    end

    def test_trigger_tokens_zero_direct_usage_falls_back_to_the_estimate
      used = RubyLLM::Message.new(role: :assistant, content: "a",
        tokens: RubyLLM::Tokens.new(input: 100, output: 20))
      fresh = RubyLLM::Message.new(role: :assistant, content: "y" * 8)
      messages = [llm_message(:user, "x" * 40), used, fresh]

      # The just-completed message carries no usage (pi's error stop-reason
      # or all-zero usage; the port: tokens nil/all-nil) — the estimate:
      # usage 120 + trailing ("y" * 8) => 2.
      assert_equal 122, Compaction.trigger_tokens(messages, fresh,
        pre_compaction_messages: identity_set)
      assert_equal 122, Compaction.trigger_tokens(messages, fresh)
    end

    def test_trigger_tokens_stale_guard_trips_inside_the_fallback
      used = RubyLLM::Message.new(role: :assistant, content: "a",
        tokens: RubyLLM::Tokens.new(input: 100, output: 20))
      fresh = RubyLLM::Message.new(role: :assistant, content: "y" * 8)
      messages = [llm_message(:user, "x" * 40), used, fresh]

      # The last usage message is a KEPT pre-compaction message — its usage
      # reflects the old (larger) context and would falsely re-trigger
      # right after a compaction: nil (pi's `return false`,
      # agent-session.ts:3063-3075).
      assert_nil Compaction.trigger_tokens(messages, fresh,
        pre_compaction_messages: identity_set(used))
    end

    def test_should_compact_boundaries
      settings = Compaction::Settings.resolve(nil)
      assert Compaction.should_compact?(16_386, 32_769, settings) # > window - reserve
      refute Compaction.should_compact?(16_384, 32_769, settings)
      refute Compaction.should_compact?(16385, 32_769, Compaction::Settings.resolve(enabled: false))
      refute Compaction.should_compact?(16385, nil, settings), "nil window disables the threshold"
      refute Compaction.should_compact?(16385, 0, settings), "<= 0 window disables the threshold"
    end

    def test_find_cut_point_budget_falling_mid_turn_keeps_the_tool_result_with_its_call
      messages = [
        llm_message(:user, "u" * 40),                                            # 10
        tool_call_message("a" * 40),                                         # 10
        llm_message(:tool, "t" * 400),                                           # 100
        llm_message(:assistant, "final"),                                        # 2
      ]
      # Budget 115: walking back, the final assistant (2) then the tool
      # result (100) then the tool-call assistant (10) cross it — the cut
      # must land on the tool-call assistant (index 1), never the tool
      # result, so the result stays joined to its call.
      assert_equal 1, Compaction.find_cut_point(messages, 115)
    end

    def test_find_cut_point_budget_crossed_by_a_tool_result_cuts_at_the_next_call
      messages = [
        llm_message(:user, "u" * 40),                                            # 10
        tool_call_message("a" * 40),                                         # 10
        llm_message(:tool, "t" * 400),                                           # 100
        llm_message(:assistant, "f" * 8),                                        # 2
      ]
      # Budget 102: the final assistant (2) then the tool result (100) cross
      # it; the next valid cut point at or after the tool result is the
      # trailing assistant (index 3) —
      # the summarized side keeps the call/result pair together.
      assert_equal 3, Compaction.find_cut_point(messages, 102)
    end

    def test_find_cut_point_returns_nil_when_nothing_can_be_cut
      messages = [llm_message(:tool, "orphan" * 10), llm_message(:tool, "x")]
      assert_nil Compaction.find_cut_point(messages, 1)
    end

    def test_prepare_returns_nil_when_the_cut_keeps_everything
      settings = Compaction::Settings.resolve(keep_recent_tokens: 20_000)
      assert_nil Compaction.prepare([llm_message(:user, "hi")], settings)
      assert_nil Compaction.prepare([llm_message(:tool, "only")], settings)
    end

    def test_prepare_splits_at_the_cut_and_excludes_system_from_the_summary
      settings = Compaction::Settings.resolve(keep_recent_tokens: 1)
      system = RubyLLM::Message.new(role: :system, content: "prompt")
      messages = [system, llm_message(:user, "old"), tool_call_message("call"), llm_message(:tool, "result"),
                  llm_message(:assistant, "final")]
      preparation = Compaction.prepare(messages, settings)

      # Budget 1 crosses at the newest message (the final assistant, index
      # 4): the summary covers the turn before it, system excluded.
      assert_equal 4, preparation.first_kept_index
      assert_equal %i[user assistant tool], preparation.messages_to_summarize.map(&:role)
      assert preparation.tokens_before.positive?
      assert_equal messages,
        [system, *preparation.messages_to_summarize, *messages[preparation.first_kept_index..]]
    end

    def test_extract_file_ops_and_compute_file_lists
      ops = Compaction.extract_file_ops([
        tool_call_message("ignored", name: "read", path: "lib/a.rb"),
        tool_call_message("ignored", name: "write", path: "lib/b.rb"),
        tool_call_message("ignored", name: "edit", path: "lib/c.rb"),
        tool_call_message("ignored", name: "bash", path: "lib/d.rb"),
        llm_message(:tool, "results"),
      ])
      lists = Compaction.compute_file_lists(ops)
      assert_equal ["lib/a.rb"], lists[:read_files]
      assert_equal %w[lib/b.rb lib/c.rb], lists[:modified_files]
    end

    def test_format_file_operations_xml_shape
      assert_equal "", Compaction.format_file_operations([], [])
      assert_equal "\n\n<read-files>\nlib/a.rb\n</read-files>",
        Compaction.format_file_operations(["lib/a.rb"], [])
      assert_equal "\n\n<read-files>\nlib/a.rb\n</read-files>\n\n<modified-files>\nlib/b.rb\n</modified-files>",
        Compaction.format_file_operations(["lib/a.rb"], ["lib/b.rb"])
    end

    def test_serialize_conversation_prefixes_and_truncation
      call = RubyLLM::ToolCall.new(id: "call_1", name: "read", arguments: {path: "a.rb"})
      messages = [
        llm_message(:user, "please look"),
        RubyLLM::Message.new(role: :assistant, content: "checking", thinking: "hmm",
                             tool_calls: {"call_1" => call}),
        llm_message(:tool, "x" * 2050),
        llm_message(:user, "go on"),
      ]

      text = Compaction.serialize_conversation(messages)
      assert_includes text, "[User]: please look"
      assert_includes text, "[Assistant thinking]: hmm"
      assert_includes text, "[Assistant]: checking"
      assert_includes text, '[Assistant tool calls]: read(path="a.rb")'
      assert_includes text, "[Tool result]: #{'x' * 2000}\n\n[... 50 more characters truncated]"
      assert_equal [
        "[User]: please look",
        "[Assistant thinking]: hmm",
        "[Assistant]: checking",
        "[Assistant tool calls]: read(path=\"a.rb\")",
        "[Tool result]: #{'x' * 2000}\n\n[... 50 more characters truncated]",
        "[User]: go on",
      ].join("\n\n"), text
    end

    def test_summarization_prompt_wraps_the_conversation
      prompt = Compaction.summarization_prompt([llm_message(:user, "hi")])
      assert_equal "<conversation>\n[User]: hi\n</conversation>\n\n#{Compaction::SUMMARIZATION_PROMPT}", prompt
    end

    def test_summarization_prompt_with_previous_summary_uses_the_update_prompt
      prompt = Compaction.summarization_prompt([llm_message(:user, "hi")], previous_summary: "earlier")
      assert_equal(
        "<conversation>\n[User]: hi\n</conversation>\n\n<previous-summary>\nearlier\n</previous-summary>\n\n" \
        "#{Compaction::UPDATE_SUMMARIZATION_PROMPT}",
        prompt
      )
    end

    private

    def llm_message(role, content)
      RubyLLM::Message.new(role:, content:)
    end

    # The loop's identity-keyed pre-compaction message set
    # (@pre_compaction_messages's shape).
    def identity_set(*messages)
      set = {}.compare_by_identity
      messages.each { |message| set[message] = true }
      set
    end

    # An assistant message making one tool call (tool results follow it in
    # the flat list, as ruby_llm builds them).
    def tool_call_message(content, name: "read", path: "x.rb")
      call = RubyLLM::ToolCall.new(id: "call_1", name:, arguments: {path:})
      RubyLLM::Message.new(role: :assistant, content:, tool_calls: {"call_1" => call})
    end
  end
end
