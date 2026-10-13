# frozen_string_literal: true

require_relative "../mcp"

module Tart
  module Tools
    # The tool registry: builds the built-in tool instances and gates the
    # loadout (BRIEF §4 schema gating).
    #
    # Schema gating: a tool not in the selected set is never instantiated and
    # never registered on the chat, so it never appears in the tool
    # declarations sent to the model (asserted in tests against the captured
    # wire payload). Tools execute unconditionally — pi ships no permissions
    # system (agent-loop.ts:832).
    module Registry
      TOOL_CLASSES = {
        "read" => "Tart::Tools::Read",
        "edit" => "Tart::Tools::Edit",
        "write" => "Tart::Tools::Write",
        "bash" => "Tart::Tools::Bash",
        "find" => "Tart::Tools::Find",
        "grep" => "Tart::Tools::Grep",
        "ls" => "Tart::Tools::Ls"
      }.freeze

      # Classes whose write boundary accepts the §5 toggle (registry.rb doc).
      WRITE_BOUNDARY_CLASSES = %w[
        Tart::Tools::Edit
        Tart::Tools::Write
      ].freeze

      module_function

      # @param selected [Array<String>] enabled tool names (schema gating).
      #   The list's ORDER is the wire order (pi _applyToolLoadout iterates
      #   the active-name list in order, agent-session.ts:1571-1581).
      # @param cwd [String] working directory for all tools.
      # @param strip_trailing_whitespace [Boolean] §5 toggle (default off):
      #   edit/write strip trailing spaces/tabs from each committed line.
      # @param mcp_servers [Hash{String => Hash}, nil] MCP server name =>
      #   mcp.json-shaped stdio config ({Mcp::Config.load} shape); nil = no
      #   MCP tools and no connections. Configured servers' tools register
      #   behind the schema gate as mcp__<server>__<tool>, declared direct.
      # @param identity [String] the resolved face — threaded to the bash
      #   tool, whose session-env keys ride its namespace (the other
      #   built-ins ignore it).
      # @param session_env [Hash{String => Proc}] suffix → reader, resolved
      #   at spawn (bash tool only; see {Tools::Bash}).
      # @return [Hash{String => RubyLLM::Tool}] instances for the selected
      #   tools only, keyed by wire name IN SELECTED ORDER.
      def build(selected:, cwd:, strip_trailing_whitespace: false, mcp_servers: nil,
                identity: Identity::DEFAULT, session_env: {})
        selected.each do |name|
          raise ArgumentError, "Unknown tool: #{name}" unless TOOL_CLASSES.key?(name)
        end

        # Selected-order keys (the I41 fix — Hash#slice kept TOOL_CLASSES'
        # receiver order, diverging from the resolved list pi declares).
        builtins = selected.to_h do |name|
          [name, build_tool(TOOL_CLASSES.fetch(name), cwd:,
                            strip_trailing_whitespace:, identity:, session_env:)]
        end
        return builtins unless mcp_servers

        builtins.merge(Mcp.tools_for(mcp_servers))
      end

      # Per-class constructor kwargs: the write-boundary tools take the §5
      # toggle; the bash tool takes the session-env exposure seams (I41) —
      # the other built-ins take neither.
      def build_tool(class_name, cwd:, strip_trailing_whitespace:,
                     identity: Identity::DEFAULT, session_env: {})
        kwargs = {cwd:}
        kwargs[:strip_trailing_whitespace] = strip_trailing_whitespace if WRITE_BOUNDARY_CLASSES.include?(class_name)
        if class_name == "Tart::Tools::Bash"
          kwargs[:identity] = identity
          kwargs[:session_env] = session_env
        end
        Object.const_get(class_name).new(**kwargs)
      end

    end
  end
end
