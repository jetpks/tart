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
      # @param cwd [String] working directory for all tools.
      # @param strip_trailing_whitespace [Boolean] §5 toggle (default off):
      #   edit/write strip trailing spaces/tabs from each committed line.
      # @param mcp_servers [Hash{String => Hash}, nil] MCP server name =>
      #   mcp.json-shaped stdio config ({Mcp::Config.load} shape); nil = no
      #   MCP tools and no connections. Configured servers' tools register
      #   behind the schema gate as mcp__<server>__<tool>, declared direct.
      # @return [Hash{String => RubyLLM::Tool}] instances for the selected
      #   tools only, keyed by wire name.
      def build(selected:, cwd:, strip_trailing_whitespace: false, mcp_servers: nil)
        selected.each do |name|
          raise ArgumentError, "Unknown tool: #{name}" unless TOOL_CLASSES.key?(name)
        end

        builtins = TOOL_CLASSES.slice(*selected).transform_values do |class_name|
          build_tool(class_name, cwd:, strip_trailing_whitespace:)
        end
        return builtins unless mcp_servers

        builtins.merge(Mcp.tools_for(mcp_servers))
      end

      # Only the write-boundary tools accept the §5 toggle; the others take
      # cwd only.
      def build_tool(class_name, cwd:, strip_trailing_whitespace:)
        kwargs = {cwd:}
        kwargs[:strip_trailing_whitespace] = strip_trailing_whitespace if WRITE_BOUNDARY_CLASSES.include?(class_name)
        Object.const_get(class_name).new(**kwargs)
      end

    end
  end
end
