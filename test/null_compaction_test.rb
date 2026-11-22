# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"

module Tart
  # I102 (KB I11.5) — null-optional compaction, the tool-wide battery: an
  # explicit nil for a DECLARED OPTIONAL parameter behaves IDENTICALLY to
  # omitting the key (same result through the execution seam), for every
  # tool with optional params. Wrong-typed NON-null values refuse exactly
  # as before (compaction changes nothing about type checking), and a
  # nulled REQUIRED param still refuses.
  class NullCompactionTest < Test
    def setup
      @dir = Dir.mktmpdir("i115-null-")
      File.write(File.join(@dir, "apple.txt"), "one\n")
      File.write(File.join(@dir, "banana.md"), "hello world\n")
    end

    def teardown
      FileUtils.rm_rf(@dir)
    end

    # ── the read family: nil optional ≡ omitted, through the seam ──────

    def test_read_nulled_offset_and_limit_match_omission
      tool = Tools::Read.new(cwd: @dir)
      omitted = tool.call("path" => "apple.txt")
      nulled = tool.call("path" => "apple.txt", "offset" => nil, "limit" => nil)
      assert_equal omitted, nulled
      # the NON-null forms still act (compaction drops nothing but nils)
      limited = tool.call("path" => "apple.txt", "limit" => 1)
      assert limited.start_with?("one\n")
      assert_includes limited, "[1 more lines in file. Use offset=2 to continue.]"
    end

    def test_read_nulled_required_param_still_refuses
      result = Tools::Read.new(cwd: @dir).call("path" => nil)
      assert result.key?(:error)
      assert_includes result[:error], 'Validation failed for tool "read"'
      assert_includes result[:error], "path: must be a string"
    end

    def test_grep_nulled_optionals_match_omission_and_wire_name_survives
      tool = Tools::Grep.new(cwd: @dir)
      omitted = tool.call("pattern" => "hello")
      nulled = tool.call("pattern" => "hello", "path" => nil, "glob" => nil,
                         "ignoreCase" => nil, "literal" => nil, "context" => nil, "limit" => nil)
      assert_equal omitted, nulled
      # a wrong-typed NON-null value still refuses with the WIRE spelling
      # (the I96 pinned bytes — compaction touches neither)
      refused = tool.call("pattern" => "hello", "ignoreCase" => "yes")
      assert refused.key?(:error)
      assert_includes refused[:error], "ignoreCase: must be boolean"
    end

    def test_find_and_ls_nulled_path_match_omission
      find = Tools::Find.new(cwd: @dir)
      assert_equal find.call("pattern" => "*.txt"), find.call("pattern" => "*.txt", "path" => nil, "limit" => nil)
      ls = Tools::Ls.new(cwd: @dir)
      assert_equal ls.call, ls.call("path" => nil, "limit" => nil)
    end

    def test_bash_nulled_timeout_matches_omission
      tool = Tools::Bash.new(cwd: @dir, identity: "test", session_env: {})
      File.write(File.join(@dir, "s.sh"), "echo hi\n")
      assert_equal tool.call("command" => "bash s.sh"),
                   tool.call("command" => "bash s.sh", "timeout" => nil)
      # a wrong-typed NON-null timeout still refuses through the contract
      # (unchanged bytes — compaction drops nothing but nils)
      refused = tool.call("command" => "bash s.sh", "timeout" => "soon")
      assert refused.key?(:error)
      assert_includes refused[:error], 'Validation failed for tool "bash"'
      assert_includes refused[:error], "timeout:"
    end

    # ── the web family (FakeHttp stubs; wire camelCase names) ──────────

    def test_web_search_nulled_num_results_matches_omission
      http = FakeSearchHttp.new
      tool = Tools::WebSearch.new(cwd: @dir, env: {"EXA_API_KEY" => "k"}, http:, api_base: "https://exa.example.test")
      omitted = tool.call("query" => "q")
      nulled = tool.call("query" => "q", "numResults" => nil, "includeText" => nil)
      assert_equal omitted, nulled
      # the request surface: the nulled call's payload is byte-identical to
      # the omitted call's (the default fills both the same way)
      assert_equal http.requests.first[:body], http.requests.last[:body]
    end

    def test_web_fetch_nulled_save_and_save_path_match_omission
      http = FakeFetchHttp.new
      make = -> { Tools::WebFetch.new(cwd: @dir, env: {"EXA_API_KEY" => "k"}, http:, api_base: "https://exa.example.test") }
      omitted = make.call.call("url" => "https://example.test/page")
      nulled = make.call.call("url" => "https://example.test/page", "save" => nil, "savePath" => nil)
      assert_equal omitted, nulled
      assert_equal 2, http.requests.size, "both shapes fetched once (save stayed off — no corpus write)"
      refute File.exist?(File.join(@dir, "build")), "nulled save never writes the corpus"
    end

    # ── the contract-less family: null ≡ omitted at self-validation ────

    def test_memory_nulled_topic_and_text_match_omission
      tool = Tools::Memory.new(cwd: @dir, home: File.join(@dir, "mem"))
      omitted = tool.call("action" => "list")
      nulled = tool.call("action" => "list", "topic" => nil, "text" => nil)
      assert_equal omitted, nulled
    end

    def test_contact_supervisor_nulled_optionals_match_omission
      # no channel configured: both shapes answer the identical belt error
      tool = Tools::ContactSupervisor.new(cwd: @dir, env: {})
      assert_equal tool.call("reason" => "progress_update"),
                   tool.call("reason" => "progress_update", "message" => nil, "interview" => nil)
    end

    def test_architect_loop_nulled_from_and_plan_match_omission
      tool = Tools::ArchitectLoop.new(cwd: @dir, output: ->(_) {}, env: {}, catalog: nil)
      omitted = tool.call
      nulled = tool.call("from" => nil, "plan" => nil)
      assert_equal omitted, nulled
      assert_equal "architect_loop: pass exactly one of `from` (path to the plan file, preferred) or `plan` (the plan text)",
                   nulled, "both shapes answer the exactly-one-of refusal identically"
    end

    def test_subagent_nulled_async_defaults_true_like_omission
      manager = SpawnRecorder.new
      tool = Tools::Subagent.new(manager:)
      first = tool.call("agent" => "worker", "task" => "t", "async" => nil, "timeout_ms" => nil)
      second = tool.call("agent" => "worker", "task" => "t")
      assert_equal first, second, "async: null and async omitted answer identically"
      assert_equal [{async: true}, {async: true}], manager.calls.map { |c| c.slice(:async) },
                   "async: null and async omitted both spawn detached (the default)"
    end

    # ── the posture rails: what compaction must NOT change ─────────────

    def test_off_schema_nil_key_still_passes_through_and_refuses
      # Law 3's binds-or-raises posture: an undeclared key — even a nil
      # one — is never compacted; it refuses exactly as before.
      tool = Tools::Read.new(cwd: @dir)
      refused = tool.call("path" => "apple.txt", "bogus_key" => nil)
      assert refused.key?(:error)
      assert_includes refused[:error], "unknown keyword"
    end

    def test_edit_and_write_have_no_optional_top_level_params
      # the sweep enumeration, executable: both write-boundary tools
      # declare exactly their required pair — nothing to compact.
      edit_optional = Tools::Edit.optional_properties
      write_optional = Tools::Write.optional_properties
      assert_equal [], edit_optional, "edit declares no optional top-level params"
      assert_equal [], write_optional, "write declares no optional top-level params"
    end

    private

    # A minimal spawn recorder standing in for Subagents::Manager: the
    # null-compact assertion only reads the spawn_run kwargs.
    class SpawnRecorder
      attr_reader :calls

      def initialize
        @calls = []
      end

      def spawn_run(kwargs)
        @calls << kwargs
        {async: kwargs[:async], id: "run-1", agent: kwargs[:agent], state: :running}
      end

      def current_session_path = nil
    end

    class FakeSearchHttp
      attr_reader :requests

      def initialize
        @requests = []
      end

      def post(base:, key:, path:, body:)
        @requests << {base:, key:, path:, body:}
        [200, {"results" => [{"title" => "T", "url" => "https://example.test/a", "text" => "snippet"}]}]
      end
    end

    def fake_search_http
      FakeSearchHttp.new
    end

    class FakeFetchHttp
      attr_reader :requests

      def initialize
        @requests = []
      end

      def post(base:, key:, path:, body:)
        @requests << {base:, key:, path:, body:}
        [200, {"results" => [{"title" => "The Guide", "url" => "https://example.test/page",
                              "text" => "Line one of the page.\nLine last."}],
               "statuses" => [{"id" => "https://example.test/page", "status" => "success"}]}]
      end
    end
  end
end
