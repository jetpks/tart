# frozen_string_literal: true

require "weakref"

module Tart
  module TUI
    # The OSC-8 hyperlink overlay (I111, Grounds §1 ruling A): the buffer
    # renders link rows PLAIN — this class writes the OSC-8 wraps to the
    # session's writer AFTER +RatatuiRuby.draw+ returns (the osc52_copy
    # idiom). Per visible link entry, in (y, then x) order:
    #
    #   \e[{y};{x}H  + SGR(fg, modifiers)  + \e]8;;{url}\e\  + text
    #   + \e]8;;\e\  + \e[0m
    #
    # y/x are 1-based (CUP); the SGR codes are the same color-symbol
    # vocabulary the gem's flush presents (crossterm's backend: modifier
    # diff first, then the color — ratatui LightBlue presents as 38;5;12).
    # The visible text is CLIPPED to the row's remaining width (a post-edge
    # write would wrap onto the next row and clobber it).
    #
    # The delta (binding condition 1): entries are keyed on (row-object
    # identity, y); a frame emits exactly the entries whose key was not
    # emitted in the previous frame AT THIS GEOMETRY EPOCH — the epoch is
    # the session viewport's (width, height) and any change re-bases the
    # set (every visible link re-emits). Departing keys leave silently
    # (Grounds §5's residual bound). An identity-stable, geometry-stable
    # frame emits ZERO escapes even when the underlying buffer redrew.
    #
    # The carrier (PHASE 0 ruling, D1/D2): the gem's span objects are
    # frozen Data (no ivar channel exists) and the frozen
    # +Transcript.markdown_lines+ rebuild drops the converter's +href+
    # field before +TUI.markdown_line+ sees it — so the carrier is a
    # tart-only side-table channel the Rust render never reads: (a) the
    # converter registers (link child modifiers-array object → href);
    # (b) +TUI.markdown_line+ resolves href per source span (field first,
    # array-registry fallback) and records (produced span object → href);
    # (c) the overlay matches final-row spans by object identity. Both
    # registries are WeakRef-keyed and compacted synchronously at every
    # overlay evaluation — growth law: entries ≤ the link-bearing rows
    # still alive (the transcript holds them) plus dead-but-unGC'd renders
    # since the last GC; compaction cannot resurrect anything (identity
    # keys) and never holds a live object alive.
    class LinkOverlay
      # The WHATWG file-URL path set (RFC 3986 unreserved + the path's
      # sub-delims and ":" "@" "/" — everything else percent-encoded per
      # UTF-8 byte, the node pathToFileURL letter pi linkPath rides:
      # render-utils.ts:19-23 over paths.ts:103-107).
      FILE_URL_UNESCAPED = /\A[A-Za-z0-9\-._~!$&'()*+,;=:@\/]\z/

      # SGR modifier codes — the crossterm attribute values the gem's
      # flush presents (style.rs parse_modifier_str → Modifier).
      MODIFIER_CODES = {
        bold: 1, dim: 2, italic: 3, underlined: 4, slow_blink: 5,
        rapid_blink: 6, reversed: 7, hidden: 8, crossed_out: 9
      }.freeze

      # Named colors → the 256-color indexes the gem's flush presents
      # (ratatui Color FromStr → crossterm Colored Display, colored.rs —
      # LightBlue → crossterm Blue → "5;12").
      COLOR_CODES = {
        black: 0, red: 1, green: 2, yellow: 3, blue: 4, magenta: 5,
        cyan: 6, gray: 7, dark_gray: 8, light_red: 9, light_green: 10,
        light_yellow: 11, light_blue: 12, light_magenta: 13,
        light_cyan: 14, white: 15
      }.freeze

      # ── the file URL (the one hyperlink-seam URL helper) ──────────

      # @return [String] the +file://+ URL for +raw_path+ resolved
      #   absolute against +cwd+ (relative resolves, absolute passes
      #   through — pi resolvePath), percent-encoded per the WHATWG
      #   file-URL path letter (space → %20, non-ASCII UTF-8 bytes
      #   escaped, "/" and the path-safe punctuators kept).
      def self.file_url(raw_path, cwd:)
        path = File.expand_path(raw_path.to_s, cwd.to_s)
        encoded = path.b.bytes.map do |byte|
          char = byte.chr
          char =~ FILE_URL_UNESCAPED ? char : format("%%%02X", byte)
        end.join
        "file://#{encoded}"
      end

      # ── the carrier registries (render-time writes, overlay reads) ──

      # Records +href+ for the converter's link-child +modifiers+ array
      # (identity-keyed — every child span of one link shares it; nested
      # em/strong own fresh arrays, each registered). NO ALIASING: the
      # array is fresh per link subtree, so two links never resolve to
      # each other's href.
      def self.record_href_carrier(modifiers_array, href)
        return unless modifiers_array.is_a?(Array)

        @array_hrefs[WeakRef.new(modifiers_array)] = href
      end

      # @return [String, nil] the href registered for +modifiers+ by
      #   ARRAY OBJECT IDENTITY (value-equal arrays never match).
      def self.array_href(modifiers_array)
        return nil unless modifiers_array.is_a?(Array)

        lookup(@array_hrefs, modifiers_array)
      end

      # Records +href+ on the produced span object (identity-keyed).
      def self.record_span_href(span, href)
        @span_hrefs[WeakRef.new(span)] = href
      end

      # The span_row regrouping re-registers rebuilt fragments so a
      # wrapped link fragment keeps its href (Grounds §4's drop-today
      # fact): the rebuilt span rides the source's recorded href.
      def self.copy_span_href(source_span, rebuilt_span)
        href = lookup(@span_hrefs, source_span)
        record_span_href(rebuilt_span, href) if href
      end

      # @return [String, nil] the href recorded for +span+ by OBJECT
      #   IDENTITY (the href field wins at record time — the registries
      #   are never consulted for a field-carrying span).
      def self.span_href(span)
        lookup(@span_hrefs, span)
      end

      # Synchronous compaction (binding condition 3): drops entries whose
      # WeakRef target died. Called at EVERY overlay evaluation; GC
      # determines when targets die — compaction itself is deterministic
      # (alive-check + delete, no wall-clock).
      def self.compact!
        sweep(@array_hrefs)
        sweep(@span_hrefs)
      end

      # The prune pin's readback (binding condition 3): both registries'
      # live-entry counts. Test-facing only — the overlay itself never
      # consults sizes.
      def self.registry_depths
        { array: @array_hrefs.size, span: @span_hrefs.size }
      end

      # The registries are IDENTITY-keyed (compare_by_identity): WeakRef
      # delegates hash/== to its frozen-Data target, so value-equal spans
      # would otherwise collide into one entry and alias their hrefs.
      @array_hrefs = {}.compare_by_identity
      @span_hrefs = {}.compare_by_identity

      class << self
        private

        def lookup(registry, target)
          compact!
          registry.each do |ref, href|
            return href if alive?(ref, target)
          end
          nil
        end

        def alive?(ref, target)
          ref.weakref_alive? && ref.__getobj__.equal?(target)
        rescue ReferenceError
          false
        end

        # In-place sweep (the identity flag must survive compaction).
        def sweep(registry)
          registry.each_key do |ref|
            registry.delete(ref) unless ref.weakref_alive?
          end
          registry
        rescue StandardError
          registry
        end
      end

      # ── the per-session delta state ───────────────────────────────

      def initialize
        @last_epoch = nil
        @last_keys = []
      end

      # One visible link's emission: the delta key rides (+row+ identity,
      # +y+); +bytes+ freezes the D-SGR literal.
      Entry = Struct.new(:row, :y, :x, :href, :text, :sgr) do
        def bytes
          "\e[#{y + 1};#{x + 1}H#{sgr}\e]8;;#{href}\e\\" \
            "#{text}\e]8;;\e\\\e[0m"
        end
      end

      # @return [String] this frame's emission bytes ("" when the delta
      #   says so). +rows+ are the submitted final window rows (in
      #   order), +y0+/+x0+ the area's screen origin (0-based), +epoch+
      #   the session viewport's [width, height].
      def emissions(rows, y0:, x0:, epoch:)
        entries = compute(rows, y0, x0, epoch)
        keys = entries.map { |entry| [entry.row, entry.y] }
        fresh =
          if epoch != @last_epoch
            # Geometry change re-bases: every visible link re-emits.
            entries
          else
            entries.reject do |entry|
              @last_keys.any? { |(row, y)| row.equal?(entry.row) && y == entry.y }
            end
          end
        @last_epoch = epoch
        @last_keys = keys
        LinkOverlay.compact!
        fresh.sort_by { |entry| [entry.y, entry.x] }.map(&:bytes).join
      end

      private

      # Walks the rows in order: screen y = y0 + row index; x = x0 + the
      # cumulative TUI.text_width of the preceding spans. Every
      # href-carrying span (per the carrier) yields one entry whose text
      # is the span content clipped to the row's remaining width.
      def compute(rows, y0, x0, epoch)
        width = epoch[0]
        entries = []
        rows.each_with_index do |line, i|
          x = x0
          line.spans.each do |span|
            span_width = TUI.text_width(span.content)
            href = LinkOverlay.span_href(span)
            if href
              remaining = [width - (x - x0), 0].max
              entries << Entry.new(line, y0 + i, x, href,
                Render::Text.clip_text(span.content, remaining), sgr(span))
            end
            x += span_width
          end
        end
        entries
      end

      # The styled prefix — the gem's flush presentation for the same
      # style: one SGR per modifier (crossterm ModifierDiff order), then
      # the fg color (SetColors follows the modifier diff).
      def sgr(span)
        style = span.style
        codes = ((style&.modifiers || []).map do |modifier|
          code = MODIFIER_CODES[modifier]
          "\e[#{code}m" if code
        end.compact)
        code = fg_code(style&.fg)
        codes << code if code
        codes.join
      end

      def fg_code(fg)
        case fg
        when nil then nil
        when Symbol then (code = COLOR_CODES[fg]) && "\e[38;5;#{code}m"
        when Integer then "\e[38;5;#{fg}m" if fg >= 0 && fg <= 255
        when String
          if (hex = fg.delete_prefix("#")) =~ /\A\h{6}\z/
            channels = hex.scan(/../).map { |pair| pair.to_i(16) }
            "\e[38;2;#{channels.join(';')}m"
          end
        end
      end
    end
  end
end
