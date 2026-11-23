# frozen_string_literal: true

require_relative "test_helper"

module Tart
  # The image overlay (I112 — the erase/redraw ruling): the delta law
  # (static → ZERO bytes; any change → delete-all-placements + re-place),
  # the transmit-once-per-generation cache, the bottom-clip crop, the
  # iterm2 cached-sequence re-emit, the read-block reservation/fallback,
  # and the markdown passthrough anchor. Every byte assertion rides an
  # ImageOverlay called DIRECTLY (no pty, no wall-clock) or a headless
  # session's injected writer; the D3 law holds — no pin asserts
  # globally-named registry sizes, only per-row identity lookups.
  class ImageOverlayTest < Test
    # The canonical fixture header: a 720×480 PNG (the reservation at
    # panel width 20 is 18×6 cells).
    PNG_720X480 = "iVBORw0KGgoAAAANSUhEUgAAAtAAAAHgAAAAAA=="

    def setup
      @dir = Dir.mktmpdir("tart-imgoverlay-")
      @png = File.join(@dir, "image.png")
      File.binwrite(@png, PNG_720X480.unpack1("m"))
    end

    def teardown
      FileUtils.rm_rf(@dir)
    end

    # The tool-block anchor spec the read-block placement registers at
    # panel width 20 (content width 18 → 18×6 cells for 720×480).
    def anchor_spec
      { path: @png, mime_type: "image/png", bytes: File.size(@png),
        width_px: 720, height_px: 480, columns: 18, rows: 6, x_offset: Render::Panel::OUTPUT_PAD.length }
    end

    def blank_row(width, bg)
      Render::Panel.panel_blank_line(width, bg)
    end

    def registered_rows
      rows = [blank_row(20, nil), blank_row(20, nil), blank_row(20, nil)]
      ImageOverlay.record_anchor(rows[1], anchor_spec)
      rows
    end

    # --- the overlay delta ---

    def test_termimg_overlay_transmits_once_then_places_per_change
      with_images("kitty") do
        overlay = ImageOverlay.new
        rows = registered_rows
        first = overlay.emissions(rows, y0: 0, x0: 0, epoch: [40, 10])
        assert_equal "\e_Ga=d,d=a,q=2\e\\", first.split("\e[")[0], "the clear rides FIRST (pi :1734-1739)"
        assert_includes first, "\e[2;2H\e_Ga=T,f=100,q=2,C=1,c=18,r=6,i=", "CUP + the full transmission"
        assert_includes first, "iVBORw0KGgo", "the base64 payload rides"
        # The identical frame emits nothing.
        assert_equal "", overlay.emissions(rows, y0: 0, x0: 0, epoch: [40, 10])
        # TWO further changes: each re-places — the transmission never re-emits.
        scrolled = [rows[1], rows[2], blank_row(20, nil)]
        second_change = overlay.emissions(scrolled, y0: 0, x0: 0, epoch: [40, 10])
        assert_includes second_change, "a=p,q=2", "a placement-only re-place"
        refute_includes second_change, "a=T,", "the transmission never re-emits on change"
        third = overlay.emissions([rows[2], scrolled[0], scrolled[1]], y0: 0, x0: 0, epoch: [40, 10])
        assert_includes third, "a=p,q=2", "every change re-places"
        transmissions = [first, second_change, third].count { |bytes| bytes.include?("a=T,") }
        assert_equal 1, transmissions, "the base64 happens ONCE per content generation"
      end
    end

    def test_termimg_overlay_static_frame_emits_zero_bytes
      with_images("kitty") do
        overlay = ImageOverlay.new
        rows = registered_rows
        refute_equal "", overlay.emissions(rows, y0: 0, x0: 0, epoch: [40, 10])
        # Identity-, position-, geometry-, generation-stable → ZERO bytes.
        assert_equal "", overlay.emissions(rows, y0: 0, x0: 0, epoch: [40, 10]),
          "the identity-stable frame re-emits nothing"
        # A rebuilt frame (fresh registered rows — the expandable block's
        # rebuild identity) re-places but never re-transmits.
        rebuilt = [blank_row(20, nil), blank_row(20, nil), blank_row(20, nil)]
        ImageOverlay.record_anchor(rebuilt[1], anchor_spec)
        bytes = overlay.emissions(rebuilt, y0: 0, x0: 0, epoch: [40, 10])
        assert_includes bytes, "a=p,q=2", "the rebuilt identity re-places"
        refute_includes bytes, "a=T,", "…never re-transmits"
      end
    end

    def test_termimg_overlay_scroll_erases_and_replaces_at_new_y
      with_images("kitty") do
        overlay = ImageOverlay.new
        rows = registered_rows
        overlay.emissions(rows, y0: 0, x0: 0, epoch: [40, 10])
        assert_equal "", overlay.emissions(rows, y0: 0, x0: 0, epoch: [40, 10]),
          "the static frame between scroll steps"
        scrolled = [rows[1], rows[2], blank_row(20, nil)]
        bytes = overlay.emissions(scrolled, y0: 0, x0: 0, epoch: [40, 10])
        assert_match(/\A\e_Ga=d,d=a,q=2\e\\\e\[1;2H\e_Ga=p,q=2,C=1,c=18,r=6,i=\d+\e\\\z/, bytes,
          "the scroll transcript: delete ALL placements, then place at the NEW y (row 1)")
      end
    end

    def test_termimg_overlay_geometry_epoch_rebases_visible_set
      with_images("kitty") do
        overlay = ImageOverlay.new
        rows = registered_rows
        overlay.emissions(rows, y0: 0, x0: 0, epoch: [40, 10])
        assert_equal "", overlay.emissions(rows, y0: 0, x0: 0, epoch: [40, 10])
        bytes = overlay.emissions(rows, y0: 1, x0: 0, epoch: [40, 10])
        assert_includes bytes, "a=p,q=2", "the epoch change re-bases: every anchor re-emits"
        refute_includes bytes, "a=T,", "…but never re-transmits (the cache answers)"
        resized = overlay.emissions(rows, y0: 0, x0: 0, epoch: [60, 12])
        assert_includes resized, "\e[2;2H", "a width/height change re-bases the set too"
      end
    end

    def test_termimg_overlay_departed_anchor_leaves_silently
      with_images("kitty") do
        overlay = ImageOverlay.new
        rows = registered_rows
        overlay.emissions(rows, y0: 0, x0: 0, epoch: [40, 10])
        # The anchor's row left the window (scrolled off) — no delete
        # bytes, no error (Grounds §5's residual bound: the image data
        # stays uploaded; the placement is already gone with the row).
        bytes = overlay.emissions([rows[0], rows[2]], y0: 0, x0: 0, epoch: [40, 10])
        # The departed anchor contributes NO per-anchor bytes — the
        # frame's only content is the delta's clear (the visible set
        # changed; pi's imagesNeedRedraw arm emits the same), and no
        # delete_kitty_image rides (the uploaded data stays cached).
        assert_equal "\e_Ga=d,d=a,q=2\e\\", bytes, "the departed anchor leaves silently (clear only)"
        refute_includes bytes, "d=I", "no image-data deletion on a plain departure"
        # The now-empty frame is static.
        assert_equal "", overlay.emissions([rows[0], rows[2]], y0: 0, x0: 0, epoch: [40, 10])
      end
    end

    def test_termimg_overlay_bottom_clip_crops_kitty_placement
      with_images("kitty") do
        overlay = ImageOverlay.new
        # The anchor lands at y=4 after the scroll in an 8-row viewport:
        # visible rows = 4 of 6 → the crop letter: y=0,
        # h=ceil(480·4/6)=320, r=4.
        rows = [blank_row(20, nil), blank_row(20, nil), blank_row(20, nil), blank_row(20, nil),
          blank_row(20, nil), blank_row(20, nil), blank_row(20, nil), blank_row(20, nil)]
        ImageOverlay.record_anchor(rows[5], anchor_spec)
        overlay.emissions(rows, y0: 0, x0: 0, epoch: [40, 8])
        scrolled = rows[1..] + [blank_row(20, nil)]
        bytes = overlay.emissions(scrolled, y0: 0, x0: 0, epoch: [40, 8])
        placement = bytes[/\e_Ga=p[^\e]*\e\\/]
        assert_match(/\A\e_Ga=p,q=2,C=1,c=18,i=\d+,y=0,h=320,r=4\e\\\z/, placement,
          "the cropped placement letter (visible rows only)")
        refute_includes placement, "r=6", "the full row count never rides a clipped placement"
      end
    end

    def test_termimg_overlay_iterm2_reemits_cached_sequence
      jpeg = File.join(@dir, "image.jpg")
      File.binwrite(jpeg, "\xFF\xD8\xFF\xC0\x00\x11\x08\x00\x05\x00\x03\x00".b + "\xAA\xBB".b)
      with_images("iterm2") do
        overlay = ImageOverlay.new
        rows = [blank_row(20, nil), blank_row(20, nil), blank_row(20, nil)]
        spec = { path: jpeg, mime_type: "image/jpeg", bytes: File.size(jpeg),
          width_px: 3, height_px: 5, columns: 18, rows: 6, x_offset: 1 }
        ImageOverlay.record_anchor(rows[1], spec)
        first = overlay.emissions(rows, y0: 0, x0: 0, epoch: [40, 10])
        assert_includes first, "\e[2;2H\e]1337;File=inline=1;size=14;width=18;height=auto:",
          "the cached iterm2 sequence at (y, x)"
        assert_equal "", overlay.emissions(rows, y0: 0, x0: 0, epoch: [40, 10]), "static → zero"
        scrolled = [rows[1], rows[2], blank_row(20, nil)]
        again = overlay.emissions(scrolled, y0: 0, x0: 0, epoch: [40, 10])
        assert_includes again, "\e]1337;File=inline=1;size=14;width=18;height=auto:",
          "the SAME cached sequence re-emits at the new (y, x)"
        assert_equal 1, again.scan("inline=1").length, "no re-encode — one sequence per frame"
      end
    end

    def test_termimg_transmission_cache_reuses_content_generation
      with_images("kitty") do
        overlay = ImageOverlay.new
        rows = registered_rows
        first = overlay.emissions(rows, y0: 0, x0: 0, epoch: [40, 10])
        # Depart, then re-enter: the generation is CACHED — the re-entry
        # places without re-transmitting.
        departed = overlay.emissions([rows[0], rows[2]], y0: 0, x0: 0, epoch: [40, 10])
        assert_equal "\e_Ga=d,d=a,q=2\e\\", departed, "the departure frame rides the delta's clear only"
        returned = overlay.emissions(rows, y0: 0, x0: 0, epoch: [40, 10])
        assert_includes returned, "a=p,q=2", "re-entry re-places"
        refute_includes returned, "a=T,", "re-entry never re-transmits (the cache answers)"
        assert_equal 1, [first, returned].count { |bytes| bytes.include?("a=T,") }
      end
    end

    # --- the read-block placement ---

    def test_termimg_read_block_reserves_image_rows_when_capable
      with_images("kitty") do
        args = { "path" => @png }
        result = "Read image file [image/png]"
        details = { image: { mime_type: "image/png", bytes: File.size(@png), path: @png } }
        rows = Render::FileBlocks.read_block_rows(args, result, 20, expanded: false, details:)
        base = Render::FileBlocks.read_block_rows(args, result, 20, expanded: false)
        assert_equal base.length + 6, rows.length, "the reservation: 6 blank rows at width 20"
        # The image region rides between the result rows and the final pad.
        reserved = rows[(base.length - 1), 6]
        assert_equal [blank_row(20, Theme[:tool_success_bg])] * 6, reserved, "BLANK panel rows"
        spec = ImageOverlay.anchor_for(reserved.first)
        assert_equal anchor_spec, spec, "the FIRST reserved row is the anchor (spec + x offset + count)"
        assert_nil ImageOverlay.anchor_for(reserved[1]), "only the first row carries the anchor"
        # Both states reserve; the note stays in the expanded arm.
        expanded_base = Render::FileBlocks.read_block_rows(args, result, 20, expanded: true)
        expanded = Render::FileBlocks.read_block_rows(args, result, 20, expanded: true, details:)
        expanded_text = expanded.map { |row| row.spans.map(&:content).join }.join("\n")
        assert_includes expanded_text, "Read image file", "the text note stays (pi renders the note AND the image)"
        assert_includes expanded_text, "[image/png]"
        assert_equal expanded_base.length + 6, expanded.length,
          "the expanded arm reserves too (pi renders independently of the text cap)"
      end
    end

    def test_termimg_read_block_off_arm_bytes_held
      # The rail's force-off (no injection): the image details change
      # NOTHING — byte-identical to the absent-details shape, no
      # registration, in BOTH toggle states.
      args = { "path" => @png }
      result = "Read image file [image/png]"
      details = { image: { mime_type: "image/png", bytes: File.size(@png), path: @png } }
      [false, true].each do |expanded|
        with_details = Render::FileBlocks.read_block_rows(args, result, 20, expanded:, details:)
        without = Render::FileBlocks.read_block_rows(args, result, 20, expanded:)
        assert_equal without, with_details, "expanded=#{expanded}: the OFF arm is today's bytes"
        with_details.each { |row| assert_nil ImageOverlay.anchor_for(row), "no anchor registered" }
      end
    end

    def test_termimg_overlay_byte_cap_falls_back_to_fallback_row
      with_images("kitty") do
        args = { "path" => @png }
        result = "Read image file [image/png]"
        # Over the 8 MiB cap (D-CAP) → the fallback row, never a reservation.
        over = { image: { mime_type: "image/png", bytes: TerminalImages::INLINE_BYTE_CAP + 1, path: @png } }
        rows = Render::FileBlocks.read_block_rows(args, result, 60, expanded: false, details: over)
        base = Render::FileBlocks.read_block_rows(args, result, 60, expanded: false)
        assert_equal base.length + 1, rows.length, "ONE fallback row instead of the reservation"
        fallback = rows[(base.length - 1)]
        assert_includes fallback.spans.map(&:content).join, "[Image: ", "the fallback row shape"
        assert_nil ImageOverlay.anchor_for(fallback), "the fallback row never registers an anchor"
        # Kitty + non-PNG → the fallback row too (D-PNG-ONLY-KITTY).
        jpeg = File.join(@dir, "image.jpg")
        File.binwrite(jpeg, "\xFF\xD8\xFF\xC0\x00\x11\x08\x00\x05\x00\x03\x00".b + "\xAA\xBB".b)
        non_png = { image: { mime_type: "image/jpeg", bytes: File.size(jpeg), path: jpeg } }
        rows = Render::FileBlocks.read_block_rows({ "path" => jpeg }, result, 60, expanded: false, details: non_png)
        fallback = rows[(base.length - 1)]
        assert_includes fallback.spans.map(&:content).join, "[Image: ", "kitty + non-PNG → the fallback"
        refute_equal [blank_row(60, Theme[:tool_success_bg])], [fallback], "a rendered row, never a reservation"
      end
    end

    # --- the markdown passthrough ---

    def test_termimg_markdown_passthrough_rides_escape_line_unwrapped
      # A LONG escape (over any wrap width) proves the anchor row never
      # wraps: a rendered-text line would split; the carrier cannot.
      sequence = "\e_Ga=T,f=100,q=2,i=42;#{'B' * 5000}\e\\"
      text = "prose line\n#{sequence}\ntrailer"
      with_images("kitty") do
        rows = Render::Transcript.markdown_lines(text, 20)
        prose = rows.first
        assert_equal " ", prose.spans.first.content, "the prose rows keep the pad"
        anchor_row = rows.find { |row| ImageOverlay.anchor_for(row) }
        refute_nil anchor_row, "the escape line produced a registered anchor row"
        assert_equal "", anchor_row.spans.map(&:content).join, "the anchor row is zero-width"
        refute_equal sequence, anchor_row.spans.map(&:content).join, "the escape never lands as text"
        assert_equal({ sequence: sequence, rows: 1, x_offset: 0 }, ImageOverlay.anchor_for(anchor_row),
          "the produced Line registers (passthrough: ONE row, unpadded, x offset 0)")
        assert_nil ImageOverlay.anchor_for(prose), "the prose rows never register"
        # The wrap never splits it: the row passed Text.wrap_row UNCHANGED
        # (zero width ≤ any width — the fits arm; no text.rb change).
        assert_equal 1, anchor_row.spans.length, "one span, never re-grouped"
      end
      # OFF: byte-identical parse — a short escape renders as today's
      # text through the pad rule (and would wrap if over width).
      off_text = "prose line\n\e_Ga=T;AAAA\e\\\ntrailer"
      rows = Render::Transcript.markdown_lines(off_text, 20)
      off_anchor = rows.find { |row| row.spans.map(&:content).join.include?("\e_G") }
      refute_nil off_anchor, "OFF: the escape is ordinary text through the pad rule"
      assert_equal " \e_Ga=T;AAAA\e\\", off_anchor.spans.map(&:content).join
      rows.each { |row| assert_nil ImageOverlay.anchor_for(row) }
    end
  end
end
