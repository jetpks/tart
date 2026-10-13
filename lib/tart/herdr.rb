# frozen_string_literal: true

require "json"
require "socket"

module Tart
  # The owner's herdr agent-state reporter, native (port of
  # ~/.pi/agent/extensions/herdr-agent-state.ts, 261 lines,
  # HERDR_INTEGRATION_VERSION 9 — Grounds §5). Registered in BOTH modes
  # (pi loads the file regardless); every report gates on mode/context.
  #
  # Env gate (herdr's own namespace — never renamed): HERDR_ENV == "1" &&
  # HERDR_SOCKET_PATH && HERDR_PANE_ID; off → the module registers nothing
  # (no socket, no state).
  #
  # Socket protocol (cross-verified against the herdr 0.9.3 binary's
  # embedded strings): newline-terminated JSON request over the UNIX
  # socket; ANY received byte = delivered; error/EOF/timeout =
  # undelivered; one attempt then ONE retry; all failures swallowed. The
  # wire values stay pi's (source "herdr:pi", agent "pi" — OQ-5: the
  # identity seam is presentation-only and herdr has no tart key; identical
  # bytes keep the owner's panes working).
  module Herdr
    SOURCE = "herdr:pi"
    AGENT = "pi"

    module_function

    # The three-var gate (exact names).
    def enabled?(env)
      env["HERDR_ENV"] == "1" && !env["HERDR_SOCKET_PATH"].to_s.empty? && !env["HERDR_PANE_ID"].to_s.empty?
    end

    # Subscribes the state machine onto the seam. env-off → inert (no
    # subscriptions at all). TUI-only: the session_start handler returns
    # before rooting unless mode == "tui" (pi's own gate — RPC/print are
    # headless; RPC still reports hasUI, mode is the reliable gate).
    def register(hooks:, env: ENV)
      return unless enabled?(env)

      reporter = Reporter.new(socket_path: env["HERDR_SOCKET_PATH"])
      pane_id = env["HERDR_PANE_ID"]
      root = false
      agent_active = false
      blocked_count = 0
      blocked_message = nil
      current_ref = nil

      # pi updateSessionRef: the session ref re-reads at session_start and
      # agent_start; agent_session_path preferred over agent_session_id.
      # The context carries pi's ref shape ({"agent_session_path" => …});
      # the Spec's {path:, id:} shape maps onto the same keys.
      session_ref = lambda do |context|
        ref = context.is_a?(Hash) ? context[:session] : nil
        next nil unless ref.is_a?(Hash)

        if ref.key?("agent_session_path") || ref.key?("agent_session_id")
          ref
        else
          mapped = {}
          mapped["agent_session_path"] = ref[:path] if ref[:path]
          mapped["agent_session_id"] = ref[:id] if ref[:id]
          mapped.empty? ? nil : mapped
        end
      end

      publish = lambda do |force: false|
        state, message = if blocked_count.positive?
          ["blocked", blocked_message]
        elsif agent_active
          ["working", nil]
        else
          ["idle", nil]
        end
        # pi publishState: dedup same state+message except a forced
        # publish (the Reporter owns the dedup + the coalescing slot).
        reporter.report_state(state, message:, session_ref: current_ref, pane_id:, force:)
      end

      hooks.on("session_start") do |event, context|
        next unless context.is_a?(Hash) && context[:mode] == "tui"

        root = true
        current_ref = session_ref.call(context)
        reporter.report_session(current_ref, pane_id:, reason: event["reason"])
        # pi: agentActive = ctx.isIdle() === false — idle on a fresh boot
        # (a reload can replace the extension without an agent_start).
        agent_active = false
        publish.call(force: true)
      end

      hooks.on("agent_start") do |_event, context|
        next unless root

        current_ref = session_ref.call(context) || current_ref
        reporter.report_session(current_ref, pane_id:)
        agent_active = true
        publish.call
      end

      # pi agent_settled with isIdle() === true → idle; the port's
      # :agent_end fires on completion AND on the interrupt rescue
      # (loop.rb) — pi's _emitAgentSettled runs in the finally, also on
      # abort, so both map here.
      hooks.on("agent_end") do |_event, _context|
        next unless root

        agent_active = false
        publish.call
      end

      # The herdr:blocked channel: count/label in, publish out. NO emitter
      # exists pi-side either (docs/extension-api.md:547 — the bridge never
      # raises it) — the channel is surface for future permission gates.
      hooks.on("herdr:blocked") do |event, _context|
        next unless root

        if event["active"]
          blocked_count += 1
          blocked_message = event["label"]
        else
          blocked_count = [0, blocked_count - 1].max
          blocked_message = nil if blocked_count.zero?
        end
        publish.call
      end
      self
    end

    # The UNIX-socket sender: non-blocking background delivery (sends run
    # off the reactor thread — the UI never blocks), ONE attempt at the
    # first timeout then ONE retry at the second, every failure swallowed,
    # session reports FIFO while state reports coalesce latest-wins in a
    # single slot drained by one in-flight sender.
    class Reporter
      TIMEOUTS = [500, 1500].freeze

      # @param socket_path [String] the UNIX socket path.
      # @param timeouts [Array(Integer, Integer)] attempt/retry budgets in
      #   ms (pi's 500/1500 defaults; the test seam shrinks them).
      def initialize(socket_path:, timeouts: TIMEOUTS)
        @socket_path = socket_path
        @timeouts = timeouts
        @mutex = Mutex.new
        @resource = ConditionVariable.new
        @sessions = []
        @state_slot = nil
        @last_state = nil
        @last_message = nil
        # pi: reportSeq starts at Date.now() * 1000, +1 per report,
        # monotonic across the process (the Spec's Time.now.to_i * 1000
        # base).
        @seq = Time.now.to_i * 1000
        @sender = Thread.new { drain_loop }
      end

      # pane.report_agent_session (pi reportSession): NO session ref → no
      # request at all (pi's early return); +reason+ adds the
      # session_start_source field.
      def report_session(session_ref, pane_id:, reason: nil)
        return unless session_ref.is_a?(Hash)

        params = {"pane_id" => pane_id, "source" => SOURCE, "agent" => AGENT}
        params["session_start_source"] = reason if reason
        params["agent_session_path"] = session_ref["agent_session_path"] if session_ref["agent_session_path"]
        params["agent_session_id"] = session_ref["agent_session_id"] if session_ref["agent_session_id"]
        request = {
          "id" => "#{SOURCE}:session:#{epoch_ms}:#{rand36}",
          "method" => "pane.report_agent_session",
          "params" => params
        }
        @mutex.synchronize do
          request["params"]["seq"] = next_seq
          @sessions << request
          @resource.signal
        end
        nil
      end

      # pane.report_agent (pi sendState): +message+ only when present
      # (JSON.stringify drops undefined); same state+message deduped
      # unless +force+ (the session_start publish). pi allocates the seq
      # at enqueue time — a deduped report consumes none.
      def report_state(state, message: nil, session_ref: nil, pane_id:, force: false)
        @mutex.synchronize do
          return if !force && state == @last_state && message == @last_message

          params = {"pane_id" => pane_id, "source" => SOURCE, "agent" => AGENT, "state" => state}
          params["message"] = message unless message.nil?
          if session_ref.is_a?(Hash)
            params["agent_session_path"] = session_ref["agent_session_path"] if session_ref["agent_session_path"]
            params["agent_session_id"] = session_ref["agent_session_id"] if session_ref["agent_session_id"]
          end
          @last_state = state
          @last_message = message
          @state_slot = {"id" => "#{SOURCE}:#{epoch_ms}:#{rand36}", "method" => "pane.report_agent",
                         "params" => params.merge("seq" => next_seq)}
          @resource.signal
        end
        nil
      end

      private

      # One sender thread; states coalesce while in flight (the slot holds
      # only the LATEST queued state), sessions queue FIFO.
      def drain_loop
        loop do
          request = @mutex.synchronize do
            @resource.wait(@mutex) while @sessions.empty? && @state_slot.nil?
            @sessions.empty? ? @state_slot.tap { @state_slot = nil } : @sessions.shift
          end
          send_request(request)
        rescue StandardError
          # swallowed — the harness NEVER crashes on herdr
        end
      end

      # One attempt at the first budget, ONE retry at the second; every
      # failure resolves undelivered (pi sendRequest).
      def send_request(request)
        @timeouts.each do |timeout_ms|
          return true if send_attempt(request, timeout_ms / 1000.0)
        end
        false
      end

      # connect → write JSON+"\n" → ANY read byte = delivered; error/EOF/
      # timeout = undelivered.
      def send_attempt(request, timeout)
        sock = UNIXSocket.new(@socket_path)
        begin
          sock.write("#{JSON.generate(request)}\n")
          return false unless IO.select([sock], nil, nil, timeout)

          sock.readpartial(1)
          true
        rescue EOFError, IOError, SystemCallError
          false
        ensure
          begin
            sock.close
          rescue IOError, SystemCallError
            nil
          end
        end
      rescue SystemCallError
        false
      end

      def next_seq
        @seq += 1
      end

      def epoch_ms
        (Time.now.to_f * 1000).to_i
      end

      def rand36
        rand(36**8).to_s(36)
      end
    end
  end
end
