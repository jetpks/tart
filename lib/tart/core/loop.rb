# frozen_string_literal: true

require "async"
require "io/wait"

module Tart
  module Core
    # The event-loop kernel (Design B, BRIEF §4/§4.1).
    #
    # One +Async+ reactor owns all reactor-side work — timers, socket/pipe
    # readers, the frame loop, and the input seam (I109): fiber tasks that
    # park on the session's exposed input-wait fds (IO#wait_readable —
    # io-event under the Async scheduler) and push onto the SAME
    # thread-safe +Async::Queue+ the poller thread used to bridge over.
    # Native input is read (poll_event(timeout: 0), the GVL-free call)
    # only when the selector reports readiness; synthetic events cross
    # threads via +SyntheticEvents.push+ (self-waking through the gem's
    # wake pipe) and are drained each frame in-loop.
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
    # main thread. With the poller thread retired (I109), ZERO threads are
    # spawned by lib/ — the census is SPAWN 0.
    class Loop
      WAKE = :wake # sentinel: unblock the idle loop (drain synthetic etc.)
      STOP = :stop # sentinel: exit the frame loop
      INTERRUPT = :interrupt # sentinel: the Signal.trap net

      # The scheduler-ready rider (Notification::Signal's mechanism — async
      # clone lib/async/notification.rb): the selector processes its ready
      # list by calling #transfer, which pushes the same queue.

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
      # or an event handler raises, the input seam's tasks are stopped with
      # the reactor's own Task#stop (no join, no linger class) and the SIGINT
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
              input_seam = InputSeam.new(@session, queue: @events)
              @input_seam = input_seam
              input_seam.start(root)
              # I103 — the input seam's boot broadcast (the loop is
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
              # work subtree, an event handler, the renderer — the input
              # seam's tasks are stopped (Task#stop; the reactor unwinds the
              # cancelled fibers before the Async block exits — no join, no
              # linger class, I109).
              request_stop
              @tasks.each(&:stop)
              @work_task&.stop
              supervisor&.stop
              input_seam&.stop
              # I103 — the input seam's teardown broadcast (teardown done).
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

      # The input seam (I109 — the poller thread's replacement): the
      # fd-driven input producer. Teardown assertions re-seat here
      # (+stopped?+ — no orphan producer after a raise).
      attr_reader :input_seam

      # @return [Boolean] whether shutdown was requested. Thread-safe — a
      #   plain GVL-atomic read; the stop! path from a foreign thread rides
      #   the STOP sentinel on the queue.
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
      # tick/every fires, the stop/interrupt flips, the input seam's boot
      # and teardown).
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
        Fiber.scheduler&.push(::Tart::Wake.new(@ready, :wake))
        nil
      end

      # Wakes the frame loop with a sentinel (V5 — the disposable per-wake
      # spawn-and-join is gone): the V1 ping against the loop's
      # @events Async::Queue. The direct push is the proven cross-thread
      # path (the input seam's, stop!'s); when a scheduler is present on the
      # producer's thread the scheduler-ready rider pushes the same
      # sentinel again (Notification::Signal's mechanism) — the
      # same-thread cross-fiber path the standing lost-wakeup claim names
      # (core/loop.rb's historical comment). Duplicate sentinel delivery
      # is safe: STOP/INTERRUPT/WAKE processing is idempotent, and signal
      # never carries a real event.
      def signal(item)
        @events << item
        Fiber.scheduler&.push(::Tart::Wake.new(@events, item))
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

    # The fd-driven input producer (I109 — the poller Thread's replacement,
    # the concurrency law's final exemption retired with it): reactor tasks
    # that park on the session's exposed input-wait fds via IO#wait_readable
    # (io-event under the Async scheduler — the park is the reactor's own,
    # no thread) and push onto the SAME @events queue the poller bridged
    # over. The wake fd drains its byte(s) and pushes the :wake sentinel
    # when synthetic events are pending (the poller's rail, preserved); the
    # tty fd runs the non-blocking ready-read (poll_event(timeout: 0) — the
    # GVL-free call, invoked ONLY when the selector reports readiness). The
    # exposed fds are never read except the wake fd's byte drain. A session
    # that exposes no fds (headless/test mode) no-ops: there is NO polling
    # timer — the idle loop stays parked on @events.
    class InputSeam
      # @param session [#input_wait_fds, #poll_event, #synthetic_pending?]
      #   the TUI session (non-exposing doubles keep working unchanged —
      #   the fd probe answers respond_to?(:input_wait_fds)).
      # @param queue [Async::Queue] the kernel's event queue (the poller's
      #   seam, preserved).
      def initialize(session, queue:)
        @session = session
        @queue = queue
        @tasks = []
        @stopped = false
        @wake_ios = {}
      end

      # Spawns one producer task per exposed fd on the reactor.
      # @param reactor [Async::Task] the kernel's root task.
      def start(reactor)
        fds = @session.respond_to?(:input_wait_fds) ? @session.input_wait_fds : {}
        @tasks << reactor.async { await_wake(fds.fetch(:wake)) } if fds.key?(:wake)
        @tasks << reactor.async { await_tty(fds.fetch(:tty)) } if fds.key?(:tty)
        nil
      end

      # Stops the producer tasks (Task#stop — the reactor's own cancel
      # mechanism; no join, no linger class). +stopped?+ is the teardown
      # observable: true the moment stop returns, and the tasks are dead
      # once the reactor unwinds (Loop#run's ensure runs inside the Async
      # block, so nothing outlives the run).
      def stop
        @stopped = true
        @tasks.each(&:stop)
        @tasks.clear
        nil
      end

      # @return [Boolean] whether the seam is stopped (the I02 orphan
      #   assertions re-seat here).
      def stopped?
        @stopped
      end

      private

      # The wake-fd producer: parks until the fd is readable (a synthetic
      # push or a SIGWINCH wrote a wake byte), drains the byte(s) (never
      # blocks — the pipe is non-blocking), then — I109 ruling 3 (F1) —
      # runs ONE non-blocking ready-read BEFORE the sentinel decision: a
      # WINCH's Resize is queued by crossterm on its OWN internal signal
      # pipe (not among the awaited fds), and the wake byte is the only
      # readiness surface the seam gets for it — without this read the
      # resize would sit until a later keystroke (measured 2.8 s or never;
      # the poller's 16 ms cadence is the parity bar this restores). The
      # fork's signal-handler chain writes crossterm's pipe and ours in the
      # same delivery, so the queued Resize is visible to this read. A
      # synthetic push rides the same read harmlessly (an empty native
      # queue returns None). Then the unchanged sentinel: :wake only when
      # synthetic events are pending (the poller's rail, preserved).
      # Async::Cancel unwinds through wait_readable at teardown (Task#stop)
      # — deliberately never rescued.
      def await_wake(fd)
        io = wake_io(fd)
        until stopped?
          io.wait_readable
          drain_wake(io)
          break if stopped?
          event = @session.poll_event(timeout: 0)
          @queue << event unless event.none?
          @queue << Loop::WAKE if @session.respond_to?(:synthetic_pending?) && @session.synthetic_pending?
        end
      end

      # The tty-fd producer: parks until input is readable on the tty, then
      # drains crossterm's ready events UNTIL none return, pushing each
      # returned event, and only then re-parks on the fd. The drain-to-None
      # is load-bearing (measured, the s19 prompt-burst defect): crossterm's
      # read consumes up to 1024 bytes of the SHARED device queue per poll,
      # so a keystroke burst lands in crossterm's USERSPACE parser while the
      # exposed tty fd goes quiet (the device queue is empty) — a single
      # ready-read per park would strand the backlog until the NEXT device
      # byte (the rig's prompt typed zero dispatches; the poller's 16 ms
      # cadence is what drained the parser at base). Events still arriving
      # during the drain keep it running; None (the parser drained) re-parks
      # — no hot-spin, the park is still wait_readable. A dead/EOF'd tty
      # surfaces as a RETURNING wait (EOF/HUP makes the fd readable), never
      # a wedge — the I75 wedge class dies structurally (there is no
      # blocking native wait anywhere on this path). Async::Cancel unwinds
      # through wait_readable at teardown (Task#stop) — never rescued.
      def await_tty(fd)
        io = IO.for_fd(fd, autoclose: false)
        until stopped?
          io.wait_readable
          break if stopped?
          loop do
            event = @session.poll_event(timeout: 0)
            break if event.none?

            @queue << event
          end
        end
      end

      def wake_io(fd)
        @wake_ios[fd] ||= IO.for_fd(fd, autoclose: false)
      end

      # Read-drains every buffered byte (read_nonblock never blocks; the
      # EOF/error tails are structural no-ops — the fd stays open).
      def drain_wake(io)
        loop do
          chunk = io.read_nonblock(4096, exception: false)
          break if chunk.nil? || chunk == :wait_readable
        end
      rescue EOFError, Errno::EIO, IOError
        nil
      end
    end
  end
end
