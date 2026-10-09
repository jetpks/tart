# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/raspberry_pi"

module RaspberryPi
  # Shared base class for the minitest suite.
  class Test < Minitest::Test
    # Runs until the block is satisfied, then returns. Fails after 5 s
    # rather than hanging.
    def wait_until
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
      until yield
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          raise "work condition never satisfied"
        end
        sleep 0.005
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
      def initialize(poll_timeout: 0.005)
        @poll_timeout = poll_timeout
        @events = Queue.new
        @synthetic = Queue.new
        @drawn = []
        @draw_mutex = Mutex.new
      end

      def push_native(event)
        @events << event
      end

      def draw(widget)
        @draw_mutex.synchronize { @drawn << widget }
      end

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
    # sync?).
    KeyEvent = Struct.new(:code, :modifiers) do
      def key? = true
      def none? = false
      def sync? = false
      def ctrl? = modifiers.include?("ctrl")
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
