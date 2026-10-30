# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/mock_llm_server"
require "stringio"

module Tart
  # The swallowed-delivery surrogate (I90 Law 6 — pins 2/5): simulates the
  # class-(a) defect's OBSERVABLE, not its mechanism (the io-event
  # ready-queue machinery is not ours to reproduce) — a run that RECEIVES a
  # cancel but never ends. #run emits :agent_start, parks on an
  # Async::Queue#pop (never a sleep), survives EXACTLY ONE Async::Cancel
  # (pops again — the swallowed-delivery shape), honors the second
  # (teardown cleanliness — a hang here is the I82 wedge class, loud), and
  # NEVER emits :agent_end — so busy? sticks and the belt's delivery
  # evidence never arrives. The pin COMPLETING is the teardown-cleanliness
  # proof; the cancel count itself is delivery-weather and never asserted.
  class SwallowSurrogate
    def initialize(sink)
      @sink = sink
      @park = Async::Queue.new
      @cancels = 0
    end

    attr_reader :cancels

    def run(*)
      @sink.call({type: :agent_start})
      begin
        @park.pop
      rescue Async::Cancel
        @cancels += 1
        retry if @cancels == 1
        raise
      end
    end

    def queued_messages?
      false
    end
  end

  # The minimal command surface (pin 4 — the I54 dispatch shape):
  # expand_skill passes through, dispatch records — the recorded call IS
  # the deferred re-dispatch observation.
  class RecordingCommands
    def initialize
      @dispatched = []
    end

    attr_reader :dispatched

    def expand_skill(text)
      text
    end

    def dispatch(text)
      @dispatched << text
      true
    end
  end

  # The I90 interrupt-delivery belt's six pins (Law 6) — the belt's
  # deterministic contract: arm on a surface-dispatched interrupt only,
  # disarm on ANY agent_end with zero residue, escalate EXACTLY ONCE with
  # the frozen loud line on a missed delivery. Self-contained wiring (the
  # repro_a.rb inline shape): MockLLMServer + ScriptedSession + the real
  # kernel + the real (or swallow-surrogate) agent, built in-file —
  # chat_test.rb is byte-frozen and never opened. Every wait polls an
  # observable through the frozen wait_until; the file holds ZERO sleep
  # tokens (I82 — the surrogate's park is a Queue#pop).
  class InterruptDeliveryBeltTest < Test
    # The frozen loud line (byte-exact, em-dash U+2014) — the escalation's
    # transcript surface (Law 3).
    BELT_LINE = "interrupt delivery failed — run aborted"

    Rig = Struct.new(:session, :kernel, :chat, :commands)

    def setup
      @server = nil
    end

    def teardown
      @server&.stop
    end

    # --- The repro_a.rb inline wiring ------------------------------------

    # ScriptedSession + the real kernel (event-only mode) + the real chat
    # surface, wired exactly as bin/tart does (renderer + on_event); the
    # agent is the block's build (the surrogate pins) or the real
    # Agent::Loop over the mock server.
    def build_rig(commands: nil)
      session = ScriptedSession.new(width: 80, height: 24)
      kernel = Core::Loop.new(session:)
      chat = Render::Chat.new(session:, kernel:, branch_reader: nil, autocomplete: nil,
                              motd: false, identity: Identity::DEFAULT)
      chat.commands = commands if commands
      chat.agent = block_given? ? yield(chat) : real_agent_for(chat)
      kernel.renderer = chat.renderer
      kernel.on_event = ->(event, source) { chat.on_event(event, source) }
      Rig.new(session, kernel, chat, commands)
    end

    # The real agent over the mock server (the belt-catch wiring): the gem
    # Client on the wire, hermetically; its events feed the chat sink.
    def real_agent_for(chat)
      Agent::Loop.new(
        chat: Test::TestChat.build(@server, tools: [], system_prompt: "test"),
        tools: [],
        on_event: ->(event) { chat.on_agent_event(event) }
      )
    end

    # The scenario shape (the I87 twins'): the script runs on its own
    # thread while kernel.run blocks the main thread; kernel.stop! rides an
    # ensure on EVERY exit path (the I82 anti-wedge belt) — skipped when
    # the belt already stopped the kernel, so a pin's stop! records stay
    # exactly the belt's own.
    def run_scenario(kernel)
      scenario = Thread.new do
        begin
          yield
        ensure
          kernel.stop! unless kernel.stop_requested?
        end
      end
      kernel.run
      scenario.join
    end

    def type(session, text)
      text.chars.each { |char| session.push_event(Tart::TUI.key_event(char)) }
      session.push_event(Tart::TUI.key_event("enter"))
    end

    # The transcript widget tree's plain text (the escape twin's render
    # observable — what actually PAINTED, not what was emitted).
    def rendered_text(session)
      widget_lines(session.drawn.last).map { |line| line.spans.map(&:content).join }.join
    end

    def widget_lines(widget)
      if widget.respond_to?(:text)
        widget.text.is_a?(String) ? [] : widget.text
      elsif widget.respond_to?(:children)
        widget.children.flat_map { |child| widget_lines(child) }
      else
        []
      end
    end

    # The mock server's captured request bodies (captured_requests drains —
    # accumulate so repeated polls see history).
    def drain_captured(into)
      into.concat(@server.captured_requests)
      into
    end

    def user_text(request)
      request["messages"].select { |message| message["role"] == "user" }.last["content"]
    end

    # --- The six pins (Law 6) --------------------------------------------

    # Pin 1 — arm on the ESC abort, disarm on delivery. Real wiring with
    # the I87-cured handshake: ESC only after the server captured the
    # request AND three content chunks RENDERED — the work task is live and
    # the agent fiber parked at the SSE read, where cancellation delivery
    # is the designed mechanism. Deterministic green: the pin's subject is
    # the disarm, not the race. The 80-char slow stream (~8 s at the frozen
    # 0.1 s/char pace) outlasts the 5 s wait_until — a dropped interrupt
    # reds loudly, never a masked natural end.
    def test_belt_arms_on_esc_abort_and_disarms_on_delivery
      @server = MockLLMServer.new.start
      @server.script([{type: :slow_stream, content: "x" * 80}, {type: :message, content: "still there"}])
      rig = build_rig
      captured = []
      run_scenario(rig.kernel) do
        type(rig.session, "long stream")
        wait_until { rig.chat.busy? }
        wait_until { drain_captured(captured).any? { |request| user_text(request) == "long stream" } }
        wait_until { rendered_text(rig.session).include?("xxx") }
        rig.session.push_event(Tart::TUI.key_event("esc"))
        wait_until { !rig.chat.busy? }
        wait_until { rig.chat.transcript_lines.join.include?("interrupted") }
        # Delivery evidence disarms the belt: flag false, exactly one arm,
        # no belt line, and the belt did NOT stop the kernel.
        assert_equal false, rig.chat.interrupt_belt_armed?
        assert_equal 1, rig.chat.interrupt_belt_arms
        assert_equal false, rig.chat.transcript_lines.join.include?(BELT_LINE)
        assert_equal false, rig.kernel.stop_requested?
        # The loop is still alive — a follow-up submit lands (the escape
        # twin's "still there" shape).
        type(rig.session, "still there")
        wait_until { drain_captured(captured).any? { |request| user_text(request) == "still there" } }
      end
      assert_includes rig.chat.transcript_lines.join, "interrupted"
    end

    # Pin 2 — the deterministic miss: the swallow surrogate parks forever
    # (never agent_end), the injected 0.2 s deadline expires, and the belt
    # escalates EXACTLY ONCE — the exact line on the transcript, the stderr
    # warn, kernel.stop! — and kernel.run RETURNS bounded (the wait_until
    # is the wall: esc→stop-observed < 5 s, never a sleep). ALSO the I90
    # ruling's graceful-degradation proof: the belt's OWN tick is swept
    # (stopped) right after the ESC — with no re-dispatch to revive it, the
    # armed flag plus the busy spinner's I58 render cadence ALONE must fire
    # the guard at the absolute deadline (the guard never depends on the
    # belt's own tick being alive).
    def test_belt_escalates_on_undelivered_delivery
      rig = build_rig { |chat| SwallowSurrogate.new(->(event) { chat.on_agent_event(event) }) }
      rig.chat.interrupt_delivery_deadline = 0.2 # the frozen seam (Law 4)
      stderr = StringIO.new
      old_stderr = $stderr
      esc_to_stop = nil
      begin
        run_scenario(rig.kernel) do
          type(rig.session, "long stream")
          # The UNGATED busy ESC — whatever the delivery weather, the
          # surrogate never ends the run: the miss is deterministic.
          wait_until { rig.chat.busy? }
          $stderr = stderr
          t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          rig.session.push_event(Tart::TUI.key_event("esc"))
          # The I90 §4 sweep: kill the belt's own watchdog tick — the
          # escalation below must ride the flag + the spinner cadence.
          rig.chat.instance_variable_get(:@interrupt_belt_task)&.stop
          wait_until { rig.kernel.stop_requested? } # bounded — the belt fired
          esc_to_stop = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
        end
      ensure
        $stderr = old_stderr
      end
      assert_equal 1, rig.chat.transcript_lines.count { |line| line.include?(BELT_LINE) }
      # The stderr warn captured: $stderr rides a StringIO across the
      # escalation window and the assertion is containment (other threads'
      # warnings absorb harmlessly). The warn PRECEDES the stop in the
      # frozen escalation order (Law 3), so it is deterministically present
      # by stop_requested? — the bounded observation above.
      assert_includes stderr.string, "tart: interrupt delivery failed — run aborted (kernel stopped)"
      assert_equal true, rig.kernel.stop_requested?
      # kernel.run RETURNED: every assert here runs on the main thread
      # after run_scenario's kernel.run came back — the belt's stop! wound
      # the loop down and the surrogate honored the second cancel.
      assert_equal 1, rig.chat.interrupt_belt_arms
      assert_operator esc_to_stop, :<, 5.0
    end

    # Pin 3 — the zero-normal-path-cost property, structural: a normal run
    # to natural end arms NOTHING (arms == 0 asserted after the natural
    # agent_end), leaves the belt disarmed, and paints no belt line.
    def test_belt_never_arms_without_an_abort
      @server = MockLLMServer.new.start
      @server.script([{type: :message, content: "done"}])
      rig = build_rig
      captured = []
      run_scenario(rig.kernel) do
        type(rig.session, "hello")
        wait_until { drain_captured(captured).any? { |request| user_text(request) == "hello" } }
        wait_until { rig.chat.transcript_lines.join.include?("done") }
        wait_until { !rig.chat.busy? }
      end
      assert_equal 0, rig.chat.interrupt_belt_arms
      assert_equal false, rig.chat.interrupt_belt_armed?
      assert_equal false, rig.chat.transcript_lines.join.include?(BELT_LINE)
    end

    # Pin 4 — the busy /compact abort rides the belt: the busy_command_arm
    # dispatch arms it (arms == 1); on honest delivery the belt disarms AND
    # the deferred command re-dispatches through the idle path (the I54
    # behavior, byte-unchanged — the recorded dispatch IS the deferred
    # surface, per the existing arm's contract). No belt line.
    def test_busy_command_abort_rides_the_belt
      @server = MockLLMServer.new.start
      @server.script([{type: :slow_stream, content: "x" * 80}])
      commands = RecordingCommands.new
      rig = build_rig(commands: commands)
      captured = []
      run_scenario(rig.kernel) do
        type(rig.session, "long stream")
        wait_until { rig.chat.busy? }
        wait_until { drain_captured(captured).any? { |request| user_text(request) == "long stream" } }
        wait_until { rendered_text(rig.session).include?("xxx") }
        type(rig.session, "/compact")
        wait_until { rig.chat.interrupt_belt_arms == 1 } # the abort-first armed it
        wait_until { !rig.chat.busy? } # honest delivery
        wait_until { commands.dispatched.include?("/compact") } # the I54 re-dispatch
      end
      assert_equal 1, rig.chat.interrupt_belt_arms
      assert_equal false, rig.chat.interrupt_belt_armed?
      assert_equal false, rig.chat.transcript_lines.join.include?(BELT_LINE)
      assert_equal ["/compact"], commands.dispatched
      assert_includes rig.chat.transcript_lines.join, "interrupted"
    end

    # Pin 5 — escalation is idempotent: three ESCs inside the deadline
    # window, every one still dispatching interrupt_work! (the recording
    # kernel observes each and delegates unchanged), the armed belt never
    # re-arms (arms == 1, the ORIGINAL deadline stands), and the escalation
    # lands EXACTLY ONCE — one belt line, one stop (the belt's own; the
    # scenario ensure's stop is skipped by its stop_requested? guard).
    def test_belt_escalation_is_idempotent
      rig = build_rig { |chat| SwallowSurrogate.new(->(event) { chat.on_agent_event(event) }) }
      rig.chat.interrupt_delivery_deadline = 0.2 # the frozen seam (Law 4)
      interrupts = []
      stops = []
      kernel = rig.kernel
      kernel.define_singleton_method(:interrupt_work!) do
        interrupts << Process.clock_gettime(Process::CLOCK_MONOTONIC)
        super()
      end
      kernel.define_singleton_method(:stop!) do
        stops << Process.clock_gettime(Process::CLOCK_MONOTONIC)
        super()
      end
      run_scenario(kernel) do
        type(rig.session, "long stream")
        wait_until { rig.chat.busy? }
        rig.session.push_event(Tart::TUI.key_event("esc"))
        rig.session.push_event(Tart::TUI.key_event("esc"))
        rig.session.push_event(Tart::TUI.key_event("esc"))
        wait_until { kernel.stop_requested? } # the belt fired, bounded
      end
      assert_equal 3, interrupts.size # the dispatch ran per ESC
      assert_equal 1, rig.chat.interrupt_belt_arms # no re-arm
      assert_equal 1, rig.chat.transcript_lines.count { |line| line.include?(BELT_LINE) }
      assert_equal 1, stops.size # exactly one stop — the belt's own
      assert_equal true, kernel.stop_requested?
    end

    # Pin 6 — the idle ESC arms nothing: no interrupt dispatch, arms == 0,
    # no belt line, the loop alive (the idle no-op, pi parity,
    # byte-unchanged). The synthetic queue is FIFO, so the ESC is
    # dispatched BEFORE the follow-up submit — the run landing proves both
    # the dispatch happened (harmlessly) and the loop survived it.
    def test_idle_esc_arms_no_belt
      @server = MockLLMServer.new.start
      @server.script([{type: :message, content: "done"}])
      rig = build_rig
      captured = []
      run_scenario(rig.kernel) do
        rig.session.push_event(Tart::TUI.key_event("esc"))
        type(rig.session, "still there") # the loop must be alive to submit
        wait_until { drain_captured(captured).any? { |request| user_text(request) == "still there" } }
      end
      assert_equal 0, rig.chat.interrupt_belt_arms
      assert_equal false, rig.chat.interrupt_belt_armed?
      assert_equal false, rig.chat.transcript_lines.join.include?(BELT_LINE)
      assert_equal false, rig.chat.transcript_lines.join.include?("interrupted")
      assert_includes rig.chat.transcript_lines.join, "still there"
    end
  end
end
