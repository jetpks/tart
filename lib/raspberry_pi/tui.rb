# frozen_string_literal: true

require "ratatui_ruby"

module RaspberryPi
  # The TUI interface module — the port's single seam to ratatui_ruby (BRIEF §2).
  #
  # Every `RatatuiRuby` call in the port lives here and nowhere else: the loop
  # kernel, tests, and the bench speak only this module's vocabulary
  # (sessions, events, widgets). Two acquisition paths:
  #
  # * real terminal — {TUI.run}, a thin wrapper over +RatatuiRuby.run+ whose
  #   ensure-based restore is the ISIG/raw-mode safety net (terminal restored
  #   even on raise);
  # * headless — {TUI.run} with +headless: true+ (test terminal via
  #   +init_test_terminal+, restored in ensure) for unit tests; the bench
  #   runs inside its own pty and uses the real path.
  module TUI
    # Raised when a session is acquired while one is already active.
    class SessionError < StandardError; end

    # A live terminal session. The loop kernel and the bench hold one of
    # these; tests may substitute any object answering the same three
    # instance methods (+draw+, +poll_event+, +push_event+).
    class Session
      # @return [Boolean] whether a real terminal session is active.
      def self.active?
        RatatuiRuby.terminal_active?
      end

      # Draws a widget tree to the terminal.
      def draw(widget)
        RatatuiRuby.draw(widget)
      end

      # Blocks up to +timeout+ seconds waiting for the next native event.
      # Returns an event object; +none?+ is true on timeout. Releases the GVL
      # while blocked (crossterm), which is what makes the poller-thread
      # design viable. In headless (test-terminal) sessions this returns
      # immediately with a None event.
      def poll_event(timeout:)
        RatatuiRuby.poll_event(timeout:)
      end

      # Pushes a synthetic event from any thread. Thread-safe (Mutex-guarded
      # queue inside ratatui_ruby); drained by the loop kernel each frame.
      # Deliberately NOT +inject_test_event+, whose queue is thread-local.
      def push_event(event)
        RatatuiRuby::SyntheticEvents.push(event)
      end

      # Drains every pending synthetic event, yielding each. Returns the
      # number of events drained.
      def drain_synthetic
        count = 0
        while RatatuiRuby::SyntheticEvents.pending?
          event = RatatuiRuby::SyntheticEvents.pop
          yield event
          count += 1
        end
        count
      end

      # Synthetic queue depth (used by tests to assert the drain).
      def synthetic_pending?
        RatatuiRuby::SyntheticEvents.pending?
      end

      # Symbol rendered at (+x+, +y+) in the terminal buffer — test/draw
      # assertions.
      def cell_symbol(x, y)
        RatatuiRuby.get_cell_at(x, y).symbol
      end
    end

    module_function

    # Acquires a terminal session and yields it, guaranteeing restore.
    #
    # @param headless [Boolean] use the headless test terminal (80x24) —
    #   for unit tests / bench scripts that are not on a real tty.
    # @param viewport [:fullscreen, :inline] real-terminal viewport.
    # @param height [Integer] height for an inline viewport.
    # @param focus_events [Boolean] enable focus gain/loss events.
    # @param bracketed_paste [Boolean] enable bracketed paste.
    # @yield [session]
    # @raise [SessionError] if a session is already active.
    #
    # The ensure-based restore is the ISIG/raw-mode safety net: whatever the
    # block does — including raising — the terminal is restored.
    def run(headless: false, viewport: :fullscreen, height: nil, focus_events: true, bracketed_paste: true)
      raise SessionError, "terminal session already active" if Session.active?

      session = Session.new
      if headless
        RatatuiRuby.init_test_terminal(80, 24, "fullscreen", nil)
        begin
          yield session
        ensure
          RatatuiRuby.restore_terminal
        end
      else
        RatatuiRuby.run(viewport:, height:, focus_events:, bracketed_paste:) do |_tui|
          yield session
        end
      end
    end

    # @return a minimal status widget: a Paragraph in a bordered Block.
    def status_panel(text)
      block = RatatuiRuby::Widgets::Block.new(title: "raspberry-pi", borders: [:all])
      RatatuiRuby::Widgets::Paragraph.new(text:, block:)
    end

    # @return [RatatuiRuby::Event::Key] a key event with the given code and
    #   modifiers (e.g. +key_event("c", modifiers: ["ctrl"])+ for Ctrl+C).
    def key_event(code, modifiers: [])
      RatatuiRuby::Event::Key.new(code:, modifiers:)
    end

    # @return [RatatuiRuby::Event::Sync] the synthetic sync event.
    def sync_event
      RatatuiRuby::Event::Sync.new
    end

    # @return [Boolean] whether +event+ is the Ctrl+C key event (byte 0x03 in
    #   raw mode arrives as an in-band Key event, never as SIGINT).
    def ctrl_c?(event)
      event.key? && event.ctrl? && event.code == "c"
    end
  end
end
