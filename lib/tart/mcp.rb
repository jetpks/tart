# frozen_string_literal: true

require "dry/monads"

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
  #
  # I45: the client's call surface returns Results — a server that fails to
  # connect or list arrives here as a Failure value (no rescue wall): the
  # warn bytes and the skip are identical, the failure path is explicit.
  module Mcp
    include Dry::Monads::Result::Mixin
    # The module_function bodies run with self = the module (the singleton
    # copies), so the constructors must ride the singleton chain too.
    extend Dry::Monads::Result::Mixin

    module_function

    # Connects the configured servers and builds their tool instances.
    #
    # @param servers [Hash{String => Hash}] server name => mcp.json-shaped
    #   stdio config (as {Config.load} returns).
    # @return [Hash{String => Tool}] wire name => wrapped tool, in
    #   declaration order. A server whose connect/list returns a Failure is
    #   skipped with a $stderr warning (pi degrades to server state "failed"
    #   and the session continues; the port's registry has no error surface —
    #   parity deviation itemized in the iteration record).
    def tools_for(servers)
      tools = {}
      used = {}
      servers.each do |name, config|
        case server_tools(name, config, used:)
        in Failure(err)
          warn "tart: mcp server \"#{name}\" failed to connect: #{err.message}"
        in Success(built)
          tools.merge!(built)
        end
      end
      tools
    end

    # @return [Result] Success(wire name => wrapped tool) for the connected
    #   server, or Failure(the client's payload). The cleanup guard closes
    #   the client on EVERY failure path (today's rescue Exception shape,
    #   explicit in the branches).
    def server_tools(name, config, used:)
      client = Client.new
      connected = client.connect(Stdio.new(command: config[:command], args: config[:args],
                                           env: config[:env], cwd: config[:cwd]))
      if connected.failure?
        client.close
        return connected
      end

      build_tools(client, name, used)
    end

    private_class_method

    # Guard-style consumption (no pattern binding: a Success payload that is
    # itself an Array splats in deconstruct).
    def build_tools(client, name, used)
      listed = client.list_tools
      if listed.failure?
        client.close
        return listed
      end

      tools = listed.value!.each_with_object({}) do |tool, acc|
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
      Success(tools)
    end
  end
end
