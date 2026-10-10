# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/mock_llm_server"
require "tmpdir"
require "fileutils"

module RaspberryPi
  # The JSONL session store (AC1/AC2): recording an agent turn to a session
  # file, parsing it back, resume seeding (the model sees prior turns on the
  # wire), and most-recent-session-for-cwd selection — against the real
  # ruby_llm client over the local mock endpoint.
  class SessionTest < Test
    def setup
      @server = MockLLMServer.new.start
      @dir = Dir.mktmpdir("raspberry-pi-session-")
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

      # The resumed run records into a NEW file, header-linked to the old,
      # starting from the new user message (prior turns are not re-recorded).
      refute_equal first.path, resumed.path
      entries = Agent::Session.load_entries(resumed.path)
      header = entries.first
      assert_equal first.path, header["parentSession"]
      assert_equal %w[user assistant], entries[1..].map { |e| e["message"]["role"] }
      assert_equal "and then?", entries[1]["message"]["content"]
    end

    # AC4: the compaction entry shape (pi CompactionEntry session-manager.ts
    # :91-104, the port's field subset) and the null first-kept fallback
    # (appendCompaction's `firstKeptEntryId ?? id`).
    def test_recorder_appends_compaction_entries
      recorder = Agent::Session::Recorder.new(cwd: @dir, root: @root)
      recorder.append_message(RubyLLM::Message.new(role: :user, content: "hi"))
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
  end
end
