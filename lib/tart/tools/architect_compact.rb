# frozen_string_literal: true

require_relative "safe_execute"

module Tart
  module Tools
    # The architect_compact tool (I95 — the port of pi's architect-loop.ts
    # registerTool architect_compact :652-681): compact this session. While
    # it is driving the architect loop, the compaction carries the driver
    # playbook as customInstructions — the keep-essentials survive every
    # compaction; outside driver mode it is a plain compaction. The port's
    # scheduling is the A-Law 7 no-abort re-expression: the tool schedules
    # a pending request on the loop (request_manual_compaction) and the
    # compaction runs at the EXISTING post-run compaction point on the
    # reactor fiber — the tool result returns, the run ends, the
    # compaction lands, the in-flight child's completion wake resumes the
    # session (compact never runs on a tool worker). Result texts are pi's
    # byte-carried strings; errors ride the {error:} result (OQ-7).
    class ArchitectCompact < Fast::Completions::Tool
      include SafeExecute

      pi_name "architect_compact"

      # pi's tool description, carried verbatim including both
      # never-compact laws.
      DESCRIPTION = "Compact this session. While it is driving the architect loop, the compaction carries the driver playbook as " \
        "customInstructions — the keep-essentials (plan reference, routing pins, per-iteration procedure) survive every " \
        "compaction; everything else is recoverable from disk. Outside driver mode it is a plain compaction. " \
        "Call it after every child launch, while a child is in flight — never before this session's first child launch and never once every child has settled. " \
        "No parameters."

      PARAMETERS_SCHEMA = { type: "object", properties: {} }.freeze

      # @param driver [Tart::ArchitectLoop] the module (the playbook state
      #   holder — driving iff the installed playbook text is non-nil).
      # @param agent [Proc] the callable resolving the Agent::Loop (the
      #   register wiring's agent:, the /new-swap idiom).
      def initialize(driver:, agent:)
        @driver = driver
        @agent = agent
      end

      description DESCRIPTION

      parameters PARAMETERS_SCHEMA.dup

      def execute
        safe_execute do
          driving = !@driver.driver_playbook_text.nil?
          loop = @agent.respond_to?(:call) ? @agent.call : @agent
          unless loop.respond_to?(:request_manual_compaction)
            # pi's guard text, carried verbatim (its ctx.compact analog is
            # the loop's scheduling seam — the honest descendent shape).
            return { error: "architect_compact: this pi build exposes no ctx.compact — nothing scheduled" }
          end

          begin
            if driving
              loop.request_manual_compaction(custom_instructions: @driver.driver_playbook_text)
            else
              loop.request_manual_compaction
            end
          rescue StandardError => e
            return { error: "architect_compact: compaction failed — #{e.message}" }
          end

          if driving
            "Session compaction scheduled with the driver playbook as customInstructions — the keep-essentials " \
              "(plan reference, routing pins, per-iteration procedure) survive; ground everything else from disk."
          else
            "Session compaction scheduled — no driver playbook in this session, compacted plainly."
          end
        end
      end
    end
  end
end
