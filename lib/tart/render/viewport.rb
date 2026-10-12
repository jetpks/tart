# frozen_string_literal: true

require_relative "text"

module Tart
  module Render
    # The transcript scroll state machine (pi ScrollView): the viewport's
    # top-line offset over the buffer (follow-end semantics,
    # scroll-view.ts:127-135), the auto scrollbar's transient show — the
    # activity stamp + retiring epoch (markScrollbarActivity :97-110) —
    # and the right-rail paint (layout.ts paintScrollbar :307-330).
    # Content size and area geometry are threaded per call by the Chat
    # coordinator (wave 1/2 positional threading); the one-shot hide
    # timer's kernel arm lives in Chat (pi's timer lives on the host
    # reactor — {Chat.mark_scrollbar_activity} receives the epoch
    # {mark} returns). Unsynchronized by design (I22 shape rule a): the
    # Chat surface owns the mutex.
    class Viewport
      # The auto scrollbar's transient hide delay (pi scroll-view.ts:55
      # scrollbarHideDelayMs, default 1000 — AC2). Injectable so tests
      # never sleep real seconds.
      SCROLLBAR_HIDE_DELAY_MS = 1000

      # Wheel scroll (item 6, pi tui-alt-screen.ts): lines per event — the
      # library default (:271, `options.wheelScrollLines ?? 1`; the
      # app-level "auto" accelerator and its fullscreen-wheel-scroll-lines
      # settings knob are cut, itemized) — and the alt+wheel multiplier
      # (:79 ALT_WHEEL_SCROLL_MULTIPLIER = 5).
      WHEEL_LINES_PER_EVENT = 1
      ALT_WHEEL_MULTIPLIER = 5

      # Wheel direction → scroll delta (pi parseWheelEvent :705-723: wheel
      # up scrolls up).
      WHEEL_DIRECTION = {"scroll_up" => -1, "scroll_down" => 1}.freeze

      # @return [Integer] the viewport's top-line offset over the buffer
      #   (the Chat readback's and mouse mapping's target).
      attr_reader :offset

      # The auto scrollbar's hide delay in ms (pi scrollbarHideDelayMs,
      # scroll-view.ts:55) — the Chat test seam's delegate.
      def hide_delay_ms
        @hide_delay_ms || SCROLLBAR_HIDE_DELAY_MS
      end

      attr_writer :hide_delay_ms

      def initialize
        @offset = 0
        @follow = true
        # The auto scrollbar's transient state (pi scroll-view.ts:74-123):
        # the activity timestamp a user scroll marks (transientScrollbarVisible
        # — fresh while younger than the hide delay) and the epoch that
        # retires stale one-shot hide timers (pi clearTimeout).
        @scrollbar_activity_at = nil
        @scrollbar_timer_epoch = 0
        @hide_delay_ms = nil
      end

      # One wheel event: lines-per-event (alt+wheel 5×, pi :710) in the
      # event's direction (pi parseWheelEvent :705-723), routed into
      # {scroll_by} — the Chat coordinator threads the content size and
      # the area's row budget. Returns {scroll_by}'s epoch (see above).
      # The wheel is the transcript's ONLY user-scroll seam since I35:
      # the page keys page the editor (pi pageScroll — the I12
      # transcript mapping retired, Viewport#scroll_page with it).
      def wheel(event, content_size, rows)
        lines = WHEEL_LINES_PER_EVENT * (event.modifiers.include?("alt") ? ALT_WHEEL_MULTIPLIER : 1)
        scroll_by(WHEEL_DIRECTION.fetch(event.kind) * lines, content_size, rows)
      end

      # Whether +epoch+'s hide timer is retired (a newer mark superseded
      # it — the armed block's pi clearTimeout analog).
      def stale?(epoch)
        @scrollbar_timer_epoch != epoch
      end

      # The hide timer's fire op: drop the activity stamp (the next
      # render paints no rail).
      def hide_scrollbar
        @scrollbar_activity_at = nil
      end

      # Scrolls the transcript by +lines+ rows (pi ScrollView.scrollBy,
      # scroll-view.ts:127-135): any move away from the end detaches; the
      # render re-arms follow whenever the offset lands at the end (wheel
      # back down = re-arm; a wheel down while following clamps and stays
      # armed — pi's next === maxScrollTop rule). While following,
      # +@offset+ tracks the last rendered end, so the wheel moves
      # relative to it. A scroll that MOVED marks scrollbar activity (pi
      # scrollBy: `if (moved !== 0) markScrollbarActivity()` — a clamped
      # no-op marks nothing) and returns its epoch for the Chat
      # The render-time offset maintenance (pi updateLayout :180-200,
      # via the Chat coordinator's transcript widget): while following
      # the offset tracks the content end; a detached offset clamps and
      # re-arms follow when it lands at the end (followingEnd = followEnd
      # && next === maxScrollTop). The follow-end adjustment NEVER marks
      # scrollbar activity (pi updateLayout :180-192 — only the
      # user-scroll seams mark). Content fitting the area force-hides the
      # transient rail (pi updateLayout :200). Returns the visible
      # window slice.
      def window(lines, rows)
        max_offset = [lines.size - rows, 0].max
        @offset = @follow ? max_offset : @offset.clamp(0, max_offset)
        @follow = true if @offset == max_offset
        @scrollbar_activity_at = nil if lines.size <= rows
        lines[@offset, rows] || []
      end

      # pi scroll-view.ts isScrollbarVisible (:74-78): the auto rail
      # paints only while the content overflows AND scroll activity is
      # fresh (transientScrollbarVisible, younger than
      # scrollbarHideDelayMs) — a settled screen never shows it (AC2).
      def scrollbar_visible?(lines, rows)
        stamp = @scrollbar_activity_at
        return false if stamp.nil? || lines.size <= rows

        Process.clock_gettime(Process::CLOCK_MONOTONIC) - stamp < hide_delay_ms / 1000.0
      end

      # One rail row (pi paintScrollbar layout.ts:307-330 via
      # replaceScrollbarCell): the glyph REPLACES the last column's cell —
      # content clips at width−1, plain padding spaces carry it to the
      # rail column, the glyph keeps its theme fg (grafted from
      # {scrollbar_glyphs}' own span — scrollbarTrack/scrollbarThumb).
      # pi's hover-driven active thumb `█` (setScrollbarActive,
      # tui-alt-screen.ts:1057-1065) has no port seam and is unreachable
      # in the rig — cut, itemized; the at-rest `┃` is the reachable
      # subset.
      def overlay_rail_cell(line, glyph, width)
        head = Text.clip_spans(line.spans, width - 1)
        pad = width - 1 - head.sum { |span| TUI.text_width(span.content) }
        spans = pad.positive? ? [*head, TUI.span(" " * pad)] : head
        TUI.line([*spans, glyph.spans.first])
      end

      # The right-gutter scrollbar (pi layout.ts:307-330 paintScrollbar:
      # track "│" / thumb "┃"). pi's actual scrollbarTrack/scrollbarThumb
      # tokens (dark.json:28-29, blue-tinted) — promoted in the theme
      # table (I12 ruling 2 carry-in; the interim dim/muted routing
      # retired). Position: the current offset.
      def scrollbar_glyphs(total, rows)
        TUI.scrollbar_lines(content_length: total, position: @offset, viewport: rows,
          track_fg: Theme[:scrollbarTrack], thumb_fg: Theme[:scrollbarThumb])
      end

      # The /new + resume reset (pi renderCurrentSessionState's container
      # clear): the offset re-pins to the end.
      def reset
        @offset = 0
        @follow = true
      end

      private

      # Scrolls the transcript by +lines+ rows (pi ScrollView.scrollBy,
      # scroll-view.ts:127-135): any move away from the end detaches; the
      # render re-arms follow whenever the offset lands at the end (wheel
      # back down = re-arm; a wheel down while following clamps and stays
      # armed — pi's next === maxScrollTop rule). While following,
      # +@offset+ tracks the last rendered end, so the wheel moves
      # relative to it. A scroll that MOVED marks scrollbar activity (pi
      # scrollBy: `if (moved !== 0) markScrollbarActivity()` — a clamped
      # no-op marks nothing) and returns its epoch for the Chat
      # coordinator's kernel arm; a no-op returns nil.
      def scroll_by(lines, content_size, rows)
        max_offset = [content_size - rows, 0].max
        start = @follow ? max_offset : @offset # pi: followingEnd ? maxScrollTop : scrollTop
        previous = @offset
        @offset = [[start + lines, max_offset].min, 0].max
        @follow = false
        mark if @offset != previous
      end

      # The auto rail's transient show (pi ScrollView.markScrollbarActivity,
      # scroll-view.ts:97-110): a moved user scroll marks the activity
      # timestamp; a re-mark bumps the epoch so the stale timer no-ops (pi
      # clearTimeout + re-set). Returns the epoch — the Chat coordinator
      # arms the one-shot hide timer on the kernel (the host reactor
      # wiring — pi's timer lives on the host).
      def mark
        @scrollbar_activity_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @scrollbar_timer_epoch += 1
      end
    end
  end
end
