# frozen_string_literal: true

require "minitest/autorun"
require "async"
require_relative "../lib/tart"

# The capability rails (I111 + I112): the default-safe posture made
# ambient-proof — every non-injecting test renders the OFF arm regardless
# of the seat's terminal (the detection matrix never reads ambient env
# here; ||= keeps an explicit seat override usable). The image rail joins
# the hyperlink rail (the D4 law: both keys are SEAT_SCRUB_EXEMPT — the
# require-time seat scrub runs after these lines and would otherwise
# DELETE the force-off at every seat, the I111 integrate-fix mechanism).
ENV["TART_HYPERLINKS"] ||= "0"
ENV["TART_IMAGE_PROTOCOL"] ||= "none"

module Tart
  # Shared base class for the minitest suite.
  class Test < Minitest::Test
    # The wedge-guard belt (I103): a generous ceiling on every event wait —
    # a failure mode, never a synchronization mechanism. A passing test
    # never depends on it: the waiter wakes on the state-signal broadcast
    # whenever the event lands. Real-child families (subagents_e2e,
    # architect_loop live fire) pass belt: CHILD_BELT_S — a cold bundle-exec
    # child boot measured ~40 s under contention (I82).
    WEDGE_BELT_S = 60
    CHILD_BELT_S = 300

    # The deterministic event wait (I103, re-rooted onto the I107 V1 belt):
    # read the subject's state version, evaluate the predicate OUTSIDE the
    # subject, on false park in wait_state_change until the version moves,
    # re-evaluate, repeat. Belt expiry raises a loud assertion naming
    # +what+. The subject is any object carrying the state-signal seam
    # (state_version / wait_state_change) — a lib seamed surface or a Gate.
    # The park is fiber-safe by construction (a Thread::Queue timed pop
    # parks a reactor FIBER; a sibling timer runs during the park — probe
    # P1b), so the cooperative variant (and its step constant) are gone: no
    # call site needs a special park anymore. No clock lines.
    def await(subject, what, belt: WEDGE_BELT_S, &predicate)
      Test.await_event(subject, what, belt: belt, &predicate)
    end

    # The OSC-8 capability inject seam (I111): forces the +TART_HYPERLINKS+
    # arm for the block ("1"/"0"), drops the cached capability consult,
    # and restores both after — the ON-arm pins' only door (the detection
    # matrix and the tmux probe are never driven by ambient env here).
    def with_hyperlinks(value)
      previous = ENV["TART_HYPERLINKS"]
      ENV["TART_HYPERLINKS"] = value
      Capabilities.reset!
      yield
    ensure
      if previous.nil?
        ENV.delete("TART_HYPERLINKS")
      else
        ENV["TART_HYPERLINKS"] = previous
      end
      Capabilities.reset!
    end

    # The images-capability inject seam (I112, the with_hyperlinks
    # sibling): forces the +TART_IMAGE_PROTOCOL+ arm for the block
    # ("kitty"/"iterm2"/"none"), drops the cached capability consult,
    # and restores both after — the ON-arm pins' only door.
    def with_images(value)
      previous = ENV["TART_IMAGE_PROTOCOL"]
      ENV["TART_IMAGE_PROTOCOL"] = value
      Capabilities.reset!
      yield
    ensure
      if previous.nil?
        ENV.delete("TART_IMAGE_PROTOCOL")
      else
        ENV["TART_IMAGE_PROTOCOL"] = previous
      end
      Capabilities.reset!
    end

    # The shared version-loop (the Gate's #await delegates here too).
    def self.await_event(subject, what, belt:)
      unless subject.respond_to?(:state_version) && subject.respond_to?(:wait_state_change)
        raise ArgumentError,
              "await needs a state-signal subject (got #{subject.class} — seamed surface or Gate)"
      end

      loop do
        version = subject.state_version
        return if yield
        unless subject.wait_state_change(version, belt: belt)
          # The belt is a wedge guard: one final predicate re-check closes
          # a lost-broadcast race before the loud failure — only a
          # genuinely never-arriving event raises.
          return if yield

          raise Minitest::Assertion, "event never arrived: #{what} (belt #{belt}s expired)"
        end
      end
    end

    # The seat-hermeticity law (I104 lever e): the ambient TART_*
    # namespace (a live driver/subagent seat exports it) must never shape
    # a test boot — tests measure the thing under test, not the seat.
    # One require-time call at this file's bottom performs it, NOT a
    # base-class setup hook: minitest subclass `setup`s shadow the base
    # class's unless they call super (many suite files define their own),
    # so a setup hook would silently miss them — require time covers the
    # serial run AND every parallel worker by construction. The staged
    # fixtures win by construction afterward; the exempt keys are the
    # harness's own (the runner's jobs override; the e2e live-space gate)
    # — and the capability rail's force-off (line 11): the require-time
    # scrub runs AFTER the rail sets it, so without the exemption the
    # scrub deletes the force-off and ambient detection shapes every
    # non-injecting test (the I111 D4 seat-sensitivity, caught by the
    # driver's integrate-proof run at a herdr+tmux seat: 13 link pins
    # red; exempting makes the OFF arm deterministic at every seat).
    # (the I112 rail var joins by name — the D4 law: a non-exempt force-off
    # is deleted by the scrub below and ambient detection shapes every
    # non-injecting test at a herdr/tmux seat).
    SEAT_SCRUB_EXEMPT = %w[TART_TEST_JOBS TART_E2E_SPACE TART_HYPERLINKS TART_IMAGE_PROTOCOL].freeze

    # The pre-scrub snapshot (frozen {String => String}): exactly the
    # keys the last scrub_seat_env! deleted, so scrub/restore are exact
    # inverses. Re-seeded on every re-invocation (a frozen map cannot be
    # mutated; the pins re-invoke the scrub mid-suite).
    SEAT_TART_ENV = {}.freeze

    # Idempotent: snapshot the present non-exempt TART_ keys, delete
    # them, re-seed the frozen snapshot constant, return the snapshot.
    def self.scrub_seat_env!
      snapshot = (ENV.keys.grep(/\ATART_/) - SEAT_SCRUB_EXEMPT)
        .to_h { |key| [key, ENV[key]] }.freeze
      snapshot.each_key { |key| ENV.delete(key) }
      remove_const(:SEAT_TART_ENV) if const_defined?(:SEAT_TART_ENV, false)
      const_set(:SEAT_TART_ENV, snapshot)
      snapshot
    end

    # The reversible half of the pair: re-apply the snapshot. The suite
    # itself never needs it — test processes are disposable — but the
    # pair is the documented restore discipline the pins prove.
    def self.restore_seat_env!
      SEAT_TART_ENV.each { |key, value| ENV[key] = value }
      nil
    end

    # The test-owned observable's side of the state-signal mechanics
    # (I103, re-rooted onto the I107 V1 vocabulary): a double / support
    # server / test-local callback array pings at its mutation points;
    # consumers await on predicates over its state. Zero lib involvement.
    # The mechanics (OQ3, the frozen belt bridge): the version is a plain
    # Integer (GVL-atomic reads; a concurrent bump still moves the version,
    # which is all any consumer observes), the park is a Thread::Queue
    # timed pop (parks a reactor FIBER; blocks a plain thread — one park
    # vocabulary at every seat), and the ping is the dual-path wake: the
    # direct queue push (the proven cross-thread path) PLUS, when a
    # scheduler is present on the producer's thread, one scheduler-ready
    # rider whose #transfer pushes the same queue (Async::Notification
    # ::Signal's mechanism, async clone lib/async/notification.rb) — both
    # paths honor the standing same-thread lost-wakeup claim. Tokens are
    # idempotent: a stale token only makes the version-loop re-check.
    class Gate
      # The scheduler-ready rider: the selector processes its ready list by
      # calling #transfer (the Notification::Signal shape).

      def initialize
        @ready = ::Thread::Queue.new
        @version = 0
      end

      # Producer side: call at every mutation point of the observable
      # (any thread; trap context safe — no lock is ever taken, the I75
      # law; the belt-matrix probe drives this seat).
      def ping
        @version += 1
        @ready.push(:wake)
        Fiber.scheduler&.push(::Tart::Wake.new(@ready, :wake))
        nil
      end

      # The await-loop's version read.
      def state_version
        @version
      end

      # The consumer-side park: until the version moves past from_version,
      # belt-bounded — nil on belt expiry with no change. From a reactor
      # fiber the pop parks the FIBER (a sibling timer runs during the
      # park); from a plain thread it blocks the thread.
      def wait_state_change(from_version, belt: WEDGE_BELT_S)
        loop do
          return @version if @version > from_version

          return nil if @ready.pop(timeout: belt).nil?
        end
      end

      # Consumer side: the version-loop over this gate's state.
      def await(what, belt: WEDGE_BELT_S, &predicate)
        Test.await_event(self, what, belt: belt, &predicate)
      end
    end
    # A scripted session double at the TUI seam: lets kernel tests drive the
    # real poller thread + Async::Queue + frame loop headlessly, without any
    # ratatui_ruby involvement (real crossterm polls fail without a tty, and
    # the Rust ext's terminal/test-event state is thread-local).
    #
    # Yields +events+ (native events returned by poll_event, one per call)
    # and +synthetic+ (events drained by drain_synthetic) for scripting.
    class ScriptedSession
      attr_reader :events, :synthetic, :drawn

      # @param poll_timeout [Float] how long a blocking poll takes (models a
      #   real terminal's frame-budget block).
      # @param width [Integer] reported viewport width (the chat surface's
      #   wrap width in kernel tests).
      # @param height [Integer] reported viewport height (the chat surface's
      #   live-region row budget in kernel tests).
      def initialize(poll_timeout: 0.005, width: 80, height: 4)
        @poll_timeout = poll_timeout
        @width = width
        @height = height
        # The sanctioned Async::Queue seam (the poller bridge's double:
        # the frame loop's fibers pop; tests push from any seat).
        @events = Async::Queue.new
        @synthetic = Async::Queue.new
        @drawn = []
        @scrollback = []
        # The pipe-backed input seam (I109): the kernel's input producer
        # parks on THESE fds exactly like a real session's — kernel tests
        # drive native + synthetic events through the REAL input path, not
        # a bypass. The :tty fd wakes on push_native (the producer answers
        # with the non-blocking poll_event(0)); the :wake fd wakes on
        # push_event (the producer drains it and pushes the :wake sentinel
        # when synthetic events are pending).
        @native_pipe_r, @native_pipe_w = IO.pipe
        @wake_pipe_r, @wake_pipe_w = IO.pipe
        [@native_pipe_w, @wake_pipe_w].each { |w| w.sync = true }
        # draw/insert_before are same-reactor mutation points (the frame
        # loop's fibers; MRI fibers on one thread are cooperative) — no
        # draw mutex since I107 (the V4 collapse).
        # The drawn surface's Gate (I103): pinged at BOTH drawn-state
        # mutation points (draw + insert_before — one version covers the
        # session surface; a draw-only predicate merely re-checks on a
        # scrollback ping, harmlessly). The read-through below lets
        # await(session, …) ride the same vocabulary as the seamed lib
        # surfaces.
        @draw_gate = Gate.new
      end

      # The live viewport Rect double (the chat surface's wrap width).
      def viewport_area
        Rect.new(0, 0, @width, @height)
      end

      Rect = Struct.new(:x, :y, :width, :height)

      # The input-wait fds double (the Session contract, I109): both pipes
      # present at every seat of this double.
      # @return [Hash] <tt>{tty: Integer, wake: Integer}</tt>.
      def input_wait_fds
        {tty: @native_pipe_r.fileno, wake: @wake_pipe_r.fileno}
      end

      def push_native(event)
        @events << event
        # The wake byte on the pipe-backed :tty fd (the producer's selector
        # reports readiness; poll_event(0) pops the event).
        @native_pipe_w.write("\0")
      end

      def draw(widget)
        @drawn << widget
        @draw_gate.ping
      end

      # Scrollback insertion (the chat surface's completed-content path);
      # recorded, not rendered, like draw. Lines inserted above the viewport,
      # in order (test assertions).
      def insert_before(height, widget)
        @scrollback << [height, widget]
        @draw_gate.ping
      end

      # The drawn surface's state-signal read-through (I103): await(session,
      # …) waits on the draw/scrollback mutation events.
      def state_version
        @draw_gate.state_version
      end

      def wait_state_change(from_version, belt: WEDGE_BELT_S)
        @draw_gate.wait_state_change(from_version, belt: belt)
      end

      attr_reader :scrollback

      def poll_event(timeout:)
        # The timeout-0 form is the fd seam's ready-read (I109) — no modeled
        # sleep; a nonzero timeout keeps the modeled blocking-poll sleep
        # (the shape the poller used to drive).
        sleep(@poll_timeout) unless timeout.zero?
        @events.empty? ? TUI_NONE : @events.pop
      end

      def push_event(event)
        @synthetic << event
        # The wake byte on the pipe-backed :wake fd — the self-waking rail
        # (the producer pushes the :wake sentinel; the idle loop's in-loop
        # drain dispatches).
        @wake_pipe_w.write("\0")
      end

      def drain_synthetic
        count = 0
        until @synthetic.empty?
          yield @synthetic.pop
          count += 1
        end
        count
      end

      def synthetic_pending?
        !@synthetic.empty?
      end
    end

    # Minimal duck-typed event doubles for ScriptedSession scripts. The real
    # ratatui events answer the same predicate protocol (key?, ctrl?, code,
    # sync?, text?, paste?).
    KeyEvent = Struct.new(:code, :modifiers) do
      def key? = true
      def none? = false
      def sync? = false
      def paste? = false
      def text? = code.length == 1 && !ctrl?
      def ctrl? = modifiers.include?("ctrl")
    end
    PasteEvent = Struct.new(:content) do
      def key? = false
      def none? = false
      def sync? = false
      def paste? = true
      def text? = false
    end
    SyncEvent = Class.new do
      def key? = false
      def none? = false
      def sync? = true
    end
    NoneEvent = Class.new do
      def none? = true
      def key? = false
      def sync? = false
    end
    TUI_NONE = NoneEvent.new.freeze
  end
end

# The ONE require-time seat scrub (I104): every test process — the serial
# run, the runner's enumeration pass, every parallel worker — boots
# hermetic from ANY seat (the docstring on Tart::Test::SEAT_SCRUB_EXEMPT
# above carries the law and the why).
Tart::Test.scrub_seat_env!
