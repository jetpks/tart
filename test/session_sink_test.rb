# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/mock_llm_server"
require_relative "support/mock_ingest_server"
require "tart/session_sink"
require "json"
require "tmpdir"
require "fileutils"
require "stringio"
require "open3"
require "rbconfig"

module Tart
  # The I74 session-sink pins, over the five gate families: /config_law/
  # (AC1), /projection/ (AC2), /engine/ (AC3, module-level against the
  # mock ingest server with tuned-down constants), /boot/ (AC3,
  # process-level real `bin/tart -p` boots), /child_capture/ (AC4).
  # Everything rides the PUBLIC surface (register / the hooks seam /
  # the projection functions) — the herdr-test discipline.
  class SessionSinkTest < Test
    # The frozen tuning (the test seam shrinks the timing constants;
    # production callers pass nothing).
    TUNING = {debounce_ms: 30, post_timeout_ms: 2000, backoff_ms: [20, 20],
              shutdown_wait_ms: 300, shutdown_post_timeout_ms: 500}.freeze

    S_ID = "018f0000-0000-7000-8000-000000000001"

    # The driven multi-turn script (the /boot/ leg): a bash tool-call turn,
    # then the final text.
    BOOT_SCRIPT = [
      {type: :stream, content: "checking the directory", tool_calls: [{id: "call_1", name: "bash", arguments: {command: "echo tool-ok"}}]},
      {type: :stream, content: "final answer"}
    ].freeze

    def setup
      @engines = []
      @servers = []
      @homes = []
    end

    def teardown
      @engines.each { |engine| engine.stop rescue nil }
      Array(@managers).each { |manager| manager.shutdown rescue nil }
      @servers.each { |server| server.stop rescue nil }
      @homes.each { |home| FileUtils.rm_rf(home) rescue nil }
    end

    # ── /config_law/ ──────────────────────────────────────────────────

    def test_config_law_file_configures_host_token_disabled
      path = write_config("host" => "http://file.test", "token" => "file-token")
      config = SessionSink.resolve_config({}, identity: "tart", config_path: path)
      assert_equal "http://file.test", config["host"]
      assert_equal "file-token", config["token"]
      assert_equal false, config["disabled"]
      assert SessionSink.configured?(config)
    end

    def test_config_law_env_host_and_token_beat_the_file
      path = write_config("host" => "http://file.test", "token" => "file-token")
      config = SessionSink.resolve_config({"TART_SESSION_SINK_HOST" => "http://env.test",
                                           "TART_SESSION_SINK_TOKEN" => "env-token"},
                                          identity: "tart", config_path: path)
      assert_equal "http://env.test", config["host"]
      assert_equal "env-token", config["token"]
    end

    def test_config_law_empty_env_values_fall_back_to_the_file
      path = write_config("host" => "http://file.test", "token" => "file-token")
      config = SessionSink.resolve_config({"TART_SESSION_SINK_HOST" => "", "TART_SESSION_SINK_TOKEN" => ""},
                                          identity: "tart", config_path: path)
      assert_equal "http://file.test", config["host"]
      assert_equal "file-token", config["token"]
    end

    def test_config_law_disabled_env_any_present_value_decides_both_directions
      path = write_config("host" => "h", "token" => "t", "disabled" => true)
      muted = SessionSink.resolve_config({"TART_SESSION_SINK_DISABLED" => "1"}, identity: "tart", config_path: path)
      assert muted["disabled"], "1 over a file-disabled row stays muted"
      also_muted = SessionSink.resolve_config({"TART_SESSION_SINK_DISABLED" => "true"}, identity: "tart", config_path: path)
      assert also_muted["disabled"], "true over a file-disabled row stays muted"
      unmuted = SessionSink.resolve_config({"TART_SESSION_SINK_DISABLED" => "0"}, identity: "tart", config_path: path)
      refute unmuted["disabled"], "any OTHER present env value unmutes (0 beats the file)"
      other = SessionSink.resolve_config({"TART_SESSION_SINK_DISABLED" => "no"}, identity: "tart", config_path: path)
      refute other["disabled"], "no beats the file"
      blank = SessionSink.resolve_config({"TART_SESSION_SINK_DISABLED" => ""}, identity: "tart", config_path: path)
      assert blank["disabled"], "an empty env value is absent — the file's row decides"
    end

    def test_config_law_malformed_and_non_object_files_are_unconfigured
      garbage = write_config_text("{not json")
      config = SessionSink.resolve_config({}, identity: "tart", config_path: garbage)
      assert_nil config["host"], "malformed file = {} = unconfigured"
      assert_nil config["token"]
      refute config["disabled"]
      refute SessionSink.configured?(config)
      array_file = write_config_text("[1, 2]")
      refute SessionSink.configured?(SessionSink.resolve_config({}, identity: "tart", config_path: array_file))
    end

    def test_config_law_absent_and_disabled_files_are_unconfigured
      refute SessionSink.configured?(SessionSink.resolve_config({}, identity: "tart", config_path: "/nonexistent/i74.json"))
      path = write_config("host" => "h", "token" => "t", "disabled" => true)
      refute SessionSink.configured?(SessionSink.resolve_config({}, identity: "tart", config_path: path))
    end

    def test_config_law_ingest_url_strips_every_trailing_slash
      assert_equal "http://deck.test/conversations/ingest", SessionSink.ingest_url("http://deck.test/")
      assert_equal "http://deck.test/conversations/ingest", SessionSink.ingest_url("http://deck.test///")
      assert_equal "http://deck.test/conversations/ingest", SessionSink.ingest_url("http://deck.test")
    end

    def test_config_law_env_keys_follow_the_identity_namespace
      path = write_config("host" => "http://file.test", "token" => "file-token")
      pi = SessionSink.resolve_config({"PI_SESSION_SINK_HOST" => "http://pi.test"}, identity: "pi", config_path: path)
      assert_equal "http://pi.test", pi["host"]
      assert_equal "http://file.test", SessionSink.resolve_config({"PI_SESSION_SINK_HOST" => "http://pi.test"},
        identity: "tart", config_path: path)["host"], "a foreign namespace must not cross identities"
    end

    def test_config_law_unconfigured_binds_nothing_on_session_start
      hooks = Hooks.new
      engine = track(SessionSink.register(hooks:, identity: "tart", env: {},
                                          config_path: "/nonexistent/i74.json"))
      bind_session(hooks, session_id: "s-inert")
      emit_user(hooks, "never captured")
      assert_empty engine.captures, "unconfigured → no capture bound (fully inert)"
    end

    def test_config_law_disabled_env_over_a_good_file_binds_nothing
      path = write_config("host" => "http://file.test", "token" => "file-token")
      hooks = Hooks.new
      engine = track(SessionSink.register(hooks:, identity: "tart",
                                          env: {"TART_SESSION_SINK_DISABLED" => "1"}, config_path: path))
      bind_session(hooks, session_id: "s-inert")
      assert_empty engine.captures, "disabled → no capture bound (fully inert)"
    end

    def test_config_law_a_config_file_appearing_mid_process_arms_the_next_session
      path = File.join(staged_home, ".tart", "session-sink.json")
      hooks = Hooks.new
      engine = track(SessionSink.register(hooks:, identity: "tart", env: {}, config_path: path))
      bind_session(hooks, session_id: "s-early")
      assert_empty engine.captures, "unconfigured at the first bind"
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.generate({"host" => "http://late.test", "token" => "late-token"}))
      bind_session(hooks, session_id: "s-late")
      assert_equal ["s-late"], engine.captures.map(&:session_id), "config resolves at EVERY bind"
    end

    def test_config_law_tuning_constants_frozen_and_the_seam_shrinks
      assert_equal 2000, SessionSink::QUEUE_CAP
      assert_equal 250, SessionSink::DEBOUNCE_MS
      assert SessionSink::DEBOUNCE_MS <= 500
      assert_equal 8000, SessionSink::POST_TIMEOUT_MS
      assert_equal 3, SessionSink::MAX_ATTEMPTS
      assert_equal [500, 1000], SessionSink::RETRY_BACKOFF_MS
      assert_equal 1000, SessionSink::SHUTDOWN_WAIT_MS
      assert_equal 2000, SessionSink::SHUTDOWN_POST_TIMEOUT_MS
      engine = track(SessionSink.register(hooks: Hooks.new, identity: "tart", env: {},
                                          config_path: "/nonexistent/i74.json", tuning: {debounce_ms: 5, backoff_ms: [1, 1]}))
      assert_equal 5, engine.timing[:debounce_ms]
      assert_equal [1, 1], engine.timing[:backoff_ms]
      assert_equal 2000, engine.timing[:queue_cap], "untouched tuning keys ride the frozen constants"
    end

    # ── /projection/ ──────────────────────────────────────────────────

    def test_projection_session_record_minted_shape
      record = SessionSink.session_record(S_ID, "/work/dir", timestamp: "2026-10-18T00:00:00.000Z")
      assert_equal({"type" => "session", "version" => 3, "id" => S_ID,
                    "timestamp" => "2026-10-18T00:00:00.000Z", "cwd" => "/work/dir"}, record)
      assert_equal Agent::Session::CURRENT_VERSION, record["version"]
    end

    def test_projection_user_record_shape
      record = JSON.parse(JSON.generate(
        SessionSink.project_event({type: :message_end, message: Agent::Message.user("hi there")}, S_ID, 1)))
      assert_equal "message_end", record["type"]
      assert_equal "#{S_ID}/1", record["id"]
      message = record["message"]
      assert_equal({"role" => "user", "content" => [{"type" => "text", "text" => "hi there"}]}, message.except("timestamp"))
      assert message["timestamp"].is_a?(Integer) && message["timestamp"] > 1_700_000_000_000
    end

    def test_projection_assistant_blocks_thinking_then_text_then_tool_calls
      call = Agent::ToolCall.new(id: "c1", name: "bash", arguments: {"command" => "ls"})
      message = Agent::Message.new(role: :assistant, content: "the answer", tool_calls: {"c1" => call},
        thinking: Agent::Thinking.new(text: "because", signature: "reasoning_content"),
        tokens: Agent::Tokens.new(input: 5, output: 4, cache_write: 0), finish_reason: "tool_calls",
        provider: "mock", model: "tart-test-model")
      record = JSON.parse(JSON.generate(
        SessionSink.project_event({type: :message_end, message:}, S_ID, 2)))
      assert_equal "#{S_ID}/2", record["id"]
      assert_equal "assistant", record["message"]["role"]
      assert_equal [
        {"type" => "thinking", "thinking" => "because", "thinkingSignature" => "reasoning_content"},
        {"type" => "text", "text" => "the answer"},
        {"type" => "toolCall", "id" => "c1", "name" => "bash", "arguments" => {"command" => "ls"}}
      ], record["message"]["content"], "blocks IN ORDER; the raw-String content is NEVER serialized verbatim"
      assert_equal "mock", record["message"]["provider"]
      assert_equal "tart-test-model", record["message"]["model"]
      assert_equal({"input" => 5, "output" => 4, "cacheWrite" => 0}, record["message"]["usage"])
      assert_equal "toolUse", record["message"]["stopReason"]
    end

    def test_projection_stop_reason_map_and_omission
      assert_equal "end_turn", mapped_stop_reason("stop")
      assert_equal "toolUse", mapped_stop_reason("tool_calls")
      assert_equal "maxTokens", mapped_stop_reason("length")
      assert_equal "error", mapped_stop_reason("error"), "everything else verbatim"
      assert_equal "some_other_reason", mapped_stop_reason("some_other_reason")
      message = Agent::Message.new(role: :assistant, content: "x")
      record = JSON.parse(JSON.generate(
        SessionSink.project_event({type: :message_end, message:}, S_ID, 1)))
      refute record["message"].key?("stopReason"), "absent finish_reason → key omitted"
    end

    def test_projection_usage_map_reports_only_reported_facts
      message = Agent::Message.new(role: :assistant, content: "x",
        tokens: Agent::Tokens.new(input: 7, output: 2, cache_read: 3))
      usage = JSON.parse(JSON.generate(
        SessionSink.project_event({type: :message_end, message:}, S_ID, 1)))["message"]["usage"]
      assert_equal({"input" => 7, "output" => 2, "cacheRead" => 3, "cacheWrite" => 0}, usage,
                   "cacheWrite rides the port's reported-or-0 convention")
      quiet = Agent::Message.new(role: :assistant, content: "x", tokens: Agent::Tokens.new(input: nil, output: nil, cache_write: 0))
      record = JSON.parse(JSON.generate(
        SessionSink.project_event({type: :message_end, message: quiet}, S_ID, 2)))
      refute record["message"].key?("usage"), "nothing reported → nothing mapped (never a fabricated totalTokens/cost)"
      refute record["message"].key?("errorMessage"), "present-only: no errorMessage without an error"
    end

    def test_projection_error_message_rides_when_present
      message = Agent::Message.error_failure(error_message: "boom")
      record = JSON.parse(JSON.generate(
        SessionSink.project_event({type: :message_end, message:}, S_ID, 1)))
      assert_equal "boom", record["message"]["errorMessage"]
      assert_equal "error", record["message"]["stopReason"]
    end

    def test_projection_tool_execution_record_shape
      call = Agent::ToolCall.new(id: "c1", name: "bash", arguments: {"command" => "ls"})
      record = JSON.parse(JSON.generate(
        SessionSink.project_event({type: :tool_execution_end, tool_call: call, result: "ok-output", duration: 1.234}, S_ID, 5)))
      assert_equal({"type" => "tool_execution_end", "id" => "#{S_ID}/5", "toolCallId" => "c1", "toolName" => "bash",
                    "result" => {"content" => [{"type" => "text", "text" => "ok-output"}]},
                    "isError" => false, "durationMs" => 1234}, record)
    end

    def test_projection_is_error_from_the_hash_error_key
      call = Agent::ToolCall.new(id: "c1", name: "bash", arguments: {})
      record = JSON.parse(JSON.generate(
        SessionSink.project_event({type: :tool_execution_end, tool_call: call, result: {"error" => "boom"}, duration: 0.5}, S_ID, 6)))
      assert_equal true, record["isError"]
      assert_equal JSON.generate({"error" => "boom"}), record["result"]["content"][0]["text"],
                   "Hash results JSON-generate (the port's result_content law)"
      plain = JSON.parse(JSON.generate(
        SessionSink.project_event({type: :tool_execution_end, tool_call: call, result: "fine", duration: 0.1}, S_ID, 7)))
      refute plain["isError"], "a String result is never an error"
    end

    def test_projection_parent_tool_call_id_present_only
      call = Agent::ToolCall.new(id: "c1", name: "bash", arguments: {})
      without = JSON.parse(JSON.generate(
        SessionSink.project_event({type: :tool_execution_end, tool_call: call, result: "x", duration: 0.1}, S_ID, 1)))
      refute without.key?("parentToolCallId"), "no emitter today — the key is absent"
      with = JSON.parse(JSON.generate(
        SessionSink.project_event({type: :tool_execution_end, tool_call: call, result: "x", duration: 0.1,
                                   parent_tool_call_id: "pc9"}, S_ID, 2)))
      assert_equal "pc9", with["parentToolCallId"]
    end

    def test_projection_skip_rules_consume_nothing
      tool = Agent::Message.tool(tool_call_id: "c1", content: "x")
      custom = Hooks::CustomMessage.new(role: :custom, custom_type: "memory-recall", content: "c", display: false)
      system = Agent::Message.system("s")
      assert_nil SessionSink.project_event({type: :message_end, message: tool}, S_ID, 8)
      assert_nil SessionSink.project_event({type: :message_end, message: custom}, S_ID, 9)
      assert_nil SessionSink.project_event({type: :message_end, message: system}, S_ID, 10)
      assert_nil SessionSink.project_event({type: :message_start, message: Agent::Message.user("x")}, S_ID, 11)
      assert_nil SessionSink.project_event({type: :agent_end}, S_ID, 12), "every other event type → nil"
    end

    def test_projection_seed_counts_the_port_spelling_and_skips_the_rest
      path = File.join(staged_home, "seed.jsonl")
      entries = [
        {"type" => "session", "version" => 3, "id" => "h", "timestamp" => "t", "cwd" => "/w"},
        {"type" => "message", "id" => "a", "parentId" => "h", "timestamp" => "t", "message" => {"role" => "user", "content" => "u"}},
        {"type" => "message", "id" => "b", "parentId" => "a", "timestamp" => "t", "message" => {"role" => "assistant", "content" => nil, "tool_calls" => {}}},
        {"type" => "message", "id" => "c", "parentId" => "b", "timestamp" => "t", "message" => {"role" => "tool", "content" => "r", "tool_call_id" => "c1"}},
        {"type" => "custom_message", "customType" => "memory-recall", "content" => "c", "display" => false, "id" => "d", "parentId" => "c", "timestamp" => "t"},
        {"type" => "compaction", "id" => "e", "parentId" => "d", "timestamp" => "t", "summary" => "s", "firstKeptEntryId" => nil, "tokensBefore" => 1, "details" => "auto"},
        "not json at all",
        {"type" => "message", "id" => "f", "parentId" => "e", "timestamp" => "t", "message" => {"role" => "assistant", "content" => "done", "tool_calls" => {}, "finish_reason" => "stop"}}
      ]
      File.write(path, entries.map { |e| e.is_a?(String) ? e : JSON.generate(e) }.join("\n"))
      assert_equal 4, SessionSink.seed_count(path), "user/assistant/tool counted; custom_message/compaction never"
      assert_equal 0, SessionSink.seed_count("/nonexistent/i74.json"), "unreadable → 0"
      assert_equal 0, SessionSink.seed_count(nil)
    end

    def test_projection_record_id_law
      assert_equal "#{S_ID}/7", SessionSink.record_id(S_ID, 7)
      assert_equal "other-sid/1", SessionSink.record_id("other-sid", 1)
    end

    def test_projection_space_slug_title_slug_and_id_fallback
      home = staged_home
      with_title = File.join(home, "with-title")
      FileUtils.mkdir_p(with_title)
      File.write(File.join(with_title, "space.yaml"), YAML.dump({"version" => 2, "id" => "unused-id", "title" => "I74 Deck Space!"}))
      assert_equal "i74-deck-space", SessionSink.space_slug_for(with_title), "slugify(title)"
      with_id = File.join(home, "with-id")
      FileUtils.mkdir_p(with_id)
      File.write(File.join(with_id, "space.yaml"), YAML.dump({"version" => 2, "id" => "my-space-id"}))
      assert_equal "my-space-id", SessionSink.space_slug_for(with_id), "the id when there is no title"
    end

    def test_projection_space_slug_malformed_yaml_walk_continues_and_none_is_nil
      home = staged_home
      parent = File.join(home, "parent")
      child = File.join(parent, "child")
      FileUtils.mkdir_p(child)
      File.write(File.join(child, "space.yaml"), "{{{ not yaml")
      File.write(File.join(parent, "space.yaml"), YAML.dump({"version" => 2, "id" => "parent-space"}))
      assert_equal "parent-space", SessionSink.space_slug_for(child), "malformed → treated as absent, walk continues"
      assert_nil SessionSink.space_slug_for(home), "no space.yaml to the filesystem root → nil"
    end

    def test_projection_agent_name_from_prompt_tag_and_the_role_strip
      prompt = "<active_agent name=\"architect-builder\"/>\nYou are the builder."
      assert_equal "architect-builder", SessionSink.agent_name_for(-> { prompt }, env: {}, identity: "tart")
      assert_equal "builder", SessionSink.agent_role_for("architect-builder"), "a leading architect- prefix strips"
      assert_equal "worker", SessionSink.agent_role_for("worker"), "else the name"
    end

    def test_projection_agent_name_env_fallback_and_neither
      assert_equal "worker", SessionSink.agent_name_for(nil, env: {"TART_SESSION_SINK_AGENT_NAME" => "worker"}, identity: "tart")
      assert_nil SessionSink.agent_name_for(nil, env: {}, identity: "tart")
      assert_nil SessionSink.agent_name_for("no tag here", env: {}, identity: "tart"), "a non-tagged prompt falls through"
    end

    def test_projection_parent_session_id_header_route_then_filename_then_env
      home = staged_home
      parent_file = File.join(home, "20261018T010101_ab12cd34.jsonl")
      File.write(parent_file, JSON.generate({"type" => "session", "version" => 3, "id" => "parent-uuid",
                                             "timestamp" => "t", "cwd" => "/w"}) + "\n")
      session_file = File.join(home, "20261018T010202_eff001.jsonl")
      File.write(session_file, JSON.generate({"type" => "session", "version" => 3, "id" => "child-uuid",
                                              "parentSession" => parent_file, "timestamp" => "t", "cwd" => "/w"}) + "\n")
      assert_equal "parent-uuid", SessionSink.parent_session_id_for(session_file, env: {}, identity: "tart"),
                   "the recorder header's parentSession → the parent file's FIRST-line id (bounded read)"
      broken = File.join(home, "20261018T010303_eff002.jsonl")
      File.write(broken, JSON.generate({"type" => "session", "version" => 3, "id" => "child-2",
                                        "parentSession" => "/nonexistent/20261018T010101_deadbeef.jsonl",
                                        "timestamp" => "t", "cwd" => "/w"}) + "\n")
      assert_equal "deadbeef", SessionSink.parent_session_id_for(broken, env: {}, identity: "tart"),
                   "an unreadable parent file falls back to the _<uuid>.jsonl filename segment"
      bare = File.join(home, "20261018T010404_eff003.jsonl")
      File.write(bare, JSON.generate({"type" => "session", "version" => 3, "id" => "child-3", "timestamp" => "t", "cwd" => "/w"}) + "\n")
      assert_equal "env-parent-id", SessionSink.parent_session_id_for(bare, env: {"TART_SESSION_SINK_PARENT_SESSION_ID" => "env-parent-id"},
                                                                     identity: "tart")
      assert_nil SessionSink.parent_session_id_for(bare, env: {}, identity: "tart"), "neither → omitted"
    end

    # ── /engine/ ──────────────────────────────────────────────────────

    def test_engine_debounce_coalesces_two_quick_events_into_one_post
      server = ingest_server
      hooks = Hooks.new
      track(new_sink(hooks:, server:))
      bind_session(hooks, session_id: "s-coal")
      emit_user(hooks, "one")
      emit_user(hooks, "two")
      assert server.wait_posts(1, 5), "the debounced batch landed"
      sleep(0.15) # past the tuned debounce: no second POST may appear
      posts = server.posts
      assert_equal 1, posts.size, "two quick events coalesce into ONE POST"
      assert_equal 1, server.max_concurrent, "≤ 1 in-flight POST by construction"
      records = posts[0][:records]
      assert_equal 3, records.size, "the session record opens EVERY body"
      assert_equal "session", records[0]["type"]
      assert_equal ["s-coal/1", "s-coal/2"], records[1..].map { |r| r["id"] }, "FIFO order preserved"
      assert_equal "one", records[1]["message"]["content"][0]["text"]
      assert_equal "two", records[2]["message"]["content"][0]["text"]
    end

    def test_engine_fifo_and_single_in_flight_under_a_slow_mock
      server = ingest_server
      server.delay_with(0.3)
      hooks = Hooks.new
      track(new_sink(hooks:, server:))
      bind_session(hooks, session_id: "s-fifo")
      emit_user(hooks, "first")
      assert server.wait_posts(1, 5), "the first POST lands"
      emit_user(hooks, "second")
      emit_user(hooks, "third")
      assert server.wait_posts(2, 5), "the coalesced tail lands"
      wait_for { server.post_count == 2 }
      assert_equal 1, server.max_concurrent, "never two POSTs in flight"
      posts = server.posts
      assert_equal ["first"], records_text(posts[0])
      assert_equal %w[second third], records_text(posts[1]), "the tail rides ONE body, FIFO order"
    end

    def test_engine_queue_cap_overflow_drops_the_oldest_and_reports
      server = ingest_server
      hooks = Hooks.new
      track(new_sink(hooks:, server:, tuning: {debounce_ms: 60, queue_cap: 2}))
      stderr = capture_stderr do
        bind_session(hooks, session_id: "s-cap")
        emit_user(hooks, "one")
        emit_user(hooks, "two")
        emit_user(hooks, "three")
        assert server.wait_posts(1, 5)
      end
      records = server.posts[0][:records]
      assert_equal ["two", "three"], records[1..].map { |record| record.dig("message", "content", 0, "text") }, "overflow drops the OLDEST records"
      assert_includes stderr, "session-sink:", "the loss reports loudly"
      assert_includes stderr, "queue overflow"
    end

    def test_engine_retry_lands_the_batch_on_the_third_attempt
      server = ingest_server
      server.fail_with([500, 500])
      hooks = Hooks.new
      track(new_sink(hooks:, server:, tuning: {debounce_ms: 20, backoff_ms: [20, 20]}))
      stderr = capture_stderr do
        bind_session(hooks, session_id: "s-retry")
        emit_user(hooks, "ride three attempts")
        wait_for { server.posts.any? { |post| post[:status] == 202 } }
      end
      posts = server.posts
      assert_equal [500, 500, 202], posts.map { |post| post[:status] }, "the SAME batch retried, MAX_ATTEMPTS total"
      assert_equal "s-retry/1", posts[2][:records][1]["id"], "the batch lands intact on attempt 3"
      refute_includes stderr, "session-sink:", "transient failures are silent (retry absorbs them)"
    end

    def test_engine_final_failure_drops_the_batch_and_the_engine_keeps_accepting
      server = ingest_server
      server.fail_with([500, 500, 500])
      hooks = Hooks.new
      track(new_sink(hooks:, server:, tuning: {debounce_ms: 20, backoff_ms: [20, 20]}))
      stderr = capture_stderr do
        bind_session(hooks, session_id: "s-drop")
        emit_user(hooks, "doomed")
        wait_for { server.post_count >= 3 }
        emit_user(hooks, "still accepted")
        wait_for { server.posts.any? { |post| post[:status] == 202 } }
      end
      assert_equal [500, 500, 500], server.posts[0, 3].map { |post| post[:status] }
      assert_includes stderr, "session-sink:", "final failure → ONE loss line"
      landed = server.posts.find { |post| post[:status] == 202 }
      assert_equal "still accepted", landed[:records][1]["message"]["content"][0]["text"],
                   "the engine keeps accepting after a dropped batch"
    end

    def test_engine_rebind_flushes_the_previous_capture_non_terminally
      server = ingest_server
      hooks = Hooks.new
      track(new_sink(hooks:, server:))
      bind_session(hooks, session_id: "s-old")
      emit_user(hooks, "old turn")
      bind_session(hooks, session_id: "s-new") # within the debounce window
      emit_user(hooks, "new turn")
      assert server.wait_posts(2, 5), "both captures flush"
      wait_for { server.post_count == 2 }
      old_post, new_post = server.posts
      assert_equal "s-old", old_post[:records][0]["id"]
      assert_equal "s-old/1", old_post[:records][1]["id"]
      refute old_post[:headers].key?("x-session-complete"), "the rebind flush is NON-terminal"
      assert_equal "s-new", new_post[:records][0]["id"], "the new capture's body opens with ITS session record"
      assert_equal "s-new/1", new_post[:records][1]["id"]
    end

    def test_engine_record_ids_stay_monotonic_across_a_same_session_rebind
      server = ingest_server
      hooks = Hooks.new
      track(new_sink(hooks:, server:))
      bind_session(hooks, session_id: "sid-9")
      emit_user(hooks, "first")
      bind_session(hooks, session_id: "sid-9") # same session id — max(counter, seed)
      emit_user(hooks, "second")
      assert server.wait_posts(2, 5)
      wait_for { server.post_count == 2 }
      ids = server.posts.flat_map { |post| post[:records][1..].map { |r| r["id"] } }
      assert_equal ["sid-9/1", "sid-9/2"], ids, "n monotonic per session id ACROSS rebinds"
    end

    def test_engine_terminal_post_completes_with_pending_records_and_the_session_record
      server = ingest_server
      hooks = Hooks.new
      track(new_sink(hooks:, server:))
      bind_session(hooks, session_id: "s-term")
      emit_user(hooks, "pending one")
      emit_user(hooks, "pending two")
      hooks.emit({"type" => "session_shutdown", "reason" => "quit"},
                 context: {cwd: Dir.pwd, mode: "print", session: nil, identity: "tart"})
      assert server.wait_posts(1, 5)
      post = server.posts[0]
      assert_equal 202, post[:status]
      assert_equal "true", post[:headers]["x-session-complete"], "the terminal POST carries the header"
      assert_equal "session", post[:records][0]["type"]
      assert_equal ["pending one", "pending two"], records_text(post), "pending content rides the terminal body, order preserved"
    end

    def test_engine_terminal_post_fires_even_with_an_empty_queue
      server = ingest_server
      hooks = Hooks.new
      track(new_sink(hooks:, server:))
      bind_session(hooks, session_id: "s-empty")
      hooks.emit({"type" => "session_shutdown", "reason" => "quit"},
                 context: {cwd: Dir.pwd, mode: "print", session: nil, identity: "tart"})
      assert server.wait_posts(1, 5), "the session record alone re-creates the conversation completed"
      post = server.posts[0]
      assert_equal "true", post[:headers]["x-session-complete"]
      assert_equal 1, post[:records].size
      assert_equal "session", post[:records][0]["type"]
    end

    def test_engine_terminal_shutdown_is_bounded_on_a_dead_host
      hooks = Hooks.new
      engine = track(SessionSink.register(hooks:, identity: "tart",
                                          env: {"TART_SESSION_SINK_HOST" => "http://127.0.0.1:1",
                                                "TART_SESSION_SINK_TOKEN" => "tok"},
                                          config_path: "/nonexistent/i74.json",
                                          tuning: {debounce_ms: 30, shutdown_wait_ms: 300, shutdown_post_timeout_ms: 400}))
      bind_session(hooks, session_id: "s-dead")
      emit_user(hooks, "dies with the batch")
      t0 = nil
      elapsed = nil
      capture_stderr do
        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        hooks.emit({"type" => "session_shutdown", "reason" => "quit"},
                   context: {cwd: Dir.pwd, mode: "print", session: nil, identity: "tart"})
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
      end
      assert elapsed < 2.0, "the handler returned within the tuned bound (#{elapsed.round(2)}s)"
      assert_empty engine.captures, "the terminal capture unbinds"
    end

    def test_engine_the_token_never_appears_in_any_loss_line
      hooks = Hooks.new
      track(SessionSink.register(hooks:, identity: "tart",
                                 env: {"TART_SESSION_SINK_HOST" => "http://127.0.0.1:1",
                                       "TART_SESSION_SINK_TOKEN" => "sekret-tok-123"},
                                 config_path: "/nonexistent/i74.json",
                                 tuning: {debounce_ms: 30, shutdown_wait_ms: 300, shutdown_post_timeout_ms: 400}))
      stderr = capture_stderr do
        bind_session(hooks, session_id: "s-tok")
        emit_user(hooks, "spills nothing")
        hooks.emit({"type" => "session_shutdown", "reason" => "quit"},
                   context: {cwd: Dir.pwd, mode: "print", session: nil, identity: "tart"})
      end
      assert_includes stderr, "session-sink:", "a loss line was produced"
      refute_includes stderr, "sekret-tok-123", "the token lives only in the Authorization header"
    end

    def test_engine_non_quit_shutdown_reason_flushes_non_terminally
      server = ingest_server
      hooks = Hooks.new
      track(new_sink(hooks:, server:))
      bind_session(hooks, session_id: "s-other")
      emit_user(hooks, "soon flushed")
      hooks.emit({"type" => "session_shutdown", "reason" => "other"}, context: {})
      assert server.wait_posts(1, 5)
      post = server.posts[0]
      refute post[:headers].key?("x-session-complete"), "non-quit reasons stay non-terminal"
      assert_equal "s-other/1", post[:records][1]["id"]
    end

    # ── /boot/ (process-level, Open3 — the launcher_smoke pattern) ────

    def test_boot_driven_multi_turn_session_streams_the_full_contract
      boot_and_capture do |ingest, _llm, _home, _stderr, exit_status, workdir|
        assert_equal 0, exit_status, "the print boot succeeded"
        assert ingest.wait_posts(1, 15), "the boot streamed to the mock ingest"
        sleep(0.3) # let any straggler land (a fast mock turn can coalesce everything)
        posts = ingest.posts
        session_ids = posts.map { |post| post[:records][0] && post[:records][0]["id"] }.compact.uniq
        assert_equal 1, session_ids.size, "one session id"
        posts.each do |post|
          assert_equal 202, post[:status]
          assert_equal "session", post[:records][0]["type"], "the session record opens EVERY body"
          assert_equal 3, post[:records][0]["version"]
          assert_equal File.realpath(workdir), post[:records][0]["cwd"]
          assert_equal "Bearer ingest-token", post[:headers]["authorization"]
          assert_equal "application/x-ndjson", post[:headers]["content-type"]
          assert_equal "i74-boot-space", post[:headers]["x-space-slug"], "the walked space.yaml's slug"
          refute post[:headers].key?("x-parent-session-id"), "a plain boot carries no parent header"
          refute post[:headers].key?("x-agent-name"), "a plain boot carries no agent headers"
          refute post[:headers].key?("x-agent-role")
        end
        content = posts.flat_map { |post| post[:records][1..] || [] }
        assert_equal %w[message_end message_end tool_execution_end message_end], content.map { |r| r["type"] },
                     "the four content records in emission order (user, tool-call assistant, tool exec, final assistant)"
        assert_equal "#{session_ids[0]}/1", content[0]["id"]
        assert_equal "hello world", content[0]["message"]["content"][0]["text"]
        assert_equal "user", content[0]["message"]["role"]
        assert_equal "toolUse", content[1]["message"]["stopReason"]
        assert_equal({"type" => "text", "text" => "checking the directory"}, content[1]["message"]["content"][0])
        assert_equal({"type" => "toolCall", "id" => "call_1", "name" => "bash", "arguments" => {"command" => "echo tool-ok"}},
                     content[1]["message"]["content"][1])
        assert_equal "call_1", content[2]["toolCallId"]
        assert_equal "tool-ok\n", content[2]["result"]["content"][0]["text"]
        assert_equal false, content[2]["isError"]
        assert_equal "final answer", content[3]["message"]["content"][0]["text"]
        assert_equal "end_turn", content[3]["message"]["stopReason"]
        ids = content.map { |record| record["id"] }
        assert_equal [1, 2, 3, 4], ids.map { |id| id.split("/").last.to_i }, "ids <sid>/<n> monotonic"
      end
    end

    def test_boot_terminal_post_completes_the_session_before_exit
      boot_and_capture do |ingest, _llm, _home, _stderr, exit_status, _workdir|
        assert_equal 0, exit_status
        assert ingest.wait_posts(1, 15)
        wait_for { ingest.post_count >= 1 }
        posts = ingest.posts
        terminal = posts.last
        assert_equal "true", terminal[:headers]["x-session-complete"], "the terminal POST carries X-Session-Complete"
        assert_equal "session", terminal[:records][0]["type"], "even the terminal body opens with the session record"
        posts[0...-1].each do |post|
          refute post[:headers].key?("x-session-complete"), "only the TERMINAL POST is marked complete"
        end
      end
    end

    def test_boot_inert_without_any_config
      boot_and_capture(config: nil) do |ingest, _llm, _home, _stderr, exit_status, _workdir|
        assert_equal 0, exit_status
        sleep(0.5) # nothing may EVER connect
        assert_equal 0, ingest.connections, "no config → zero connections (fully inert)"
        assert_equal 0, ingest.post_count
      end
    end

    def test_boot_inert_with_a_malformed_config_file
      boot_and_capture(config: :malformed) do |ingest, _llm, _home, _stderr, exit_status, _workdir|
        assert_equal 0, exit_status
        sleep(0.5)
        assert_equal 0, ingest.connections, "malformed file = unconfigured = zero connections"
        assert_equal 0, ingest.post_count
      end
    end

    def test_boot_inert_with_disabled_env_over_a_good_file
      boot_and_capture(env_extra: {"TART_SESSION_SINK_DISABLED" => "1"}) do |ingest, _llm, _home, _stderr, exit_status, _workdir|
        assert_equal 0, exit_status
        sleep(0.5)
        assert_equal 0, ingest.connections, "DISABLED env beats the good file → zero connections"
        assert_equal 0, ingest.post_count
      end
    end

    # ── /child_capture/ ───────────────────────────────────────────────

    def test_child_capture_env_picks_the_five_identity_namespaced_keys
      manager, run = spawn_pinned_run(env: default_capture_env.merge(
        "PI_SESSION_SINK_HOST" => "http://127.0.0.1:1", "PI_SESSION_SINK_TOKEN" => "tok",
        "PI_SESSION_SINK_DISABLED" => "0"), agent: fake_parent_loop)
      _, env = manager.spawn_argv_and_env(run)
      assert_equal "http://127.0.0.1:1", env["PI_SESSION_SINK_HOST"]
      assert_equal "tok", env["PI_SESSION_SINK_TOKEN"]
      assert_equal "0", env["PI_SESSION_SINK_DISABLED"]
      assert_equal "worker", env["PI_SESSION_SINK_AGENT_NAME"], "the run's agent label, unconditional"
      assert_equal "parent-session-id", env["PI_SESSION_SINK_PARENT_SESSION_ID"], "the live parent recorder id"
    end

    def test_child_capture_env_picks_omitted_when_the_parent_has_none
      manager, run = spawn_pinned_run(env: default_capture_env, agent: nil)
      _, env = manager.spawn_argv_and_env(run)
      refute env.key?("PI_SESSION_SINK_HOST"), "no parent env pick → key omitted (FILE-configured parents need no pick)"
      refute env.key?("PI_SESSION_SINK_TOKEN")
      refute env.key?("PI_SESSION_SINK_DISABLED")
      refute env.key?("PI_SESSION_SINK_PARENT_SESSION_ID"), "no parent recorder → key omitted"
      assert_equal "worker", env["PI_SESSION_SINK_AGENT_NAME"], "the label rides regardless"
    end

    def test_child_capture_env_picks_ride_identity_namespaced_tart_keys
      manager, run = spawn_pinned_run(env: default_capture_env.merge(
        "TART_SESSION_SINK_HOST" => "http://127.0.0.1:1"), agent: nil, identity: "tart")
      _, env = manager.spawn_argv_and_env(run)
      assert_equal "http://127.0.0.1:1", env["TART_SESSION_SINK_HOST"], "the namespace follows the identity"
      refute env.key?("PI_SESSION_SINK_HOST")
    end

    def test_child_capture_real_child_round_trip_streams_its_own_session
      ingest = ingest_server
      llm = MockLLMServer.new.start
      track_server(llm)
      llm.script([{type: :stream, content: "child answer"}])
      home = track_home(Dir.mktmpdir("i74-child-"))
      workdir = Dir.mktmpdir("i74-child-cwd-")
      parent_env = default_capture_env.merge(
        "PI_API_BASE" => llm.url, "PI_SESSION_SINK_HOST" => ingest.url,
        "PI_SESSION_SINK_TOKEN" => "ingest-token", "PI_SESSION_SINK_DISABLED" => "0")
      loop = fake_parent_loop
      manager = track_manager(Subagents::Manager.new(cwd: workdir, home: File.join(home, "subagents"),
                                                     env: parent_env, identity: "pi", hooks: Hooks.new, agent: loop))
      run = manager.spawn_run(agent: "worker", task: "report the answer", async: false,
                              timeout_ms: 0, tool_timeout_ms: 0)
      child_log = File.join(run[:dir], "runner.stderr.log")
      assert_equal :completed, run[:state],
                   "the child booted and completed (stderr: #{File.file?(child_log) ? File.read(child_log)[0, 400] : "(no log)"})"
      assert ingest.wait_posts(1, 15), "the child streamed to the mock ingest"
      wait_for { ingest.post_count >= 1 }
      posts = ingest.posts
      posts.each do |post|
        assert_equal "session", post[:records][0]["type"], "every child body opens with its session record"
        assert_equal "Bearer ingest-token", post[:headers]["authorization"]
        assert_equal "parent-session-id", post[:headers]["x-parent-session-id"], "the plumbed parent id rides"
        assert_equal "worker", post[:headers]["x-agent-name"], "the plumbed label rides"
        assert_equal "worker", post[:headers]["x-agent-role"], "role = the label (no architect- prefix to strip)"
      end
      child_session_id = posts[0][:records][0]["id"]
      refute_equal "parent-session-id", child_session_id, "the child binds its OWN session id"
      content = posts.flat_map { |post| post[:records][1..] || [] }
      assert content.any? { |record| record["type"] == "message_end" && record["id"].start_with?("#{child_session_id}/") },
             "content records carry the child's own id space"
      assert_equal "true", posts.last[:headers]["x-session-complete"], "terminal POST at child exit"
    end

    # ── helpers ───────────────────────────────────────────────────────

    def default_sink_env(server)
      {"TART_SESSION_SINK_HOST" => server.url, "TART_SESSION_SINK_TOKEN" => "test-token"}
    end

    def new_sink(hooks:, server:, env: {}, config_path: "/nonexistent/i74.json", system_prompt: nil, tuning: TUNING)
      engine_env = server ? default_sink_env(server).merge(env) : env
      SessionSink.register(hooks:, identity: "tart", env: engine_env, config_path:, system_prompt:, tuning:)
    end

    def bind_session(hooks, session_id:, session_path: nil, cwd: Dir.pwd, mode: "print")
      hooks.emit({"type" => "session_start", "reason" => "startup"},
                 context: {cwd:, mode:, session: {"agent_session_id" => session_id, "agent_session_path" => session_path},
                           identity: "tart"})
    end

    def emit_user(hooks, text)
      hooks.emit({type: :message_end, message: Agent::Message.user(text)}, context: {identity: "tart"})
    end

    def records_text(post)
      post[:records][1..].map { |record| record.dig("message", "content", 0, "text") }
    end

    def mapped_stop_reason(reason)
      message = Agent::Message.new(role: :assistant, content: "x", finish_reason: reason)
      JSON.parse(JSON.generate(
        SessionSink.project_event({type: :message_end, message:}, S_ID, 1)))["message"]["stopReason"]
    end

    def capture_stderr
      old = $stderr
      io = StringIO.new
      $stderr = io
      yield
      io.string
    ensure
      $stderr = old
    end

    def wait_for(timeout: 5)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      until yield
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          flunk "condition never satisfied"
        end
        sleep 0.01
      end
    end

    def write_config(hash)
      path = File.join(staged_home, ".tart", "session-sink.json")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.generate(hash))
      path
    end

    def write_config_text(text)
      path = File.join(staged_home, ".tart", "session-sink.json")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, text)
      path
    end

    def ingest_server
      track_server(MockIngestServer.new.start)
    end

    def staged_home
      @staged ||= track_home(Dir.mktmpdir("i74-sink-"))
    end

    def track(engine)
      @engines << engine
      engine
    end

    def track_server(server)
      @servers << server
      server
    end

    def track_home(home)
      @homes << home
      home
    end

    def track_manager(manager)
      @managers ||= []
      @managers << manager
      manager
    end

    # The default child-env closure for the child_capture pins (the
    # subagents_test CLOSED-env shape, identity "pi").
    def default_capture_env
      {"PATH" => ENV["PATH"], "HOME" => staged_home, "PI_API_KEY" => "test-key", "PI_API_BASE" => "http://localhost:1/v1"}
    end

    def fake_parent_loop(id: "parent-session-id", path: "/tmp/parent.jsonl")
      recorder = Struct.new(:id, :path).new(id, path)
      Struct.new(:recorder).new(recorder)
    end

    def spawn_pinned_run(env:, agent:, identity: "pi")
      manager = track_manager(Subagents::Manager.new(cwd: Dir.pwd, home: File.join(staged_home, "subagents"),
                                                     env:, identity:, hooks: Hooks.new, agent:))
      run = manager.spawn_run(agent: "worker", task: "t", async: false, timeout_ms: 0, tool_timeout_ms: 0)
      [manager, run]
    end

    # A real print boot against the mock LLM + mock ingest: the config
    # rides the staged HOME's .tart/session-sink.json (the file law,
    # end to end). Yields [ingest, llm, home, stderr, exit_status, workdir].
    def boot_and_capture(config: :good, env_extra: {}, prompt: "hello world")
      ingest = ingest_server
      llm = MockLLMServer.new.start
      track_server(llm)
      llm.script(BOOT_SCRIPT)
      home = track_home(Dir.mktmpdir("i74-boot-"))
      workdir = track_home(Dir.mktmpdir("i74-work-"))
      FileUtils.mkdir_p(File.join(home, ".tart"))
      if config == :malformed
        File.write(File.join(home, ".tart", "session-sink.json"), "{not json")
      elsif config
        File.write(File.join(home, ".tart", "session-sink.json"),
                   JSON.generate({"host" => ingest.url, "token" => "ingest-token"}))
      end
      File.write(File.join(workdir, "space.yaml"),
                 YAML.dump({"version" => 2, "id" => "20261009-pi-port", "title" => "I74 Boot Space"}))
      env = {
        "PATH" => ENV.fetch("PATH"), "HOME" => home,
        "TART_MCP_CONFIG" => File.join(home, "absent-mcp.json"),
        "TART_API_KEY" => "k", "TART_API_BASE" => llm.url,
        "TART_IDENTITY" => nil, "TART_MODEL" => nil, "TART_PROVIDER" => nil,
        "TART_CONTEXT_WINDOW" => nil, "TART_MODEL_REASONING" => nil, "TART_THINKING_LEVEL" => nil,
        "PI_MODEL" => nil, "PI_PROVIDER" => nil, "PI_API_KEY" => nil, "PI_API_BASE" => nil,
        "PI_CONTEXT_WINDOW" => nil, "PI_SESSION_SINK_DISABLED" => nil,
        "TART_SESSION_SINK_HOST" => nil, "TART_SESSION_SINK_TOKEN" => nil,
        "TART_SESSION_SINK_DISABLED" => nil, "TART_SESSION_SINK_PARENT_SESSION_ID" => nil,
        "TART_SESSION_SINK_AGENT_NAME" => nil
      }.merge(env_extra)
      bin_tart = File.expand_path("bin/tart", Dir.pwd)
      _stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, bin_tart, "-p", prompt, chdir: workdir)
      yield ingest, llm, home, stderr, status.exitstatus, workdir
    end
  end
end
