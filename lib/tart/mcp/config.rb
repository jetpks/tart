# frozen_string_literal: true

require "json"

require_relative "../schemas/mcp"

module Tart
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
      DEFAULT_PATH = File.expand_path("~/.tart/mcp.json")

      class ConfigError < StandardError; end

      module_function

      # @param path [String] the mcp.json path (default ~/.tart/mcp.json).
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

        servers = parsed.fetch("mcpServers", {})
        # Fail-fast preserved (OQ-3): the contract evaluates servers in
        # parsed insertion order with pi's check order, so the FIRST failure
        # is exactly today's raise; the error-as-raise surface and the
        # "#{path}: " prefix stay here.
        result = Schemas::Mcp.call(servers)
        raise ConfigError, "#{path}: #{Schemas::Mcp.first_failure_text(result)}" if result.failure?

        servers.each_with_object({}) do |(name, raw), config|
          config[name] = normalize_server(raw)
        end
      end

      # Validates one server entry (kept public — the per-server hook):
      # raises ConfigError with pi's exact string on failure via the
      # {Schemas::Mcp} contract; returns the normalized stdio config on
      # success.
      def validate_server!(name, raw)
        result = Schemas::Mcp.call(name => raw)
        raise ConfigError, Schemas::Mcp.first_failure_text(result) if result.failure?

        normalize_server(raw)
      end

      # The normalized stdio config (pi's shape), contract-validated by the
      # callers.
      def normalize_server(raw)
        {command: raw["command"], args: raw["args"] || [], env: raw["env"], cwd: raw["cwd"]}
      end
    end
  end
end
