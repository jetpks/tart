# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/mock_llm_server"
require "tmpdir"
require "fileutils"
require "json"

module Tart
  # The I96 boundary cure (jetpks/tart#19): a tool call whose arguments
  # cannot BIND — a missing required keyword, or an unknown one — used to
  # raise ArgumentError at the execute(**normalized) dispatch in
  # SafeExecute#call, BEFORE the in-body safe_execute rescue or
  # validate_input could run, and the escape killed the whole agent
  # session. The boundary rescue returns the structured I43 validation
  # result instead: the seam consult first (the canonical `is missing`
  # wrapper), then ONE minted belt wrapper for the cases validation cannot
  # speak for (a pure unknown keyword; a contract-less name). Exactly the
  # seven Specification pins; the helpers are self-contained in this file
  # (the reference harnesses' helpers are class-private — the I90/I94
  # precedent). Hermetic by construction: the scripted transports are never
  # reached on the failing paths, and pin 7 rides the loopback
  # MockLLMServer over a scripted session — no network, no sleeps, no skips.
  class SafeExecuteBindingTest < Test
    # Pin 4 — today's exact bytes on the present-but-invalid path: the
    # "Received arguments" payload carries the BOUND defaults, the no-change
    # boundary D1 protects (the rescue must never see this call).
    PRESENT_INVALID_BYTES =
      "Validation failed for tool \"web_search\":\n" \
      "  - query: must be a string\n" \
      "\n" \
      "Received arguments:\n" \
      "{\n" \
      "  \"query\": 42,\n" \
      "  \"numResults\": null,\n" \
      "  \"includeText\": false\n" \
      "}"

    def setup
      @dir = Dir.mktmpdir("t96-pins-")
      @server = nil
    end

    def teardown
      @server&.stop
      FileUtils.rm_rf(@dir)
    end

    # Pin 1 — THE issue's repro, literal: a no-arg web_search call returns
    # the canonical wrapper bytes (dry's `query: is missing` line, empty
    # payload). Deterministic: the binding fails before any transport work,
    # and the stub below would NoMethodError if a leg ever reached it.
    def test_missing_required_argument_returns_the_validation_error
      error = error_result(web_search_tool.call, "web_search")

      assert_equal "Validation failed for tool \"web_search\":\n" \
                   "  - query: is missing\n" \
                   "\n" \
                   "Received arguments:\n" \
                   "{}", error
    end

    # Pin 2 — one pin, seven required-keyword tools: each no-arg call
    # returns the wrapper header and names EVERY required key with the
    # canonical `is missing` line (write/edit assert BOTH keys).
    def test_every_required_keyword_tool_returns_validation_error_when_required_args_omitted
      cases = {
        "bash" => [Tools::Bash.new(cwd: @dir, env: {}), %w[command]],
        "edit" => [Tools::Edit.new(cwd: @dir), %w[path edits]],
        "read" => [Tools::Read.new(cwd: @dir), %w[path]],
        "write" => [Tools::Write.new(cwd: @dir), %w[path content]],
        "grep" => [Tools::Grep.new(cwd: @dir), %w[pattern]],
        "find" => [Tools::Find.new(cwd: @dir), %w[pattern]],
        "web_fetch" => [Tools::WebFetch.new(cwd: @dir, env: {}), %w[url]],
      }
      cases.each do |pi_name, (tool, required)|
        error = error_result(tool.call, pi_name)

        assert error.start_with?("Validation failed for tool \"#{pi_name}\":\n"),
          "#{pi_name}: not the wrapper header: #{error.inspect}"
        required.each do |key|
          assert_includes error, "  - #{key}: is missing",
            "#{pi_name}: the missing #{key} line is absent: #{error.inspect}"
        end
      end
    end

    # Pin 3 — partial omission names ONLY the missing key: the wrapper
    # carries exactly one failure line (anchored by the blank line that
    # closes the failure block) and never the key that was sent.
    def test_partial_omission_names_only_the_missing_key
      edit_error = error_result(Tools::Edit.new(cwd: @dir).call("path" => File.join(@dir, "f.txt")), "edit")

      assert_includes edit_error, "  - edits: is missing\n\n"
      refute_includes edit_error, "  - path: is missing"

      write_error = error_result(Tools::Write.new(cwd: @dir).call("content" => "x"), "write")

      assert_includes write_error, "  - path: is missing\n\n"
      refute_includes write_error, "  - content: is missing"
    end

    # Pin 4 — the present-but-invalid path is BYTE-UNCHANGED: the call
    # never raises ArgumentError, the rescue is never entered, and the
    # in-body validate_input wrapper still prints the BOUND defaults.
    def test_present_but_invalid_is_byte_unchanged
      error = error_result(web_search_tool.call("query" => 42), "web_search")

      assert_equal PRESENT_INVALID_BYTES, error
    end

    # Pin 5 — the sibling unknown-keyword class: the belt wrapper speaks the
    # ArgumentError's own message as the single failure line, both sent keys
    # in the received payload; the mixed missing+unknown case reports
    # MISSING (Ruby's binding precedence) and the seam consult wins — the
    # canonical wrapper, not the belt.
    def test_unknown_keyword_returns_validation_shaped_error_never_raises
      error = error_result(Tools::Bash.new(cwd: @dir, env: {}).call("command" => "echo hi", "zzz" => 1), "bash")

      assert error.start_with?("Validation failed for tool \"bash\":\n")
      assert_includes error, "  - unknown keyword: :zzz\n"
      assert_includes error, "\"command\": \"echo hi\""
      assert_includes error, "\"zzz\": 1"

      mixed = error_result(web_search_tool.call("bogus" => 1), "web_search")

      assert_includes mixed, "  - query: is missing\n"
      refute_includes mixed, "unknown keyword"
    end

    # Pin 6 — the contract-less belt: memory has no Schemas::Tools contract,
    # so the consult raises KeyError; the belt swallows it and speaks the
    # wrapper vocabulary. No escape, no raise.
    def test_contractless_tool_belt_never_raises
      error = error_result(Tools::Memory.new(cwd: @dir).call("bogus" => 1), "memory")

      assert error.start_with?("Validation failed for tool \"memory\":\n")
      assert_includes error, "  - unknown keyword: :bogus\n"
      assert_includes error, "\"bogus\": 1"
    end

    # Pin 7 — the #19 observable at the loop level: a scripted session whose
    # model emits a bash call with EMPTY arguments COMPLETES (user ->
    # assistant -> tool -> assistant), and the second request carries the
    # tool result for call_1 — the validation error the model can
    # self-correct on. Deterministic: scripted responses, no timing.
    def test_the_agent_session_survives_a_missing_arg_tool_call
      @server = MockLLMServer.new.start
      @server.script([
        {type: :stream, content: "", tool_calls: [{id: "call_1", name: "bash", arguments: {}}]},
        {type: :message, content: "recovered after the missing command"},
      ])
      agent = kernel_agent(Tools::Registry.build(selected: %w[bash], cwd: @dir))
      result = run_on_kernel(agent, "run the thing")

      assert_equal %i[user assistant tool assistant], result.map(&:role)
      assert_equal "recovered after the missing command", result.last.content

      requests = @server.captured_requests
      assert_equal 2, requests.size
      tool_message = requests.last["messages"].find { |message| message["role"] == "tool" }
      assert_equal "call_1", tool_message["tool_call_id"]
      # The {error:} hash result rides the wire as its JSON serialization
      # (the executor's result_content); the failure line survives the
      # encode verbatim, and one decode recovers the canonical wrapper.
      assert_includes tool_message["content"], "command: is missing"
      error_text = JSON.parse(tool_message["content"]).fetch("error")
      assert_includes error_text, "Validation failed for tool \"bash\""
      assert_includes error_text, "- command: is missing"
    end

    private

    # The issue repro's constructor; the transport stub is a bare Object —
    # any leg that ever reached it would NoMethodError loudly (these pins'
    # calls all fail at validation, never at the transport).
    def web_search_tool
      Tools::WebSearch.new(cwd: @dir, env: {"EXA_API_KEY" => "pin-key"}, http: Object.new)
    end

    # The never-raises property, enforced structurally: an escaped raise
    # fails the test as an error before this helper runs.
    def error_result(result, pi_name)
      assert result.is_a?(Hash) && result.key?(:error),
        "#{pi_name}: expected an {error:} result, got #{result.inspect}"
      result[:error]
    end

    # The agent-loop harness idiom, self-contained: the real client chat on
    # the loopback mock + the real Agent::Loop with a null event sink.
    def kernel_agent(tools)
      chat = TestChat.build(@server, tools: tools.values, system_prompt: "test prompt")
      Agent::Loop.new(chat:, tools:, on_event: ->(_event) { nil })
    end

    # The documented kernel usage: the scripted session drives a headless
    # run on the reactor fiber (Core::Loop — the kernel, not a bare Async).
    def run_on_kernel(agent, prompt)
      result = nil
      Core::Loop.new(session: ScriptedSession.new).run { result = agent.run(prompt) }
      result
    end
  end
end
