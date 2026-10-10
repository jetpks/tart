# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/tart"

module Tart
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
      end

      # Scrollback insertion (the chat surface's completed-content path);
      # recorded, not rendered, like draw. Lines inserted above the viewport,
      # in order (test assertions).
      def insert_before(height, widget)
        @draw_mutex.synchronize { @scrollback << [height, widget] }
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
