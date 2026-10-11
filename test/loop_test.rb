# frozen_string_literal: true

require_relative "test_helper"

module Tart
  class LoopTest < Test
    def test_first_frame_draws_at_boot_with_zero_events
      session = ScriptedSession.new
      event_loop = Core::Loop.new(session:, renderer: -> { "boot frame" })

      # No input event is ever pushed: the run ends as soon as the boot
      # render appears (pi renders on start; tui.ts start() requestRender).
      event_loop.run { wait_until { !session.drawn.empty? } }

      assert_operator event_loop.stats[:draws], :>=, 1,
        "the first frame must render at boot, before any input event"
    end

    # request_draw (I20, pi requestRenderCallback): exactly one frame, no
    # animation window — the scrollbar-hide timer's hide redraw. A wake
    # alone never draws (the poller's synthetic-drain wake); the explicit
    # dirty mark does.
    def test_request_draw_wakes_exactly_one_frame
      session = ScriptedSession.new
      event_loop = Core::Loop.new(session:, renderer: -> { "frame" })

      event_loop.run do
        wait_until { !session.drawn.empty? } # the boot frame
        event_loop.async { event_loop.request_draw }
        wait_until { event_loop.stats[:draws] > 1 }
      end

      assert_equal 2, event_loop.stats[:draws],
        "request_draw = one dirty frame, then the loop is event-driven again"
    end

    def test_native_events_round_trip_through_poller_and_queue
      session = ScriptedSession.new
      received = Queue.new
      event_loop = Core::Loop.new(session:, on_event: ->(event, source) { received << [event, source] })
      session.push_native(KeyEvent.new("q", []))

      event_loop.run { wait_until { !received.empty? } }

      event, source = received.pop(timeout: 0)
      assert_equal "q", event.code
      assert_equal :native, source
    end

    def test_synthetic_events_round_trip_from_another_thread
      # Cross-thread synthetic bridge at the kernel level: a foreign thread
      # pushes into the session's synthetic queue, the real poller thread
      # wakes the idle loop, the kernel drains in-loop and dispatches. (The
      # real ratatui SyntheticEvents queue itself is covered by TUITest — a
      # real headless session cannot serve a poller thread, whose crossterm
      # poll fails without a tty.)
      session = ScriptedSession.new
      received = Queue.new
      event_loop = Core::Loop.new(session:, on_event: ->(event, source) { received << [event, source] })

      event_loop.run do
        Thread.new { session.push_event(SyncEvent.new) }
        wait_until { !received.empty? }
      end

      event, source = received.pop(timeout: 0)
      assert event.sync?
      assert_equal :synthetic, source
    end

    # The gem's mouse event duck-shape (the surface's wheel/selection
    # events; ScriptedSession's native queue takes any event double).
    MouseEvent = Struct.new(:kind) do
      def mouse? = true

      def moved? = kind == "moved"

      def key? = false
    end

    # Mouse events dispatch to the surface like any other event (I14 item
    # 6: the kernel routes the gem's mouse events; shape verified live on
    # the synthetic seam).
    def test_mouse_events_route_to_the_surface
      session = ScriptedSession.new
      received = Queue.new
      event_loop = Core::Loop.new(session:, on_event: ->(event, source) { received << [event, source] })
      session.push_event(MouseEvent.new("scroll_up"))

      event_loop.run { wait_until { !received.empty? } }

      event, source = received.pop(timeout: 0)
      assert event.mouse?
      assert_equal "scroll_up", event.kind
      assert_equal :synthetic, source
    end

    # A bare pointer move carries no state change (pi renders on
    # press/click/drag/wheel, not motion — tui-alt-screen.ts
    # applyMouseDispatchResult); with all-motion mouse capture on, moves
    # stream per pointer step and must not trigger redraws.
    def test_bare_pointer_motion_does_not_redraw
      session = ScriptedSession.new
      received = Queue.new
      event_loop = Core::Loop.new(session:, renderer: -> { "frame" }, on_event: ->(event, _s) { received << event })

      event_loop.run do
        wait_until { !session.drawn.empty? } # the boot frame
        session.push_event(MouseEvent.new("moved"))
        wait_until { !received.empty? }
      end

      assert_equal 1, event_loop.stats[:draws], "the boot frame is the only draw; motion must not redraw"
    end

    def test_state_carrying_mouse_events_redraw
      session = ScriptedSession.new
      event_loop = Core::Loop.new(session:, renderer: -> { "frame" })

      event_loop.run do
        wait_until { !session.drawn.empty? } # the boot frame
        session.push_event(MouseEvent.new("drag"))
        wait_until { event_loop.stats[:draws] > 1 }
      end

      assert_operator event_loop.stats[:draws], :>, 1, "press/drag/wheel events redraw"
    end

    # Backlog C — pi's keybindings: ctrl+c is app.clear (the EDITOR's
    # clear/double-exit, keybindings.ts:27 + handleCtrlC); the loop is not
    # the decider. The key reaches the surface handler; escape is the
    # interrupt (the escape-path test below). The trap net keeps real
    # SIGINTs for non-raw contexts.
    def test_ctrl_c_reaches_the_surface_as_app_clear
      session = ScriptedSession.new
      session.push_native(KeyEvent.new("c", ["ctrl"]))
      seen = []
      event_loop = Core::Loop.new(session:)
      event_loop.on_event = ->(event, _source) { seen << event }
      event_loop.run { sleep 0.05 }

      assert seen.any? { |e| e.respond_to?(:code) && e.code == "c" },
        "the ctrl+c key reaches the surface (app.clear)"
      refute event_loop.interrupted?, "ctrl+c no longer interrupts in-band"
    end

    # interrupt_work! (item 5/AC6, the escape path): cancels live work
    # through the same Task#stop mechanism WITHOUT the ctrl+c quit
    # fallback — an idle loop stays alive (pi onEscape aborts a streaming
    # run, interactive-mode.ts:3070-3090; app.interrupt = escape,
    # keybindings.ts:26).
    def test_interrupt_work_cancels_tasks_without_stopping_the_loop
      session = ScriptedSession.new
      state = {cancelled: false, still_running: nil}
      spawned = Queue.new
      event_loop = Core::Loop.new(session:)
      event_loop.on_event = lambda do |_event, _source|
        if spawned.empty?
          spawned << event_loop.async do
            loop { sleep 0.01 }
          rescue Async::Cancel
            state[:cancelled] = true
            raise
          end
        else
          event_loop.interrupt_work!
          state[:still_running] = !event_loop.stop_requested?
          event_loop.stop!
        end
      end
      session.push_native(KeyEvent.new("a", []))
      session.push_native(KeyEvent.new("b", []))

      event_loop.run

      assert state[:cancelled], "the async'd agent-run task is cancelled (Task#stop — the ctrl+c mechanism)"
      assert state[:still_running], "the loop outlives the interrupt — escape never quits (no stop! fallback)"
    end

    def test_static_loop_is_not_fixed_rate
      session = ScriptedSession.new(poll_timeout: 0.005)
      event_loop = Core::Loop.new(session:)

      event_loop.run { sleep 1.0 }

      assert_operator event_loop.stats[:wakes], :<, 10,
        "a static loop must block on the event queue, not wake at a fixed rate"
    end

    def test_animation_window_deadline_paces_frames
      session = ScriptedSession.new
      event_loop = Core::Loop.new(session:, renderer: -> { "frame" })
      work = ->(_task) do
        event_loop.animate(duration: 1.0)
        sleep 1.2
      end

      event_loop.run(&work)

      draws = event_loop.stats[:draws]
      # Deadline-paced at 60 Hz: ~60 frames over the 1 s window. The hard
      # >=58 fps gate is enforced by bench/seam_bench.rb; the suite asserts
      # the pacing behavior on a looser floor.
      assert_operator draws, :>=, 50, "expected ~60 deadline-paced frames, got #{draws}"
      assert_operator draws, :<=, 72
    end

    def test_reactor_owned_timer_ticks
      session = ScriptedSession.new
      ticks = Queue.new
      event_loop = Core::Loop.new(session:)
      work = ->(_task) do
        event_loop.every(0.02, ticks: 10) { |i| ticks << i }
        wait_until { ticks.size >= 10 }
      end

      event_loop.run(&work)

      assert_equal 10, ticks.size
    end

    def test_stop_from_another_thread_ends_run
      session = ScriptedSession.new
      event_loop = Core::Loop.new(session:)
      thread = Thread.new do
        sleep 0.1
        event_loop.stop!
      end

      event_loop.run { sleep 5 }

      thread.join
    end

    private

    # Runs inside the work task until the block is satisfied, then returns
    # (letting the work subtree finish normally and the supervisor stop the
    # loop). Fails the run after 5 s rather than hanging.
    def wait_until
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
      until yield
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          raise "work condition never satisfied"
        end
        sleep 0.005
      end
    end
  end
end
