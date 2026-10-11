# frozen_string_literal: true

require "yaml"

module Tart
  module Parity
    # A scripted scenario: the prompt typed into both apps, the mock LLM
    # response script both apps receive (byte-identical, re-armed per app),
    # and the expected number of mock requests per app.
    #
    # YAML shape (see parity/scenarios/*.yml):
    #   name: s1_text_turn
    #   prompt: "hello"
    #   expected_requests: 1
    #   responses:
    #     - type: stream
    #       content: "..."
    #
    # `responses` entries are handed verbatim (symbolized) to
    # MockLLMServer#script — see test/support/mock_llm_server.rb for the
    # spec vocabulary (:stream/:message/:error/...).
    class Scenario
      attr_reader :name, :prompt, :expected_requests, :responses

      def self.load(path)
        raise Error, "#{path}: no such scenario file" unless File.readable?(path)

        data = YAML.safe_load_file(path, aliases: false)
        raise Error, "#{path}: not a mapping" unless data.is_a?(Hash)

        new(path, data)
      rescue Psych::SyntaxError, ArgumentError => e
        raise Error, "#{path}: invalid YAML (#{e.message})"
      end

      def initialize(path, data)
        @path = path
        @name = require_field(data, "name")
        @prompt = require_field(data, "prompt")
        @expected_requests = require_field(data, "expected_requests")
        unless @expected_requests.is_a?(Integer) && @expected_requests.positive?
          raise Error, "#{path}: expected_requests must be a positive integer"
        end

        responses = require_field(data, "responses")
        raise Error, "#{path}: responses must be a non-empty list" unless responses.is_a?(Array) && !responses.empty?

        @responses = responses.map do |spec|
          symbolized = deep_symbolize(spec)
          symbolized[:type] = symbolized[:type].to_s.to_sym if symbolized.is_a?(Hash) && symbolized[:type]
          symbolized
        end
      end

      private

      def require_field(data, key)
        raise Error, "#{@path}: missing required field '#{key}'" unless data.key?(key)

        data.fetch(key)
      end

      def deep_symbolize(value)
        case value
        when Hash then value.to_h { |k, v| [k.to_s.to_sym, deep_symbolize(v)] }
        when Array then value.map { |v| deep_symbolize(v) }
        else value
        end
      end
    end
  end
end
