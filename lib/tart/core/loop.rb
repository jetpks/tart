# frozen_string_literal: true

require "async"

require_relative "poller"

module Tart
  module Core
    # The event-loop kernel (Design B, BRIEF §4/§4.1).
    #
    # One +Async+ reactor owns all reactor-side work — timers, socket/pipe
    # readers, the frame loop. A dedicated {Poller} thread polls the TUI and
    # bridges native events over the thread-safe +Async::Queue+. Synthetic
    # events cross threads via +SyntheticEvents.push+ (through the TUI
    # module) and are drained each frame in-loop.
    #
    # Ctrl+C is handled in-band: in raw mode byte 0x03 arrives as a Key event
    # ("c" + ctrl), which cancels the in-flight work task subtree via
    # +Task#stop+. A +Signal.trap("INT")+ net routes through the same
    # in-band interrupt — it only cancels tasks, never relies on SIGINT
    # default behavior.
    #
    # Pacing is adaptive: while an animation window is open ({#animate}),
    # frames are deadline-paced at the frame rate (sleep until the next frame
    # deadline, not fixed sleep); with no window open the loop is
    # event-driven — it blocks on the event queue and does not wake.
    #
    # Cross-thread state: everything crosses threads via the sanctioned seams
    # (+Async::Queue+, +SyntheticEvents+) except the stop flag, which is
    # mutex-guarded. All other mutable state (@work_task, @tasks,
    # @animation_deadline, stats) is touched only by reactor fibers on the
    # main thread.
    class Loop
      WAKE = :wake # sentinel: unblock the idle loop (drain synthetic etc.)
      STOP = :stop # sentinel: exit the frame loop
      INTERRUPT = :interrupt # sentinel: the Signal.trap net

      # Wake this long before a frame deadline; the remainder is spun out
      # cooperatively because a reactor sleep overshoots by ~2ms.
      SPIN_MARGIN = 0.002

      # @param session [TUI::Session or duck-type: #draw, #poll_event,
      #   #push_event, #drain_synthetic, #synthetic_pending?]
      # @param renderer [Proc, nil] called once per draw; returns a status
      #   String (rendered as a Paragraph in a Block) or a widget tree drawn
      #   as-is (I04: the chat surface's live region).
      # @param on_event [Proc, nil] called as +(event, source)+ for every
      #   dispatched event; +source+ is +:native+ or +:synthetic+.
      # @param frame_rate [Numeric] animation-window frame rate (Hz).
      def initialize(session:, renderer: nil, on_event: nil, frame_rate: 60)
        @session = session
        @renderer = renderer
        @on_event = on_event
        @frame_interval = 1.0 / frame_rate

        @events = Async::Queue.new
        @stop_mutex = Mutex.new
        @stop = false
        @interrupted = false
        @work_error = nil

        # Reactor-thread-only state (no mutex needed; see class comment).
        @work_task = nil
        @tasks = []
        @animation_deadline = nil
        # Boot render: the first frame is dirty by definition (pi renders on
        # start — tui.ts start() requestRender); after it, draw_frame's gate
        # keeps static frames off the CPU (I01).
        @dirty = true
        @draws = 0
        @wakes = 0

        @running = false
      end

      # Runs the kernel until the work block completes or the loop is
      # stopped/interrupted. The terminal lifecycle is the caller's: wrap in
      # +TUI.run+ (its ensure restores the terminal even on raise).
      #
      # Without a block this is the documented event-only mode: the loop
      # runs until {#stop!} or an interrupt arrives — there is no work task
      # to supervise, so nothing pushes STOP on its own.
      #
      # Teardown is exception-safe (I02 carry-in): whatever the work block
      # or an event handler raises, the poller is stopped and the SIGINT
      # trap net is restored to its pre-run handler. A {Loop} is single-use;
      # build a new one to run again.
      #
      # @yield the work block, run as a reactor task subtree; Ctrl+C cancels
      #   exactly this subtree (and re-raises any error it raised, after
      #   the terminal is restored).
      def run(&work)
        raise "loop already running" if @running
        @running = true
        previous_trap = install_trap_net

        begin
          Async do |root|
            begin
              @work_task = root.async(&work) if work
              poller = Poller.new(@session, queue: @events, frame_interval: @frame_interval, stop_flag: self)
              poller.start
              supervisor = root.async { supervise(@work_task) }
              frame_loop
            rescue StandardError => e
              # An error from the frame loop itself (an event handler, the
              # renderer) must surface after teardown: async 2.x does not
              # re-raise the root task body's exception, it only logs it.
              @work_error = e
            ensure
              # Exception-safe teardown (I02 carry-in): whatever raised — the
              # work subtree, an event handler, the renderer — the poller must
              # see the stop flag before it is joined, or it lingers (and the
              # linger error would mask the original failure).
              request_stop
              @tasks.each(&:stop)
              @work_task&.stop
              supervisor&.stop
              @poller = poller
              poller&.stop
            end
          end
        ensure
          Signal.trap("INT", previous_trap)
        end

        raise @work_error if @work_error
        self
      end

      # Opens an animation window: frames are deadline-paced at the frame
      # rate until +duration+ seconds elapse. May be called from any reactor
      # fiber; wakes an idle loop.
      def animate(duration:)
        @animation_deadline = now + duration
        signal(WAKE)
      end

      # @return [Boolean] whether an animation window is open.
      def animating?
        @animation_deadline && now < @animation_deadline
      end

      # Requests exactly one redraw (pi requestRenderCallback): marks the
      # next frame dirty and wakes an idle loop. Unlike {#animate} it opens
      # no animation window — one frame, then the loop is event-driven
      # again (the I20 scrollbar-hide timer's hide redraw). Reactor context
      # only (the dirty flag is reactor state).
      def request_draw
        @dirty = true
        signal(WAKE)
      end

      # Spawns a task on the reactor. Reactor context only (call from the
      # work block or tasks it spawned).
      def async(&block)
        task = Async::Task.current.async(&block)
        @tasks << task
        task
      end

      # Periodic timer on the reactor: fires +ticks+ times, +period+ seconds
      # apart, on an absolute schedule (no cumulative drift). Yields the
      # tick number (1-based).
      def every(period, ticks:, &block)
        async do
          t0 = now
          ticks.times do |i|
            block.call(i + 1)
            d = t0 + (i + 1) * period - now
            sleep d if d > 0
          end
        end
      end

      # Requests shutdown from any thread: sets the stop flag (mutex-guarded)
      # and wakes the idle loop.
      def stop!
        request_stop
        signal(STOP)
      end

      # @return [Boolean] whether the poller thread is still alive. Used by
      #   tests to prove teardown leaves no orphan poller.
      attr_reader :poller

      # @return [Boolean] whether shutdown was requested. Thread-safe; the
      #   poller thread polls this every frame.
      def stop_requested?
        @stop_mutex.synchronize { @stop }
      end

      # Cancels the in-flight work (the work task, else the {#async} tasks)
      # WITHOUT the Ctrl+C quit fallback — the editor's escape-interrupt path
      # (pi app.interrupt, keybindings.ts:26 → onEscape aborts a streaming
      # run, interactive-mode.ts:3070-3090): an idle loop stays alive. Same
      # Task#stop mechanism as the Ctrl+C path — no second interrupt path.
      # @return [Boolean] whether any live work was cancelled.
      def interrupt_work!
        work = @work_task
        if work&.alive?
          work.stop
          true
        elsif @tasks.any?(&:alive?)
          @tasks.each(&:stop)
          true
        end
      end

      # @return [Boolean] whether a Ctrl+C interrupt was seen this run.
      #   Thread-safe (I02 carry-in).
      def interrupted?
        @stop_mutex.synchronize { @interrupted }
      end

      # @return [Hash] run statistics (draws, event-driven wakes, interruption).
      # Thread-safe (I02 carry-in: readable from any thread).
      def stats
        @stop_mutex.synchronize do
          {draws: @draws, wakes: @wakes, interrupted: @interrupted}
        end
      end

      # Renderer/event-handler setters (I04: the chat surface attaches itself
      # after the kernel and chat are built together). Reactor-side only;
      # set before {#run}.
      attr_writer :renderer, :on_event

      private

      # Cancels the in-flight work task subtree on Ctrl+C. With no live work
      # task, cancels any reactor tasks spawned via {#async} (I04: the chat
      # surface submits agent runs this way); with nothing alive, the
      # interrupt stops the loop.
      def interrupt!
        @stop_mutex.synchronize { @interrupted = true }
        interrupt_work! || stop!
      end

      # Runs the work subtree; any exit path eventually stops the loop.
      def supervise(work_task)
        return unless work_task
        begin
          work_task.wait
        rescue Async::Cancel
          # Expected after a Ctrl+C interrupt or loop teardown.
        rescue StandardError => e
          @work_error = e
        ensure
          signal(STOP)
        end
      end

      # Wakes the frame loop with a sentinel from reactor-side code (a
      # fiber). The push crosses a thread boundary: Async::Queue delegates
      # to ::Queue, and a push from another fiber on this thread can fail to
      # wake a fiber blocked in #pop — the wakeup relies on the scheduler's
      # unblock, which reliably writes the selector's wakeup pipe only from
      # another thread (measured lost wakeups on async 2.46 / ruby 4.0;
      # cross-thread pushes — the poller, stop! from a foreign thread — are
      # the proven path).
      def signal(item)
        Thread.new { @events << item }.join
        self
      end

      def frame_loop
        next_deadline = nil
        until stop_requested?
          @session.drain_synthetic { |event| process(event, :synthetic) }
          drain_native
          draw_frame
          if animating?
            next_deadline ||= now + @frame_interval
            delta = next_deadline - now
            # Reactor sleep overshoots ~2ms on this platform (measured:
            # sleep(1/60) returns at ~18.7ms), so sleep to just short of the
            # deadline, then cooperatively spin out the remainder.
            sleep(delta - SPIN_MARGIN) if delta > SPIN_MARGIN
            sleep(0) while now < next_deadline
            next_deadline += @frame_interval
            # Re-anchor instead of bursting if a frame fell far behind.
            next_deadline = now + @frame_interval if next_deadline < now
          else
            next_deadline = nil
            process(@events.pop, :native) # event-driven: no fixed-rate wake
            @wakes += 1
          end
        end
      end

      def drain_native
        until @events.empty?
          process(@events.pop, :native)
        end
      end

      # Handles one queue item or synthetic event: control sentinels or
      # dispatch to the handler. In-band Ctrl+C is NOT intercepted here —
      # the key reaches the editor (pi's app.clear: clear, twice exits;
      # keybindings.ts:27, handleCtrlC) and ESCAPE is the interrupt (the
      # editor's onEscape path). The trap net keeps real SIGINTs
      # (interrupt_work! || stop!) for non-raw contexts.
      def process(event, source)
        case event
        when STOP then request_stop
        when INTERRUPT then interrupt!
        when WAKE then nil # wake only; the synthetic drain does the work
        else
          @on_event&.call(event, source)
          # Mouse events dispatch to the surface (wheel scroll, selection);
          # a bare pointer move carries no state change (the surface
          # ignores it — pi tui-alt-screen.ts applyMouseDispatchResult
          # renders on press/click/drag/wheel, not motion), and with
          # all-motion capture on (gem init.rs:67) moves stream on every
          # pointer step: redrawing per move would burn the idle CPU.
          @dirty = true unless event.respond_to?(:moved?) && event.moved?
        end
      end

      # Sets the stop flag (mutex-guarded). The STOP sentinel that wakes the
      # idle loop is pushed by whoever asks for the stop.
      def request_stop
        @stop_mutex.synchronize { @stop = true }
      end

      def draw_frame
        return unless @dirty || animating?
        @dirty = false
        return unless @renderer
        rendered = @renderer.call
        @session.draw(rendered.is_a?(String) ? TUI.status_panel(rendered) : rendered)
        @draws += 1
      end

      # Installs the SIGINT trap net; returns the previous handler so run's
      # teardown can restore it.
      def install_trap_net
        Signal.trap("INT") { @events << INTERRUPT }
      end

      def now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
