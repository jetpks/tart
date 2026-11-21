# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/tart"

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

    # The deterministic event wait (I103): read the subject's state
    # version, evaluate the predicate OUTSIDE the object lock (the public
    # readers take it; MRI Mutexes are non-reentrant), on false park in
    # wait_state_change until the version moves, re-evaluate, repeat. Belt
    # expiry raises a loud assertion naming +what+. The subject is any
    # object carrying the state-signal seam (state_version /
    # wait_state_change) — a lib seamed surface or a Gate.
    #
    # cooperative: (REQUIRED at reactor-fiber call sites) — CV#wait parks
    # the THREAD, which would stall the whole reactor; the cooperative
    # variant re-checks the predicate after each cooperative yield
    # (async's Kernel#sleep patch) instead. On this same thread every
    # producer must run between yields, so a bounded cooperative re-check
    # after every suspension misses no event — the belt caps it purely as
    # the wedge guard. No clock lines either way.
    COOPERATIVE_STEP_S = 0.005

    def await(subject, what, belt: WEDGE_BELT_S, cooperative: false, &predicate)
      Test.await_event(subject, what, belt: belt, cooperative: cooperative, &predicate)
    end

    # The shared version-loop (the Gate's #await delegates here too).
    def self.await_event(subject, what, belt:, cooperative: false)
      unless subject.respond_to?(:state_version) && subject.respond_to?(:wait_state_change)
        raise ArgumentError,
              "await needs a state-signal subject (got #{subject.class} — seamed surface or Gate)"
      end

      if cooperative
        steps = [(belt / COOPERATIVE_STEP_S).round, 1].max
        steps.times do
          return if yield
          task = (defined?(Async) && Async::Task.current?)
          task ? task.sleep(COOPERATIVE_STEP_S) : sleep(COOPERATIVE_STEP_S)
        end
        return if yield
        raise Minitest::Assertion, "event never arrived: #{what} (belt #{belt}s expired)"
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
    # harness's own (the runner's jobs override; the e2e live-space gate).
    SEAT_SCRUB_EXEMPT = %w[TART_TEST_JOBS TART_E2E_SPACE].freeze

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
    # (I103): a double / support server / test-local callback array pings
    # at its mutation points; consumers await on predicates over its
    # state. Zero lib involvement.
    class Gate
      def initialize
        @mutex = Mutex.new
        @cv = ConditionVariable.new
        @version = 0
      end

      # Producer side: call at every mutation point of the observable
      # (any thread; trap-free).
      def ping
        @mutex.synchronize do
          @version += 1
          @cv.broadcast
        end
        nil
      end

      # The await-loop's version read (under the lock).
      def state_version
        @mutex.synchronize { @version }
      end

      # The consumer-side park: until the version moves past from_version,
      # belt-bounded — nil on belt expiry with no change.
      def wait_state_change(from_version, belt: WEDGE_BELT_S)
        @mutex.synchronize do
          until @version > from_version
            return nil unless @cv.wait(@mutex, belt)
          end
          @version
        end
      end

      # Consumer side: the version-loop over this gate's state.
      def await(what, belt: WEDGE_BELT_S, cooperative: false, &predicate)
        Test.await_event(self, what, belt: belt, cooperative: cooperative, &predicate)
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
        @events = Queue.new
        @synthetic = Queue.new
        @drawn = []
        @scrollback = []
        @draw_mutex = Mutex.new
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

      def push_native(event)
        @events << event
      end

      def draw(widget)
        @draw_mutex.synchronize { @drawn << widget }
        @draw_gate.ping
      end

      # Scrollback insertion (the chat surface's completed-content path);
      # recorded, not rendered, like draw. Lines inserted above the viewport,
      # in order (test assertions).
      def insert_before(height, widget)
        @draw_mutex.synchronize { @scrollback << [height, widget] }
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
        sleep(@poll_timeout)
        @events.empty? ? TUI_NONE : @events.pop
      end

      def push_event(event)
        @synthetic << event
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
