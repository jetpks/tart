# frozen_string_literal: true

require "yaml"

module TuiSplitRig
  # A scripted scenario: the prompt typed into both apps, the mock LLM
  # response script both apps receive (byte-identical, re-armed per app),
  # and the expected number of mock requests per app.
  #
  # YAML shape (see scenarios/*.yml):
  #   name: s1_text_turn
  #   prompt: "hello"
  #   expected_requests: 1
  #   responses:
  #     - type: stream
  #       content: "..."
  #   context_window: 10         # optional: shrink BOTH apps' context window
  #                              # (pi's staged models.json + tart's
  #                              # TART_CONTEXT_WINDOW) and zero both apps'
  #                              # compaction knobs — the threshold-trigger
  #                              # lever (s7). Unset: the 32768 defaults.
  #   env:                       # optional per-app env overrides (the
  #     tart:                    # runner layers them over its staged
  #       TART_IDENTITY: tart    # env — the branding/staging seam)
  #
  # `responses` entries are handed verbatim (symbolized) to
  # MockLLMServer#script — see test/support/mock_llm_server.rb for the
  # spec vocabulary (:stream/:message/:error/...).
  class Scenario
    APPS = %w[pi tart].freeze

    attr_reader :name, :prompt, :expected_requests, :responses, :env, :context_window

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
      @env = parse_env(data)
      @context_window = parse_context_window(data)
    end

    # The optional scenario context window (s7's compaction lever): a
    # positive integer or absent. Validated at load, not at boot.
    def parse_context_window(data)
      raw = data["context_window"]
      return nil if raw.nil?

      raise Error, "#{@path}: context_window must be a positive integer" unless raw.is_a?(Integer) && raw.positive?

      raw
    end

    # The optional per-app env overrides: app name → {ENV_VAR => value},
    # both stringified. Unknown app names and non-mapping shapes are rig
    # errors — the seam is validated at load, not at boot.
    def parse_env(data)
      raw = data["env"] || {}
      raise Error, "#{@path}: env must be a mapping of app => {VAR => value}" unless raw.is_a?(Hash)

      raw.to_h do |app, vars|
        raise Error, "#{@path}: unknown env app '#{app}' (valid: #{APPS.join(", ")})" unless APPS.include?(app)
        raise Error, "#{@path}: env.#{app} must be a mapping of VAR => value" unless vars.is_a?(Hash)

        [app, vars.to_h { |key, value| [String(key), String(value)] }]
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
