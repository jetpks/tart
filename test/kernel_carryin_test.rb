# frozen_string_literal: true

require_relative "test_helper"

module RaspberryPi
  # I02 carry-ins (defect ledger / I02 Verdict): exception-safe kernel
  # teardown, SIGINT trap restoration, surfaced poller joins, and the
  # documented event-only mode.
  class KernelCarryInTest < Test
    def test_raising_event_handler_terminates_poller_and_reraises
      session = ScriptedSession.new
      event_loop = Core::Loop.new(session:, on_event: ->(_event, _source) { raise "handler boom" })
      session.push_native(KeyEvent.new("q", []))

      error = assert_raises(RuntimeError) { event_loop.run { sleep 30 } }
      assert_equal "handler boom", error.message
      refute event_loop.poller&.thread&.alive?, "no orphan poller after a handler raise"
    end

    def test_raising_renderer_terminates_poller_and_reraises
      session = ScriptedSession.new
      event_loop = Core::Loop.new(session:, renderer: -> { raise "renderer boom" })
      session.push_native(KeyEvent.new("q", []))

      error = assert_raises(RuntimeError) { event_loop.run { sleep 30 } }
      assert_equal "renderer boom", error.message
      refute event_loop.poller&.thread&.alive?, "no orphan poller after a renderer raise"
    end

    def test_raising_work_terminates_poller_and_reraises
      session = ScriptedSession.new
      event_loop = Core::Loop.new(session:)

      # Yield to the reactor before raising: async 2.46 logs "Task may have
      # ended with unhandled exception" unless someone is waiting on the task
      # (task.rb:224-226 `unless @promise.waiting?`), and a synchronous raise
      # beats the kernel's supervisor to the wait. The yield lets the
      # supervisor register, so the failure stays observed as handled — the
      # kernel still reraises it after teardown, which is what we assert.
      error = assert_raises(RuntimeError) do
        event_loop.run do
          sleep 0.001
          raise "work boom"
        end
      end
      assert_equal "work boom", error.message
      refute event_loop.poller&.thread&.alive?, "no orphan poller after a work raise"
    end

    def test_sigint_trap_disposition_restored_after_run
      received = Queue.new
      previous = Signal.trap("INT") { received << :mine }
      begin
        event_loop = Core::Loop.new(session: ScriptedSession.new)
        event_loop.run { sleep 0.05 }

        # The kernel's INT net must be gone: our own handler fires again.
        Process.kill("INT", Process.pid)
        assert_equal :mine, received.pop(timeout: 2) || received.pop
      ensure
        Signal.trap("INT", previous)
      end
    end

    def test_interrupt_via_sigint_cancels_work
      received = Queue.new
      previous = Signal.trap("INT") { received << :mine }
      begin
        state = {cancelled: false}
        work = ->(_task) do
          loop { sleep 0.01 }
        rescue Async::Cancel
          state[:cancelled] = true
          raise
        end
        event_loop = Core::Loop.new(session: ScriptedSession.new)
        # The kernel installs its net for the duration; route INT in-band.
        thread = Thread.new { sleep 0.1; Process.kill("INT", Process.pid) }
        event_loop.run(&work)
        thread.join

        assert event_loop.interrupted?, "SIGINT must cancel the work subtree in-band"
        assert state[:cancelled]
      ensure
        Signal.trap("INT", previous)
        received.pop(timeout: 0) rescue nil
      end
    end

    def test_poller_stop_surfaces_missed_join
      session = ScriptedSession.new(poll_timeout: 10) # a poll takes 10 s
      poller = Core::Poller.new(session, queue: Async::Queue.new, frame_interval: 1.0 / 60,
                                stop_flag: stop_flag)
      poller.start

      error = assert_raises(Core::PollerLingerError) { poller.stop }
      assert_includes error.message, "poller thread"
    ensure
      poller.thread.kill if poller.thread&.alive?
    end

    def test_blockless_run_is_event_only_mode
      session = ScriptedSession.new
      event_loop = Core::Loop.new(session:)
      thread = Thread.new do
        sleep 0.1
        event_loop.stop!
      end

      event_loop.run # no block: event-only mode, runs until stopped
      thread.join
      assert event_loop.stats.is_a?(Hash)
    end

    private

    def stop_flag
      @stop_flag ||= Class.new do
        def stop_requested? = false
      end.new
    end
  end
end
