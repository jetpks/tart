# frozen_string_literal: true

require_relative "mcp/jsonrpc"
require_relative "mcp/stdio"
require_relative "mcp/client"
require_relative "mcp/config"
require_relative "mcp/tool"

module Tart
  # MCP server support (BRIEF §7.3): hand-rolled stdio JSON-RPC client,
  # mcp.json-shaped configuration, and the tool wrapper that puts configured
  # servers' tools into the loadout as mcp__<server>__<tool>.
  #
  # Parity shape (pi): transports/ (Stdio) split from the protocol client
  # (Client); config validation carries pi's exact error strings (Config);
  # the exposure surface ships `direct` only.
  module Mcp
    module_function

    # Connects the configured servers and builds their tool instances.
    #
    # @param servers [Hash{String => Hash}] server name => mcp.json-shaped
    #   stdio config (as {Config.load} returns).
    # @return [Hash{String => Tool}] wire name => wrapped tool, in
    #   declaration order. A server that fails to connect or list is skipped
    #   with a $stderr warning (pi degrades to server state "failed" and the
    #   session continues; the port's registry has no error surface — parity
    #   deviation itemized in the iteration record).
    def tools_for(servers)
      tools = {}
      used = {}
      servers.each do |name, config|
        tools.merge!(server_tools(name, config, used:))
      rescue StandardError => e
        warn "tart: mcp server \"#{name}\" failed to connect: #{e.message}"
      end
      tools
    end

    def server_tools(name, config, used:)
      client = Client.new
      begin
        client.connect(Stdio.new(command: config[:command], args: config[:args],
                                 env: config[:env], cwd: config[:cwd]))
        build_tools(client, name, used)
      rescue Exception
        client.close
        raise
      end
    end

    private_class_method

    def build_tools(client, name, used)
      client.list_tools.each_with_object({}) do |tool, acc|
        taken = ->(candidate) { used.key?(candidate) || acc.key?(candidate) }
        wire_name = Tool.tool_name(name, tool["name"], taken)
        used[wire_name] = true
        acc[wire_name] = Tool.new(
          wire_name:,
          server: name,
          remote_name: tool["name"],
          description: tool["description"],
          input_schema: tool["inputSchema"],
          client:
        )
      end
    end
  end
end
