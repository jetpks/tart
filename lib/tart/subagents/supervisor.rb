# frozen_string_literal: true

require "fast/uuid"
require "json"
require "fileutils"

require_relative "../identity"

module Tart
  module Subagents
    # The supervisor (intercom) constants + the bridge (I49 Spec §4.1) —
    # the child-side shapes pi byte-pins: the request/reply `type` strings,
    # the custom_type the parent surfaces under, the bridge instruction,
    # the 64KB message cap, the 10-minute default ask timeout, and the
    # reason headings. Grounded in pi-subagents 0.77.0:
    # src/intercom/{native-supervisor-channel,intercom-bridge,
    # supervisor-ui}.js (cites inline at each constant).
    module Supervisor
      # pi supervisor-ui.js:3 SUPERVISOR_REQUEST_MESSAGE_TYPE, byte-exact
      # (OQ-3 — pi's exact underscore string over the port's hyphen
      # convention; `subagent-notify` is itself pi's exact string).
      REQUEST_CUSTOM_TYPE = "subagent_supervisor_request"

      # The file-protocol `type` strings (pi sendSupervisorRequest /
      # writeReply), byte-exact.
      REQUEST_TYPE = "subagent.supervisor.request"
      REPLY_TYPE = "subagent.supervisor.reply"

      # pi intercom-bridge.js INTERCOM_BRIDGE_MARKER (:9) — the idempotence
      # marker apply_bridge skips on.
      INTERCOM_BRIDGE_MARKER = "Intercom orchestration channel:"

      # pi intercom-bridge.js DEFAULT_INTERCOM_BRIDGE_TEMPLATE (:22-34),
      # VERBATIM (chomped — pi's backtick template carries no trailing
      # newline), under the marker line (pi buildIntercomBridgeInstruction
      # :107-112 — `${MARKER}\n${template}`). Byte-pinned by test.
      BRIDGE_INSTRUCTION = (<<~INSTRUCTION).chomp.freeze
        Intercom orchestration channel:
        The inherited thread is reference-only. Do not continue that conversation or send questions, status updates, or completion handoffs to the supervisor in normal assistant text.

        Use contact_supervisor first. It resolves the supervisor session and run metadata automatically.
        - Need a decision, blocked, approval, or product/API/scope ambiguity: contact_supervisor({ reason: "need_decision", message: "<question>" })
        - Need structured supervisor input rather than a freeform reply: contact_supervisor({ reason: "interview_request", message: "<what input is needed>", interview: { title: "...", questions: [] } })
        - After contact_supervisor with reason "need_decision" or "interview_request", stay alive and continue only after the reply arrives. Do not finish your final response with a choose-one question.
        - Do not ask for clarification when the only conflict is review-only/no-edit versus progress-writing or artifact-writing instructions. If an output path is configured but no write-capable tool is available, return the complete artifact in your final response; the runtime will persist it. Do not contact the supervisor merely because you cannot write that output path directly.
        - Meaningful progress or unexpected discoveries that change the plan: contact_supervisor({ reason: "progress_update", message: "UPDATE: <summary>" })

        Do not use contact_supervisor for routine completion handoffs. If no coordination is needed, return a focused task result.
      INSTRUCTION

      # pi MAX_MESSAGE_BYTES = 64 * 1024 (:29).
      MAX_MESSAGE_BYTES = 65_536

      # pi DEFAULT_ASK_TIMEOUT_MS = 10 minutes (:30); the env override
      # speaks `<IDENTITY>_INTERCOM_ASK_TIMEOUT_MS` (pi
      # PI_INTERCOM_ASK_TIMEOUT_MS, askTimeoutMs :96-100).
      DEFAULT_ASK_TIMEOUT_MS = 600_000
      ASK_TIMEOUT_ENV_SUFFIX = "INTERCOM_ASK_TIMEOUT_MS"

      # The poll cadence: the I48 watcher's (Manager::POLL_INTERVAL; pi
      # CHANNEL_POLL_MS = min(POLL_INTERVAL_MS, 500)).
      POLL_INTERVAL = 0.25

      REASONS = %w[need_decision interview_request progress_update].freeze

      # pi reasonHeading (:70-75), byte-exact.
      REASON_HEADINGS = {
        "need_decision" => "Subagent needs a supervisor decision.",
        "interview_request" => "Subagent requests a structured supervisor interview.",
        "progress_update" => "Subagent progress update."
      }.freeze

      # pi requestRunInactive's terminal vocabulary — the port reads the
      # I48 status.json state (Manager::TERMINAL_STATES).
      TERMINAL_RUN_STATES = %w[completed failed stopped].freeze

      module_function

      # D5 — pi applyIntercomBridgeToAgent (:172-198) with mode "always":
      # EVERY gate-on child gets contact_supervisor unioned into its tool
      # list (appended last, deduped) and the bridge instruction appended
      # to its system prompt (idempotent on the marker). Returns a NEW
      # spec Hash — never mutates (BUILTIN_AGENTS entries are frozen and
      # their pins hold byte-identical).
      def apply_bridge(spec)
        tools = Array(spec[:tools])
        tools += ["contact_supervisor"] unless tools.include?("contact_supervisor")
        prompt = spec[:system_prompt].to_s.strip
        system_prompt =
          if prompt.include?(INTERCOM_BRIDGE_MARKER)
            prompt
          elsif prompt.empty?
            BRIDGE_INSTRUCTION
          else
            "#{prompt}\n\n#{BRIDGE_INSTRUCTION}"
          end
        spec.merge(tools:, system_prompt:)
      end

      # The ask bound (pi askTimeoutMs :96-100): a positive
      # `<IDENTITY>_INTERCOM_ASK_TIMEOUT_MS` env value wins; anything else
      # falls back to pi's 10-minute default.
      def ask_timeout_ms(env: ENV, identity: Identity::DEFAULT)
        parsed = Integer(env[Identity.env_key(identity, ASK_TIMEOUT_ENV_SUFFIX)].to_s.strip)
        parsed.positive? ? parsed : DEFAULT_ASK_TIMEOUT_MS
      rescue ArgumentError, TypeError
        DEFAULT_ASK_TIMEOUT_MS
      end

      def reason_heading(reason)
        REASON_HEADINGS.fetch(reason, REASON_HEADINGS.fetch("need_decision"))
      end

      # The surfaced ask (Spec §4.4 — pi requestVisibleText :459-478
      # adapted: the childIndex line is CUT, the reply hint names the
      # port's one-tool vocabulary, the interview JSON is 2-space indented
      # per the frozen spec).
      def request_visible_text(request)
        lines = [reason_heading(request[:reason]),
                 "Run: #{request[:run_id]}",
                 "Agent: #{request[:agent]}",
                 ""]
        lines << request[:message].to_s unless request[:message].to_s.empty?
        if request[:reason] == "interview_request"
          lines << ""
          lines << "Structured response requested. Reply with JSON, optionally fenced in ```json, " \
                   "matching the requested interview shape."
          lines << JSON.pretty_generate(request[:interview]) unless request[:interview].nil?
        end
        lines << ""
        lines << "Reply with: subagent({ action: \"reply\", reply_to: \"#{request[:id]}\", message: \"...\" })"
        lines << ""
        lines << "Live guidance: subagent({ action: \"steer\", id: \"#{request[:run_id]}\", message: \"...\" }) " \
                 "(Reply to the pending request first.)"
        lines.join("\n")
      end

      # pi formatPendingLine (:450-458) adapted to the port's one-tool
      # vocabulary; the request notice can be missed — pending is the
      # parent's only way to read the question again.
      def pending_line(request)
        header = "- #{request[:id]}: #{request[:agent]} [#{request[:run_id]}] #{request[:reason]}. " \
                 "Reply: subagent({ action: \"reply\", reply_to: \"#{request[:id]}\", message: \"...\" })"
        message = request[:message].to_s
        message.empty? ? header : "#{header}\n  #{message.gsub("\n", "\n  ")}"
      end

      # Atomic temp+rename (the I48 control-channel idiom; rename over an
      # existing path is atomic on POSIX).
      def atomic_write_json(path, payload)
        temp = "#{path}.#{Process.pid}.#{Thread.current.object_id}.tmp"
        File.write(temp, JSON.generate(payload))
        File.rename(temp, path)
      ensure
        File.delete(temp) if defined?(temp) && temp && File.exist?(temp)
      end

      def now_ms
        (Process.clock_gettime(Process::CLOCK_REALTIME) * 1000).round
      end
    end

    # The parent-side channel (I49 Spec §4.3, D8): ONE 0.25s poll thread
    # scanning `<home>/*/control/supervisor-requests/*.json` (disk-first —
    # no Manager coupling; new run dirs are picked up naturally), the
    # request-id-keyed pending registry, the ONE-TIME surfacing through the
    # I47 seam (`send_next_turn` + the completion kick shape), and the
    # lifecycle sweep (resolved / expired / terminal-run — T3's disk-first
    # rule). pi createNativeSupervisorChannel (:318-660) is the observable
    # oracle; the TS machinery (fs.watch, settle subscriptions, foreground
    # attention marks, correlations) is replaced by the port's single
    # queue + wake.
    #
    # Delivery semantics (OQ-8's ruled shape): an IDLE interactive parent's
    # wake drains the ask as the turn's opening messages; a BUSY parent's
    # queued ask rides the next add_user_message drain; kernel/agent nil
    # (print boots) = queue only — the child's ask timeout bounds every
    # miss.
    class SupervisorChannel
      attr_reader :home

      # @param home [String] the runs root (the Manager's home).
      # @param hooks [Tart::Hooks, nil] the I47 seam (the surfacing path).
      # @param kernel [Object, nil] the interactive wake bridge (a duck
      #   #async; the SAME object the Manager holds). nil = queue only.
      # @param agent [Proc, Agent::Loop, nil] the current parent loop (or a
      #   callable returning it) — the wake target. nil = queue only.
      def initialize(home:, hooks:, kernel: nil, agent: nil)
        @home = home
        @hooks = hooks
        @kernel = kernel
        @agent = agent
        @mutex = Mutex.new
        @pending = {}
        @seen = {}
        @thread = nil
      end

      # Starts the poll thread (idempotent).
      def start
        thread = nil
        @mutex.synchronize do
          thread = @thread
          if thread.nil? || !thread.alive?
            thread = Thread.new do
              Thread.current.name = "tart-supervisor-channel" if Thread.current.respond_to?(:name=)
              poll_loop
            end
            @thread = thread
          end
        end
        self
      end

      # Stops the poll thread (idempotent; Manager#shutdown joins it). One
      # final lifecycle sweep — resolution only, no new registrations — so
      # a shutdown leaves no consumable request behind on disk.
      def stop
        thread = @mutex.synchronize do
          caught = @thread
          @thread = nil
          caught
        end
        sweep_pending
        thread&.join(Supervisor::POLL_INTERVAL * 8)
        nil
      end

      # The reply path (T1 leaf-id discipline): the target must be a
      # REQUEST id — no fuzzy matching, no run-id/agent-name addressing
      # (OQ-5). pi writeReply + resolvePendingRequest's replyTo branch,
      # byte-exact errors. The registry is the primary source; a MISS
      # falls back to a disk-first EXACT-id lookup — the poll thread can
      # lag a just-landed ask by up to one tick, and a parent that
      # answers faster than the poll must not lose the reply (the same
      # disk-first rule the lifecycle rides). An id with no request file
      # anywhere still fails loudly.
      def reply(reply_to:, message:)
        text = message.to_s
        raise ArgumentError, "message is required for supervisor replies." if text.strip.empty?

        request = @mutex.synchronize { @pending[reply_to.to_s] } || discover_request(reply_to.to_s)
        unless request
          raise ArgumentError, "No pending supervisor request found for reply_to '#{reply_to}'."
        end
        @mutex.synchronize { @pending[request[:id]] = request }

        Supervisor.atomic_write_json(reply_path(request), reply_payload(request, text.strip))
        @mutex.synchronize { @pending.delete(request[:id]) }
        remove_request_file(request)
        "Replied to supervisor request #{request[:id]}."
      end

      # The registry snapshot (request-id keyed; the tool's re-read path).
      def pending
        @mutex.synchronize { @pending.values.map(&:dup) }
      end

      # pi buildParentSupervisorTool's pending arm (:450-458): the empty
      # line is pi byte-exact; one formatted line per pending ask.
      def pending_text
        requests = pending
        return "No pending supervisor requests." if requests.empty?

        requests.map { |request| Supervisor.pending_line(request) }.join("\n")
      end

      private

      def poll_loop
        until thread_stopped?
          tick
          sleep Supervisor::POLL_INTERVAL
        end
      rescue StandardError
        sleep 0.05 # a transient IO error never kills the channel
        retry
      end

      def thread_stopped?
        @mutex.synchronize { @thread.nil? }
      end

      # One pass: the pending sweep (lifecycle on registered asks) first —
      # pi refreshPendingRequests — then the new-file scan.
      def tick
        sweep_pending
        scan_requests
      end

      def sweep_pending
        stale = pending.select { |request| request_lifecycle(request, Supervisor.now_ms) != :pending }
        stale.each do |request|
          @mutex.synchronize { @pending.delete(request[:id]) }
          remove_request_file(request)
        end
      end

      def scan_requests
        Dir.glob(request_glob).sort.each do |path|
          next if seen?(path)
          mark_seen(path)

          request = parse_request_file(path)
          if request.nil?
            File.unlink(path) # poison: unlinked + skipped (the steer-inbox rule)
            next
          end
          unless request[:expects_reply]
            # Progress is already visible through child activity; do not
            # inject a parent message or trigger a parent model turn (pi
            # :406-412, verbatim rule).
            File.unlink(path)
            next
          end
          lifecycle = request_lifecycle(request, Supervisor.now_ms)
          if lifecycle != :pending
            # resolved / expired / inactive: pi's cleanupRequestLifecycle —
            # the request file goes with the verdict.
            File.unlink(path) rescue nil
            next
          end

          @mutex.synchronize { @pending[request[:id]] = request }
          surface(request)
        end
      rescue SystemCallError
        nil # a vanished file loses to the next tick
      end

      # The lifecycle verdict (pi requestLifecycle :333-341 minus the
      # session/ownership arms the port has no counterpart for): reply
      # present → resolved; past the bound → expired; the run reached a
      # terminal state on disk → inactive. Anything else stays pending.
      def request_lifecycle(request, now)
        return :resolved if File.file?(reply_path(request))
        return :expired if now > expires_at(request)
        return :inactive if run_terminal?(request[:run_id])

        :pending
      end

      def expires_at(request)
        request[:expires_at] || request[:created_at] + Supervisor::DEFAULT_ASK_TIMEOUT_MS
      end

      def run_terminal?(run_id)
        return false if run_id.to_s.empty?

        status = read_json(File.join(@home, run_id, "status.json"))
        status.is_a?(Hash) && Supervisor::TERMINAL_RUN_STATES.include?(status["state"])
      rescue StandardError
        false
      end

      # The ONE-TIME surface (pi :413-447): send_next_turn + the completion
      # kick shape (`kernel.async { agent.wake }` — idle-interactive; busy
      # and print parents ride the next drain, OQ-8). A surfacing failure
      # must not lose the ask — it is already registered (pi's own rule).
      def surface(request)
        @hooks&.send_next_turn(custom_type: Supervisor::REQUEST_CUSTOM_TYPE,
                               content: Supervisor.request_visible_text(request),
                               display: true)
        return unless @kernel

        @kernel.async { loop_for_wake&.wake }
      rescue StandardError
        nil
      end

      def loop_for_wake
        loop = @agent.respond_to?(:call) ? @agent.call : @agent
        loop
      end

      # --- the file protocol (Spec §4.2) ---

      def request_glob
        File.join(@home, "*", "control", "supervisor-requests", "*.json")
      end

      # The disk-first reply fallback: an EXACT request-id file anywhere
      # under the runs root whose lifecycle is still pending. A path-unsafe
      # id (separators, dot segments) can never name a request file —
      # treated as a miss.
      def discover_request(id)
        return nil if id.empty? || id.include?("/") || id.include?("\\") || id == "." || id == ".."

        Dir.glob(File.join(@home, "*", "control", "supervisor-requests")).each do |dir|
          path = File.join(dir, "#{id}.json")
          next unless File.file?(path)

          request = parse_request_file(path)
          return nil if request.nil?
          return request if request_lifecycle(request, Supervisor.now_ms) == :pending

          return nil
        end
        nil
      end

      # `control/supervisor-requests/<id>.json` → the request record.
      # Files failing the JSON/type/id/reason/message shape are poison.
      def parse_request_file(path)
        payload = read_json(path)
        return nil unless payload.is_a?(Hash)
        return nil unless payload["type"] == Supervisor::REQUEST_TYPE
        return nil unless payload["id"].is_a?(String) && !payload["id"].empty?
        return nil unless Supervisor::REASONS.include?(payload["reason"])
        return nil unless payload["message"].is_a?(String)
        return nil if payload["message"].strip.empty? && payload["reason"] != "interview_request"
        return nil unless payload["runId"].is_a?(String) && payload["agent"].is_a?(String)

        interview = payload["interview"] if payload.key?("interview")
        {
          id: payload["id"], run_id: payload["runId"], agent: payload["agent"],
          reason: payload["reason"], message: payload["message"],
          expects_reply: payload["expectsReply"] == true,
          created_at: payload["createdAt"].is_a?(Integer) ? payload["createdAt"] : Supervisor.now_ms,
          expires_at: payload["expiresAt"].is_a?(Integer) ? payload["expiresAt"] : nil,
          interview:, channel_dir: File.dirname(File.dirname(path)), path:
        }
      end

      def reply_payload(request, message)
        {type: Supervisor::REPLY_TYPE, requestId: request[:id],
         createdAt: Supervisor.now_ms, message:}
      end

      def reply_path(request)
        File.join(request[:channel_dir], "supervisor-replies", "#{request[:id]}.json")
      end

      def remove_request_file(request)
        File.unlink(request[:path]) if request[:path] && File.file?(request[:path])
      rescue StandardError
        nil # reply files and receipts remain authoritative
      end

      def seen?(path)
        @mutex.synchronize { @seen.key?(path) }
      end

      def mark_seen(path)
        @mutex.synchronize { @seen[path] = true }
      end

      def read_json(path)
        return nil unless File.file?(path)

        JSON.parse(File.read(path))
      rescue JSON::ParserError, StandardError
        nil
      end
    end
  end
end
