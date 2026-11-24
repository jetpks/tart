# frozen_string_literal: true

require_relative "safe_execute"

module Tart
  module Tools
    # The architect_compact tool (I95 — the port of pi's architect-loop.ts
    # registerTool architect_compact :652-681, re-based on the 6576da6
    # threshold update): compact this session. While it is driving the
    # architect loop, the compaction carries the driver playbook as
    # customInstructions — the keep-essentials survive every compaction —
    # and the tool self-guards on context size: under the compaction
    # threshold (max(150k tokens, 15% of the context window)) the call is
    # a skipped no-op, nothing scheduled; outside driver mode it is a
    # plain compaction. The port's scheduling is the A-Law 7 no-abort
    # re-expression: the tool schedules a pending request on the loop
    # (request_manual_compaction) and the compaction runs at the EXISTING
    # post-run compaction point on the reactor fiber — the tool result
    # returns, the run ends, the compaction lands, the in-flight child's
    # completion wake resumes the session (compact never runs on a tool
    # worker). Result texts are pi's byte-carried strings; errors ride
    # the {error:} result (OQ-7).
    class ArchitectCompact < Fast::Completions::Tool
      include SafeExecute

      pi_name "architect_compact"

      # pi's tool description (the 6576da6 wording), carried verbatim
      # including both never-compact laws, the re-send note, and the
      # threshold self-guard.
      DESCRIPTION = "Compact this session. While it is driving the architect loop, the compaction carries the driver playbook as " \
        "customInstructions — the keep-essentials (plan reference, routing pins, per-iteration procedure) survive every " \
        "compaction, and the playbook is re-sent into the session after any compaction; everything else is recoverable from disk. " \
        "While driving the tool self-guards on context size: a call with the context under the compaction threshold " \
        "(max(150k tokens, 15% of the context window)) is a skipped no-op — call it on every child launch and let it decide. " \
        "Outside driver mode it is a plain compaction. " \
        "Call it after every child launch, while a child is in flight — never before this session's first child launch and never once every child has settled. " \
        "No parameters."

      PARAMETERS_SCHEMA = { type: "object", properties: {} }.freeze

      # @param driver [Tart::ArchitectLoop] the module (the playbook state
      #   holder — driving iff the installed playbook text is non-nil; the
      #   threshold functions live beside it).
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

          # The cadence call is cheap: while driving, a context under the
          # compaction threshold skips (pi's tool-execute threshold branch).
          # A loop without the usage seam (the older-pi-build analog) keeps
          # the old always-compact behavior — this gate never fires there.
          if driving && loop.respond_to?(:context_usage)
            skipped = cadence_skip(loop)
            return skipped if skipped
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

      private

      # The driving-cadence self-guard (pi's tool-execute threshold branch,
      # architect-loop.ts :749-781): under the compaction threshold — or
      # with an unmeasurable usage — the call is a skipped no-op, nothing
      # scheduled (pi's skip texts, byte-carried); nil = over threshold,
      # compact. The threshold functions ride the driver (the module — the
      # same seam the playbook state reads through).
      def cadence_skip(loop)
        usage = loop.context_usage
        if usage.nil?
          return "architect_compact: skipped — context usage is not measurable right now, so nothing compacted. " \
                 "Keep the cadence: call again after the next child launch."
        end

        threshold = @driver.compaction_threshold(usage[:context_window])
        return nil if @driver.should_compact?(usage[:tokens], usage[:context_window])

        if usage[:tokens].nil?
          "architect_compact: skipped — context size is not measurable right now " \
            "(threshold #{format_tokens(threshold)} tokens). " \
            "Keep the cadence: call again after the next child launch."
        else
          percent = usage[:percent].nil? ? "?" : usage[:percent]
          "architect_compact: skipped — context at ~#{format_tokens(usage[:tokens])} tokens " \
            "(#{percent}% of a #{format_tokens(usage[:context_window])}-token window), " \
            "under the #{format_tokens(threshold)}-token compaction threshold. " \
            "Keep the cadence: call again after the next child launch."
        end
      end

      # pi's toLocaleString("en-US") number shape — the skip texts embed
      # comma-grouped numbers (150,000, not 150000).
      def format_tokens(number)
        number.to_s.gsub(/(\d)(?=(\d{3})+\z)/, "\\1,")
      end
    end
  end
end
