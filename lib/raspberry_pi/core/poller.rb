# frozen_string_literal: true

module RaspberryPi
  module Core
    # The poller thread failed to terminate after stop (I02 carry-in).
    class PollerLingerError < StandardError; end

    # Dedicated thread bridging native TUI input into the reactor (Design B).
    #
    # Loops {Session#poll_event} — crossterm releases the GVL while blocked,
    # so the reactor fiber on the main thread keeps running — and hands every
    # event to the reactor over the thread-safe +Async::Queue+, the only
    # cross-thread seam besides +SyntheticEvents+.
    #
    # The poller knows nothing about interrupts or frames: it forwards events
    # verbatim; the loop kernel classifies Ctrl+C and paces frames.
    class Poller
      # @param session [#poll_event, #synthetic_pending?] the TUI session.
      # @param queue [Async::Queue] reactor-bound queue (thread-safe).
      # @param frame_interval [Float] poll budget in seconds (~1/60).
      # @param stop_flag [#stop_requested?] thread-safe stop predicate.
      def initialize(session, queue:, frame_interval:, stop_flag:)
        @session = session
        @queue = queue
        @frame_interval = frame_interval
        @stop_flag = stop_flag
        @thread = nil
      end

      def start
        @thread = Thread.new { poll_loop }
      end

      # Joins the poller; it returns within ~one frame of the stop flag.
      # Raises when the poller thread did not terminate within the join
      # budget (I02 carry-in: a missed join must surface, not vanish — an
      # orphaned poller would keep polling a restored terminal).
      #
      # @return [Thread, nil] the poller thread.
      def stop
        return unless @thread

        @thread.join(1)
        if @thread.alive?
          raise PollerLingerError, "poller thread did not terminate within 1s of stop"
        end
        @thread
      end

      # @return [Thread, nil] the poller thread (for orphan assertions).
      attr_reader :thread

      private

      def poll_loop
        until @stop_flag.stop_requested?
          t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          event = @session.poll_event(timeout: @frame_interval)
          @queue << event unless event.none?
          # Wake the idle loop so it drains pending synthetic events; the
          # events themselves are drained in-loop from SyntheticEvents.
          @queue << :wake if @session.synthetic_pending?
          # Headless (test-terminal) polls return instantly; keep the poller
          # from hot-spinning in that mode. A real terminal blocks ~one frame.
          if event.none?
            elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
            sleep(0.001) if elapsed < @frame_interval / 4
          end
        end
      end
    end
  end
end
