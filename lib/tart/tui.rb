# frozen_string_literal: true

require "ratatui_ruby"

module Tart
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
    # these; tests may substitute any object answering the same instance
    # methods (+draw+, +poll_event+, +push_event+, +drain_synthetic+,
    # +synthetic_pending?+, +cell_symbol+, +insert_before+,
    # +buffer_content+, +viewport_area+).
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

      # Foreground color of the cell at (+x+, +y+) — style assertions on the
      # headless test terminal. Named colors read back as symbols (+:red+,
      # +:light_blue+, +:dark_gray+), indexed as integers, RGB as
      # +"#rrggbb"+; nil when the cell carries the terminal default.
      def cell_fg(x, y)
        RatatuiRuby.get_cell_at(x, y).fg
      end

      # Background color of the cell at (+x+, +y+) — the bg readback for the
      # body-color spans (same readback vocabulary as {cell_fg}).
      def cell_bg(x, y)
        RatatuiRuby.get_cell_at(x, y).bg
      end

      # Modifiers of the cell at (+x+, +y+) — modifier-style assertions on
      # the headless test terminal (e.g. the input line's fake cursor reads
      # back as [:reversed]).
      def cell_modifiers(x, y)
        RatatuiRuby.get_cell_at(x, y).modifiers
      end

      # Inserts content above an inline viewport into scrollback (the chat
      # surface's completed-content path). Requires an inline viewport;
      # +height+ is the number of lines the widget renders. Follow with a
      # +draw+ — the insertion may clobber or scroll the viewport (gem doc).
      def insert_before(height, widget)
        RatatuiRuby.insert_before(height, widget)
      end

      # The full terminal buffer as one line per row — render assertions on
      # the headless test terminal.
      def buffer_content
        RatatuiRuby.get_buffer_content.split("\n")
      end

      # The live viewport Rect (width is the wrap width for the chat
      # surface); nil is never returned by the real session, but callers
      # duck-typed against test doubles should tolerate absence.
      def viewport_area
        RatatuiRuby.viewport_area
      end

      # Resizes the terminal to +width+×+height+ (the AC1 resize-redraw
      # proof on the headless test terminal; a no-op without a session).
      def resize(width, height)
        RatatuiRuby.resize_terminal(width, height)
      end
    end

    module_function

    # Acquires a terminal session and yields it, guaranteeing restore.
    #
    # @param headless [Boolean] use the headless test terminal — for unit
    #   tests / bench scripts that are not on a real tty. With +viewport:+
    #   the test terminal honors the same viewport types as the real path
    #   (verified 1.5.0: +init_test_terminal+ parses "inline" identically),
    #   so hermetic tests exercise the real inline/insert_before path.
    # @param width [Integer] headless test-terminal width (default 80).
    # @param screen_height [Integer] headless test-terminal height (default 24).
    # @param viewport [:fullscreen, :inline] viewport.
    # @param height [Integer] height for an inline viewport.
    # @param focus_events [Boolean] enable focus gain/loss events.
    # @param bracketed_paste [Boolean] enable bracketed paste.
    # @yield [session]
    # @raise [SessionError] if a session is already active.
    #
    # The ensure-based restore is the ISIG/raw-mode safety net: whatever the
    # block does — including raising — the terminal is restored.
    def run(headless: false, viewport: :fullscreen, height: nil, width: nil, screen_height: nil,
            focus_events: true, bracketed_paste: true)
      raise SessionError, "terminal session already active" if Session.active?

      session = Session.new
      if headless
        RatatuiRuby.init_test_terminal(width || 80, screen_height || 24, viewport.to_s, height)
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

    # @return [RatatuiRuby::Layout::Layout] one layout split: +children[i]+
    #   renders into the rect +constraints[i]+ carves (gem layout/layout.rb:44).
    #   The fullscreen chat surface's root is a vertical split — transcript /
    #   editor block / footer (pi chat-viewport.ts VStack root).
    def layout(children:, constraints:, direction: :vertical)
      RatatuiRuby::Layout::Layout.new(direction:, constraints:, children:)
    end

    # @return [RatatuiRuby::Layout::Constraint] exactly +n+ cells.
    def constraint_length(n)
      RatatuiRuby::Layout::Constraint.length(n)
    end

    # @return [RatatuiRuby::Layout::Constraint] at least +n+ cells, more if
    #   the split affords it (the transcript area's take-the-rest rule).
    def constraint_min(n)
      RatatuiRuby::Layout::Constraint.min(n)
    end

    # @return [Array<RatatuiRuby::Text::Line>] the transcript scrollbar's
    #   glyph run — one line per viewport row (pi layout.ts:285-330
    #   getScrollbarGeometry + paintScrollbar, ported exactly): a full-height
    #   track of "│" (+track_fg+) with the thumb "┃" (+thumb_fg+) sized
    #   max(min(2, track), min(track, round(track²/content))) and placed
    #   round(scrollTop/maxScrollTop · maxThumbTop). Verified against the
    #   gem's Widgets::Scrollbar (1.5.0, live) and rejected: it burns the
    #   first/last track rows on begin/end glyphs and computes a different
    #   thumb size — pi is the oracle.
    def scrollbar_lines(content_length:, position:, viewport:, track_fg:, thumb_fg:)
      content_length = [content_length, 1].max
      thumb = [[2, viewport].min, [viewport, (viewport * viewport.to_f / content_length).round].min].max
      max_scroll_top = [content_length - viewport, 0].max
      max_thumb_top = viewport - thumb
      thumb_top = max_scroll_top.zero? ? 0 : (position * max_thumb_top.to_f / max_scroll_top).round
      (0...viewport).map do |row|
        if row >= thumb_top && row < thumb_top + thumb
          line("┃", fg: thumb_fg)
        else
          line("│", fg: track_fg)
        end
      end
    end

    # @return [RatatuiRuby::Widgets::Block] a bordered container: +title+ on
    #   the top border (the editor area's status line, pi custom-editor.ts
    #   renderTopBorder), +border_style+/+title_style+ the border/title
    #   colors, +children+ the widgets rendered inside the borders.
    def block(title: nil, borders: [:all], border_style: nil, title_style: nil, children: [])
      RatatuiRuby::Widgets::Block.new(title:, borders:, border_style:, title_style:, children:)
    end

    # @return [Array<String>] the display lines of a drawn widget tree —
    #   the test/draw readback for composed layouts: a Paragraph yields its
    #   text rows (String or Lines), a Layout/Block yields its children's
    #   rows in order (a Block's title row is not display content).
    def widget_lines(widget)
      if widget.respond_to?(:text)
        text = widget.text
        text.is_a?(String) ? text.lines(chomp: true) : text.map { |line| line.spans.map(&:content).join }
      elsif widget.respond_to?(:children)
        widget.children.flat_map { |child| widget_lines(child) }
      else
        []
      end
    end

    # @return a minimal status widget: a Paragraph in a bordered Block.
    def status_panel(text)
      block = RatatuiRuby::Widgets::Block.new(title: "tart", borders: [:all])
      RatatuiRuby::Widgets::Paragraph.new(text:, block:)
    end

    # @return a Paragraph widget (the chat surface's live region / scrollback
    #   line builder). +text+ is a String (newlines are rows) or an array of
    #   Lines (one styled row each) built by {line}.
    def paragraph(text:, wrap: false)
      RatatuiRuby::Widgets::Paragraph.new(text:, wrap:)
    end

    # @return [RatatuiRuby::Style::Style] a style value (fg/bg colors +
    #   modifiers). Colors are symbol names or hex strings ("#rrggbb") —
    #   whichever the gem's Style accepts (style.rb:100-104; hex parses to
    #   Color::Rgb in ext style.rs:20-33).
    def style(fg: nil, bg: nil, modifiers: [])
      RatatuiRuby::Style::Style.new(fg:, bg:, modifiers:)
    end

    # @return [RatatuiRuby::Text::Span] one styled span — the seam's span
    #   vocabulary (fg/bg colors + modifiers, all optional; an unstyled
    #   span carries no Style value at all).
    def span(content, fg: nil, bg: nil, modifiers: [])
      styled = (fg || bg || modifiers.any?) ? style(fg:, bg:, modifiers:) : nil
      RatatuiRuby::Text::Span.new(content:, style: styled)
    end

    # @return [RatatuiRuby::Text::Line] one display line. +text+ is a String
    #   (a single span, optionally fg-colored — nil = the terminal default)
    #   or an array of {span} objects (multi-span rows: the input line's
    #   fake cursor, markdown styling).
    def line(text, fg: nil)
      spans = text.is_a?(String) ? [span(text, fg:)] : text
      RatatuiRuby::Text::Line.new(spans:)
    end

    # @return [RatatuiRuby::Text::Line] one display line built from a
    #   markdown-vocabulary row: an Array of duck-typed spans answering
    #   +text/+fg/+modifiers+ (Render::Markdown::Span's contract — +fg+ a
    #   color symbol or nil, +modifiers+ modifier symbols). An empty row is
    #   a blank line.
    def markdown_line(row)
      line(row.map { |s| span(s.text, fg: s.fg, modifiers: s.modifiers) })
    end

    # @return [Integer] the display width of +string+ in terminal cells
    #   (wrapping measurements; native, no terminal session required).
    def text_width(string)
      RatatuiRuby::Text.width(string)
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

    # @return [RatatuiRuby::Event::Paste] a bracketed-paste event (bracketed
    #   paste is enabled on init; the whole block arrives as one event).
    def paste_event(content)
      RatatuiRuby::Event::Paste.new(content:)
    end

    # @return [RatatuiRuby::Event::Mouse] a mouse event with the given kind
    #   ("down"/"up"/"drag"/"moved"/"scroll_up"/"scroll_down"), cell
    #   position, button and modifiers — the shape the real terminal's
    #   crossterm parse produces (gem ext events.rs:552-612; mouse capture
    #   is enabled on every real init — init.rs:67). The chat surface's
    #   wheel-scroll and selection tests drive events through the
    #   synthetic seam in exactly this shape.
    def mouse_event(kind:, x:, y:, button: "none", modifiers: [])
      RatatuiRuby::Event::Mouse.new(kind:, x:, y:, button:, modifiers:)
    end

    # Copies +text+ to the system clipboard with an OSC 52 write — pi
    # tui-alt-screen.ts copyTextToClipboard's fallback path (:1476-1487):
    # the base64 payload under bell-terminated OSC 52, buffer "c". The
    # host-injected native-clipboard write pi prefers (tui-renderer.ts:39-45)
    # is cut (no platform tooling seam — itemized deviation). Invisible to
    # the rendered buffer: straight to stdout, flushed so it cannot land
    # after the gem's terminal restore.
    def osc52_copy(text)
      $stdout.write("\e]52;c;#{[text].pack("m0")}\a")
      $stdout.flush
    end

    # @return [Boolean] whether +event+ is the Ctrl+C key event (byte 0x03 in
    #   raw mode arrives as an in-band Key event, never as SIGINT).
    def ctrl_c?(event)
      event.key? && event.ctrl? && event.code == "c"
    end

    # @return [Boolean] whether +event+ is the bare escape key (pi's
    #   app.interrupt binding, keybindings.ts:26 — the editor's onEscape
    #   path, custom-editor.ts:103-111).
    def escape?(event)
      # The gem's canonical code is "esc" (event/key/system.rb:36) — a
      # real tty never delivers "escape".
      event.key? && event.code == "esc" && !(event.modifiers & %w[ctrl alt]).any?
    end
  end
end
