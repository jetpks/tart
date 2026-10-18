# frozen_string_literal: true

require_relative "test_helper"

module Tart
  # The none-event double for this file's session doubles (TUI_NONE lives on
  # Tart::Test — not visible from these nested classes).
  SH_NONE = Class.new do
    def none? = true

    def key? = false

    def sync? = false
  end.new.freeze

  # The I75 signal-hygiene unit table (the pins behind the frozen
  # signal-hygiene-units gate filters — `/routing/` and `/teardown/` are the
  # gate's frozen -n filters, so every pin name carries its substring).
  # The LIVE proofs (real wedged pollers, real exit codes, real survivors)
  # are the six-leg harness legs — every unit here is mechanism-level, with
  # the hard-exit primitive STUBBED (the frozen division of labor: units pin
  # the guard/ladder/containment mechanics, the harness legs prove the
  # primitive live).
  class SignalHygieneTest < Test
    # --- /routing/ ---

    def test_routing_constants_are_frozen
      assert_equal({"HUP" => 129, "TERM" => 143}, TUI::SignalGuard::EXIT_FOR,
        "the 128+signum convention is frozen (the gem's own declared intent, pi's observable)")
      assert_equal 10, TUI::SignalGuard::EXIT_BOUND_S, "the delivery->exit bound is frozen"
      assert_predicate TUI::SignalGuard::EXIT_FOR, :frozen?
    end

    def test_routing_arm_traps_hup_and_term_and_captures_previous_handlers
      # The gem's require-time TERM trap is LIVE in this process (tart was
      # required) — capture it so the test can restore the exact pre-state;
      # the guard's own capture/restore is proven against a SEEDED state.
      gem_term_trap = Signal.trap("TERM", "IGNORE")
      guard = TUI::SignalGuard.new.arm
      begin
        assert_equal "IGNORE", guard.previous["TERM"],
          "the pre-arm handler is captured (the INT-net discipline)"
        probe_term = Signal.trap("TERM", "DEFAULT") # probe: is the trap ours?
        assert_kind_of Proc, probe_term, "TERM is tart-trapped during the armed window"
        Signal.trap("TERM", probe_term) # put the guard's trap back
        probe_hup = Signal.trap("HUP", "DEFAULT")
        assert_kind_of Proc, probe_hup, "HUP is tart-trapped during the armed window"
        Signal.trap("HUP", probe_hup)
      ensure
        guard.disarm
      end
      after = Signal.trap("TERM", "DEFAULT")
      assert_equal "IGNORE", after, "the seeded pre-arm handler is restored after disarm"
      Signal.trap("TERM", gem_term_trap) # restore the process's real pre-state
      after_hup = Signal.trap("HUP", "DEFAULT")
      Signal.trap("HUP", after_hup)
      assert_equal "DEFAULT", after_hup, "HUP rides back to its pre-arm handler too"
    end

    def test_routing_run_bracket_traps_during_and_restores_after
      # The pre-bracket handlers: HUP is DEFAULT (the gem traps only
      # INT/TERM at require time), TERM is the gem's own require-time trap.
      before_hup = Signal.trap("HUP", "DEFAULT")
      Signal.trap("HUP", before_hup)
      before_term = Signal.trap("TERM", "DEFAULT")
      Signal.trap("TERM", before_term)
      TUI.run(headless: true) do |_session|
        probe_hup = Signal.trap("HUP", "DEFAULT")
        assert_kind_of Proc, probe_hup, "HUP is trapped for the duration of the TUI.run bracket"
        Signal.trap("HUP", probe_hup)
        probe_term = Signal.trap("TERM", "DEFAULT")
        assert_kind_of Proc, probe_term, "TERM is trapped for the duration of the TUI.run bracket (the gem's is overridden)"
        Signal.trap("TERM", probe_term)
      end
      after_hup = Signal.trap("HUP", "DEFAULT")
      Signal.trap("HUP", after_hup)
      assert_equal "DEFAULT", after_hup, "the HUP handler is restored after the bracket"
      after_term = Signal.trap("TERM", "DEFAULT")
      Signal.trap("TERM", after_term)
      assert_equal before_term, after_term,
        "the captured pre-bracket TERM handler (the gem's require-time trap) is back after the bracket"
    end

    def test_routing_int_is_not_trapped_by_the_guard
      # SIGINT stays the loop's trap net (byte-frozen discipline): the guard
      # must not touch it inside its armed window.
      previous_int = Signal.trap("INT", "DEFAULT")
      TUI.run(headless: true) do |_session|
        probe = Signal.trap("INT", "DEFAULT")
        Signal.trap("INT", probe)
        assert_equal "DEFAULT", probe, "the guard installs no INT trap (the loop's net is the one INT authority)"
      end
      assert_equal "DEFAULT", Signal.trap("INT", previous_int), "INT is untouched end to end"
    end

    def test_routing_first_signal_code_wins
      fired = []
      guard = TUI::SignalGuard.new(exit_primitive: ->(code) { fired << code })
      guard.deliver("HUP")
      assert_equal 129, guard.pending_exit_code, "HUP records 129"
      guard.deliver("TERM") # a second signal DURING the routing: escalation, first code wins
      assert_equal [129], fired, "the hard exit carries the FIRST signal's code, never the second's"
      assert_equal 129, guard.pending_exit_code
    end

    def test_routing_second_signal_escalates_immediately
      fired = []
      ladder_ran = false
      guard = TUI::SignalGuard.new(
        steps: [-> { ladder_ran = true }],
        exit_primitive: ->(code) { fired << code })
      guard.deliver("TERM") # first signal: recorded (143)
      assert_empty fired, "the first signal only records + routes — no hard exit yet"
      refute_predicate guard, :exited?
      guard.deliver("HUP") # a second signal while the (not-yet-run) ladder is pending: IMMEDIATE escalation
      assert_equal [143], fired, "the escalation fired right in the trap handler, with the first code"
      refute ladder_ran, "the escalation bypasses the remaining ladder steps"
    end

    def test_routing_delivery_routes_the_loop_stop_path
      # The in-band routing end to end: an armed guard + a live kernel; the
      # HUP arrives from a foreign thread (the real delivery is trap context
      # on the main thread — the INT net's exact pattern), the frame loop
      # exits through its NORMAL return path, and run() RETURNS (no raise —
      # bin/tart's flush tail after kernel.run is thereby reached).
      fired = []
      guard = TUI::SignalGuard.new(exit_primitive: ->(code) { fired << code })
      guard.arm
      SignalGuardStub.activate(guard)
      event_loop = Core::Loop.new(session: ScriptedSession.new)
      Thread.new { sleep 0.1; Process.kill("HUP", Process.pid) }
      event_loop.run { wait_until { guard.pending_exit_code } }
      assert_equal 129, guard.pending_exit_code, "the delivered HUP recorded its code"
      assert_empty fired,
        "run() returned normally — the hard exit is the bracket tail's, not the loop's"
      refute_predicate event_loop.poller.thread, :alive?, "the (fast) poller joined cleanly on this path"
    ensure
      guard&.disarm
      SignalGuardStub.deactivate
    end

    # --- /teardown/ ---

    def test_teardown_ladder_runs_steps_in_order_then_the_hard_exit
      log = []
      guard = TUI::SignalGuard.new(
        steps: [-> { log << :stop_loop }, -> { log << :flush }],
        exit_primitive: ->(code) { log << [:exit, code] })
      guard.deliver("HUP")
      guard.complete
      assert_equal [:stop_loop, :flush, [:exit, 129]], log,
        "loop stop before flush, flush before the hard exit (the frozen ladder order)"
    end

    def test_teardown_deadline_check_skips_remaining_steps
      log = []
      guard = TUI::SignalGuard.new(
        bound: 0.2,
        steps: [-> { sleep 0.5; log << :slow_step }, -> { log << :skipped_step }],
        exit_primitive: ->(code) { log << [:exit, code] })
      guard.deliver("TERM")
      guard.complete
      assert_includes log, :slow_step, "an already-running step completes"
      refute_includes log, :skipped_step, "steps past the EXIT bound are skipped"
      assert_equal [:exit, 143], log.last, "the hard exit ALWAYS fires, even past the bound"
    end

    def test_teardown_hard_exit_fires_with_the_recorded_code_and_is_idempotent
      fired = []
      guard = TUI::SignalGuard.new(exit_primitive: ->(code) { fired << code })
      guard.deliver("HUP")
      guard.complete
      guard.complete # a second shutdown call is a no-op
      assert_equal [129], fired, "the hard exit fired exactly once, with the recorded code"
      assert_predicate guard, :exited?, "the latch holds across repeated complete calls"
    end

    def test_teardown_poller_linger_error_is_contained_on_the_signal_path
      # The poller parks past the 1s join (the wedged-native-call shape at
      # the Ruby seam, Grounds F4); on the signal path the linger raise is
      # contained — logged, never re-raised — and run() RETURNS so the flush
      # tail after kernel.run can run (the F5 mask is cured).
      guard = TUI::SignalGuard.new(exit_primitive: ->(_code) { nil })
      guard.arm
      SignalGuardStub.activate(guard)
      session = LingeringSession.new(2.5)
      event_loop = Core::Loop.new(session:)
      Thread.new { sleep 0.1; Process.kill("HUP", Process.pid) }
      # The HUP lands while the poller is parked inside its poll — the wedged
      # shape (deterministic: wait for the park before the run can wind down).
      event_loop.run { wait_until { session.polling? && guard.pending_exit_code } }
      assert_predicate event_loop.poller.thread, :alive?,
        "the wedged poller was abandoned, not joined to death (the hard exit owns it)"
    ensure
      guard&.disarm
      SignalGuardStub.deactivate
    end

    def test_teardown_poller_linger_error_still_surfaces_off_the_signal_path
      # Containment is signal-path-ONLY. At the Loop#run level the inner
      # ensure's re-raise is (async 2.x) swallowed+logged by the root task —
      # the standing I02 SURFACE is the raise itself, pinned at the Poller
      # seam (kernel_carryin_test pins it too; re-pinned here against the
      # cure's containment so the two live side by side).
      session = LingeringSession.new(2.5)
      poller = Core::Poller.new(session, queue: Queue.new, frame_interval: 1.0 / 60,
                                stop_flag: Object.new.tap { |o| o.define_singleton_method(:stop_requested?) { false } })
      poller.start
      wait_until { session.polling? } # the poller is parked inside its 2.5s poll
      error = assert_raises(Core::PollerLingerError) { poller.stop }
      assert_includes error.message, "poller thread"
    ensure
      poller.thread.kill if poller.thread&.alive?
    end

    def test_teardown_dead_tty_errors_are_contained_on_the_signal_path_only
      # The containment seam: dead-tty draw/restore errors (Errno::EIO, the
      # gem's "Failed to show the cursor" class) are contained on the signal
      # path and re-raised off it.
      guard = TUI::SignalGuard.new(exit_primitive: ->(_code) { nil })
      event_loop = Core::Loop.new(session: ScriptedSession.new)
      eio = Errno::EIO.new("dead pty")
      refute event_loop.contain_signal_path_error(eio),
        "off the signal path the caller re-raises (the standing surface)"
      guard.arm
      SignalGuardStub.activate(guard)
      begin
        guard.deliver("TERM")
        assert_equal 143, guard.pending_exit_code
        assert event_loop.contain_signal_path_error(eio),
          "on the signal path the dead-tty error is contained (logged, never masking the code)"
      ensure
        guard.disarm
        SignalGuardStub.deactivate
      end
    end

    def test_teardown_bracket_reraises_dead_tty_errors_off_the_signal_path
      # arm_and_complete's EIO containment is signal-path-only: a plain
      # Errno::EIO out of the block re-raises exactly as before.
      assert_raises(Errno::EIO) do
        TUI.run(headless: true) do |_session|
          raise Errno::EIO, "dead pty"
        end
      end
    end

    # --- doubles ---

    # A session double whose poll blocks LONGER than the poller's 1s join —
    # the poller thread parks inside poll (the F4 shape at the Ruby seam) and
    # lingers past the stop. +polling?+ flips true at poll entry so tests can
    # sequence deterministically around the parked poll.
    class LingeringSession
      def initialize(poll_s)
        @poll_s = poll_s
        @polling = false
      end

      def polling?
        @polling
      end

      def poll_event(timeout:)
        @polling = true
        sleep(@poll_s)
        SH_NONE
      end

      def draw(_widget); end

      def push_event(_event); end

      def drain_synthetic = 0

      def synthetic_pending? = false
    end

    # The class-level active-registry seam for kernel-level units: the real
    # arming owner is TUI.run's bracket; a bare kernel unit wires via
    # install_trap_net's lookup, so the stub plants the guard there.
    class SignalGuardStub
      class << self
        def activate(guard)
          TUI::SignalGuard.instance_variable_set(:@active, guard)
        end

        def deactivate
          TUI::SignalGuard.instance_variable_set(:@active, nil)
        end
      end
    end
  end
end
