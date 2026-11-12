# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"
require "json"

module Tart
  # The web_fetch tool's contract (BRIEF §3): capped page text inline, the
  # SAVE MODE with the workdir-confined corpus directory (path escapes
  # fail LOUDLY), the failure vocabulary, and the key-hygiene law —
  # HERMETIC: fake http seam, zero network, planted fake key.
  class WebFetchToolTest < Test
    FAKE_KEY = "t01-fake-exa-key-DO-NOT-USE"
    URL = "https://docs.example.com/guide/intro"
    PAGE_TEXT = "Line one of the page.\n" + ("filler text\n" * 500) + "Line last."

    def setup
      @dir = Dir.mktmpdir("t01-web-fetch-")
    end

    def teardown
      FileUtils.rm_rf(@dir)
    end

    class FakeHttp
      attr_reader :requests

      def initialize(code:, payload:)
        @code = code
        @payload = payload
        @requests = []
      end

      def post(base:, key:, path:, body:)
        @requests << {base:, key:, path:, body:}
        [@code, @payload]
      end
    end

    class LeakyRaisingHttp
      def post(base:, key:, path:, body:)
        raise Errno::ECONNREFUSED, "connection refused to #{base} (key=#{key})"
      end
    end

    def contents_payload(status: "success", text: PAGE_TEXT)
      {"requestId" => "req-9",
       "results" => [{"title" => "The Guide", "url" => URL, "text" => text}],
       "statuses" => [{"id" => URL, "status" => status,
                       "source" => "crawled"}]}
    end

    def tool(http = FakeHttp.new(code: 200, payload: contents_payload),
             env = {"EXA_API_KEY" => FAKE_KEY})
      Tools::WebFetch.new(cwd: @dir, env:, http:, api_base: "https://exa.example.test")
    end

    # --- the fetch render + request surface ---

    def test_fetch_returns_title_and_capped_text
      result = tool.execute(url: URL)

      assert_includes result, "The Guide"
      assert_includes result, URL
      assert_includes result, "Line one of the page."
      assert_includes result, "Line last."
      assert_operator result.bytesize, :<, Tools::Truncate::DEFAULT_MAX_BYTES + 1024,
        "the inline extract is house-truncated"
    end

    def test_the_request_surface_is_pinned_against_the_exa_contents_api
      http = FakeHttp.new(code: 200, payload: contents_payload)
      tool(http).execute(url: URL)

      request = http.requests.first
      assert_equal "https://exa.example.test", request.fetch(:base)
      assert_equal "/contents", request.fetch(:path)
      assert_equal FAKE_KEY, request.fetch(:key)
      assert_equal [URL], request.fetch(:body).fetch("urls")
      assert_equal({"maxCharacters" => Tools::WebFetch::FETCH_TEXT_MAX_CHARS},
        request.fetch(:body).fetch("text"))
    end

    # --- save mode: the corpus + the confinement law ---

    def test_save_mode_writes_full_source_under_the_corpus_and_returns_path
      t = tool
      result = t.execute(url: URL, save: true)

      saved = Dir.glob(File.join(@dir, "build", "corpus", "**", "*.txt")).sort
      assert_equal 1, saved.size, "exactly one corpus file"
      assert_includes result, "Saved #{saved.first}"
      assert File.read(saved.first) == PAGE_TEXT, "the FULL source text is persisted"
      assert_includes result, "Line one of the page.", "the extract rides along"

      # Deterministic: the same URL saves to the same path (idempotent).
      t.execute(url: URL, save: true)
      assert_equal 1, Dir.glob(File.join(@dir, "build", "corpus", "**", "*.txt")).size
    end

    def test_savepath_selects_a_relative_path_inside_the_corpus
      tool.execute(url: URL, save: true, savePath: "sub/dir/note.txt")

      expected = File.join(@dir, "build", "corpus", "sub", "dir", "note.txt")
      assert File.file?(expected)
      assert_equal PAGE_TEXT, File.read(expected)
    end

    def test_path_escape_attempts_fail_loudly_and_write_nowhere
      escapes = ["../escape.txt", "a/../../escape.txt", "/tmp/escape.txt",
                 "~/escape.txt", "sub/../../../../escape.txt"]

      escapes.each do |save_path|
        result = tool.execute(url: URL, save: true, savePath: save_path)

        assert result.key?(:error), "#{save_path.inspect} must fail loudly"
        assert_includes result[:error], "web_fetch refusing to save outside the corpus directory"
      end

      refute File.exist?(File.join(@dir, "escape.txt"))
      refute File.exist?(File.join(@dir, "build", "corpus", "escape.txt"))
      refute File.exist?(File.join(@dir, "build", "corpus", "sub"))
      assert_equal [], Dir.glob(File.join(Dir.tmpdir, "escape.txt"))
    end

    def test_a_symlinked_corpus_component_cannot_smuggle_the_target_out
      corpus = File.join(@dir, "build", "corpus")
      outside = Dir.mktmpdir("t01-outside-")
      FileUtils.mkdir_p(corpus)
      FileUtils.ln_s(outside, File.join(corpus, "linked"))

      result = tool.execute(url: URL, save: true, savePath: "linked/escape.txt")

      assert result.key?(:error), "a symlinked component must not smuggle the write out"
      refute File.exist?(File.join(outside, "escape.txt"))
    ensure
      FileUtils.rm_rf(outside) if outside
    end

    # --- the failure vocabulary (pinned strings, no crash, no key) ---

    def test_missing_key_is_a_clear_error_not_a_crash
      result = tool(FakeHttp.new(code: 200, payload: contents_payload), {}).execute(url: URL)

      assert_equal({error: "web_fetch unavailable: EXA_API_KEY is not set"}, result)
    end

    def test_per_url_failure_status_renders_the_machine_detail
      payload = {"requestId" => "r", "results" => [],
                 "statuses" => [{"id" => URL, "status" => "error",
                                 "error" => {"tag" => "content_not_found",
                                             "httpStatusCode" => 404}}]}
      result = tool(FakeHttp.new(code: 200, payload: payload)).execute(url: URL)

      assert_equal({error: "Exa could not fetch #{URL} (content_not_found 404)"}, result)
    end

    def test_http_error_envelope_and_connection_failure_curate_their_strings
      envelope = {"requestId" => "r", "error" => "boom #{FAKE_KEY}", "tag" => "internal_error"}
      http_error = tool(FakeHttp.new(code: 500, payload: envelope)).execute(url: URL)
      assert_equal "Exa fetch failed with HTTP 500 (internal_error)", http_error[:error]

      conn = tool(LeakyRaisingHttp.new).execute(url: URL)
      assert_equal({error: "Exa fetch failed: Errno::ECONNREFUSED"}, conn)
    end

    def test_non_http_url_rejects_with_the_pinned_message
      http = FakeHttp.new(code: 200, payload: contents_payload)
      result = tool(http).execute(url: "ftp://files.example.com/x")

      assert_equal({error: "Invalid URL: must be an http(s) URL"}, result)
      assert_empty http.requests, "no request leaves the tool for a bad URL"
    end

    def test_the_key_never_surfaces_on_any_path
      outputs = []
      outputs << tool.execute(url: URL).to_s
      outputs << tool.execute(url: URL, save: true).to_s
      outputs << tool(FakeHttp.new(code: 402, payload: {"requestId" => "r", "error" => "no credits #{FAKE_KEY}", "tag" => "payment_required"}))
        .execute(url: URL).to_s
      outputs << tool(LeakyRaisingHttp.new).execute(url: URL).to_s
      outputs << tool.execute(url: "../etc/passwd").to_s

      outputs.each { |output| refute_includes output, FAKE_KEY }
    end

    # --- the I43 input contract + wire shape ---

    def test_wrong_typed_input_rejects_through_the_contract
      result = tool.execute(url: URL, save: "yes")

      assert result.key?(:error)
      assert_includes result[:error], 'Validation failed for tool "web_fetch"'
    end

    def test_wire_name_and_schema_declaration
      assert_equal "web_fetch", Tools::WebFetch.pi_name
      schema = Tools::WebFetch.new(cwd: @dir).parameters_schema
      assert_equal %w[url], schema.fetch("required")
      assert_equal "boolean", schema.fetch("properties").fetch("save").fetch("type")
      assert schema.fetch("properties").key?("savePath")
    end
  end
end
