# frozen_string_literal: true

module RaspberryPi
  module Tools
    # The tool registry: builds the built-in tool instances and gates the
    # loadout (BRIEF §4 safety gating).
    #
    # Schema gating: a tool not in the selected set is never instantiated and
    # never registered on the chat, so it never appears in the tool
    # declarations sent to the model (asserted in tests against the captured
    # wire payload).
    #
    # Approval gating: destructive tools ({DESTRUCTIVE}) declare
    # `requires_approval` (ruby_llm native mechanics, verified in gem source:
    # Chat#run_tools partitions pending calls through the tool's approval
    # resolver; undecided approval-required calls stay pending and
    # Chat#waiting?/awaiting_approval? report it). The agent loop calls the
    # injectable approval callback on the kernel fiber for exactly those
    # pending calls.
    module Registry
      TOOL_CLASSES = {
        "read" => "RaspberryPi::Tools::Read",
        "edit" => "RaspberryPi::Tools::Edit",
        "write" => "RaspberryPi::Tools::Write",
        "bash" => "RaspberryPi::Tools::Bash",
        "find" => "RaspberryPi::Tools::Find",
        "grep" => "RaspberryPi::Tools::Grep",
        "ls" => "RaspberryPi::Tools::Ls"
      }.freeze

      module_function

      # @param selected [Array<String>] enabled tool names (schema gating).
      # @param cwd [String] working directory for all tools.
      # @return [Hash{String => RubyLLM::Tool}] instances for the selected
      #   tools only, keyed by wire name. Destructive tools are extended with
      #   requires_approval (ruby_llm native approval gating, verified in gem
      #   source: Chat#run_tools consults tool.requires_approval? before
      #   executing; undecided calls stay pending and Chat#awaiting_approval?
      #   reports them).
      def build(selected:, cwd:)
        selected.each do |name|
          raise ArgumentError, "Unknown tool: #{name}" unless TOOL_CLASSES.key?(name)
        end

        TOOL_CLASSES.slice(*selected).transform_values do |class_name|
          instance = Object.const_get(class_name).new(cwd:)
          instance.extend(approval_module) if approval_required?(instance.name)
          instance
        end
      end

      APPROVAL_MODULE = Module.new do
        def requires_approval?
          true
        end
      end

      def approval_module
        APPROVAL_MODULE
      end

      # @return [Boolean] whether the named tool gates behind approval.
      def approval_required?(name)
        Tools::DESTRUCTIVE.include?(name)
      end
    end
  end
end
