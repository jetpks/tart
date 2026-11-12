# frozen_string_literal: true

require_relative "safe_execute"
require_relative "support/exa_client"
require_relative "../settings"

module Tart
  module Tools
    # The web_search tool (BRIEF §3): Exa POST /search — structured,
    # capped, auditable search for agents without bash. The agent's ONLY
    # network-capable tools are web_search and web_fetch; everything the
    # model sees about the web flows through here.
    #
    # Hermetic by construction: the HTTP transport is the injectable +http+
    # seam (default {ExaClient}); the suite stubs it and never touches a
    # socket. The API key is read from +EXA_API_KEY+ via the injectable
    # +env+ (constructor read — bash's session-env precedent) and NEVER
    # appears in any output, error message, or logged line: every failure
    # renders a curated pinned string; connection failures name the
    # exception CLASS only (the session_sink post_once precedent — an
    # exception's own message may echo request metadata).
    class WebSearch < Fast::Completions::Tool
      include SafeExecute

      pi_name "web_search"

      # Hard caps (BRIEF §3 context economy): the request never asks Exa
      # for more than MAX_NUM_RESULTS results, and inline page text is
      # capped at INLINE_TEXT_MAX_CHARS per result (server-side via
      # contents.text.maxCharacters — the cheapest place to cut).
      #
      # D3 — the real Exa ceilings SPLIT by endpoint (spec-time pin,
      # Grounds G5): /contents text.maxCharacters tops out at 5,000,000
      # (server default), but /search contents.text.maxCharacters tops out
      # at 1,000,000. Our frozen asks sit under both: 2,000 inline search
      # text here, 1,000,000 on the web_fetch side.
      DEFAULT_NUM_RESULTS = 5
      MAX_NUM_RESULTS = 10
      INLINE_TEXT_MAX_CHARS = 2000

      DESCRIPTION = "Search the web via Exa. Returns structured results (title, url, snippet, " \
        "published date when available). Set includeText to true to also return a capped extract " \
        "of each page's text. Results are hard-capped at #{MAX_NUM_RESULTS}."

      # STRING-KEYED THROUGHOUT (I64 — the strict engine reads string keys).
      PARAMETERS_SCHEMA = {
        "type" => "object",
        "properties" => {
          "query" => {"type" => "string", "description" => "The search query"},
          "numResults" => {"type" => "number", "description" => "Number of results (default 5, capped at 10)"},
          "includeText" => {"type" => "boolean", "description" => "Include a capped text extract per result (default false)"}
        },
        "required" => ["query"]
      }.freeze

      # Pinned failure strings (byte-exact, the tool's own voice — the
      # bash-timeout precedent; the key never rides any of them).
      MISSING_KEY_MESSAGE = "web_search unavailable: EXA_API_KEY is not set"

      attr_reader :cwd, :details

      # @param cwd [String] working directory (corpus + settings tier).
      # @param env [Hash] the environment read at CALL time (the key).
      # @param http [Object] the transport seam (default {ExaClient});
      #   responds to post(base:, key:, path:, body:) → [code, parsed] or
      #   [:error, ExceptionClass].
      # @param api_base [String, nil] explicit API base; nil = resolve
      #   settings exaApiBase at call time (user/project settings tier).
      def initialize(cwd:, env: ENV, http: ExaClient, api_base: nil)
        @cwd = cwd
        @env = env
        @http = http
        @api_base = api_base
        @details = nil
      end

      description DESCRIPTION

      parameters PARAMETERS_SCHEMA.dup

      # @return [String] the model-facing result list, or {error:} on
      #   failure (SafeExecute — never a loop crash).
      def execute(query:, numResults: nil, includeText: false)
        safe_execute do
          failure = validate_input(query:, numResults:, includeText:)
          return failure if failure

          key = @env["EXA_API_KEY"]
          return {error: MISSING_KEY_MESSAGE} if key.nil? || key.empty?

          # D2: the wire schema says "number" — models send integral
          # floats. Floor floats to the request integer, THEN clamp to
          # 1..MAX_NUM_RESULTS; a value above the cap is clamped, never
          # sent.
          requested = numResults || DEFAULT_NUM_RESULTS
          requested = requested.floor if requested.is_a?(Float)
          count = requested.clamp(1, MAX_NUM_RESULTS)
          contents = {"highlights" => true}
          contents["text"] = {"maxCharacters" => INLINE_TEXT_MAX_CHARS} if includeText

          Fast::Completions::Cancellation.check
          code, payload = http_post(key:, path: "/search",
                                    body: {"query" => query, "numResults" => count,
                                           "type" => "auto", "contents" => contents})
          return {error: failure_message("search", code, payload)} unless code == 200

          results = payload.is_a?(Hash) ? payload["results"] : nil
          return {error: 'Exa search returned no results (malformed response)'} unless results.is_a?(Array)

          Fast::Completions::Cancellation.check
          @details = {exa: {request_id: payload["requestId"], num_results: results.size,
                            status_code: code}}
          render(query, results)
        end
      end

      private

      # The transport belt: the http seam returns [:error, ExceptionClass]
      # on connection failure (ExaClient), but a seam that RAISES is
      # converted here too — the exception MESSAGE never flows (it may
      # echo request metadata; the class is all the model ever sees).
      def http_post(key:, path:, body:)
        @http.post(base: api_base, key:, path:, body:)
      rescue StandardError => e
        [:error, e.class]
      end

      def api_base
        @api_base || Settings.load(cwd: @cwd).settings.fetch("exaApiBase")
      end

      # The pinned failure render: HTTP status + the envelope's machine tag
      # (the envelope's human `error` field is Exa's prose, not ours —
      # shown capped; the tag is the stable machine handle). Connection
      # failures name the exception class ONLY.
      def failure_message(verb, code, payload)
        if code == :error
          "Exa #{verb} failed: #{payload}"
        elsif payload.is_a?(Hash) && payload["tag"]
          "Exa #{verb} failed with HTTP #{code} (#{payload['tag']})"
        else
          "Exa #{verb} failed with HTTP #{code}"
        end
      end

      def render(query, results)
        lines = ["#{results.size} result#{results.size == 1 ? "" : "s"} for #{query.inspect} (Exa search)", ""]
        results.each_with_index do |result, index|
          lines << "[#{index + 1}] #{result['title'].to_s}"
          lines << "    URL: #{result['url'].to_s}"
          lines << "    Published: #{result['publishedDate']}" if result["publishedDate"]
          lines << "    Author: #{result['author']}" if result["author"]
          highlights = result["highlights"]
          lines << "    Snippet: #{Array(highlights).join(' … ')}" if highlights && !Array(highlights).empty?
          text = result["text"].to_s
          lines << "    Text: #{text}" unless text.empty?
        end
        Truncate.truncate_head(lines.join("\n")).content
      end
    end
  end
end
