# frozen_string_literal: true

require "net/http"
require "json"

module Tart
  module Tools
    # The Exa HTTP transport (the session_sink Net::HTTP precedent — stdlib
    # only, no new dependency). One POST per call, no retries: an agent
    # retrying a search is the loop's job, not the tool's.
    #
    # The seam is injectable: both web tools take an +http:+ object
    # defaulting to this module (the hermetic tests stub it — zero network
    # in the suite). The contract: post(path, body_hash) → [Integer code,
    # parsed JSON or nil]. Connection failures raise NOTHING back to the
    # caller as raw exceptions — they return [:error, ExceptionClass] so
    # the tools can render a class-only message (session_sink post_once
    # precedent: an exception's own message may echo response metadata; the
    # class never carries the key).
    module ExaClient
      DEFAULT_TIMEOUT_SECONDS = 30.0

      module_function

      # @param base [String] API base URL (settings exaApiBase).
      # @param key [String] the API key (x-api-key header).
      # @param path [String] endpoint path ("/search", "/contents").
      # @param body [Hash] the JSON request body.
      # @param timeout [Float] open/read/write timeout seconds.
      # @return [Array] [status_code Integer, parsed Hash/nil] on HTTP
      #   response (any code); [:error, ExceptionClass] on connection
      #   failure.
      def post(base:, key:, path:, body:, timeout: DEFAULT_TIMEOUT_SECONDS)
        uri = URI.join("#{base.chomp('/')}/", path)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = timeout
        http.read_timeout = timeout
        http.write_timeout = timeout
        request = Net::HTTP::Post.new(uri.request_uri)
        request["x-api-key"] = key
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(body)
        response = http.request(request)
        parsed = begin
          JSON.parse(response.body.to_s)
        rescue JSON::ParserError
          nil
        end
        [response.code.to_i, parsed]
      rescue StandardError => e
        [:error, e.class] # the class only — never the message (key hygiene)
      end
    end
  end
end
