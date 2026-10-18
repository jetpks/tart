# frozen_string_literal: true

require "json"
require "async"
require "async/http"

module Tart
  module Models
    # The live /v1/models listing (I71 R3): ONE bounded, authenticated GET
    # against the CONFIGURED provider's own OpenAI-compatible models
    # endpoint, returning the listed model ids — or nil on ANY failure.
    # This is the ONLY network surface the /model menu adds, and it is
    # strictly demand-driven (menu open, user-initiated — never at boot,
    # never a runtime pi.dev fetch).
    #
    # Thread discipline (the lib/tart/herdr.rb sender discipline): the
    # one-off Async::HTTP client runs inside ONE dedicated background
    # thread — off the reactor, the UI never blocks. This module is the
    # ONE sanctioned background-thread site in the tree (the
    # threads-budget gate excludes exactly this file; the
    # listing-thread-law gate pins exactly one site here and none
    # elsewhere in the models family).
    #
    # Failure surface: connect refused, timeout, non-200, malformed body —
    # EVERY failure class returns nil, NOTHING is raised into the caller,
    # and there are NO retries / backoff (one fetch per menu open).
    module Listing
      # The frozen bounded-timeout window (R3): the whole one-shot fetch
      # (connect + response) is killed at this deadline; the synchronous
      # join below adds a small teardown margin.
      TIMEOUT = 5

      # The join margin over the request's own timeout bound (the worker's
      # Async deadline already bounds the work; this only covers teardown).
      JOIN_MARGIN = 1

      module_function

      # Fetches the model ids. Two delivery forms over the ONE background
      # thread:
      # - callback form (the menu-merge path, R4): +on_result+ receives the
      #   result (Array<String> of ids, or nil) ON the worker thread and
      #   {fetch} returns immediately — the menu renders the user entries
      #   right away and merges when the fetch lands;
      # - synchronous form (tests, simple callers): omit +on_result+ and
      #   {fetch} joins the worker (bounded) and returns the result itself.
      def fetch(base_url:, api_key:, timeout: TIMEOUT, on_result: nil)
        result = nil
        worker = Thread.new do
          begin
            result = request_ids(base_url: base_url, api_key: api_key, timeout: timeout)
          rescue StandardError
            result = nil # every failure class degrades to nil — never raises into the caller
          end
          on_result&.call(result)
        end
        return worker if on_result

        worker.join(timeout + JOIN_MARGIN)
        result
      end

      # The one attempt: GET <base_url>/models with the Bearer
      # Authorization, parsed for the OpenAI-compatible listing shape.
      # Bound as a whole by the Async timeout (a hung server ⇒ TimeoutError
      # ⇒ nil).
      def request_ids(base_url:, api_key:, timeout:)
        # No `return` inside the Async block: the block runs on its own
        # fiber (the ruby-4.0 non-local-return across the fiber boundary
        # would unwind the method before the request fires) — the body is
        # a plain value expression. The whole attempt is bounded by the
        # task's with_timeout (a hung server ⇒ TimeoutError ⇒ nil); the
        # one-off reactor answers its TASK — #wait joins it (the block has
        # run to completion by then, or #wait re-raises its failure: the
        # timeout bound).
        Async do |task|
          task.with_timeout(timeout) do
            endpoint = Async::HTTP::Endpoint.parse("#{base_url.to_s.sub(%r{/+\z}, "")}/models")
            client = Async::HTTP::Client.new(endpoint)
            response = client.get("/models", headers: {"Authorization" => "Bearer #{api_key}",
                                                       "Accept" => "application/json"})
            begin
              body = response.status == 200 ? response.read : nil
              body ? parse_ids(body) : nil
            ensure
              client.close
            end
          end
        end.wait
      end

      # The listing body: {"object":"list","data":[{"id":…,"object":"model"}…]}
      # — anything else is malformed ⇒ nil (non-Hash, no data array, or a
      # parse failure).
      def parse_ids(body)
        parsed = JSON.parse(body)
        return nil unless parsed.is_a?(Hash) && parsed["data"].is_a?(Array)

        parsed["data"].filter_map do |model|
          next unless model.is_a?(Hash)

          id = model["id"]
          id if id.is_a?(String) && !id.empty?
        end
      rescue StandardError
        nil
      end
    end
  end
end
