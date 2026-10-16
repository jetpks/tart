# frozen_string_literal: true

require_relative "safe_execute"

module Tart
  module Tools
    # The subagent tool (I48 — the delegation surface): spawn (foreground
    # blocking or async detached), status, steer, stop over the
    # {Subagents::Manager}. Parameter names are snake_case — the port's
    # own tool vocabulary (pi-subagents' camelCase is TS-surface, not an
    # owner observable; Specification §3). Results are plain Strings
    # (the OQ-7 I47 rule); the failure paths ride the port's {error:}
    # tool-result shape (§2.2 — foreground non-zero exit / no final
    # text) via {SafeExecute}.
    #
    # Declared LAST on the wire when the settings gate is on (the I47
    # registered-tools merge order; hooks.register_tool). With the gate
    # off this class is never instantiated and never reaches the wire —
    # the frozen digests hold.
    class Subagent < Fast::Completions::Tool
      include SafeExecute

      pi_name "subagent"

      DESCRIPTION = "Delegate work to a subagent. Built-in agents: worker (implementation), oracle " \
        "(high-context decision consistency, runs from a fork of this conversation), reviewer (read-only review); " \
        "custom agents load from ~/.tart/agents/**/*.md and <cwd>/.tart/agents/**/*.md (YAML frontmatter over a " \
        "system-prompt body). " \
        "Pass agent + task to delegate — by default the run detaches and returns immediately; completion arrives " \
        "as a native notification (async: false blocks until the child finishes and returns its output). " \
        "Manage runs with action: \"status\" (+ optional id), action: \"steer\" (id + message), action: \"stop\" (id). " \
        "Supervisor intercom: action: \"pending\" re-reads the children's open supervisor asks; action: \"reply\" " \
        "(reply_to + message) answers one by its request id. " \
        "Set timeout_ms (run deadline, default 30 min, 0 = unbounded) and tool_timeout_ms (per-tool-call deadline) " \
        "explicitly for long-running children."

      PARAMETERS_SCHEMA = {
        type: "object",
        properties: {
          "agent" => {type: "string", description: "Built-in agent name: worker, oracle, or reviewer (spawn)"},
          "task" => {type: "string", description: "The task text for the child (spawn)"},
          "async" => {type: "boolean", description: "true (default) = detach and return immediately; " \
                                                      "false = block until the child finishes"},
          "model" => {type: "string", description: "Model override: provider/id or provider/id:level " \
                                                     "(level: off/minimal/low/medium/high/xhigh/max)"},
          "timeout_ms" => {type: "integer", description: "Run-level deadline in milliseconds " \
                                                           "(default 1800000; 0 = unbounded)"},
          "tool_timeout_ms" => {type: "integer", description: "Per-tool-call hard deadline in milliseconds " \
                                                                "(default: unset)"},
          "action" => {type: "string", description: "Management action: status, steer, stop, or the " \
                                                     "supervisor intercom's reply/pending",
                        "enum" => %w[status steer stop reply pending]},
          "id" => {type: "string", description: "Run id (status/steer/stop)"},
          "reply_to" => {type: "string", description: "The pending supervisor request id being answered (reply)"},
          "message" => {type: "string", description: "Steering text (steer) or the supervisor reply text (reply)"},
          "mode" => {type: "string", description: "Steer mode: steer (deliver into the running turn), " \
                                                    "follow_up (queue for later), auto (default)", "enum" => %w[steer follow_up auto]}
        }
      }.freeze

      # @param manager [Subagents::Manager] the registry (constructor-injected —
      #   the tool owns no state of its own).
      def initialize(manager:)
        @manager = manager
      end

      description DESCRIPTION

      parameters PARAMETERS_SCHEMA.dup

      # The dispatch (Specification §3): agent+task (no action) → spawn
      # with `async` defaulting TRUE (pi's default-on); action status /
      # steer / stop; the supervisor intercom's reply / pending (I49);
      # every other combination → the safe-next-steps error naming the
      # actions.
      def execute(agent: nil, task: nil, async: nil, model: nil, timeout_ms: nil, tool_timeout_ms: nil,
                  action: nil, id: nil, reply_to: nil, message: nil, mode: nil)
        safe_execute do
          case action
          when nil, ""
            return safe_next_steps if agent.to_s.strip.empty? || task.to_s.strip.empty?

            run = @manager.spawn_run(
              agent: agent.to_s,
              task: task.to_s,
              async: async.nil? ? true : async != false && async != "false",
              model: model,
              timeout_ms: integer_param(timeout_ms, "timeout_ms"),
              tool_timeout_ms: integer_param(tool_timeout_ms, "tool_timeout_ms"),
              parent_session: @manager.current_session_path
            )
            next run[:async] ? start_message(run) : foreground_result(run)
          when "status"
            next @manager.status(id: present(id))
          when "steer"
            return safe_next_steps if present(id).nil? || present(message).nil?

            next @manager.steer(id: id.to_s, message: message.to_s, mode: mode || "auto").fetch(:text)
          when "stop"
            return safe_next_steps if present(id).nil?

            next @manager.stop(id: id.to_s)
          when "reply"
            return safe_next_steps if present(reply_to).nil? || present(message).nil?

            # No channel (a Manager built without register — tests) means
            # provably nothing is pending: the state error IS the T1 text.
            channel = @manager.supervisor_channel
            next channel&.reply(reply_to: reply_to.to_s, message: message.to_s) ||
                 {error: "No pending supervisor request found for reply_to '#{reply_to}'."}
          when "pending"
            next @manager.supervisor_channel&.pending_text || "No pending supervisor requests."
          else
            safe_next_steps
          end
        end
      end

      # The current parent session path (the :fork seeding source) — the
      # Manager resolves it from the live loop; nil (print parents) falls
      # back to fresh per pi's implicit-fork fallback.
      def parent_session_path = @manager.current_session_path

      private

      # The async start message (Specification §7, byte-pinned): pi's
      # headline + the guidance adapted per OQ-5 (no bg_wait — the port
      # has native completion notification instead; the status action is
      # named exactly).
      def start_message(run)
        id = run[:id]
        "Async: #{run[:agent]} [#{id}]\n\nDetached. Return control now: native completion wakes you, " \
          "so do not sleep or poll for it.\nOne-shot check: subagent({ action: \"status\", id: \"#{id}\" })."
      end

      # The foreground tool result: the child's final text verbatim
      # (§7); non-zero exit / no final text → the {error:} shape carrying
      # the first stderr line (§2.2 — the port's tool contract).
      def foreground_result(run)
        result = @manager.result(id: run[:id]) || {}
        return result["output"].to_s if run[:state] == :completed && result["success"] == true

        error = result["error"].to_s
        error = "the subagent run ended #{run[:state]} without output" if error.empty?
        {error:}
      end

      # The safe-next-steps error (pi's shape names the management
      # actions; the port names status + the intercom actions).
      def safe_next_steps
        {error: "Unknown subagent call. Delegate with agent + task (async defaults to true), or manage runs: " \
                'subagent({ action: "status" }) for the fleet, subagent({ action: "status", id: "..." }) ' \
                'for one run, action "steer" with id + message, action "stop" with id, ' \
                'action "pending" for the children\'s open supervisor asks, or action "reply" with reply_to + message ' \
                'to answer one.'}
      end

      def present(value)
        stripped = value.to_s.strip
        stripped.empty? ? nil : stripped
      end

      # Coerce an optional integer param; garbage → the safe-next-steps
      # error (a String from the wire never crashes the tool).
      def integer_param(value, name)
        return nil if value.nil? || value == ""

        Integer(value)
      rescue ArgumentError, TypeError
        raise ArgumentError, "#{name} must be an integer (got #{value.inspect})"
      end
    end
  end
end
