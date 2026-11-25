# frozen_string_literal: true

require "dry-validation"
require "uri"

module Tart
  module Schemas
    # B3 — mcp.json (pi's packages/mcp/src/config.ts validateMcpServerConfig
    # — the v1.6.0 shape: a stdio OR a Streamable HTTP arm). The contract
    # replaces validate_server!'s hand-rolled checks: every check is a rule
    # carrying pi's EXACT per-server string, evaluated in the frozen order
    # (servers in parsed insertion order; within a server must-be-an-object
    # → the legacy-SSE type check → the stdio-field checks args → env →
    # cwd (byte-held, every entry) → the arm dispatch: `url` + an
    # http-family `type` (nil/"http"/"streamable-http") checks url →
    # headers; `command` + a stdio-family `type` (nil/"stdio") completes
    # the stdio arm; anything else is pi's needs-either), so the first
    # collected failure is exactly the fail-fast raise (OQ-3's ruling:
    # first-error, not collect-all). The root-shape guard and the
    # ConfigError wrapping ("#{path}: ") stay in {Mcp::Config.load} — a
    # boundary never raises where it did not raise before, and the schema
    # module stays ConfigError-free.
    #
    # I122: the `url` arm is the Streamable HTTP transport (pi
    # config.ts:107-113 — url wins over command, an http-family `type`
    # required; unknown fields are kept, unchecked); `type: "sse"` is pi's
    # exact legacy rejection (:103-104). The stdio arm's checks are
    # byte-held (args/env/cwd, pi's validateStdioFields order).
    module Mcp
      HTTP_TYPES = [nil, "http", "streamable-http"].freeze
      STDIO_TYPES = [nil, "stdio"].freeze
      private_constant :HTTP_TYPES, :STDIO_TYPES

      class ServersContract < Dry::Validation::Contract
        json do
          # Bare declaration: symbolizes the wrapper key for the rule and
          # carries no predicates (the root guard lives in Config.load).
          optional(:mcpServers)
        end

        rule(:mcpServers) do
          next unless value.is_a?(Hash)

          value.each do |name, raw|
            unless raw.is_a?(Hash)
              key([:mcpServers, name]).failure(%(server "#{name}" must be an object))
              next
            end

            # pi's legacy-SSE rejection (config.ts:103-104), checked
            # before the arm dispatch.
            key([:mcpServers, name]).failure(
              %(server "#{name}": legacy SSE transport is not supported; use the streamable HTTP URL)
            ) if raw["type"] == "sse"

            # The stdio-field checks (pi's validateStdioFields :159-167)
            # run for EVERY entry in the byte-held order (args → env →
            # cwd) — the I43-frozen first-failure traversal, preserved so
            # every existing pin holds byte-exact (the one itemized
            # divergence from pi: a junk stdio field on an HTTP entry
            # rejects with the stdio string, where pi ignores it — pi
            # checks fields per arm).
            args = raw["args"]
            unless args.nil? || (args.is_a?(Array) && args.all?(String))
              key([:mcpServers, name]).failure(%(server "#{name}": args must be an array of strings))
            end
            env = raw["env"]
            unless env.nil? || (env.is_a?(Hash) && env.all? { |env_key, env_value| env_key.is_a?(String) && env_value.is_a?(String) })
              key([:mcpServers, name]).failure(%(server "#{name}": env must map names to strings))
            end
            cwd = raw["cwd"]
            key([:mcpServers, name]).failure(%(server "#{name}": cwd must be a string)) unless
              cwd.nil? || cwd.is_a?(String)

            # The arm dispatch (I122, pi config.ts:107-118): a String `url`
            # with an http-family type (or none) is the Streamable HTTP
            # arm — url wins over command; a String `command` with a
            # stdio-family type (or none) is the stdio arm; anything else
            # is pi's needs-either rejection. The url/headers checks are
            # pi's validateHttpFields (:152-154): url then headers.
            if Schemas::Mcp.http_entry?(raw)
              unless Schemas::Mcp.http_url?(raw["url"])
                key([:mcpServers, name]).failure(%(server "#{name}": url must be an http or https URL))
              end
              headers = raw["headers"]
              unless headers.nil? ||
                     (headers.is_a?(Hash) && headers.all? { |k, v| k.is_a?(String) && v.is_a?(String) })
                key([:mcpServers, name]).failure(%(server "#{name}": headers must map names to strings))
              end
            elsif !Schemas::Mcp.stdio_entry?(raw)
              key([:mcpServers, name]).failure(
                %(server "#{name}" needs either "command" (stdio) or "url" (streamable HTTP))
              )
            end
          end
        end
      end

      CONTRACT = ServersContract.new.freeze

      module_function

      # The servers-hash contract call (input wrapped once — the contract's
      # schema symbolizes the wrapper key only; server bodies keep their
      # parsed string keys, exactly what the rules navigate).
      def call(servers)
        CONTRACT.call("mcpServers" => servers)
      end

      # The first failure's exact text — the ConfigError payload after the
      # "#{path}: " prefix.
      def first_failure_text(result)
        message = result.errors.to_a.first
        message.respond_to?(:text) ? message.text : message.to_s
      end

      # pi's arm dispatch (config.ts:107-118): a String `url` with an
      # http-family `type` (or none) is the Streamable HTTP arm — url wins
      # over command.
      def http_entry?(raw)
        raw["url"].is_a?(String) && HTTP_TYPES.include?(raw["type"])
      end

      # A String `command` with a stdio-family `type` (or none) is the
      # stdio arm.
      def stdio_entry?(raw)
        raw["command"].is_a?(String) && STDIO_TYPES.include?(raw["type"])
      end

      # pi's URL check (config.ts:152): parseable AND http or https.
      def http_url?(url)
        parsed = URI.parse(url)
        parsed.scheme == "http" || parsed.scheme == "https"
      rescue URI::InvalidURIError, ArgumentError
        false
      end
    end
  end
end
