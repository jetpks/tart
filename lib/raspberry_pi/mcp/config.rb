# frozen_string_literal: true

require "json"

module RaspberryPi
  module Mcp
    # mcp.json-shaped server configuration: the `{"mcpServers": {name: {...}}}`
    # shape shared by other MCP clients (pi's extensions/mcp/config.ts), with
    # per-server validation carrying pi's exact error strings
    # (core/mcp-servers.ts validateMcpServerConfig, stdio subset).
    #
    # The port speaks stdio only: an url entry is a port-specific error (pi
    # would accept it as streamable-http — out of scope, parity deviation
    # itemized in the iteration record).
    module Config
      DEFAULT_PATH = File.expand_path("~/.raspberry-pi/mcp.json")

      class ConfigError < StandardError; end

      module_function

      # @param path [String] the mcp.json path (default ~/.raspberry-pi/mcp.json).
      # @return [Hash{String => Hash}] server name => stdio config
      #   ({command:, args:, env:, cwd:}); a missing file is no servers, no error.
      # @raise [ConfigError] the file is unreadable, not the mcpServers shape,
      #   or a server entry fails validation (pi's exact error strings,
      #   prefixed "#{path}: " like pi's per-file error collection).
      def load(path = DEFAULT_PATH)
        return {} unless File.exist?(path)

        parsed = begin
          JSON.parse(File.read(path, mode: "rb"))
        rescue JSON::ParserError => e
          raise ConfigError, "#{path}: #{e.message}"
        end
        unless parsed.is_a?(Hash) && (!parsed.key?("mcpServers") || parsed["mcpServers"].is_a?(Hash))
          raise ConfigError, "#{path}: expected an object with an \"mcpServers\" object"
        end

        parsed.fetch("mcpServers", {}).each_with_object({}) do |(name, raw), servers|
          begin
            servers[name] = validate_server!(name, raw)
          rescue ConfigError => e
            raise ConfigError, "#{path}: #{e.message}"
          end
        end
      end

      # Validates one server entry. Raises ConfigError with pi's exact string
      # on failure; returns the normalized stdio config on success.
      def validate_server!(name, raw)
        raise ConfigError, %(server "#{name}" must be an object) unless raw.is_a?(Hash)

        unless raw["args"].nil? || (raw["args"].is_a?(Array) && raw["args"].all?(String))
          raise ConfigError, %(server "#{name}": args must be an array of strings)
        end
        unless raw["env"].nil? || (raw["env"].is_a?(Hash) && raw["env"].all? { |k, v| k.is_a?(String) && v.is_a?(String) })
          raise ConfigError, %(server "#{name}": env must map names to strings)
        end
        unless raw["cwd"].nil? || raw["cwd"].is_a?(String)
          raise ConfigError, %(server "#{name}": cwd must be a string)
        end
        raise ConfigError, %(server "#{name}": streamable HTTP transport is not supported (stdio only)) if
          raw.key?("url")

        if raw["command"].is_a?(String)
          {command: raw["command"], args: raw["args"] || [], env: raw["env"], cwd: raw["cwd"]}
        else
          raise ConfigError, %(server "#{name}" needs either "command" (stdio) or "url" (streamable HTTP))
        end
      end
    end
  end
end
