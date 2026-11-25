# frozen_string_literal: true

require "json"

require_relative "../schemas/mcp"

module Tart
  module Mcp
    # mcp.json-shaped server configuration: the `{"mcpServers": {name: {...}}}`
    # shape shared by other MCP clients (pi's packages/mcp/src/config.ts),
    # with per-server validation carrying pi's exact error strings — the
    # stdio arm AND the Streamable HTTP arm (I122: a String `url` with an
    # http-family `type`, or none; `headers` sent with every request).
    #
    # Two load surfaces (I122's composition with the OQ-3 fail-fast
    # contract):
    #
    # - {load} — the FAIL-FAST surface, byte-held: raises ConfigError on
    #   the FIRST failure in parsed insertion order with the "#{path}: "
    #   prefix. Direct callers (tests, TART_MCP_CONFIG tooling) keep the
    #   frozen raise contract.
    # - {load_with_diagnostics} — the BOOT surface, never-raising for any
    #   file-content class (the models.json never-raise law): malformed
    #   JSON, a non-mcpServers root, or a per-server validation failure
    #   becomes a NAMED diagnostic and the server is SKIPPED — the good
    #   servers still load. The boots consume this surface; a missing
    #   file stays no-servers-no-diagnostics (byte-held); an unreadable
    #   file is a diagnostic (today it is an Errno crash).
    module Config
      DEFAULT_PATH = File.expand_path("~/.tart/mcp.json")

      class ConfigError < StandardError; end

      # The never-raising boot load: the servers that validated, plus one
      # diagnostic line per failure class (the ConfigError text bytes
      # with the "#{path}: " prefix — the same message load raises).
      class LoadResult < Struct.new(:servers, :diagnostics)
        def initialize(servers = {}, diagnostics = [])
          super
        end
      end

      module_function

      # @param path [String] the mcp.json path (default ~/.tart/mcp.json).
      # @return [Hash{String => Hash}] server name => normalized config
      #   (stdio {command:, args:, env:, cwd:} or http {url:, headers:});
      #   a missing file is no servers, no error.
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

      # The never-raising boot load (the models.json law): any failure
      # class becomes a named diagnostic and the offending server (or the
      # whole file, for root failures) is skipped; the remaining servers
      # load. The FIRST diagnostic is byte-equal to {load}'s raise
      # message (same traversal, same strings).
      #
      # @return [LoadResult] {servers:, diagnostics:} — the good servers
      #   and one diagnostic String per failure.
      def load_with_diagnostics(path = DEFAULT_PATH)
        return LoadResult.new unless File.exist?(path)

        parsed = begin
          JSON.parse(File.read(path, mode: "rb"))
        rescue JSON::ParserError, SystemCallError => e
          return LoadResult.new({}, ["#{path}: #{e.message}"])
        end
        unless parsed.is_a?(Hash) && (!parsed.key?("mcpServers") || parsed["mcpServers"].is_a?(Hash))
          return LoadResult.new({}, ["#{path}: expected an object with an \"mcpServers\" object"])
        end

        servers = parsed.fetch("mcpServers", {})
        servers.each_with_object(LoadResult.new) do |(name, raw), result|
          result.servers[name] = validate_server!(name, raw)
        rescue ConfigError => e
          result.diagnostics << "#{path}: #{e.message}"
        end
      end

      # Validates one server entry (kept public — the per-server hook):
      # raises ConfigError with pi's exact string on failure via the
      # {Schemas::Mcp} contract; returns the normalized config on success.
      def validate_server!(name, raw)
        result = Schemas::Mcp.call(name => raw)
        raise ConfigError, Schemas::Mcp.first_failure_text(result) if result.failure?

        normalize_server(raw)
      end

      # The normalized config (pi's shape), contract-validated by the
      # callers: the http arm when a String `url` rides an http-family
      # type (url wins over command — pi's dispatch), else the stdio arm.
      def normalize_server(raw)
        if Schemas::Mcp.http_entry?(raw)
          {url: raw["url"], headers: raw["headers"]}
        else
          {command: raw["command"], args: raw["args"] || [], env: raw["env"], cwd: raw["cwd"]}
        end
      end
    end
  end
end
