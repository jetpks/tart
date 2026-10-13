# frozen_string_literal: true

require "dry-validation"

module Tart
  module Schemas
    # B3 — mcp.json (pi's extensions/mcp/config.ts + core/mcp-servers.ts
    # validateMcpServerConfig, stdio subset). The contract replaces
    # validate_server!'s hand-rolled checks: every check is a rule carrying
    # pi's EXACT per-server string, evaluated in pi's order (servers in
    # parsed insertion order; within a server must-be-an-object → args →
    # env → cwd → url → command), so the first collected failure is exactly
    # today's fail-fast raise (OQ-3's ruling: first-error, not collect-all).
    # The root-shape guard and the ConfigError wrapping ("#{path}: ") stay
    # in {Mcp::Config.load} — a boundary never raises where it did not
    # raise before, and the schema module stays ConfigError-free.
    module Mcp
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
            key([:mcpServers, name]).failure(%(server "#{name}": streamable HTTP transport is not supported (stdio only))) if
              raw.key?("url")
            unless raw["command"].is_a?(String)
              key([:mcpServers, name]).failure(%(server "#{name}" needs either "command" (stdio) or "url" (streamable HTTP)))
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
    end
  end
end
