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
    # Cross-thread state: everything crosses threads via the sanctioned
    # seams (+Async::Queue+, +SyntheticEvents+). The stop/interrupt/stats
    # flags are plain booleans since I107 (the concurrency law, V4): a
    # GVL-atomic write is the whole cross-thread story — +stop!+ from a
    # foreign thread stays supported (the flag write + the +Async::Queue+
    # push are thread-safe). All other mutable state (@work_task, @tasks,
    # @animation_deadline, stats) is touched only by reactor fibers on the
    # main thread.
    class Loop
      WAKE = :wake # sentinel: unblock the idle loop (drain synthetic etc.)
      STOP = :stop # sentinel: exit the frame loop
      INTERRUPT = :interrupt # sentinel: the Signal.trap net

      # The scheduler-ready rider (Notification::Signal's mechanism — async
      # clone lib/async/notification.rb): the selector processes its ready
      # list by calling #transfer, which pushes the same queue.
      Wake = Struct.new(:queue, :token) do
        def alive? = true

        def transfer
          queue.push(token)
        end
      end
      private_constant :Wake

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
        # The I103 state-signal seam's wake queue (V1): a plain Thread::Queue
        # whose timed pop parks a reactor FIBER (a sibling timer runs during
        # the park) and blocks a plain thread — one park vocabulary at every
        # seat. Kept separate from @events: seam tokens must never surface
        # as dispatched events.
        @ready = Async::Queue.new
        @state_version = 0
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
              # I103 — the poller lifecycle's boot broadcast (the loop is
              # live; foreign stoppers await this instead of a delay bet).
              signal_state_change
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
              begin
                poller&.stop
              rescue PollerLingerError => e
                # I75: on the signal path the poller is wedged inside one
                # native call (Grounds F4) and is ABANDONED — the linger raise
                # must not mask the signal routing or it would skip the flush
                # tail (F5's mask). Off the signal path it still surfaces
                # (I02: a missed join must surface).
                raise unless contain_signal_path_error(e)
              end
              # I103 — the poller lifecycle's broadcast (teardown done).
              signal_state_change
            end
          end
        ensure
          Signal.trap("INT", previous_trap)
        end

        if @work_error
          # I75: on the signal path a draw/frame error (the dead tty's
          # Errno::EIO class, Grounds F8) is contained — logged, never
          # re-raised — or it would skip the flush tail exactly like the
          # unrouted-signal unwind did (F5). Off the signal path it raises
          # exactly as before (the standing surface).
          raise @work_error unless contain_signal_path_error(@work_error)
        end
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
            # I103 — the tick fire's broadcast (the block just ran).
            signal_state_change
            d = t0 + (i + 1) * period - now
            sleep d if d > 0
          end
        end
      end

      # Repeating redraw request on an absolute schedule (I58 — pi's Loader
      # interval, loader.ts:12/:82-99): fires {request_draw} every +interval+
      # seconds until the returned task is cancelled (+stop+, the same
      # Task#stop mechanism every reactor task answers to). The unbounded
      # form of {#every}: the busy duration is unknown up front, so a finite
      # tick count cannot express the busy window. Reactor context only.
      # The first fire lands one interval after the arm (setInterval
      # semantics — pi's Loader advances its frame on TIME and then
      # updateDisplay calls requestRender); arming state paints frame 0
      # itself ({request_draw} from the arming sink).
      def tick(interval)
        async do
          t0 = now
          n = 0
          loop do
            n += 1
            d = t0 + n * interval - now
            sleep d if d > 0
            request_draw
            # I103 — the tick fire's broadcast (the fire just landed).
            signal_state_change
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

      # @return [Boolean] whether shutdown was requested. Thread-safe — a
      #   plain GVL-atomic read; the poller thread polls this every frame.
      def stop_requested?
        @stop
      end

      # --- I103 state-signal seam (I107 V1 mechanics) ---------------------
      # The await-loop's version read + the test-only park, riding the V1
      # wake: a plain-Integer version (GVL-atomic reads; producers bump at
      # the same mutation funnels I103 froze) and a Thread::Queue timed-pop
      # park (parks a reactor FIBER; blocks a plain thread). The footprint
      # is these two methods, signal_state_change, and its call sites:
      # deleting them restores base behavior byte-for-byte (a ping with no
      # waiter is a no-op; production never waits).
      def state_version
        @state_version
      end

      # Parks until the version moves past from_version, belt-bounded (nil
      # on belt expiry with no change). Production never calls this.
      def wait_state_change(from_version, belt: 60)
        loop do
          return @state_version if @state_version > from_version

          return nil if @ready.pop(timeout: belt).nil?
        end
      end

      # The signal-path containment seam (I75): on the signal path (the
      # TUI.run bracket's SignalGuard has a recorded exit code) a teardown
      # error is CONTAINED — logged, one line, never re-raised, never
      # masking the recorded exit code — and this returns true. Off the
      # signal path it returns false and the caller re-raises (the standing
      # I02 surface is untouched).
      def contain_signal_path_error(error)
        return false unless signal_exit_pending?
        warn "tart: contained after signal: #{error.class}: #{error.message.to_s[0, 160]}"
        true
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
        @interrupted
      end

      # @return [Hash] run statistics (draws, event-driven wakes, interruption).
      # Thread-safe (I02 carry-in: readable from any thread — the counters
      # are plain GVL-atomic reads).
      def stats
        {draws: @draws, wakes: @wakes, interrupted: @interrupted}
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
        @interrupted = true
        signal_state_change
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

      # I103 — the state-signal broadcast (additive observability): the
      # tail of every observed mutation funnel (stat/draw accounting,
      # tick/every fires, the stop/interrupt flips, the poller teardown).
      # The V1 wake: bump the plain-Integer version, then ping BOTH paths
      # — the direct queue push (the proven cross-thread wake) and, when a
      # scheduler is present on the producer's thread, the scheduler-ready
      # rider whose #transfer pushes the same queue (Notification::Signal's
      # mechanism) — honoring the standing same-thread lost-wakeup claim.
      # A ping with no waiter is a no-op (tokens are idempotent: a stale
      # token only makes the version-loop re-check).
      def signal_state_change
        @state_version += 1
        @ready.push(:wake)
        Fiber.scheduler&.push(Wake.new(@ready, :wake))
        nil
      end

      # Wakes the frame loop with a sentinel (V5 — the disposable per-wake
      # spawn-and-join is gone): the V1 ping against the loop's
      # @events Async::Queue. The direct push is the proven cross-thread
      # path (the poller's, stop!'s); when a scheduler is present on the
      # producer's thread the scheduler-ready rider pushes the same
      # sentinel again (Notification::Signal's mechanism) — the
      # same-thread cross-fiber path the standing lost-wakeup claim names
      # (core/loop.rb's historical comment). Duplicate sentinel delivery
      # is safe: STOP/INTERRUPT/WAKE processing is idempotent, and signal
      # never carries a real event.
      def signal(item)
        @events << item
        Fiber.scheduler&.push(Wake.new(@events, item))
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
            # I103 — stat accounting's broadcast.
            signal_state_change
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

      # Sets the stop flag (a plain GVL-atomic write — stop! from a foreign
      # thread stays supported). The STOP sentinel that wakes the idle loop
      # is pushed by whoever asks for the stop.
      def request_stop
        @stop = true
        signal_state_change
      end

      # @return [Boolean] whether a signal exit is pending on this run's
      #   SignalGuard (nil-safe: a kernel run without a TUI.run bracket —
      #   unit/bench contexts — has no guard and no signal path).
      def signal_exit_pending?
        guard = defined?(Tart::TUI::SignalGuard) ? Tart::TUI::SignalGuard.active : nil
        guard&.signal_exit_pending? || false
      end

      def draw_frame
        return unless @dirty || animating?
        @dirty = false
        return unless @renderer
        rendered = @renderer.call
        @session.draw(rendered.is_a?(String) ? TUI.status_panel(rendered) : rendered)
        @draws += 1
        # I103 — draw accounting's broadcast (the frame landed).
        signal_state_change
      end

      # Installs the SIGINT trap net; returns the previous handler so run's
      # teardown can restore it. I75 ADDITIVE (the routing law): the active
      # SignalGuard (a TUI.run bracket armed it) wires its HUP/TERM routing
      # onto this loop's sentinel queue — the same push the INT net does
      # (trap-context push is the proven pattern; the signal's EINTR itself
      # wakes the parked scheduler). The guard owns the HUP/TERM traps and
      # their restore; SIGINT stays this loop's one authority, untouched.
      def install_trap_net
        guard = defined?(Tart::TUI::SignalGuard) ? Tart::TUI::SignalGuard.active : nil
        guard&.route(-> { @events << STOP })
        Signal.trap("INT") { @events << INTERRUPT }
      end

      def now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
