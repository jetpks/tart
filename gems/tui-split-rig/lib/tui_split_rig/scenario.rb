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
  #   suppress_usage: true       # optional: serve every response WITHOUT the
  #                              # usage payload — both apps' triggers must
  #                              # fall back to the estimate (the Case-3
  #                              # zero-usage path, s8). Default: false.
#   post_settle_keys: ["C-o"]  # optional: tmux key tokens sent AFTER the
#                              # reply settles, each followed by a re-settle,
#                              # before the capture — the settled-screen
#                              # instrument for post-reply key flows (s9's
#                              # ctrl+o startup-help flip). Default: none.
#   mid_run_keys:              # optional (I54): {after_request: N, keys:
#     after_request: 1         # [...]} — after the prompt is sent, poll the
#     keys: ["text", "Enter"]  # mock's NON-DRAINING request_count until it
#                              # reaches N (HARD_CAP-bounded; a dead pane or
#                              # a timeout fails the app's completed), then
#                              # send the keys and let the reply settle —
#                              # the mid-run submit instrument (s12/s13).
#                              # Default: none (today's behavior).
#   stage_project_resources: true  # optional: write the loaded-resource set
#                              # into BOTH apps' run sandbox — AGENTS.md at
#                              # the cwd, one project skill, one user skill
#                              # in the staged agent dir (pi: agentDir
#                              # skills/; tart: staged settings root
#                              # skills/), one project prompt template —
#                              # byte-identical per app (s9). Default: false.
#   stage_memory: true         # optional: stage the memory-recall set (s11)
#                              # — pi: the owner's memory.ts VERBATIM (the
#                              # rig fixture) into the staged agent dir
#                              # (user-dir extensions auto-load, no settings
#                              # row) + the frozen index at
#                              # <agentDir>/memory/pi/MEMORY.md; tart: the
#                              # {"memory" => true} settings row merged into
#                              # the staged settings.json + the same index
#                              # at .tart/memory/tart/MEMORY.md. Default:
#                              # false.
  #   env:                       # optional per-app env overrides (the
  #     tart:                    # runner layers them over its staged
  #       TART_IDENTITY: tart    # env — the branding/staging seam)
  #
  # `responses` entries are handed verbatim (symbolized) to
  # MockLLMServer#script — see test/support/mock_llm_server.rb for the
  # spec vocabulary (:stream/:message/:error/...).
  class Scenario
    APPS = %w[pi tart].freeze

    attr_reader :name, :prompt, :expected_requests, :responses, :env, :context_window, :suppress_usage,
                :post_settle_keys, :mid_run_keys, :stage_project_resources, :stage_memory

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
      @suppress_usage = parse_suppress_usage(data)
      @post_settle_keys = parse_post_settle_keys(data)
      @mid_run_keys = parse_mid_run_keys(data)
      @stage_project_resources = parse_stage_project_resources(data)
      @stage_memory = parse_stage_memory(data)
    end

    # The optional scenario context window (s7's compaction lever): a
    # positive integer or absent. Validated at load, not at boot.
    def parse_context_window(data)
      raw = data["context_window"]
      return nil if raw.nil?

      raise Error, "#{@path}: context_window must be a positive integer" unless raw.is_a?(Integer) && raw.positive?

      raw
    end

    # The optional usage-suppression knob (the Case-3 instrument): a
    # boolean or absent.
    def parse_suppress_usage(data)
      raw = data["suppress_usage"]
      return false if raw.nil?

      raise Error, "#{@path}: suppress_usage must be a boolean" unless raw == true || raw == false

      raw
    end

    # The optional post-settle key list (the s9 instrument): a list of
    # tmux key tokens (strings), or absent → [].
    def parse_post_settle_keys(data)
      raw = data["post_settle_keys"]
      return [] if raw.nil?

      raise Error, "#{@path}: post_settle_keys must be a list of key strings" unless raw.is_a?(Array) && raw.all?(String)

      raw.map { |key| String(key) }
    end

    # The optional mid-run key knob (the s12/s13 instrument, I54):
    # {after_request: positive Integer, keys: [String]} or absent → nil.
    # Validated at load like the existing knobs.
    def parse_mid_run_keys(data)
      raw = data["mid_run_keys"]
      return nil if raw.nil?

      raise Error, "#{@path}: mid_run_keys must be a mapping" unless raw.is_a?(Hash)
      after = raw["after_request"]
      unless after.is_a?(Integer) && after.positive?
        raise Error, "#{@path}: mid_run_keys.after_request must be a positive integer"
      end
      keys = raw["keys"]
      raise Error, "#{@path}: mid_run_keys.keys must be a list of key strings" unless keys.is_a?(Array) && keys.all?(String)

      {after_request: after, keys: keys.map { |key| String(key) }}
    end

    # The optional loaded-resource staging knob (the s9 instrument): a
    # boolean or absent.
    def parse_stage_project_resources(data)
      raw = data["stage_project_resources"]
      return false if raw.nil?

      raise Error, "#{@path}: stage_project_resources must be a boolean" unless raw == true || raw == false

      raw
    end

    # The optional memory-recall staging knob (the s11 instrument): a
    # boolean or absent.
    def parse_stage_memory(data)
      raw = data["stage_memory"]
      return false if raw.nil?

      raise Error, "#{@path}: stage_memory must be a boolean" unless raw == true || raw == false

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
