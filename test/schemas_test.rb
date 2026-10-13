# frozen_string_literal: true

require_relative "test_helper"
require "fileutils"
require "tmpdir"

module Tart
  # The I43 boundary schemas (AC1–AC5): the accept/reject tables through the
  # public APIs — today's exact error strings ARE the contract (the Grounds
  # §5 fixture table) — plus the tool-input vocabulary (pinned in-tool
  # strings byte-exact, pi's loop wrapper for the rest) and the settings
  # contract outcome tables (context-window tiers, thinkingLevel
  # vocabulary, modelReasoning staging).
  class SchemasTest < Test
    def setup
      @dir = Dir.mktmpdir("tart-schemas-")
    end

    def teardown
      FileUtils.rm_rf(@dir)
    end

    # --- B2: models.json accept/reject (exact strings, exact order) ---------

    def load_models_error(body)
      File.write(File.join(@dir, "models.json"), body)
      Models.load(root: @dir).error
    end

    def test_models_reject_table_matches_todays_exact_strings
      suffix = "(#{@dir}/models.json)"
      cases = {
        "[1,2]" => "  - root: expected a JSON object",
        "{}" => "  - providers: expected an object of providers",
        '{"default": 5}' => "  - default: expected a \"provider/model-id\" string\n  - providers: expected an object of providers",
        '{"providers": 5}' => "  - providers: expected an object of providers",
        '{"providers": {"a": 5}}' => "  - providers.a: expected an object",
        '{"providers": {"a": {"name": 5, "baseUrl": 5, "apiKey": 5, "api": 5}}}' =>
          "  - providers.a.name: expected a string\n  - providers.a.baseUrl: expected a string\n" \
          "  - providers.a.apiKey: expected a string\n  - providers.a.api: expected a string",
        '{"providers": {"a": {"models": 5}}}' => "  - providers.a.models: expected an array",
        '{"providers": {"a": {"models": [5]}}}' => "  - providers.a.models[0]: expected an object",
        '{"providers": {"a": {"models": [{}]}}}' => "  - providers.a.models[0].id: required non-empty string",
        '{"providers": {"a": {"models": [{"id": ""}]}}}' => "  - providers.a.models[0].id: required non-empty string",
        '{"providers": {"a": {"models": [{"id": "m", "name": 5, "reasoning": 5, "contextWindow": 0, "maxTokens": -1}]}}}' =>
          "  - providers.a.models[0].name: expected a string\n  - providers.a.models[0].reasoning: expected a boolean\n" \
          "  - providers.a.models[0].contextWindow: expected a positive integer\n  - providers.a.models[0].maxTokens: expected a positive integer",
        '{"providers": {"a": {"models": [{"id": "m", "thinkingLevelMap": "high"}]}}}' =>
          "  - providers.a.models[0].thinkingLevelMap: expected an object",
        '{"providers": {"a": {"models": [{"id": "m", "thinkingLevelMap": {"low": 5}}]}}}' =>
          "  - providers.a.models[0].thinkingLevelMap.low: expected a string or null",
        # The multi-error interleave: default, then provider fields, then
        # models in order — parsed insertion order, per-model field order.
        '{"default": 5, "providers": {"a": {"name": 5, "models": [{"id": ""}, {"id": "m", "thinkingLevelMap": {"low": 5}}]}}}' =>
          "  - default: expected a \"provider/model-id\" string\n  - providers.a.name: expected a string\n" \
          "  - providers.a.models[0].id: required non-empty string\n  - providers.a.models[1].thinkingLevelMap.low: expected a string or null"
      }
      cases.each do |body, lines|
        assert_equal "Invalid models.json schema:\n#{lines}\n#{suffix}", load_models_error(body), body
      end
    end

    def test_models_accept_table_loads_byte_identical_entries
      File.write(File.join(@dir, "models.json"), <<~JSON)
        {"providers": {"glm": {"name": "GLM", "baseUrl": "https://example.test/v1", "apiKey": "k", "api": "openai-completions",
          "models": [{"id": "m", "name": "m", "reasoning": true, "contextWindow": 200000,
                      "thinkingLevelMap": {"off": null, "low": "low", "madeup": "x"}}]}}}
      JSON
      config = Models.load(root: @dir)

      assert_nil config.error
      assert_equal({provider: "glm", id: "m", name: "m", reasoning: true, context_window: 200_000, max_tokens: nil,
                    thinking_level_map: {off: nil, low: "low", madeup: "x"}, compat: nil}, config.model_entries.first.to_h,
        "the entry hash shape and the I36 symbolization ride the schema path unchanged")
    end

    # --- I46: the per-model compat subset --------------------------------------

    # The owner's live zai catalog object (Grounds §3, verbatim compat —
    # supportsStore/supportsStrictMode are UNKNOWN keys: tolerated, no
    # error — pi additionalProperties:true).
    OWNER_COMPAT = {"supportsStore" => false, "supportsDeveloperRole" => false,
                    "supportsReasoningEffort" => true, "maxTokensField" => "max_tokens",
                    "thinkingFormat" => "zai", "supportsStrictMode" => true,
                    "zaiToolStream" => true}.freeze

    def compat_model_json(compat)
      JSON.generate({"providers" => {"a" => {"models" => [{"id" => "m", "compat" => compat}]}}})
    end

    def test_models_compat_reject_table_matches_the_enumerated_lines
      suffix = "(#{@dir}/models.json)"
      cases = {
        compat_model_json(5) => "  - providers.a.models[0].compat: expected an object",
        compat_model_json(["zai"]) => "  - providers.a.models[0].compat: expected an object",
        compat_model_json({"thinkingFormat" => "nope"}) =>
          "  - providers.a.models[0].compat.thinkingFormat: expected a thinking format",
        compat_model_json({"maxTokensField" => "tokens"}) =>
          %(  - providers.a.models[0].compat.maxTokensField: expected "max_tokens" or "max_completion_tokens"),
        compat_model_json({"supportsDeveloperRole" => "yes"}) =>
          "  - providers.a.models[0].compat.supportsDeveloperRole: expected a boolean",
        compat_model_json({"supportsReasoningEffort" => 1}) =>
          "  - providers.a.models[0].compat.supportsReasoningEffort: expected a boolean",
        compat_model_json({"zaiToolStream" => "true"}) =>
          "  - providers.a.models[0].compat.zaiToolStream: expected a boolean",
        # Several bad keys in one object: the five-key rule order
        # (thinkingFormat, maxTokensField, then the booleans).
        compat_model_json({"thinkingFormat" => "nope", "zaiToolStream" => "yes"}) =>
          "  - providers.a.models[0].compat.thinkingFormat: expected a thinking format\n" \
          "  - providers.a.models[0].compat.zaiToolStream: expected a boolean"
      }
      cases.each do |body, lines|
        assert_equal "Invalid models.json schema:\n#{lines}\n#{suffix}", load_models_error(body), body
      end
    end

    def test_models_compat_accept_table_and_interleave
      # Each of the five keys alone; all five; the owner's verbatim object
      # with its unknown keys — every row loads clean.
      rows = [
        {"thinkingFormat" => "zai"},
        {"maxTokensField" => "max_tokens"},
        {"maxTokensField" => "max_completion_tokens"},
        {"supportsDeveloperRole" => true},
        {"supportsReasoningEffort" => false},
        {"zaiToolStream" => true},
        {"thinkingFormat" => "zai", "maxTokensField" => "max_tokens", "supportsDeveloperRole" => false,
         "supportsReasoningEffort" => true, "zaiToolStream" => true},
        OWNER_COMPAT
      ]
      rows.each do |compat|
        assert_nil load_models_error(compat_model_json(compat)), compat.inspect
      end

      # The interleave: compat errors ride AFTER the model's existing
      # fields in parsed order (id, name, reasoning, thinkingLevelMap,
      # contextWindow/maxTokens, THEN compat).
      body = JSON.generate({"providers" => {"a" => {"models" => [
        {"id" => "", "compat" => 5},
        {"id" => "m", "contextWindow" => 0, "compat" => {"thinkingFormat" => "nope"}}
      ]}}})
      assert_equal "Invalid models.json schema:\n" \
        "  - providers.a.models[0].id: required non-empty string\n" \
        "  - providers.a.models[0].compat: expected an object\n" \
        "  - providers.a.models[1].contextWindow: expected a positive integer\n" \
        "  - providers.a.models[1].compat.thinkingFormat: expected a thinking format\n" \
        "(#{@dir}/models.json)", load_models_error(body)
    end

    # --- B3: mcp.json accept/reject (exact strings, fail-fast) --------------

    def load_mcp(body)
      path = File.join(@dir, "mcp.json")
      File.write(path, body.is_a?(String) ? body : JSON.generate(body))
      Mcp::Config.load(path)
    end

    def test_mcp_reject_table_matches_todays_exact_strings
      path = File.join(@dir, "mcp.json")
      cases = {
        "[1, 2]" => %(expected an object with an "mcpServers" object),
        '{"mcpServers": "nope"}' => %(expected an object with an "mcpServers" object),
        '{"mcpServers": {"x": "nope"}}' => %(server "x" must be an object),
        '{"mcpServers": {"x": {"command": "c", "args": "nope"}}}' => %(server "x": args must be an array of strings),
        '{"mcpServers": {"x": {"command": "c", "args": [1]}}}' => %(server "x": args must be an array of strings),
        '{"mcpServers": {"x": {"command": "c", "env": {"a": 1}}}}' => %(server "x": env must map names to strings),
        '{"mcpServers": {"x": {"cwd": 3}}}' => %(server "x": cwd must be a string),
        '{"mcpServers": {"x": {"url": "https://e/mcp"}}}' => %(server "x": streamable HTTP transport is not supported (stdio only)),
        '{"mcpServers": {"x": {"args": []}}}' => %(server "x" needs either "command" (stdio) or "url" (streamable HTTP)),
        # Fail-fast, insertion order: the FIRST invalid server's error wins.
        '{"mcpServers": {"a": "nope", "b": {"command": "c"}}}' => %(server "a" must be an object)
      }
      cases.each do |body, message|
        error = assert_raises(Mcp::Config::ConfigError, body) { load_mcp(body) }
        assert_equal "#{path}: #{message}", error.message, body
      end
    end

    def test_mcp_accept_table_normalizes_and_tolerates
      assert_equal({}, load_mcp("{}"), "no mcpServers key is no servers, no error")
      assert_equal({"x" => {command: "c", args: [], env: nil, cwd: nil}}, load_mcp('{"mcpServers": {"x": {"command": "c"}}}'))

      error = assert_raises(Mcp::Config::ConfigError) { load_mcp("{not json") }
      # The prefix is the pin; the parser message itself is passthrough.
      assert_match(%r{\A#{Regexp.escape(@dir)}/mcp\.json: }, error.message)
    end

    # --- B4: tool inputs — pinned strings + pi's wrapper vocabulary ---------

    def validate_input(pi_name, arguments)
      Schemas::Tools.validate(pi_name, arguments)
    end

    def assert_wrapper(pi_name, result, *lines)
      assert result.is_a?(Hash) && result.key?(:error), "expected an {error:} result, got #{result.inspect}"
      body = "Validation failed for tool \"#{pi_name}\":\n#{lines.map { |line| "  - #{line}" }.join("\n")}\n\nReceived arguments:\n"
      assert result[:error].start_with?(body), "#{result[:error].inspect} lacks the wrapper body #{body.inspect}"
    end

    def test_bash_timeout_pins_are_byte_exact_and_win_over_schema_prose
      pinned = {error: "Invalid timeout: must be a finite number of seconds"}
      assert_equal pinned, validate_input("bash", {command: "ls", timeout: -1})
      assert_equal pinned, validate_input("bash", {command: "ls", timeout: 0})
      assert_equal pinned, validate_input("bash", {command: "ls", timeout: Float::INFINITY})
      # The pinned in-tool message is the WHOLE result even when another arg
      # is wrong-typed (today's raise order — the tool check ran first).
      assert_equal pinned, validate_input("bash", {command: 5, timeout: -1})
    end

    def test_bash_shape_failures_speak_the_wrapper
      assert_nil validate_input("bash", {command: "ls", timeout: 1.5, extra: true}), "unknown keys tolerated"
      assert_wrapper("bash", validate_input("bash", {command: "ls", timeout: "5"}), "timeout: must be an integer or must be a float")
      assert_wrapper("bash", validate_input("bash", {command: 5}), "command: must be a string")
    end

    def test_edit_edits_pins_are_byte_exact_for_empty_not_array_and_nil
      pinned = {error: "Edit tool input is invalid. edits must contain at least one replacement."}
      assert_equal pinned, validate_input("edit", {path: "f", edits: []})
      assert_equal pinned, validate_input("edit", {path: "f", edits: "xx"})
      assert_equal pinned, validate_input("edit", {path: "f", edits: nil})
      assert_equal pinned, validate_input("edit", {path: 5, edits: []}), "pinned wins over a wrong-typed path (today's raise order)"
    end

    def test_edit_accepts_every_shape_todays_edit_accepts
      assert_nil validate_input("edit", {path: "f", edits: [{old_text: "a", new_text: "b"}]}), "snake kwargs"
      assert_nil validate_input("edit", {path: "f", edits: [{oldText: "a", newText: "b"}]}), "camel symbols"
      assert_nil validate_input("edit", {path: "f", edits: [{"oldText" => "a", "newText" => "b"}]}), "wire string keys"
      assert_nil validate_input("edit", {path: "f", edits: [{old_text: "", new_text: ""}]}), "empty strings flow to EditDiff"
      assert_nil validate_input("edit", {path: "f", edits: [{oldText: nil, newText: nil}]}), "nil-shapes flow to EditDiff"
    end

    def test_edit_shape_failures_speak_the_wrapper_with_dotted_paths
      assert_wrapper("edit", validate_input("edit", {path: "f", edits: [5]}), "edits.0: must be a hash")
      assert_wrapper("edit", validate_input("edit", {path: "f", edits: [{oldText: 5}]}), "edits.0.oldText: must be a string")
      assert_wrapper("edit", validate_input("edit", {path: 5, edits: [{old_text: "a", new_text: "b"}]}), "path: must be a string")
    end

    def test_every_tool_rejects_wrong_typed_args_with_the_wrapper_and_accepts_valid
      assert_nil validate_input("read", {path: "a", offset: 5, limit: 2})
      assert_wrapper("read", validate_input("read", {path: 5}), "path: must be a string")
      assert_wrapper("read", validate_input("read", {path: "a", offset: "x"}), "offset: must be an integer or must be a float")

      assert_nil validate_input("write", {path: "f", content: "x"})
      assert_wrapper("write", validate_input("write", {path: "f", content: 5}), "content: must be a string")

      assert_nil validate_input("ls", {})
      assert_wrapper("ls", validate_input("ls", {limit: "x"}), "limit: must be an integer or must be a float")

      assert_nil validate_input("grep", {pattern: "p", ignore_case: true, literal: false, context: 2, limit: 10})
      assert_wrapper("grep", validate_input("grep", {pattern: 5}), "pattern: must be a string")
      assert_wrapper("grep", validate_input("grep", {pattern: "p", ignore_case: "yes"}), "ignore_case: must be boolean")

      assert_nil validate_input("find", {pattern: "*.rb", path: "d", limit: 5})
      assert_wrapper("find", validate_input("find", {pattern: "p", limit: {}}), "limit: must be an integer or must be a float")
    end

    # --- B1: the settings resolution contracts (outcome tables) -------------

    def test_context_window_env_tier_table
      table = {
        "99" => 99, "007" => 7, "0" => 0,
        "-5" => nil, "+5" => nil, " 5" => nil, "5.5" => nil, "abc" => nil, "" => nil, nil => nil
      }
      table.each do |value, expected|
        assert_equal expected, Schemas::Settings.context_window_env(value), value.inspect
      end
    end

    def test_context_window_file_and_model_tier_table
      table = {5 => 5, 1 => 1, 0 => nil, -1 => nil, "5" => nil, 5.5 => nil, nil => nil}
      table.each do |value, expected|
        assert_equal expected, Schemas::Settings.context_window_value(value), value.inspect
      end
    end

    def test_thinking_level_vocabulary_table
      table = {
        "off" => "off", "minimal" => "minimal", "low" => "low", "medium" => "medium",
        "high" => "high", "xhigh" => "xhigh", "max" => "max",
        "loud" => nil, 5 => nil, nil => nil
      }
      table.each do |value, expected|
        assert_equal expected, Schemas::Settings.thinking_level(value), value.inspect
      end
    end

    def test_model_reasoning_staging_table
      table = {nil => nil, true => true, "true" => true, false => false, "false" => false, 5 => false, "yes" => false}
      table.each do |value, expected|
        assert_equal expected, Schemas::Settings.model_reasoning(value), value.inspect
      end
    end

    def test_file_view_types_the_carried_keys_and_tolerates_unknowns
      result = Schemas::Settings.file_view.call(
        "identity" => "tart", "defaultModel" => "m", "defaultProvider" => "p", "apiBase" => "https://x",
        "apiKey" => nil, "contextWindow" => 1000, "thinkingLevel" => "high",
        "compaction" => {"enabled" => false, "reserveTokens" => 100, "keepRecentTokens" => 5},
        "modelReasoning" => "true", "defaultTools" => ["read", "+grep"], "notARealKey" => [1]
      )
      assert_empty result.errors.to_h, "a well-formed file with unknown keys passes the tolerant view"

      bad = Schemas::Settings.file_view.call("contextWindow" => "abc", "thinkingLevel" => 5, "defaultTools" => [1])
      assert bad.failure?, "type-invalid values are REPORTED by the view (and never gate Settings.load)"
    end
  end
end
