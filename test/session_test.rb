# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/mock_llm_server"
require "tmpdir"
require "fileutils"

module Tart
  # The JSONL session store (AC1/AC2): recording an agent turn to a session
  # file, parsing it back, resume seeding (the model sees prior turns on the
  # wire), and most-recent-session-for-cwd selection — against the real
  # fast-completions client over the local mock endpoint.
  class SessionTest < Test
    def setup
      @server = MockLLMServer.new.start
      @dir = Dir.mktmpdir("tart-session-")
      @root = File.join(@dir, "root")
    end

    def teardown
      @server.stop
      FileUtils.rm_rf(@dir)
    end

    def test_uuid7_is_time_ordered_v7
      first = Agent::Session.uuidv7(time: Time.at(1_000_000_000))
      second = Agent::Session.uuidv7(time: Time.at(2_000_000_000))

      assert_match(/\A[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/, first)
      assert first < second, "uuidv7 must sort by time"
    end

    def test_recorded_turn_writes_header_then_message_entries_in_order
      File.write(File.join(@dir, "fixture.txt"), "x")
      @server.script([
        {type: :stream, content: "listing", tool_calls: [{id: "call_1", name: "ls", arguments: {path: "."}}]},
        {type: :message, content: "the listing is above"}
      ])
      recorder = Agent::Session::Recorder.new(cwd: @dir, root: @root)
      agent = agent_on_kernel(tools: Tools::Registry.build(selected: %w[ls], cwd: @dir), recorder:)
      run_agent(agent, "list the files")

      assert File.exist?(recorder.path), "the first user message must create the file"
      assert_equal Agent::Session.dir_path(@dir, root: @root), File.dirname(recorder.path)
      assert_match(/_\w{8}-\w{4}-\w{4}-\w{4}-\w{12}\.jsonl\z/, File.basename(recorder.path))

      # One JSON object per line, parseable with malformed-line tolerance.
      raw_lines = File.readlines(recorder.path, chomp: true)
      entries = Agent::Session.parse_entries(File.read(recorder.path))
      assert_equal raw_lines.size, entries.size

      header = entries.first
      assert_equal "session", header["type"]
      assert_equal 3, header["version"]
      assert_equal recorder.id, header["id"]
      assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z\z/, header["timestamp"])
      assert_equal File.expand_path(@dir), header["cwd"]
      refute header.key?("parentSession")

      messages = entries[1..]
      assert_equal %w[user assistant tool assistant], messages.map { |e| e["message"]["role"] }
      assert messages.all? { |e| e["type"] == "message" }
      assert_equal "list the files", messages[0]["message"]["content"]
      assert_equal "the listing is above", messages[3]["message"]["content"]
      tool_entry = messages[2]["message"]
      assert_equal "call_1", tool_entry["tool_call_id"]
      assert_includes tool_entry["content"], "fixture.txt"

      # pi's leaf chain: parentId of the first message is null; each next
      # entry chains to the previous entry's id.
      assert_nil messages[0]["parentId"]
      messages.each_cons(2) { |prev, entry| assert_equal prev["id"], entry["parentId"] }
    end

    def test_parse_skips_malformed_lines_and_rejects_headerless_files
      path = File.join(@dir, "hand.jsonl")
      File.write(path, [
        '{"type":"session","version":3,"id":"abc","timestamp":"t","cwd":"/tmp"}',
        "not json at all",
        "",
        '{"type":"message","id":"e1","parentId":null,"timestamp":"t","message":{"role":"user","content":"hi"}}'
      ].join("\n"))

      entries = Agent::Session.load_entries(path)
      assert_equal 2, entries.size
      assert_equal "session", entries[0]["type"]
      assert_equal "hi", entries[1]["message"]["content"]

      # pi loadEntriesFromFile: a file that does not open with a valid
      # session header reads as empty.
      File.write(path, '{"type":"not-a-session"}')
      assert_empty Agent::Session.load_entries(path)
      assert_empty Agent::Session.load_entries(File.join(@dir, "missing.jsonl"))
    end

    def test_null_and_missing_content_tolerated_on_load
      path = File.join(@dir, "tolerant.jsonl")
      File.write(path, [
        '{"type":"session","version":3,"id":"abc","timestamp":"t","cwd":"/tmp"}',
        '{"type":"message","id":"e1","parentId":null,"timestamp":"t","message":{"role":"system","content":null}}',
        '{"type":"message","id":"e2","parentId":"e1","timestamp":"t","message":{"role":"user"}}',
        '{"type":"message","id":"e3","parentId":"e2","timestamp":"t","message":{"role":"assistant","content":null}}',
        '{"type":"usage","id":"e4","parentId":"e3","timestamp":"t"}'
      ].join("\n"))

      messages = Agent::Session.context_messages(path)
      assert_equal %i[system user assistant], messages.map { |m| m[:role] }
      assert_equal ["", "", ""], messages.map { |m| m[:content] },
        "null/missing content must be tolerated (the port's '' mapping), non-message entries project to nothing"
    end

    def test_resume_seeds_prior_turns_and_records_into_a_linked_new_file
      File.write(File.join(@dir, "fixture.txt"), "x")
      @server.script([
        {type: :stream, content: "listing", tool_calls: [{id: "call_1", name: "ls", arguments: {path: "."}}]},
        {type: :message, content: "the listing is above"}
      ])
      tools = Tools::Registry.build(selected: %w[ls], cwd: @dir)
      first = Agent::Session::Recorder.new(cwd: @dir, root: @root)
      run_agent(agent_on_kernel(tools:, recorder: first), "list the files")
      first_entries = Agent::Session.load_entries(first.path)[1..]

      @server.script([{type: :message, content: "continuing"}])
      resumed = Agent::Session::Recorder.new(cwd: @dir, root: @root, parent_session: first.path)
      seed = Agent::Session.context_messages(first.path)
      run_agent(agent_on_kernel(tools:, recorder: resumed, seed_messages: seed), "and then?")

      # The model demonstrably sees the prior turns: the captured request
      # payload carries them ahead of the new prompt.
      payload = @server.captured_requests.last["messages"]
        .reject { |m| %w[system developer].include?(m["role"]) } # the with_instructions system prompt
      assert_equal %w[user assistant tool assistant user], payload.map { |m| m["role"] }
      assert_equal "list the files", payload[0]["content"]
      assert_equal "call_1", payload[2]["tool_call_id"]
      assert_equal "and then?", payload[4]["content"]

      # The resumed run records into a NEW file, header-linked to the old.
      # The fork is content-complete (pi forkFrom :1847-1853, I42): the
      # parent's non-header entries copy VERBATIM — original ids/parentIds,
      # original contents — and the new turn chains from the copied tail.
      refute_equal first.path, resumed.path
      entries = Agent::Session.load_entries(resumed.path)
      header = entries.first
      assert_equal first.path, header["parentSession"]

      lineage = entries[1, 4]
      assert_equal %w[user assistant tool assistant], lineage.map { |e| e["message"]["role"] },
        "the copied lineage precedes the new turn"
      assert_equal first_entries, lineage, "copied entries are byte-identical (verbatim copy)"

      new_turns = entries[5..]
      assert_equal %w[user assistant], new_turns.map { |e| e["message"]["role"] }
      assert_equal "and then?", new_turns[0]["message"]["content"]
      assert_equal lineage.last["id"], new_turns[0]["parentId"],
        "the new leaf chains from the copied tail"

      # Self-contained: the resumed FILE alone replays the full lineage
      # (no re-seed from the parent needed — a second resume hop composes).
      assert_equal %i[user assistant tool assistant user assistant],
        Agent::Session.context_messages(resumed.path).map { |m| m[:role] }
    end

    # The bashExecution record (pi recordBashResult agent-session.ts:3879)
    # projects to a USER context message — pi convertToLlm's bashExecution
    # case (messages.ts:149-160) with the bashExecutionToText bytes
    # (messages.ts:82-97). The !!-prefixed execution (excludeFromContext)
    # is skipped entirely.
    def test_bash_execution_record_projects_to_user_context
      recorder = Agent::Session::Recorder.new(cwd: @dir, root: @root)
      recorder.append_bash_execution(Agent::Session.bash_execution_message(
        command: "echo hi", output: "hi\n", exit_code: 0, cancelled: false,
        truncated: false, full_output_path: nil))

      entry = Agent::Session.load_entries(recorder.path).last
      projected = Agent::Session.entry_to_context_message(entry)
      assert_equal :user, projected.role
      # pi's bytes: the raw output (its trailing newline included)
      # fenced between the code markers.
      assert_equal "Ran `echo hi`\n```\nhi\n\n```", projected.content
    end

    def test_bash_execution_context_text_variants
      build = lambda do |overrides|
        Agent::Session.bash_execution_message(command: "x", output: "out", exit_code: 0,
          cancelled: false, truncated: false, full_output_path: nil, **overrides)
      end
      # The projection reads LOADED entries — the JSON round-trip (string
      # keys), exactly what a resume reads.
      text = lambda do |message|
        entry = Agent::Session.message_entry(message, id: "e", parent_id: nil, timestamp: "t")
        Agent::Session.entry_to_context_message(JSON.parse(JSON.generate(entry))).content
      end

      assert_equal "Ran `x`\n(no output)", text.call(build.call(output: "")),
        "empty output renders the placeholder (bashExecutionToText)"
      assert_equal "Ran `x`\n```\nout\n```\n\nCommand exited with code 2",
        text.call(build.call(exit_code: 2)), "the non-zero exit notice"
      assert_equal "Ran `x`\n```\nout\n```\n\n(command cancelled)",
        text.call(build.call(cancelled: true)), "the cancellation notice"
      assert_equal "Ran `x`\n```\nout\n```\n\n[Output truncated. Full output: /tmp/x.log]",
        text.call(build.call(truncated: true, full_output_path: "/tmp/x.log")),
        "the truncation notice — pi's USER-bash wording, not the tool's"
    end

    def test_bang_bang_execution_is_skipped_from_context
      message = Agent::Session.bash_execution_message(command: "echo secret", output: "s", exit_code: 0,
        cancelled: false, truncated: false, full_output_path: nil, exclude_from_context: true)
      entry = Agent::Session.message_entry(message, id: "e", parent_id: nil, timestamp: "t")
      assert_nil Agent::Session.entry_to_context_message(JSON.parse(JSON.generate(entry)))
    end

    # The resumed run's model demonstrably sees the !-execution: the
    # captured request payload carries the projected user message.
    def test_resumed_run_sees_the_bash_execution_in_context
      recorder = Agent::Session::Recorder.new(cwd: @dir, root: @root)
      recorder.append_bash_execution(Agent::Session.bash_execution_message(
        command: "echo hi", output: "hi\n", exit_code: 0, cancelled: false,
        truncated: false, full_output_path: nil))

      @server.script([{type: :message, content: "noted"}])
      tools = Tools::Registry.build(selected: [], cwd: @dir)
      seed = Agent::Session.context_messages(recorder.path)
      resumed = Agent::Session::Recorder.new(cwd: @dir, root: @root, parent_session: recorder.path)
      run_agent(agent_on_kernel(tools:, recorder: resumed, seed_messages: seed), "and then?")

      payload = @server.captured_requests.last["messages"]
        .reject { |m| %w[system developer].include?(m["role"]) }
      assert_equal %w[user user], payload.map { |m| m["role"] }
      assert_match(/\ARan `echo hi`/, payload[0]["content"])
    end

    # AC4: the compaction entry shape (pi CompactionEntry session-manager.ts
    # :91-104, the port's field subset) and the null first-kept fallback
    # (appendCompaction's `firstKeptEntryId ?? id`).
    def test_recorder_appends_compaction_entries
      recorder = Agent::Session::Recorder.new(cwd: @dir, root: @root)
      recorder.append_message(Agent::Message.user("hi"))
      id = recorder.append_compaction(summary: "the summary", first_kept_entry_id: nil,
        tokens_before: 42, details: {"readFiles" => ["a.rb"], "modifiedFiles" => []})

      entries = Agent::Session.load_entries(recorder.path)
      compaction = entries.last
      assert_equal "compaction", compaction["type"]
      assert_equal id, compaction["id"]
      assert_equal entries[1]["id"], compaction["parentId"]
      assert_equal id, compaction["firstKeptEntryId"], "null first-kept falls back to the entry id"
      assert_equal "the summary", compaction["summary"]
      assert_equal 42, compaction["tokensBefore"]
      assert_equal({"readFiles" => ["a.rb"], "modifiedFiles" => []}, compaction["details"])
    end

    # AC3 (I30): the summarization usage persists on the compaction entry
    # (pi CompactionEntry.usage, session-manager.ts:99) — camelCase, the
    # round-trip through the file; estimated_tokens_after is not a field
    # (pi doesn't carry it); nil usage omits the key (pi's optional
    # usage — JSON drops undefined).
    def test_recorder_persists_the_summarization_usage_on_the_compaction_entry
      recorder = Agent::Session::Recorder.new(cwd: @dir, root: @root)
      recorder.append_message(Agent::Message.user("hi"))
      recorder.append_compaction(summary: "the summary", first_kept_entry_id: nil, tokens_before: 42,
        details: {}, usage: {"input" => 10, "output" => 5, "totalTokens" => 15})
      recorder.append_compaction(summary: "second", first_kept_entry_id: nil, tokens_before: 1, details: {})

      entries = Agent::Session.load_entries(recorder.path)
      assert_equal({"input" => 10, "output" => 5, "totalTokens" => 15}, entries[2]["usage"])
      refute entries[2].key?("estimatedTokensAfter")
      refute entries[3].key?("usage")
    end

    # AC3 (I30): the gem's Usage readers map onto pi's Usage (types.ts
    # :446) camelCase persisted shape — nothing unreported persists; the
    # 1h-ttl cache-write sub-key died with the replaced client; the
    # cache-write zero persists (the recorded parser default) while an
    # unreported cache-read drops; totalTokens is the gem's NATIVE total
    # (OQ-9); nothing reported persists nothing (pi's usage-undefined
    # entries).
    def test_compaction_usage_maps_the_gem_usage_to_pis_usage_shape
      usage = Fast::Completions::Usage.new(input: 10, output: 5, cache_read: 4,
        cache_write: 2, reasoning: 3, total_tokens: 24)
      assert_equal(
        {"input" => 10, "output" => 5, "cacheRead" => 4, "cacheWrite" => 2,
         "reasoning" => 3, "totalTokens" => 24},
        Agent::Session.compaction_usage(usage))

      # The frozen parser asymmetry: the reported zero cache WRITE
      # persists, an unreported (zero) cache READ drops.
      mocked = Fast::Completions::Usage.new(input: 10, output: 5, total_tokens: 15)
      assert_equal({"input" => 10, "output" => 5, "cacheWrite" => 0, "totalTokens" => 15},
        Agent::Session.compaction_usage(mocked))

      assert_nil Agent::Session.compaction_usage(Fast::Completions::Usage::ZERO)
      assert_nil Agent::Session.compaction_usage(nil)
    end

    # AC3 (I30): the recorder's context projection (pi buildContextEntries
    # :475-513) — the compaction entry leading, the kept entries from
    # firstKeptEntryId onward (system messages skipped), the as-loaded
    # shape load_entries reads back.
    def test_recorder_context_entries_projects_the_kept_tail
      recorder = Agent::Session::Recorder.new(cwd: @dir, root: @root)
      recorder.append_message(Agent::Message.user("old question"))
      recorder.append_message(Agent::Message.new(role: :system, content: "prompt state"))
      kept_id = recorder.append_message(Agent::Message.new(role: :assistant, content: "kept answer"))
      recorder.append_compaction(summary: "the summary", first_kept_entry_id: kept_id,
        tokens_before: 1, details: {})

      entries = recorder.context_entries
      assert_equal "compaction", entries.first["type"]
      assert_equal ["kept answer"], entries.drop(1).map { |e| e["message"]["content"] }
      assert_equal Agent::Session.load_entries(recorder.path)[3, 1], entries.drop(1)
    end

    # AC4: compaction-aware context replay (pi buildContextEntries
    # :475-513): the summary, the kept entries from firstKeptEntryId
    # (system messages skipped), everything after — none of the
    # summarized-away messages; files without compaction entries unchanged.
    def test_compaction_aware_context_messages_replay
      path = File.join(@dir, "compacted.jsonl")
      File.write(path, [
        '{"type":"session","version":3,"id":"abc","timestamp":"t","cwd":"/tmp"}',
        '{"type":"message","id":"e1","parentId":null,"timestamp":"t","message":{"role":"user","content":"old question"}}',
        '{"type":"message","id":"e2","parentId":"e1","timestamp":"t","message":{"role":"assistant","content":"old answer"}}',
        '{"type":"message","id":"e2b","parentId":"e2","timestamp":"t","message":{"role":"system","content":"prompt state"}}',
        '{"type":"compaction","id":"e3","parentId":"e2b","timestamp":"t","summary":"the summary","firstKeptEntryId":"e2","tokensBefore":42,"details":{"readFiles":[],"modifiedFiles":[]}}',
        '{"type":"message","id":"e4","parentId":"e3","timestamp":"t","message":{"role":"user","content":"after compaction"}}',
      ].join("\n"))

      messages = Agent::Session.context_messages(path)
      assert_equal %i[user assistant user], messages.map { |m| m[:role] }
      assert_includes messages[0][:content],
        "The conversation history before this point was compacted into the following summary:"
      assert_includes messages[0][:content], "the summary"
      assert_includes messages[0][:content], "</summary>"
      assert_equal "old answer", messages[1][:content]
      assert_equal "after compaction", messages[2][:content]
    end

    # AC4 end-to-end: the seeded next-request payload on a compacted
    # session file shows exactly summary + kept + after, and none of the
    # pre-compaction summarized messages.
    def test_resume_after_compaction_seeds_the_compacted_context
      @server.script([{type: :message, content: "continuing"}])
      path = File.join(@dir, "compacted.jsonl")
      File.write(path, [
        '{"type":"session","version":3,"id":"abc","timestamp":"t","cwd":"/tmp"}',
        '{"type":"message","id":"e1","parentId":null,"timestamp":"t","message":{"role":"user","content":"old question"}}',
        '{"type":"message","id":"e2","parentId":"e1","timestamp":"t","message":{"role":"assistant","content":"old answer"}}',
        '{"type":"compaction","id":"e3","parentId":"e2","timestamp":"t","summary":"the summary","firstKeptEntryId":"e2","tokensBefore":42,"details":{"readFiles":[],"modifiedFiles":[]}}',
        '{"type":"message","id":"e4","parentId":"e3","timestamp":"t","message":{"role":"user","content":"after compaction"}}',
      ].join("\n"))

      recorder = Agent::Session::Recorder.new(cwd: @dir, root: @root, parent_session: path)
      run_agent(agent_on_kernel(recorder:, seed_messages: Agent::Session.context_messages(path)), "and now?")

      payload = @server.captured_requests.last["messages"]
        .reject { |m| %w[system developer].include?(m["role"]) }
      assert_equal %w[user assistant user user], payload.map { |m| m["role"] }
      assert_includes payload[0]["content"], "the summary"
      refute_includes payload[0]["content"], "old question", "the summarized-away turn is gone"
      assert_equal "old answer", payload[1]["content"]
      assert_equal "after compaction", payload[2]["content"]
      assert_equal "and now?", payload[3]["content"]
    end

    def test_most_recent_session_for_cwd_selection
      dir = Agent::Session.ensure_dir(@dir, root: @root)
      other_cwd = File.join(@dir, "elsewhere")
      matching_old = write_session_file(dir, cwd: @dir)
      matching_new = write_session_file(dir, cwd: @dir)
      foreign_new = write_session_file(dir, cwd: other_cwd)
      # mtimes: matching_old < matching_new < foreign_new
      FileUtils.touch(matching_old, mtime: Time.at(1_000))
      FileUtils.touch(matching_new, mtime: Time.at(2_000))
      FileUtils.touch(foreign_new, mtime: Time.at(3_000))

      assert_equal matching_new, Agent::Session.find_most_recent(dir, cwd: @dir),
        "the newest session whose header cwd resolves to the requested cwd"
      assert_equal foreign_new, Agent::Session.find_most_recent(dir, cwd: nil),
        "no cwd filter: the newest session regardless of header cwd"
      assert_nil Agent::Session.find_most_recent(dir, cwd: other_cwd.tr("w", "x"))
      assert_nil Agent::Session.find_most_recent(File.join(@dir, "nope"))
    end

    def test_recorder_off_when_nil
      @server.script([{type: :message, content: "ok"}])
      agent = agent_on_kernel
      run_agent(agent, "hi")

      assert_equal "ok", agent.new_messages.last.content
      assert_empty Dir.glob(File.join(@root, "sessions", "**", "*.jsonl")),
        "no recorder, no files anywhere under the root"
    end

    # --- I60 error_transcript: the failure entry (D1/D2) --------------------

    # AC1: the synthesized failure message round-trips through the recorder
    # — the file gains the entry on the leaf chain with the D1 byte family
    # (no token keys), and the context projection reads it back as a plain
    # assistant ContextMessage.
    def test_error_transcript_failure_entry_round_trips_through_the_recorder
      @server.script([{type: :error, status: 400, message: "The max_tokens parameter is illegal."}])
      recorder = Agent::Session::Recorder.new(cwd: @dir, root: @root)
      agent = agent_on_kernel(recorder:)
      run_agent(agent, "hello")

      entries = File.readlines(recorder.path).map { |line| JSON.parse(line) }
      assert_equal 3, entries.size, "header + user + the failure entry — the two-line defect is dead"
      assert_equal({"role" => "assistant", "content" => "", "tool_calls" => {},
                    "finish_reason" => "error",
                    "error_message" => "400: The max_tokens parameter is illegal."},
        entries.last["message"], "the D1 byte family — error_message rides, no token keys")
      assert_equal entries[1]["id"], entries.last["parentId"], "the entry chains from the user turn"

      # The context readback: a plain assistant context message (the wire
      # conversion's empty-assistant skip keeps it off every request).
      context = Agent::Session.context_messages(recorder.path)
      assert_equal({role: :assistant, content: "", tool_calls: {}, finish_reason: "error",
                    error_message: "400: The max_tokens parameter is illegal."},
        context.last)
    end

    # AC1: the seed side — from_seed_hash reads declared fields only: a
    # resumed failure message seeds content ""/finish_reason "error" while
    # error_message stays display-side (replay renders from the RAW entry
    # hash); pre-I60 files (no error_message key) seed byte-identically.
    def test_error_transcript_seed_keeps_error_message_display_side
      recorded = Agent::Message.error_failure(error_message: "400: boom")
      seeded = Agent::Message.from_seed_hash(recorded.to_h.transform_keys(&:to_s))

      assert_equal "", seeded.content
      assert_equal "error", seeded.finish_reason
      assert_nil seeded.error_message, "error_message is display-side — the seed never reads it"
      assert_nil seeded.tokens&.input, "the seed's token duck carries no counts (no token keys recorded)"

      pre_i60 = Agent::Message.new(role: :assistant, content: "done", tokens: nil, finish_reason: "stop")
      reseeded = Agent::Message.from_seed_hash(pre_i60.to_h.transform_keys(&:to_s))
      assert_equal "done", reseeded.content
      assert_equal "stop", reseeded.finish_reason
      assert_nil reseeded.error_message, "pre-I60 files: no error_message key, nothing changes"
    end

    # Session.list (item 2/AC2, pi SessionManager.list's discovery shape):
    # the cwd's valid-header sessions, mtime descending, fixture-rooted.
    def test_lists_the_cwd_s_sessions_newest_first
      dir = Agent::Session.ensure_dir(@dir, root: @root)
      other_cwd = File.join(@dir, "elsewhere")
      old = write_session_file(dir, cwd: @dir)
      newest = write_session_file(dir, cwd: @dir)
      foreign = write_session_file(dir, cwd: other_cwd)
      broken = File.join(dir, "broken.jsonl")
      File.write(broken, "not a session header\n")
      FileUtils.touch(old, mtime: Time.at(1_000))
      FileUtils.touch(newest, mtime: Time.at(2_000))
      FileUtils.touch(foreign, mtime: Time.at(3_000))
      FileUtils.touch(broken, mtime: Time.at(4_000))

      assert_equal [newest, old], Agent::Session.list(cwd: @dir, root: @root),
        "mtime descending, valid headers only, header cwd resolved to the requested cwd"
      assert_empty Agent::Session.list(cwd: File.join(@dir, "nowhere"), root: @root)
    end

    def test_preview_carries_the_first_user_message
      dir = Agent::Session.ensure_dir(@dir, root: @root)
      path = File.join(dir, "#{Agent::Session.uuidv7}.jsonl")
      header = Agent::Session.header(id: Agent::Session.uuidv7, cwd: @dir)
      entry = Agent::Session.message_entry({role: "user", content: "  fix the\n  flaky test  "},
        id: Agent::Session.generate_id(Set.new), parent_id: nil, timestamp: Agent::Session.now_iso)
      File.write(path, "#{JSON.generate(header)}\n#{JSON.generate(entry)}\n")

      assert_equal "fix the flaky test", Agent::Session.preview(path),
        "squashed first user message (pi renders session.firstMessage)"
      assert_nil Agent::Session.preview(File.join(dir, "absent.jsonl"))
    end

    # persisted? (item 1/AC1, pi isPersisted :1166): false until the first
    # user/assistant message flushes the file; true after.
    def test_persisted_tracks_the_first_flush
      recorder = Agent::Session::Recorder.new(cwd: @dir, root: @root)
      refute recorder.persisted?, "a setup-only session leaves no file"

      message = Agent::Message.user("hi")
      recorder.append_message(message)
      assert recorder.persisted?, "the file exists once a user message landed"
    end

    # The shapes-family additive pins (I44): the wrap tolerance rows ride
    # the REAL loaded-file path, the projection output stays today's Hash
    # shape (the .to_h-at-the-gem-seam rule), and read_header returns the
    # typed header with the discovery reads intact.
    def test_shapes_wraps_tolerance_rows_on_the_load_path
      path = File.join(@dir, "tolerant.jsonl")
      File.write(path, [
        '{"type":"session","version":3,"id":"abc","timestamp":"t","cwd":"/tmp"}',
        "not json at all",
        '{"type":"usage","id":"e0","parentId":null,"timestamp":"t"}',
        '{"type":"message","id":"e1","parentId":null,"timestamp":"t","message":"nope"}',
        '{"type":"message","id":"e2","parentId":null,"timestamp":"t","message":{"content":"role-less"}}',
        '{"type":"message","id":"e3","parentId":null,"timestamp":"t","message":{"role":"user","content":null}}'
      ].join("\n"))

      assert_equal({role: :user, content: ""}, Agent::Session.context_messages(path).first,
        "every malformed class projects to nothing; the one good row carries null content as the empty string")
    end

    def test_context_messages_output_stays_the_recorded_hash_shape
      path = File.join(@dir, "shape.jsonl")
      File.write(path, [
        '{"type":"session","version":3,"id":"abc","timestamp":"t","cwd":"/tmp"}',
        '{"type":"message","id":"e1","parentId":null,"timestamp":"t","message":{"role":"user","content":"q"}}',
        '{"type":"message","id":"e2","parentId":"e1","timestamp":"t","message":{"role":"assistant","content":null,"tool_calls":[{"id":"call_1","name":"ls","arguments":{"path":"."}}]}}',
        '{"type":"message","id":"e3","parentId":"e2","timestamp":"t","message":{"role":"tool","tool_call_id":"call_1","content":"fixture.txt"}}'
      ].join("\n"))

      messages = Agent::Session.context_messages(path)
      messages.each { |message| assert_instance_of Hash, message, "the add_message seam consumes plain hashes" }
      assert_equal({role: :user, content: "q"}, messages[0])
      assert_equal({role: :assistant, content: "", tool_calls: [{"id" => "call_1", "name" => "ls",
        "arguments" => {"path" => "."}}]}, messages[1],
        "the open body rides whole, in the recorded key order (the wire shape)")
      assert_equal({role: :tool, tool_call_id: "call_1", content: "fixture.txt"}, messages[2])
    end

    def test_read_header_returns_the_typed_header
      path = File.join(@dir, "headed.jsonl")
      File.write(path, [
        '{"type":"session","version":3,"id":"abc","timestamp":"t","cwd":"/tmp","parentSession":"/old"}',
        '{"type":"message","id":"e1","parentId":null,"timestamp":"t","message":{"role":"user","content":"hi"}}'
      ].join("\n"))

      header = Agent::Session.read_header(path)
      assert_instance_of Shapes::SessionHeader, header
      assert_equal "abc", header.id
      assert_equal "/tmp", header.cwd
      assert_equal "3", header.version.to_s, "the metadata rides nominal"
      assert_equal "/old", header.parentSession
      assert_equal "/old", header["parentSession"], "the discovery reads stay (string-keyed, nil-safe)"
      assert_nil Agent::Session.read_header(File.join(@dir, "absent.jsonl"))
    end

    # ---- I77: the model identity battery (AC3) — every assistant from a
    # live chat records its running `provider` + `model` (pi's own
    # per-assistant pair), present-only, so the 06:58Z forensics gap (six
    # malformed calls, no model identity anywhere in the file) cannot recur.

    # A model-bearing assistant projects the pair at the frozen key
    # position (immediately after tool_calls) with the usage conventions
    # intact.
    def test_model_identity_assistant_to_h_emits_the_pair_at_the_frozen_key_position
      message = Agent::Message.new(role: :assistant, content: "hi", provider: "openrouter",
        model: "reflection/beam-1.0-501b-a23b:nitro",
        tokens: Agent::Tokens.new(input: 5, output: 4, cache_write: 0), finish_reason: "stop")
      assert_equal [:role, :content, :tool_calls, :provider, :model, :finish_reason,
                    :input_tokens, :output_tokens, :cache_write_tokens], message.to_h.keys,
        "the pair rides immediately after tool_calls, before thinking/usage"
      assert_equal "openrouter", message.to_h[:provider]
      assert_equal "reflection/beam-1.0-501b-a23b:nitro", message.to_h[:model]
    end

    # The pair sits between tool_calls and thinking when a thinking text
    # rides too (the frozen position is relative, not trailing).
    def test_model_identity_pair_precedes_the_thinking_keys
      message = Agent::Message.new(role: :assistant, content: "hi", provider: "zai", model: "glm-5.3",
        thinking: Agent::Thinking.new(text: "because", signature: "reasoning_content"))
      keys = message.to_h.keys
      assert keys.index(:tool_calls) < keys.index(:provider), "after tool_calls"
      assert keys.index(:model) < keys.index(:thinking), "before thinking"
      assert_equal [:role, :content, :tool_calls, :provider, :model, :thinking, :thinking_signature], keys
    end

    # The nil-gated byte shape: a model-less assistant (the fixture-seed
    # class) keeps the exact frozen key set — session-golden holds with NO
    # re-pin.
    def test_model_identity_model_less_assistant_keeps_the_frozen_key_set
      plain = Agent::Message.new(role: :assistant, content: "hi").to_h
      assert_equal [:role, :content, :tool_calls], plain.keys
      tokened = Agent::Message.new(role: :assistant, content: "hi",
        tokens: Agent::Tokens.new(input: 5, output: 4, cache_write: 0), finish_reason: "stop").to_h
      assert_equal [:role, :content, :tool_calls, :finish_reason, :input_tokens, :output_tokens,
                    :cache_write_tokens], tokened.keys, "no identity keys without a model"
    end

    # The pair survives the recorder round trip (the recorded line carries
    # the string keys, parse-back equal) — the forensics gap is closed.
    def test_model_identity_pair_survives_the_recorder_round_trip
      recorder = Agent::Session::Recorder.new(cwd: @dir, root: @root)
      # a lone assistant never opens the file (pi's conversation-bearing
      # gate) — the user turn opens it, the assistant rides the flush
      recorder.append_message(Agent::Message.user("hi"))
      recorder.append_message(Agent::Message.new(role: :assistant, content: "the answer",
        provider: "openrouter", model: "reflection/beam-1.0-501b-a23b:nitro"))

      entry = File.readlines(recorder.path).map { |line| JSON.parse(line) }
        .find { |line| line["message"] && line["message"]["role"] == "assistant" }["message"]
      assert_equal "openrouter", entry["provider"]
      assert_equal "reflection/beam-1.0-501b-a23b:nitro", entry["model"]
    end

    # Replay safety: from_seed_hash reads DECLARED fields only — a
    # model-bearing recorded body seeds model-inert (the wire re-stamp is
    # the live model) — wire-delta EXACT holds with no re-pin.
    def test_model_identity_seed_from_a_model_bearing_body_is_model_inert
      recorder = Agent::Session::Recorder.new(cwd: @dir, root: @root)
      recorder.append_message(Agent::Message.user("hi"))
      recorder.append_message(Agent::Message.new(role: :assistant, content: "the answer",
        provider: "openrouter", model: "reflection/beam-1.0-501b-a23b:nitro"))
      entry = File.readlines(recorder.path).map { |line| JSON.parse(line) }
        .find { |line| line["message"] && line["message"]["role"] == "assistant" }["message"]

      seed = Agent::Message.from_seed_hash(entry)
      assert_nil seed.model
      assert_nil seed.provider
      assert_equal "the answer", seed.content
    end

    # The synthesized failure assistant (error_failure — no model stamped)
    # gains no keys.
    def test_model_identity_error_failure_assistant_gains_no_keys
      failure = Agent::Message.error_failure(error_message: "boom")
      assert_equal [:role, :content, :tool_calls, :finish_reason, :error_message], failure.to_h.keys
    end

    # User and tool messages gain no keys.
    def test_model_identity_user_and_tool_messages_gain_no_keys
      assert_equal [:role, :content], Agent::Message.user("hi").to_h.keys
      tool = Agent::Message.tool(tool_call_id: "c1", content: "x").to_h
      assert_equal [:role, :content, :tool_call_id], tool.keys
    end

    private

    def agent_on_kernel(tools: {}, recorder: nil, seed_messages: [])
      chat = TestChat.build(@server, tools: tools.values, system_prompt: "test prompt")
      Agent::Loop.new(chat:, tools:, recorder:, seed_messages:)
    end

    def run_agent(agent, prompt)
      kernel = Core::Loop.new(session: ScriptedSession.new)
      kernel.run { agent.run(prompt) }
    end

    # A minimal but valid session file (header + one user message entry).
    def write_session_file(dir, cwd:)
      path = File.join(dir, "#{Agent::Session.uuidv7}.jsonl")
      header = Agent::Session.header(id: Agent::Session.uuidv7, cwd:, timestamp: Agent::Session.now_iso)
      entry = Agent::Session.message_entry({role: "user", content: "hi"},
        id: Agent::Session.generate_id(Set.new), parent_id: nil, timestamp: Agent::Session.now_iso)
      File.write(path, "#{JSON.generate(header)}\n#{JSON.generate(entry)}\n")
      path
    end

    # --- I47: the custom_message entry (pi CustomMessageEntry,
    # session-manager.ts:1339-1360) ---

    def test_append_custom_message_writes_the_pi_entry_shape_on_the_leaf_chain
      recorder = Agent::Session::Recorder.new(cwd: @dir, root: @root)
      user_id = recorder.append_message(OpenStruct.new(role: :user, content: "hi", to_h: {role: "user", content: "hi"}))
      custom_id = recorder.append_custom_message(custom_type: "memory-recall", content: "RECALL", display: true)

      entries = File.readlines(recorder.path).map { |line| JSON.parse(line) }
      custom = entries[2]
      assert_equal({"type" => "custom_message", "customType" => "memory-recall", "content" => "RECALL",
                    "display" => true}, custom.slice("type", "customType", "content", "display"))
      assert_equal user_id, custom["parentId"], "the entry chains from the leaf"
      assert_equal custom_id, custom["id"]
      assert custom["timestamp"]
      refute custom.key?("details"), "pi's details-undefined is omitted"
    end

    def test_a_custom_message_never_opens_the_session_file
      recorder = Agent::Session::Recorder.new(cwd: @dir, root: @root)
      recorder.append_custom_message(custom_type: "memory-recall", content: "RECALL", display: true)

      refute recorder.persisted?, "a recall never creates a session file alone"
      refute File.exist?(recorder.path)

      recorder.append_message(OpenStruct.new(role: :user, content: "hi", to_h: {role: "user", content: "hi"}))
      assert recorder.persisted?
      types = File.readlines(recorder.path).map { |line| JSON.parse(line)["type"] }
      assert_equal %w[session custom_message message], types, "the held entry rides the first flush in order"
    end

    def test_custom_message_replays_as_a_user_role_context_message
      recorder = Agent::Session::Recorder.new(cwd: @dir, root: @root)
      recorder.append_message(OpenStruct.new(role: :user, content: "hi", to_h: {role: "user", content: "hi"}))
      recorder.append_custom_message(custom_type: "memory-recall", content: "RECALL", display: true)

      messages = Agent::Session.context_messages(recorder.path)

      assert_equal [%i[user user], ["hi", "RECALL"]], messages.map { |message| [message[:role], message[:content]] },
        "pi sessionEntryToContextMessages: the recall text rides the wire again on resume"
    end
  end
end
