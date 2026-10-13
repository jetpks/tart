# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/mock_llm_server"
require "open3"
require "tmpdir"
require "fileutils"
require "json"
require "shellwords"

module Tart
  # The I42 e2e-session instrument (AC1–AC5): the REAL `bin/tart` in print
  # mode as a subprocess against the REAL working tree — a scripted
  # six-tool session (read / grep / find / bash / edit / write), a resume
  # by id (the model sees the recorded turns), a resume by path under
  # long-run compaction (PI_CONTEXT_WINDOW=10 + zeroed knobs), and the
  # compacted re-resume (most-recent) proving the usage drop.
  #
  # Hermeticity: per leg a FRESH staged HOME (Dir.mktmpdir — the owner's
  # real ~/.tart is never written) staged with the full-7 defaultTools
  # (the I41 restore hatch; legs C/C2 add zeroed compaction knobs), an
  # ABSENT TART_MCP_CONFIG, and a subprocess env of exactly
  # {PATH, HOME, PI_API_KEY, PI_API_BASE, TART_MCP_CONFIG} via
  # unsetenv_others (no live key, no owner env leaks; gems resolve from
  # the ruby gem home — the rig's verified staging, runner.rb:326-330).
  # The only network is the MockLLMServer on 127.0.0.1. Scratch targets
  # live under <root>/tmp/ (gitignored) and die at teardown.
  #
  # Legs B/C/C2 resume the previous leg's session, and a session lives
  # under its run's HOME — so each leg TEST re-runs the full predecessor
  # chain as REAL subprocess runs inside its own fresh home (1 + 2 + 3 + 4
  # boots across the four methods). The lineage, the parentSession links,
  # and the most-recent selection are therefore the run's true products,
  # never copied fixtures; and leg C2's size comparison against leg C's
  # first request reads the same server's capture, as the AC requires.
  # Prefix helpers assert only exit 0 + request counts (fail-fast
  # plumbing); the deep assertions live in the leg's own test method.
  class E2ESessionTest < Test
    REPO_ROOT = File.expand_path("#{__dir__}/..")

    A_PROMPT = "work the six-tool checklist on this tree"
    A_FINAL = "e2e leg A final: all six tools answered"
    A_MARKER = "E2E-EDIT-MARKER-ORIGINAL"
    A_REPLACEMENT = "E2E-EDIT-MARKER-EDITED"
    A_SUMMARY_TEXT = "e2e leg A summary: six tools exercised"
    B_PROMPT = "continue from the recorded turns (leg B)"
    B_FINAL = "e2e leg B final: prior context replayed"
    C_PROMPT = "long-run turn (leg C)"
    C_TURN = "e2e leg C turn answer"
    C_SUMMARY = "e2e compaction summary: earlier turns folded"
    C2_PROMPT = "post-compaction question (leg C2)"
    C2_FINAL = "e2e leg C2 final: summary seeded"

    def setup
      @server = MockLLMServer.new.start
      @home = Dir.mktmpdir("tart-e2e-home-")
      @scratch = File.join(space_root, "tmp", "i42-e2e-#{object_id}")
      FileUtils.mkdir_p(@scratch)
      puts "[e2e] space root: #{space_root}"
      puts "[e2e] repo dir:    #{repo_dir}"
      puts "[e2e] staged HOME: #{@home}"
      puts "[e2e] scratch dir: #{@scratch}"
    end

    def teardown
      @server.stop
      FileUtils.rm_rf(@home)
      FileUtils.rm_rf(@scratch)
    end

    # Leg A (AC1/AC2/AC3): the six-tool run records one session file —
    # header + every conversation message in order — and the bash turn's
    # PI_SESSION_ID/PI_SESSION_FILE match that recording (the recorder-
    # backed print session env, proven in the large).
    def test_leg_a_six_tool_run_records_the_session
      requests, a_path, header, entries = run_leg_a

      # One scripted response per request: a tool result rides the NEXT
      # request's payload.
      first_line = File.readlines(File.join(repo_dir, "lib/tart/agent/loop.rb")).first.chomp
      assert_includes tool_message(requests[1], "c1"), first_line, "read carries loop.rb's first line"
      assert_includes tool_message(requests[2], "c2"), "seam_bench.rb", "grep names seam_bench.rb"
      assert_includes tool_message(requests[3], "c3"), "registry.rb", "find names registry.rb"
      bash_lines = tool_message(requests[4], "c4").lines.map(&:strip)
      assert_equal space_root, bash_lines[0], "bash pwd == the space root"
      assert_equal header.fetch("id"), bash_lines[1], "PI_SESSION_ID == the recorded header id"
      assert_equal a_path, bash_lines[2], "PI_SESSION_FILE == the recorded session path"
      assert_equal "line one\n#{A_REPLACEMENT}\nline three\n", File.read(File.join(@scratch, "edit-me.md"))
      assert_equal A_SUMMARY_TEXT, File.read(File.join(@scratch, "summary.md"))

      # The recording: EXACTLY ONE jsonl for the root; header + the user
      # prompt, six tool-call assistants with their tool results, and the
      # final assistant — roles enumerated in order.
      assert_equal 1, session_files.size
      assert_equal "session", header["type"]
      assert_equal space_root, header["cwd"]
      refute header.key?("parentSession"), "a fresh print run has no parent"
      assert_equal A_PROMPT, entries[1]["message"]["content"]
      assert_equal(%w[user] + %w[assistant tool] * 6 + %w[assistant],
        entries[1..].map { |e| e["message"]["role"] })
    end

    # Leg B (AC3/AC4): resume by ID — the model sees A's recorded turns
    # ahead of the new prompt, and the continued run records into a new
    # parent-linked file whose entries carry the copied lineage verbatim.
    def test_leg_b_resume_by_id_replays_the_recorded_context
      _, a_path, a_header, a_entries = run_leg_a
      b_requests, b_path = run_leg_b(a_path, a_header.fetch("id"))

      payload = non_system_payload(b_requests.first)
      assert_equal a_entries[1..].map { |e| e["message"]["role"] } + %w[user],
        payload.map { |m| m["role"] }, "A's recorded conversation + the new prompt LAST"
      assert_equal A_PROMPT, payload.first["content"], "the recorded turns lead"
      assert_equal B_PROMPT, payload.last["content"]

      assert_equal 2, session_files.size
      header = Agent::Session.read_header(b_path)
      assert_equal a_path, header["parentSession"], "the fork links A"
      entries = Agent::Session.load_entries(b_path)
      assert_equal a_entries[1..], entries[1, a_entries.size - 1],
        "the copied lineage is verbatim (ids/parentIds/timestamps/contents)"
      new_turns = entries[a_entries.size..]
      assert_equal %w[user assistant], new_turns.map { |e| e["message"]["role"] }
      assert_equal B_PROMPT, new_turns.first["message"]["content"]
      assert_equal entries[a_entries.size - 1]["id"], new_turns.first["parentId"],
        "the new leaf chains from the copied tail"
    end

    # Leg C (AC5): resume by PATH under PI_CONTEXT_WINDOW=10 + zeroed
    # knobs — the completed turn triggers threshold compaction: the
    # standalone summarization call (no tools) is served and a compaction
    # entry records. The file is self-contained across both hops (A's and
    # B's turns came along through the fork copy).
    def test_leg_c_resume_by_path_compacts_under_a_tiny_window
      _, a_path, a_header, = run_leg_a
      _, b_path = run_leg_b(a_path, a_header.fetch("id"))
      c_requests, c_path = run_leg_c(b_path)

      assert_equal 2, c_requests.size, "the turn, then the summarization"
      assert c_requests.first["tools"], "the turn request carries the tools"
      refute c_requests.last.key?("tools"), "the standalone summarization call carries none"

      assert_equal 3, session_files.size
      entries = Agent::Session.load_entries(c_path)
      compaction = entries.last
      assert_equal "compaction", compaction["type"]
      assert_operator compaction["tokensBefore"], :>=, 10
      assert_kind_of String, compaction["firstKeptEntryId"]
      assert entries.any? { |e| e.is_a?(Hash) && e["message"].is_a?(Hash) && e["message"]["content"] == B_PROMPT },
        "the two-hop lineage (A+B) rode the fork copy into C's file"
    end

    # Leg C2 (AC5): `-r` with NO id = the most recent session (C's) — the
    # compacted re-resume seeds the summary, never the summarized-away
    # prompts, and its payload is byte-smaller than leg C's first request
    # (the usage drop).
    def test_leg_c2_most_recent_resume_seeds_the_compacted_summary
      _, a_path, a_header, = run_leg_a
      _, b_path = run_leg_b(a_path, a_header.fetch("id"))
      c_requests, c_path = run_leg_c(b_path)

      stage_home(compaction: true)
      @server.script([{type: :message, content: C2_FINAL}])
      stdout, stderr, status = tart(C2_PROMPT, resume: :most_recent)
      assert_equal 0, status.exitstatus, "leg C2 exits 0 (stderr: #{stderr})"
      assert_includes stdout, C2_FINAL
      puts "[e2e] leg C2: exit 0, resumed the most-recent session (#{c_path})"

      requests = @server.captured_requests
      assert_equal 1, requests.size
      payload = non_system_payload(requests.first)
      assert payload.any? { |m| m["content"].to_s.include?(Compaction::COMPACTION_SUMMARY_PREFIX) },
        "the compaction summary marker rides the payload"
      refute payload.any? { |m| m["content"].to_s.include?(A_PROMPT) },
        "leg A's first prompt was compacted away"
      assert_operator JSON.generate(requests.first["messages"]).bytesize, :<,
        JSON.generate(c_requests.first["messages"]).bytesize,
        "the compacted payload is byte-smaller than leg C's first request"

      # The most-recent pick: C2's new file (the newest) forks C's — the
      # parentSession link is the resolve-time proof that C was picked.
      assert_equal 4, session_files.size
      assert_equal c_path, Agent::Session.read_header(session_files.last)["parentSession"]
    end

    private

    # Space-root resolution (Grounds 3, OQ-4): TART_E2E_SPACE > the
    # main-checkout parent (git-common-dir minus /.git, take the parent)
    # when it validates (a repos/tart child OR a space.yaml/architecture
    # entry) > the checkout root itself (a standalone clone — real files
    # either way). The choice is printed at setup.
    def space_root
      @space_root ||= begin
        return ENV.fetch("TART_E2E_SPACE") if ENV["TART_E2E_SPACE"]

        candidate = main_checkout_parent
        candidate && valid_space?(candidate) ? candidate : REPO_ROOT
      end
    end

    def main_checkout_parent
      out = `git -C #{REPO_ROOT.shellescape} rev-parse --path-format=absolute --git-common-dir 2>/dev/null`
      return nil unless $?.success? && !out.strip.empty?

      # The common dir points at the main checkout's .git: strip /.git for
      # the checkout, then walk UP (max two levels — the space shape is
      # repos/<repo> under the root) to the first validated space root.
      checkout = out.strip.sub(%r{/\.git\z}, "")
      [checkout, File.expand_path("..", checkout), File.expand_path("../..", checkout)]
        .find { |path| valid_space?(path) }
    end

    def valid_space?(path)
      File.directory?(File.join(path, "repos", "tart")) ||
        File.file?(File.join(path, "space.yaml")) || File.directory?(File.join(path, "architecture"))
    end

    # The repo the legs' tool calls address: the space layout's checkout
    # under the root, else the root itself (the standalone-clone fallback —
    # byte-identical files, so every tool result assertion holds either
    # way). The SESSION cwd stays the root.
    def repo_dir
      @repo_dir ||=
        if File.directory?(File.join(space_root, "repos", "tart"))
          File.join(space_root, "repos", "tart")
        else
          space_root
        end
    end

    # The leg's staged settings: the full-7 defaultTools (the I41 hatch —
    # the six scripted tools all exist); legs C/C2 add zeroed compaction
    # knobs so the tiny window compacts the whole tail.
    def stage_home(compaction: false)
      settings = {"defaultTools" => %w[read bash edit write find grep ls]}
      settings["compaction"] = {"enabled" => true, "reserveTokens" => 0, "keepRecentTokens" => 0} if compaction
      FileUtils.mkdir_p(File.join(@home, ".tart"))
      File.write(File.join(@home, ".tart", "settings.json"), JSON.generate(settings))
    end

    # The launcher_smoke env pattern, closed: unsetenv_others makes the
    # child env EXACTLY this hash (no live keys, no owner TART_* leaks —
    # the OS injects only PKG_CONFIG_PATH/__CF_USER_TEXT_ENCODING).
    def tart_env(extra)
      {
        "PATH" => ENV.fetch("PATH", nil),
        "HOME" => @home,
        "PI_API_KEY" => "e2e-key",
        "PI_API_BASE" => @server.url,
        "TART_MCP_CONFIG" => File.join(@home, "absent-mcp.json")
      }.merge(extra)
    end

    # Runs bin/tart -p against the space root. +resume+: false = no flag;
    # a String id/path = `-r VALUE`; :most_recent = a bare `-r` (which
    # must precede -p so OptionParser does not read -p as its argument).
    def tart(prompt, resume: false, env: {})
      args =
        case resume
        when :most_recent then ["-r", "-p", prompt]
        when String then ["-p", prompt, "-r", resume]
        else ["-p", prompt]
        end
      Open3.capture3(tart_env(env), RbConfig.ruby, File.join(REPO_ROOT, "bin", "tart"),
        *args, space_root, chdir: REPO_ROOT, unsetenv_others: true)
    end

    # The staged sessions dir for the root (Session.default_root under the
    # staged HOME).
    def session_files
      dir = Agent::Session.dir_path(space_root, root: File.join(@home, ".tart"))
      File.directory?(dir) ? Dir.glob(File.join(dir, "*.jsonl")).sort_by { |path| File.mtime(path) } : []
    end

    def tool_message(request, call_id)
      message = request["messages"].find { |m| m["role"] == "tool" && m["tool_call_id"] == call_id }
      assert message, "the request carries call #{call_id}'s tool result"
      message["content"].to_s
    end

    def non_system_payload(request)
      request["messages"].reject { |m| %w[system developer].include?(m["role"]) }
    end

    # --- leg runners (prefix-safe: exit 0 + request count, then return) ---

    def run_leg_a
      stage_home
      @server.script([
        {type: :stream, tool_calls: [{id: "c1", name: "read",
                                      arguments: {path: File.join(repo_dir, "lib/tart/agent/loop.rb"), limit: 4}}]},
        {type: :stream, tool_calls: [{id: "c2", name: "grep",
                                      arguments: {pattern: "SEAM_BENCH_OK", path: File.join(repo_dir, "bench")}}]},
        {type: :stream, tool_calls: [{id: "c3", name: "find",
                                      arguments: {pattern: "*.rb", path: File.join(repo_dir, "lib/tart/tools")}}]},
        {type: :stream, tool_calls: [{id: "c4", name: "bash",
                                      arguments: {command: "pwd && printenv PI_SESSION_ID && printenv PI_SESSION_FILE"}}]},
        {type: :stream, tool_calls: [{id: "c5", name: "edit",
                                      arguments: {path: File.join(@scratch, "edit-me.md"),
                                                  edits: [{oldText: A_MARKER, newText: A_REPLACEMENT}]}}]},
        {type: :stream, tool_calls: [{id: "c6", name: "write",
                                      arguments: {path: File.join(@scratch, "summary.md"), content: A_SUMMARY_TEXT}}]},
        {type: :stream, content: A_FINAL},
      ])
      File.write(File.join(@scratch, "edit-me.md"), "line one\n#{A_MARKER}\nline three\n")

      stdout, stderr, status = tart(A_PROMPT)
      assert_equal 0, status.exitstatus, "leg A exits 0 (stderr: #{stderr})"
      assert_includes stdout, A_FINAL, "the final response lands on stdout"
      requests = @server.captured_requests
      assert_equal 7, requests.size, "6 tool calls + the final text"

      assert_equal 1, session_files.size, "EXACTLY ONE jsonl records for the root"
      path = session_files.first
      entries = Agent::Session.load_entries(path)
      puts "[e2e] leg A: exit 0, 7 requests, session #{File.basename(path)}"
      [requests, path, entries.first, entries]
    end

    def run_leg_b(a_path, a_id)
      stage_home
      @server.script([{type: :message, content: B_FINAL}])
      stdout, stderr, status = tart(B_PROMPT, resume: a_id)
      assert_equal 0, status.exitstatus, "leg B exits 0 (stderr: #{stderr})"
      assert_includes stdout, B_FINAL
      requests = @server.captured_requests
      assert_equal 1, requests.size, "one scripted response for leg B"
      b_path = (session_files - [a_path]).first
      assert b_path, "leg B records its own file"
      puts "[e2e] leg B: exit 0, resumed #{a_id}, session #{File.basename(b_path)}"
      [requests, b_path]
    end

    def run_leg_c(b_path)
      stage_home(compaction: true)
      @server.script([
        {type: :message, content: C_TURN},
        {type: :message, content: C_SUMMARY},
      ])
      stdout, stderr, status = tart(C_PROMPT, resume: b_path, env: {"PI_CONTEXT_WINDOW" => "10"})
      assert_equal 0, status.exitstatus, "leg C exits 0 (stderr: #{stderr})"
      assert_includes stdout, C_TURN
      requests = @server.captured_requests
      assert_equal 2, requests.size, "the turn, then the summarization"
      c_path = session_files.last
      puts "[e2e] leg C: exit 0, resumed by path, session #{File.basename(c_path)}, compaction recorded"
      [requests, c_path]
    end
  end
end
