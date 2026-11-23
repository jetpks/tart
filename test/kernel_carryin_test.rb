# frozen_string_literal: true

require_relative "test_helper"

module Tart
  # I02 carry-ins (defect ledger / I02 Verdict): exception-safe kernel
  # teardown, SIGINT trap restoration, surfaced teardown errors, and the
  # documented event-only mode. (I109: the poller-thread pins are re-seated
  # on the input seam — the thread class died with the thread.)
  class KernelCarryInTest < Test
    def test_raising_event_handler_stops_the_input_seam_and_reraises
      session = ScriptedSession.new
      event_loop = Core::Loop.new(session:, on_event: ->(_event, _source) { raise "handler boom" })
      session.push_native(KeyEvent.new("q", []))

      error = assert_raises(RuntimeError) { event_loop.run { sleep 30 } }
      assert_equal "handler boom", error.message
      assert_predicate event_loop.input_seam, :stopped?,
        "no orphan input-seam producer after a handler raise"
    end

    def test_raising_renderer_stops_the_input_seam_and_reraises
      session = ScriptedSession.new
      event_loop = Core::Loop.new(session:, renderer: -> { raise "renderer boom" })
      session.push_native(KeyEvent.new("q", []))

      error = assert_raises(RuntimeError) { event_loop.run { sleep 30 } }
      assert_equal "renderer boom", error.message
      assert_predicate event_loop.input_seam, :stopped?,
        "no orphan input-seam producer after a renderer raise"
    end

    def test_raising_work_stops_the_input_seam_and_reraises
      session = ScriptedSession.new
      event_loop = Core::Loop.new(session:)

      # Yield to the reactor before raising: async 2.46 logs "Task may have
      # ended with unhandled exception" unless someone is waiting on the task
      # (task.rb:224-226 `unless @promise.waiting?`), and a synchronous raise
      # beats the kernel's supervisor to the wait. The boot await parks this
      # work fiber until the kernel's post-boot broadcast, so the supervisor
      # registers before the raise — the failure stays observed as handled —
      # and the kernel still reraises it after teardown, which is what we
      # assert.
      error = assert_raises(RuntimeError) do
        event_loop.run do
          await(event_loop, "the kernel's boot broadcast") do
            event_loop.state_version >= 1
          end
          raise "work boom"
        end
      end
      assert_equal "work boom", error.message
      assert_predicate event_loop.input_seam, :stopped?,
        "no orphan input-seam producer after a work raise"
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

    def test_blockless_run_is_event_only_mode
      session = ScriptedSession.new
      event_loop = Core::Loop.new(session:)
      thread = Thread.new do
        # I103 (A): the kernel's post-boot broadcast — the foreign stopper
        # parks on the loop's seam instead of betting a delay on the boot.
        await(event_loop, "the kernel's boot broadcast") { event_loop.state_version >= 1 }
        event_loop.stop!
      end

      event_loop.run # no block: event-only mode, runs until stopped
      thread.join
      assert event_loop.stats.is_a?(Hash)
    end

  end
end
