# frozen_string_literal: true

require_relative "test_helper"

module Tart
  class LoopTest < Test
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

    def test_ctrl_c_interrupt_cancels_in_flight_task_subtree
      session = ScriptedSession.new
      session.push_native(KeyEvent.new("c", ["ctrl"]))
      state = {steps: 0, cancelled: false}
      work = ->(_task) do
        loop do
          state[:steps] += 1
          sleep 0.01
        end
      rescue Async::Cancel
        state[:cancelled] = true
        raise
      end

      event_loop = Core::Loop.new(session:)
      event_loop.run(&work)

      assert event_loop.interrupted?, "Ctrl+C must be seen in-band, not via SIGINT"
      assert state[:cancelled], "the in-flight task subtree must be cancelled"
      assert_operator state[:steps], :<, 50, "work must stop well before the loop tears down"
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
