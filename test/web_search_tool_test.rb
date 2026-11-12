# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"
require "json"

module Tart
  # The web_search tool's contract (BRIEF §3, the I43 discipline):
  # structured capped results, the request surface pinned against the Exa
  # /search API, the failure vocabulary (missing key, HTTP errors,
  # connection failures), and the key-hygiene law — HERMETIC: the http
  # seam is a fake, zero network; the key is a planted fake value whose
  # bytes must never surface anywhere.
  class WebSearchToolTest < Test
    FAKE_KEY = "t01-fake-exa-key-DO-NOT-USE"

    def setup
      @dir = Dir.mktmpdir("t01-web-search-")
    end

    def teardown
      FileUtils.rm_rf(@dir)
    end

    # The hermetic transport: captures the request, answers canned JSON.
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

    # A transport whose failure paths might leak: raises an exception whose
    # MESSAGE carries fake request metadata — the tool must render the
    # class only, never the message.
    class LeakyRaisingHttp
      def post(base:, key:, path:, body:)
        raise OpenSSL::OpenSSLError, "verify failed for #{base} with key #{key}"
      end
    end

    def search_response(results)
      {"requestId" => "req-1", "results" => results,
       "costDollars" => 0.001, "searchTime" => 120.0}
    end

    def sample_results
      [
        {"title" => "First Hit", "url" => "https://a.example/x",
         "publishedDate" => "2026-01-02T00:00:00.000Z", "author" => "A. Author",
         "highlights" => ["first snippet", "second snippet"]},
        {"title" => "Second Hit", "url" => "https://b.example/y",
         "highlights" => ["other snippet"]}
      ]
    end

    def tool(http = FakeHttp.new(code: 200, payload: search_response(sample_results)),
             env = {"EXA_API_KEY" => FAKE_KEY})
      Tools::WebSearch.new(cwd: @dir, env:, http:, api_base: "https://exa.example.test")
    end

    # --- the structured result render ---

    def test_structured_results_render_title_url_snippet_and_dates_when_present
      result = tool.execute(query: "ruby async")

      assert_includes result, "[1] First Hit"
      assert_includes result, "URL: https://a.example/x"
      assert_includes result, "Published: 2026-01-02T00:00:00.000Z"
      assert_includes result, "Author: A. Author"
      assert_includes result, "Snippet: first snippet … second snippet"
      assert_includes result, "[2] Second Hit"
      assert_includes result, "URL: https://b.example/y"
      assert_equal 1, result.scan("Published:").size, "no publishedDate on result 2 — its line is omitted"
    end

    def test_no_text_inline_by_default_and_capped_text_when_requested
      default_http = FakeHttp.new(code: 200, payload: search_response(sample_results))
      tool(default_http).execute(query: "q")

      body = default_http.requests.first.fetch(:body)
      assert_equal true, body.fetch("contents").fetch("highlights")
      refute body.fetch("contents").key?("text"), "text is off by default"

      text_http = FakeHttp.new(code: 200, payload: search_response(sample_results))
      tool(text_http).execute(query: "q", includeText: true)
      assert_equal({"maxCharacters" => Tools::WebSearch::INLINE_TEXT_MAX_CHARS},
        text_http.requests.first.fetch(:body).fetch("contents").fetch("text"))
    end

    def test_num_results_default_cap_and_float_floor
      capped_http = FakeHttp.new(code: 200, payload: search_response(sample_results))
      tool(capped_http).execute(query: "q", numResults: 500)

      assert_equal Tools::WebSearch::MAX_NUM_RESULTS,
        capped_http.requests.first.fetch(:body).fetch("numResults"),
        "a request above the cap is clamped, never sent"

      defaulted_http = FakeHttp.new(code: 200, payload: search_response(sample_results))
      tool(defaulted_http).execute(query: "q")
      assert_equal Tools::WebSearch::DEFAULT_NUM_RESULTS,
        defaulted_http.requests.first.fetch(:body).fetch("numResults")

      # D2: the wire schema says "number" — models send integral floats.
      # An integral float floors to the request integer; a float above the
      # cap floors then clamps. The wire never carries a fractional count.
      float_http = FakeHttp.new(code: 200, payload: search_response(sample_results))
      tool(float_http).execute(query: "q", numResults: 7.0)
      assert_equal 7, float_http.requests.first.fetch(:body).fetch("numResults")
      assert_predicate float_http.requests.first.fetch(:body).fetch("numResults"), :integer?,
        "an integral float is floored to the request integer"

      capped_float_http = FakeHttp.new(code: 200, payload: search_response(sample_results))
      tool(capped_float_http).execute(query: "q", numResults: 500.0)
      assert_equal Tools::WebSearch::MAX_NUM_RESULTS,
        capped_float_http.requests.first.fetch(:body).fetch("numResults")
    end

    def test_the_request_surface_is_pinned_against_the_exa_search_api
      http = FakeHttp.new(code: 200, payload: search_response(sample_results))
      tool(http).execute(query: "the query", includeText: true)

      request = http.requests.first
      assert_equal "https://exa.example.test", request.fetch(:base)
      assert_equal "/search", request.fetch(:path)
      assert_equal FAKE_KEY, request.fetch(:key), "the key rides the x-api-key header seam only"
      assert_equal "the query", request.fetch(:body).fetch("query")
      assert_equal "auto", request.fetch(:body).fetch("type")
    end

    def test_total_output_runs_through_the_house_truncate
      long = (1..10).map do |i|
        {"title" => "T#{i}", "url" => "https://x.example/#{i}",
         "highlights" => ["lorem ipsum " * 400]}
      end
      t = tool(FakeHttp.new(code: 200, payload: search_response(long)))
      result = t.execute(query: "q", includeText: true)

      assert_operator result.bytesize, :<, Tools::Truncate::DEFAULT_MAX_BYTES + 1024,
        "the render is house-truncated (#{Tools::Truncate::DEFAULT_MAX_BYTES} bytes)"
    end

    # --- the failure vocabulary (pinned strings, no crash, no key) ---

    def test_missing_key_is_a_clear_error_not_a_crash
      result = tool(FakeHttp.new(code: 200, payload: search_response([])), {}).execute(query: "q")

      assert_equal({error: "web_search unavailable: EXA_API_KEY is not set"}, result)
      refute_includes result.values.join, FAKE_KEY
    end

    def test_http_error_envelope_renders_status_and_tag_only
      envelope = {"requestId" => "req-2", "error" => "Invalid API key #{FAKE_KEY}",
                  "tag" => "invalid_api_key"}
      result = tool(FakeHttp.new(code: 401, payload: envelope)).execute(query: "q")

      assert result.key?(:error)
      assert_equal "Exa search failed with HTTP 401 (invalid_api_key)", result[:error]
      refute_includes result[:error], FAKE_KEY
    end

    def test_connection_failure_names_the_exception_class_only
      result = tool(LeakyRaisingHttp.new).execute(query: "q")

      assert_equal({error: "Exa search failed: OpenSSL::OpenSSLError"}, result)
    end

    def test_the_key_never_surfaces_on_any_path
      outputs = []
      outputs << tool.execute(query: "q").to_s
      outputs << tool(FakeHttp.new(code: 429, payload: {"requestId" => "r", "error" => "Rate limited #{FAKE_KEY}", "tag" => "rate_limited"}))
        .execute(query: "q").to_s
      outputs << tool(LeakyRaisingHttp.new).execute(query: "q").to_s
      outputs << tool(FakeHttp.new(code: 200, payload: {"requestId" => "r", "results" => nil}))
        .execute(query: "q").to_s

      outputs.each { |output| refute_includes output, FAKE_KEY }
    end

    # --- the I43 input contract ---

    def test_wrong_typed_input_rejects_through_the_contract
      result = tool.execute(query: "q", numResults: "five")

      assert result.key?(:error)
      assert_includes result[:error], 'Validation failed for tool "web_search"'
    end

    def test_wire_name_and_schema_declaration
      assert_equal "web_search", Tools::WebSearch.pi_name
      schema = Tools::WebSearch.new(cwd: @dir).parameters_schema
      assert_equal %w[query], schema.fetch("required")
      assert schema.fetch("properties").key?("numResults")
      assert_equal "boolean", schema.fetch("properties").fetch("includeText").fetch("type")
    end
  end
end
