# frozen_string_literal: true

require_relative "safe_execute"
require_relative "../architect_loop"

module Tart
  module Tools
    # The architect_loop tool (I95 — the port of pi's architect-loop.ts
    # registerTool architect_loop :613-660): enter driver mode on a plan.
    # Exactly one of from | plan; validates routing against architect.yaml,
    # regenerates the space's role agent files, installs the driver
    # playbook, and returns THE PLAYBOOK as the result text (pi's contract:
    # the playbook is the tool's result; the model reads its operating
    # instructions in-turn). Error results carry the reason (pi's
    # errorResult shape — the port's plain-string error result; the port
    # has no isError channel, OQ-7 — the memory/subagent precedent).
    # Declared LAST on the wire (the I47 registered-tools merge) with NO
    # <tools> snippet row (no promptSnippet in the port). NOTE: the DRIVER
    # module is always spelled Tart::ArchitectLoop here — the bare constant
    # resolves to THIS class inside Tools.
    class ArchitectLoop < Fast::Completions::Tool
      include SafeExecute

      pi_name "architect_loop"

      # pi's tool description, carried verbatim.
      DESCRIPTION = "Enter driver mode on a plan — this session becomes the loop's driver (the detached coordinator is retired). " \
        "Pass `from` (path to the committed plan file; preferred) or `plan` (the plan text verbatim). " \
        "Validates routing against architect.yaml and regenerates the space's role agent files, then installs the driver playbook: " \
        "it comes back as this result's text (your operating instructions), and every architect_compact while you drive carries it as the keep-essentials — " \
        "call architect_compact only after a child launch, never before the first. Begin driving in this turn: ground from disk and proceed to the first child spawn; " \
        "do not end the turn before the first child is in flight. " \
        "Requires the cwd to be inside a space (space.yaml + architect.yaml)."

      # pi ARCHITECT_LOOP_PARAMS (:563-576) — descriptions carried verbatim.
      PARAMETERS_SCHEMA = {
        type: "object",
        properties: {
          "from" => {
            type: "string",
            description: "Path to the committed plan file (preferred). Exactly one of from | plan is required."
          },
          "plan" => {
            type: "string",
            description: "The plan text verbatim (when no plan file exists). Exactly one of from | plan is required."
          }
        }
      }.freeze

      # @param cwd [String] the session cwd (the register boot's workdir —
      #   the config resolution's start dir; pi reads ctx.cwd per execute).
      # @param output [Proc] the one-line surface callable (the register
      #   wiring's output:; the generation pass's inform channel).
      # @param env [Hash] the env tier source (SPACE_ARCHITECT_GLOBAL_CONFIG).
      # @param catalog [Proc] the validation catalog LOADER — fresh per pass
      #   (A-Law 9; register threads the law's default).
      def initialize(cwd:, output:, env: ENV, catalog:)
        @cwd = cwd
        @output = output
        @env = env
        @catalog = catalog
      end

      description DESCRIPTION

      parameters PARAMETERS_SCHEMA.dup

      def execute(from: nil, plan: nil)
        safe_execute do
          # JS truthiness on the params (pi `(params.from ? 1 : 0) +
          # (params.plan ? 1 : 0) !== 1`): an empty string counts as absent.
          present_from = from.is_a?(String) && !from.empty?
          present_plan = plan.is_a?(String) && !plan.empty?
          if (present_from ? 1 : 0) + (present_plan ? 1 : 0) != 1
            return "architect_loop: pass exactly one of `from` (path to the plan file, preferred) or `plan` (the plan text)"
          end

          begin
            plan_text = Tart::ArchitectLoop.extract_plan(present_from ? "--from #{from}" : plan)
            config = Tart::ArchitectLoop.resolve_config(@cwd, env: @env)
            unless config
              return "architect_loop: #{Tart::ArchitectLoop.no_config_message(@cwd, env: @env)}"
            end
            # Pre-flight regeneration + routing validation; errors name the
            # file and the key (pi's errorResult arm).
            Tart::ArchitectLoop.generate_agent_files(config, output: @output, catalog: @catalog, env: @env)
          rescue StandardError => e
            return "architect_loop: #{e.message}"
          end

          plan_ref = present_from ? from : Tart::ArchitectLoop::INLINE_PLAN_REF
          Tart::ArchitectLoop.install_driver_mode(config, plan_ref, present_from ? nil : plan_text, output: @output)
        end
      end
    end
  end
end
