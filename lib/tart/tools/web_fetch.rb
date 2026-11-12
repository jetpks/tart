# frozen_string_literal: true

require "fileutils"
require "pathname"
require "digest"
require "uri"
require_relative "safe_execute"
require_relative "support/exa_client"
require_relative "../settings"

module Tart
  module Tools
    # The web_fetch tool (BRIEF §3): Exa POST /contents for one known URL —
    # capped page text inline, or SAVE MODE: the full fetched source text
    # persisted under the corpus directory (confined to the workdir — a
    # path-escape attempt fails LOUDLY as an {error:} result, never a
    # silent write elsewhere) and the path + a capped extract returned.
    # The saved corpus is the context-window extender for many-session
    # quests.
    #
    # Hermetic by construction (the WebSearch seams): injectable +http+
    # transport, injectable +env+ for EXA_API_KEY, curated pinned failure
    # strings, exception classes only on connection failures.
    class WebFetch < Fast::Completions::Tool
      include SafeExecute

      pi_name "web_fetch"

      # The fetched-source bound. Exa's text.maxCharacters ceiling SPLITS
      # by endpoint (D3, Grounds G5): /contents tops out at 5,000,000
      # (server default 5M), /search contents.text at 1,000,000. This ask
      # rides /contents: 1,000,000 chars — the frozen ask, plenty for a
      # source page, bounded for cost and corpus sanity.
      FETCH_TEXT_MAX_CHARS = 1_000_000

      # The corpus root, relative to the tool cwd (BRIEF §6:
      # build/corpus/). Created on first save.
      CORPUS_SUBDIR = File.join("build", "corpus")

      DESCRIPTION = "Fetch a known URL via Exa and return its page text (capped). " \
        "Set save to true to also persist the full fetched source text under the corpus " \
        "directory (#{CORPUS_SUBDIR}/) and return the saved path plus a capped extract; " \
        "savePath selects a relative path inside the corpus directory."

      # STRING-KEYED THROUGHOUT (I64 — the strict engine reads string keys).
      PARAMETERS_SCHEMA = {
        "type" => "object",
        "properties" => {
          "url" => {"type" => "string", "description" => "The http(s) URL to fetch"},
          "save" => {"type" => "boolean", "description" => "Persist the full source text under build/corpus (default false)"},
          "savePath" => {"type" => "string", "description" => "Relative path inside the corpus directory (default: derived from the URL)"}
        },
        "required" => ["url"]
      }.freeze

      # Pinned failure strings (byte-exact; the key never rides any).
      MISSING_KEY_MESSAGE = "web_fetch unavailable: EXA_API_KEY is not set"
      ESCAPE_MESSAGE = "web_fetch refusing to save outside the corpus directory: %s"

      attr_reader :cwd, :details

      # @param cwd [String] working directory — the corpus root's parent
      #   and the settings resolution cwd.
      # @param env [Hash] the environment read at CALL time (the key).
      # @param http [Object] the transport seam (default {ExaClient}).
      # @param api_base [String, nil] explicit API base; nil = resolve
      #   settings exaApiBase at call time.
      def initialize(cwd:, env: ENV, http: ExaClient, api_base: nil)
        @cwd = cwd
        @env = env
        @http = http
        @api_base = api_base
        @details = nil
      end

      description DESCRIPTION

      parameters PARAMETERS_SCHEMA.dup

      # @return [String] title + capped page text (plus the saved path in
      #   save mode), or {error:} on failure.
      def execute(url:, save: false, savePath: nil)
        safe_execute do
          failure = validate_input(url:, save:, savePath:)
          return failure if failure

          key = @env["EXA_API_KEY"]
          return {error: MISSING_KEY_MESSAGE} if key.nil? || key.empty?

          Fast::Completions::Cancellation.check
          code, payload = http_post(key:, path: "/contents",
                                    body: {"urls" => [url],
                                           "text" => {"maxCharacters" => FETCH_TEXT_MAX_CHARS}})
          return {error: failure_message(code, payload)} unless code == 200

          status = Array(payload.is_a?(Hash) ? payload["statuses"] : nil)
                      .find { |entry| entry.is_a?(Hash) && entry["id"] == url }
          if status && status["status"] != "success"
            return {error: fetch_failure_message(url, status["error"])}
          end

          result = Array(payload["results"]).find { |entry| entry.is_a?(Hash) && entry["url"] == url }
          return {error: "Exa returned no content for #{url}"} unless result

          Fast::Completions::Cancellation.check
          text = result["text"].to_s
          if save
            saved = persist(url, text, savePath)
            return saved if saved.is_a?(Hash)
            saved_path = saved
          end
          @details = {exa: {request_id: payload["requestId"], status_code: code,
                            saved_path:}}
          render(url, result, text, saved_path)
        end
      end

      private

      # The transport belt (WebSearch's comment verbatim): a raising seam
      # is converted here — the exception MESSAGE never flows.
      def http_post(key:, path:, body:)
        @http.post(base: api_base, key:, path:, body:)
      rescue StandardError => e
        [:error, e.class]
      end

      def api_base
        @api_base || Settings.load(cwd: @cwd).settings.fetch("exaApiBase")
      end

      def failure_message(code, payload)
        if code == :error
          "Exa fetch failed: #{payload}"
        elsif payload.is_a?(Hash) && payload["tag"]
          "Exa fetch failed with HTTP #{code} (#{payload['tag']})"
        else
          "Exa fetch failed with HTTP #{code}"
        end
      end

      # The per-URL failure (the /contents statuses leg): the machine tag
      # and HTTP code from the status entry — curated, key-free.
      def fetch_failure_message(url, error)
        detail = error.is_a?(Hash) ? [error["tag"], error["httpStatusCode"]].compact.join(" ") : nil
        detail ? "Exa could not fetch #{url} (#{detail})" : "Exa could not fetch #{url}"
      end

      # SAVE MODE + the confinement law. The corpus root is
      # <cwd>/build/corpus; a savePath resolves against it and MUST stay
      # inside it (lexically after expansion, AND via realdirpath — an
      # existing symlinked component cannot smuggle the target out).
      # Absolute savePath and any escape fail LOUDLY with the pinned
      # message, never a silent write elsewhere.
      def persist(url, text, save_path)
        corpus_root = File.expand_path(CORPUS_SUBDIR, @cwd)
        target = if save_path
          if save_path.start_with?("/", "~")
            return {error: format(ESCAPE_MESSAGE, save_path)}
          end
          File.expand_path(save_path, corpus_root)
        else
          File.join(corpus_root, derived_name(url))
        end

        # Confinement leg 1 — LEXICAL: after expansion the target must be
        # the corpus root or inside it. Catches ../ chains, absolute and
        # ~ paths, before anything touches the filesystem.
        unless target == corpus_root || target.start_with?("#{corpus_root}/")
          return {error: format(ESCAPE_MESSAGE, save_path || derived_name(url))}
        end

        # Confinement leg 2 — SYMLINK: create the target's directory, then
        # resolve both paths for real; an existing symlinked component
        # that smuggles the target out of the corpus is rejected here.
        FileUtils.mkdir_p(File.dirname(target))
        corpus_real = Pathname.new(corpus_root).realdirpath.to_s
        target_real = Pathname.new(target).realdirpath.to_s
        unless target_real == corpus_real || target_real.start_with?("#{corpus_real}/")
          return {error: format(ESCAPE_MESSAGE, save_path || derived_name(url))}
        end

        File.write(target, text)
        target
      end

      # A deterministic save name from the URL: <host>/<sanitized slug + 12
      # hex of the full URL's SHA-256>.txt — stable across calls for the
      # same URL (a refetch overwrites in place, idempotent).
      def derived_name(url)
        uri = URI(url)
        host = (uri.host || "unknown").gsub(/[^A-Za-z0-9.-]/, "-")
        slug = (uri.path.to_s.split("/").reject(&:empty?).last || "index")
                .gsub(/[^A-Za-z0-9._-]/, "-")[0, 60]
        hash = Digest::SHA256.hexdigest(url)[0, 12]
        File.join(host, "#{slug}-#{hash}.txt")
      end

      def render(url, result, text, saved_path)
        header = []
        header << result["title"].to_s unless result["title"].to_s.empty?
        header << url
        prefix = saved_path ? "Saved #{saved_path} (#{text.bytesize} bytes)" : nil
        extract = Truncate.truncate_head(text).content
        [prefix, *header, "", extract].compact.join("\n")
      end
    end
  end
end
