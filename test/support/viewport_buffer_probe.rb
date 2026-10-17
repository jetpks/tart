# frozen_string_literal: true

# The bounded RatatuiRuby artifact probe (I66 F4 / AC3) — a STANDALONE
# script: rake does not load it (Rakefile's test glob is
# `test/**/*_test.rb`; nothing requires this file).
#
# It drives the rail-overlay case through the gem's own headless
# terminal API (`TUI.run(headless:)` → `RatatuiRuby.draw` →
# `RatatuiRuby.get_cell_at` reads) with the frozen 3-frame method:
#
#   frame 1 (settle): draw the row set — full-width panel-bg rows (the
#     Panel vocabulary), a plain no-bg row, a true-straddle row (a wide
#     grapheme occupying the last two cells); read the cells.
#   frame 2 (rail): the rows through the REAL
#     `Viewport#overlay_rail_cell` + `TUI.scrollbar_lines`; read.
#   frame 3 (fade): the ORIGINAL row set again; read.
#
#   artifact A (the inset/missing rail): reproduced iff on frame 2 any
#     row's rail glyph fails to paint at the last column OR any
#     overlaid line's composed width ≠ the area width.
#   artifact B (stuck dark after the fade): reproduced iff on frame 3
#     any NON-STRADDLE row's `cell_bg(W−1)` differs from FRAME 1's OWN
#     read of the same cell (never the nominal bg — the gem's wide-char
#     continuation cells read nil even pre-rail, measured).
#
# Discrimination (frozen): the drive is re-run with a MINIMAL gem-only
# composition (hand-built RatatuiRuby spans reproducing the same cell
# shapes — no Viewport/Text/Panel); the artifact persisting there homes
# it in ratatui_ruby (letter b), else in tart's composition (letter a);
# neither reproducing = not reproducible in-buffer (letter c).
#
# Output: the per-frame cell reads + `VIEWPORT_PROBE_OK <a|b|c>`, with
# exit 0 in EVERY outcome — the probe reports, never fails.
#
# Run: env -u HERDR_* bundle exec ruby test/support/viewport_buffer_probe.rb

require "tart"

W = 20                    # the area width (the frozen measured shape)
AREA_ROWS = 12            # the headless terminal height
ROW_COUNT = 8             # the probe's row set (overflows nothing — the
                          # overlay is driven directly, not through Chat)
STRADDLE_ROW = 5          # the row whose last two cells are the wide grapheme

module Tart
  module Support
    # The probe driver: one row set, one 3-frame read cycle, one artifact
    # verdict. Two drives run it — the real composition and the gem-only
    # mirror — and the letters compare them.
    class ViewportBufferProbe
      Result = Struct.new(:reads, :artifact_a, :artifact_b, keyword_init: true)

      attr_reader :report

      def initialize
        @report = []
      end

      # The tart-composition drive: the row set through the REAL
      # {Render::Viewport#overlay_rail_cell} + {TUI.scrollbar_lines}.
      def tart_drive
        rows = panel_rows
        rowset = build_rowset(rows)
        viewport = Render::Viewport.new
        glyphs = TUI.scrollbar_lines(content_length: ROW_COUNT, position: 2, viewport: ROW_COUNT,
          track_fg: Theme[:scrollbarTrack], thumb_fg: Theme[:scrollbarThumb])
        drive("tart composition (Viewport#overlay_rail_cell + TUI.scrollbar_lines)") do |frame|
          case frame
          when 1 then TUI.paragraph(text: rowset, wrap: false)
          when 2
            overlaid = rowset.each_with_index.map { |line, i| viewport.overlay_rail_cell(line, glyphs[i], W) }
            @overlaid = overlaid
            @expected_glyphs = glyphs.map { |g| g.spans.first.content }
            TUI.paragraph(text: overlaid, wrap: false)
          when 3 then TUI.paragraph(text: rowset, wrap: false)
          end
        end
      end

      # The gem-only drive: the same cell shapes, hand-built RatatuiRuby
      # spans — no Viewport, no Text, no Panel. The hand rail mirrors the
      # composed shapes the real overlay produces (head to width−1 with
      # the straddler replaced whole, the pad and the glyph carrying the
      # row's own bg provenance).
      def gem_drive
        bg = Theme[:tool_success_bg]
        track_fg = Theme[:scrollbarTrack]
        text_fg = Theme[:text]
        rowset = [
          TUI.line([TUI.span("g" * W, fg: text_fg, bg: bg)]),
          TUI.line([TUI.span("g" * W, fg: text_fg, bg: bg)]),
          TUI.line([TUI.span("g" * W, fg: text_fg, bg: bg)]),
          TUI.line([TUI.span("p" * W)]), # plain — no bg anywhere
          TUI.line([TUI.span("g" * W, fg: text_fg, bg: bg)]),
          TUI.line([TUI.span("s" * (W - 2), fg: text_fg, bg: bg), TUI.span("漢", fg: text_fg, bg: bg)]),
          TUI.line([TUI.span("g" * W, fg: text_fg, bg: bg)]),
          TUI.line([TUI.span("g" * W, fg: text_fg, bg: bg)]),
        ]
        glyph = "│"
        rail = rowset.map do |line|
          if line.spans.first.content.start_with?("p")
            [TUI.span("p" * (W - 1)), TUI.span(glyph, fg: track_fg)]
          elsif line.spans.last.content == "漢"
            [TUI.span("s" * (W - 2), fg: text_fg, bg: bg), TUI.span(" ", bg: bg), TUI.span(glyph, fg: track_fg, bg: bg)]
          else
            [TUI.span("g" * (W - 1), fg: text_fg, bg: bg), TUI.span(glyph, fg: track_fg, bg: bg)]
          end.then { |spans| TUI.line(spans) }
        end
        drive("gem-only composition (hand-built RatatuiRuby spans)") do |frame|
          case frame
          when 1 then TUI.paragraph(text: rowset, wrap: false)
          when 2
            @overlaid = rail
            @expected_glyphs = Array.new(ROW_COUNT, glyph)
            TUI.paragraph(text: rail, wrap: false)
          when 3 then TUI.paragraph(text: rowset, wrap: false)
          end
        end
      end

      # The verdict letter (frozen): a = reproduced, tart composition home;
      # b = reproduced, ratatui_ruby home; c = not reproducible in-buffer.
      def letter
        tart = tart_artifacts
        gem = gem_artifacts
        if tart[:a] || tart[:b]
          (gem[:a] || gem[:b]) ? "b" : "a"
        else
          "c"
        end
      end

      private

      def panel_rows
        bg = Theme[:tool_success_bg]
        [
          Render::Panel.padded_fg_rows("grep ok 0", W, fg: Theme[:toolTitle], bg: bg).first,
          Render::Panel.padded_fg_rows("grep ok 1", W, fg: Theme[:toolTitle], bg: bg).first,
          Render::Panel.padded_fg_rows("grep ok 2", W, fg: Theme[:toolTitle], bg: bg).first,
          TUI.line(" plain text no bg"), # the plain no-bg row
          Render::Panel.padded_fg_rows("grep ok 3", W, fg: Theme[:toolTitle], bg: bg).first,
          TUI.line([TUI.span(" " * (W - 2), bg: bg), # the true-straddle row
            TUI.span("漢", fg: Theme[:text], bg: bg)]),
          Render::Panel.padded_fg_rows("grep ok 4", W, fg: Theme[:toolTitle], bg: bg).first,
          Render::Panel.padded_fg_rows("grep ok 5", W, fg: Theme[:toolTitle], bg: bg).first,
        ]
      end

      def build_rowset(rows)
        # The row set: 8 rows — panel rows 0-2, plain 3, panel 4, the
        # straddler 5, panel 6-7.
        rows
      end

      # One 3-frame cycle through the gem's headless terminal. Reads the
      # cells per frame via RatatuiRuby.get_cell_at, prints them, and
      # classifies artifacts A/B against the frame-1 baseline.
      def drive(title)
        result = TUI.run(headless: true, viewport: :fullscreen, width: W, screen_height: AREA_ROWS) do |session|
          reads = {}
          baseline = nil
          1.upto(3) do |frame|
            session.draw(yield(frame))
            reads[frame] = (0...ROW_COUNT).map do |y|
              cell = RatatuiRuby.get_cell_at(W - 1, y)
              {symbol: cell.symbol, fg: cell.fg, bg: cell.bg}
            end
            baseline = reads[1].map { |r| r[:bg] } if frame == 1
          end

          say("== #{title} ==")
          reads.each do |frame, rows|
            say("frame #{frame} #{%w[settle rail fade][frame - 1]}: " + rows.each_with_index.map do |r, y|
              "row #{y}: sym=#{r[:symbol].inspect} fg=#{r[:fg].inspect} bg=#{r[:bg].inspect}"
            end.join(" | "))
          end

          # Artifact A (frame 2): a rail glyph missing at the last column
          # or any overlaid line's composed width ≠ the area width.
          width_offenders = (@overlaid || []).each_with_index.select do |line, _i|
            line.spans.sum { |span| TUI.text_width(span.content) } != W
          end.map(&:last)
          glyph_offenders = (@expected_glyphs || []).each_with_index.select do |glyph, i|
            reads[2][i][:symbol] != glyph
          end.map(&:last)
          artifact_a = width_offenders.any? || glyph_offenders.any?
          say("artifact A (inset/missing rail): " + (artifact_a ? \
            "REPRODUCED — width≠#{W} rows #{width_offenders.inspect}, glyph-not-at-#{W - 1} rows #{glyph_offenders.inspect}" : \
            "absent (every overlaid line composes exactly #{W} cells; every glyph paints at column #{W - 1})"))

          # Artifact B (frame 3): any NON-straddle row's bg at W−1 differs
          # from frame 1's OWN read of that cell (never the nominal bg —
          # the straddler's continuation cell reads nil even pre-rail).
          b_offenders = (0...ROW_COUNT).select do |y|
            next false if y == STRADDLE_ROW

            reads[3][y][:bg] != baseline[y]
          end
          artifact_b = b_offenders.any?
          say("artifact B (stuck dark after fade): " + (artifact_b ? \
            "REPRODUCED — rows #{b_offenders.inspect} (frame1 #{b_offenders.map { |y| baseline[y].inspect }.join(", ")} vs frame3 #{b_offenders.map { |y| reads[3][y][:bg].inspect }.join(", ")})" : \
            "absent (every non-straddle row's cell_bg(#{W - 1}) reads frame 1's own value)"))

          Result.new(reads:, artifact_a:, artifact_b:)
        end
        artifacts[result.object_id] = {a: result.artifact_a, b: result.artifact_b}
        result
      end

      def artifacts
        @artifacts ||= {}
      end

      def tart_artifacts
        artifacts.values.first || {a: true, b: true}
      end

      def gem_artifacts
        artifacts.values.last || {a: true, b: true}
      end

      def say(line)
        @report << line
        puts line
      end
    end
  end
end

probe = Tart::Support::ViewportBufferProbe.new
probe.tart_drive
probe.gem_drive
letter = probe.letter
puts "verdict: #{letter} " + {
  "a" => "(reproduced — tart's composition home)",
  "b" => "(reproduced — ratatui_ruby home)",
  "c" => "(not reproducible in-buffer)",
}[letter]
puts "VIEWPORT_PROBE_OK #{letter}"
exit 0