# frozen_string_literal: true

require "fileutils"
require "json"

require_relative "safe_execute"
require_relative "../subagents/supervisor"

module Tart
  module Tools
    # The child-side supervisor tool (I49 Spec §5, D6): a gate-on child
    # asks its parent through the run-dir file channel — the request file
    # lands under `<run-dir>/control/supervisor-requests/`, then the tool
    # blocks polling `supervisor-replies/<request-id>.json` until the
    # supervisor's answer, the ask timeout, or the run deadline (T2: the
    # child self-deadline owns that kill — no tool-timeout interplay). pi
    # registerNativeSupervisorClient + sendSupervisorRequest
    # (native-supervisor-channel.js :112-228) is the observable oracle;
    # the port wraps pi's throws in the {error:} result shape with pi's
    # message bytes verbatim inside.
    #
    # REGISTRY BUILTIN, ENV-INERT: the tool joins TOOL_CLASSES so a child's
    # `--tools` allowlist resolves it through the existing validation, but
    # it activates only when `<IDENTITY>_SUPERVISOR_CHANNEL` is set
    # (constructor env read — bash's TOOL_TIMEOUT_MS precedent); unset, it
    # answers the no-channel error and never touches disk. It is in NO
    # default loadout — Settings::DEFAULT_TOOL_NAMES is untouched, so the
    # default wire never changes.
    class ContactSupervisor < RubyLLM::Tool
      include SafeExecute

      pi_name "contact_supervisor"

      # pi registerNativeSupervisorClient's description byte-exact.
      DESCRIPTION = "Contact the parent/supervisor session for a blocking decision, " \
                    "structured interview, or progress update."

      # pi ContactSupervisorParamsSchema (:34-40): reason is the required
      # enum; message optional (execute validates the non-blank rule);
      # interview is a free-form object (additionalProperties true).
      PARAMETERS_SCHEMA = {
        type: "object",
        properties: {
          "reason" => {type: "string",
                        description: "Why you are contacting the supervisor: need_decision " \
                                     "(blocking question), interview_request (structured input), " \
                                     "or progress_update (fire-and-forget status)",
                        "enum" => Subagents::Supervisor::REASONS},
          "message" => {type: "string", description: "The question or update text (required unless " \
                                                      "reason is interview_request)"},
          "interview" => {type: "object", description: "The requested interview shape (interview_request)",
                           additionalProperties: true}
        },
        required: ["reason"]
      }.freeze

      # @param cwd [String] the working directory (the Bash-branch
      #   constructor shape; unused — the channel lives under the run dir).
      # @param identity [String] the resolved face (the env namespace).
      # @param session_env [Hash] the bash-branch constructor shape
      #   (accepted for Registry.build_tool uniformity; unused — the
      #   intercom env is the closed child env, not the session exposure).
      # @param env [Hash] the environment read at CONSTRUCTION (bash's
      #   TOOL_TIMEOUT_MS precedent): the channel dir, the agent label, and
      #   the ask timeout.
      def initialize(cwd:, identity: Identity::DEFAULT, session_env: {}, env: ENV)
        @cwd = cwd
        key = ->(suffix) { Identity.env_key(identity, suffix) }
        @channel_dir = env[key.("SUPERVISOR_CHANNEL")].to_s
        @agent = env[key.("SUBAGENTS_AGENT")].to_s.strip
        @agent = "agent" if @agent.empty?
        @ask_timeout_ms = Subagents::Supervisor.ask_timeout_ms(env:, identity:)
      end

      description DESCRIPTION

      parameters PARAMETERS_SCHEMA.dup

      # The request → (blocking) reply protocol. Validation failures ride
      # the {error:} shape (the I43 tool-contract discipline — this tool
      # has no Schemas::Tools member, the contracts registry is frozen);
      # pi's error messages are byte-exact inside.
      def execute(reason: nil, message: nil, interview: nil)
        safe_execute do
          next no_channel_error if @channel_dir.strip.empty?

          reason = reason.to_s
          next {error: "reason must be one of #{Subagents::Supervisor::REASONS.join(", ")}."} unless
            Subagents::Supervisor::REASONS.include?(reason)

          text = message.to_s.strip
          next {error: MESSAGE_REQUIRED} if text.empty? && reason != "interview_request"

          payload = build_request(reason, text, interview)
          serialized = JSON.generate(payload)
          next {error: "Supervisor request is too large."} if
            serialized.bytesize > Subagents::Supervisor::MAX_MESSAGE_BYTES

          write_request(payload)
          next "Supervisor progress update queued." if reason == "progress_update"

          wait_for_reply(payload)
        end
      end

      private

      # pi sendSupervisorRequest's messages, byte-exact.
      MESSAGE_REQUIRED = "message is required for supervisor decisions and progress updates."

      def no_channel_error
        {error: "No supervisor channel configured for this session."}
      end

      # The §4.2 request shape: `{type, id, createdAt, expiresAt? (iff
      # expectsReply), reason, message, expectsReply, runId, agent,
      # interview?}`. runId is the channel path's run-dir component; the
      # agent label rides `<IDENTITY>_SUBAGENTS_AGENT` (blank → "agent" —
      # pi's safeSegment fallback shape).
      def build_request(reason, message, interview)
        created_at = Subagents::Supervisor.now_ms
        expects_reply = reason != "progress_update"
        payload = {
          type: Subagents::Supervisor::REQUEST_TYPE,
          id: Fast::UUID.uuid_v4,
          createdAt: created_at,
          reason:, message:, expectsReply: expects_reply,
          runId: run_id, agent: @agent
        }
        payload[:expiresAt] = created_at + @ask_timeout_ms if expects_reply
        payload[:interview] = interview unless interview.nil?
        payload
      end

      def run_id
        component = File.basename(File.dirname(File.expand_path(@channel_dir)))
        component.empty? ? "unknown" : component
      end

      def write_request(payload)
        FileUtils.mkdir_p(requests_dir)
        Subagents::Supervisor.atomic_write_json(request_path(payload[:id]), payload)
      end

      # pi waitForReply (:178-197): poll the reply path every 250ms until
      # the deadline; a malformed reply file is skipped (the parent may be
      # mid-write — atomic rename makes that a no-op in practice). On
      # timeout the request is removed and pi's message thrown (SafeExecute
      # wraps it verbatim).
      def wait_for_reply(payload)
        id = payload[:id]
        deadline = payload[:createdAt] + @ask_timeout_ms
        reply_file = File.join(@channel_dir, "supervisor-replies", "#{id}.json")
        while Subagents::Supervisor.now_ms <= deadline
          reply = read_reply(reply_file, id)
          if reply
            File.unlink(request_path(id)) rescue nil
            return "**Reply from supervisor:**\n#{reply["message"]}"
          end
          sleep Subagents::Supervisor::POLL_INTERVAL
        end
        File.unlink(request_path(id)) rescue nil
        {error: "Timed out waiting for supervisor reply."}
      end

      def read_reply(path, id)
        return nil unless File.file?(path)

        payload = JSON.parse(File.read(path))
        return nil unless payload.is_a?(Hash)
        return nil unless payload["type"] == Subagents::Supervisor::REPLY_TYPE
        return nil unless payload["requestId"] == id
        return nil unless payload["message"].is_a?(String)

        payload
      rescue JSON::ParserError, StandardError
        nil
      end

      def requests_dir
        File.join(@channel_dir, "supervisor-requests")
      end

      def request_path(id)
        File.join(requests_dir, "#{id}.json")
      end
    end
  end
end
