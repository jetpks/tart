# frozen_string_literal: true

require_relative "test_helper"

module Tart
  # The transmission module (I112 — pi terminal-image.ts's protocol
  # letter): the line predicate, the kitty encode/erase/placement letter,
  # the iterm2 letter, the bounded dimension sniffers, the cell geometry,
  # the bottom-clip crop arithmetic, and the fallback row. INLINE base64
  # literals only (the fixture tree stays byte-held); every blob here is
  # a minimal valid header, not a real image.
  class TerminalImagesTest < Test
    # The 3×5 PNG header (the canonical shape every pin shares): sig +
    # IHDR length 13 + "IHDR" + BE u32 3 + BE u32 5 + 4 CRC bytes.
    PNG_3X5 = "iVBORw0KGgoAAAANSUhEUgAAAAMAAAAFAAAAAA=="

    def setup
      @dir = Dir.mktmpdir("tart-termimg-")
    end

    def teardown
      FileUtils.rm_rf(@dir)
    end

    # --- the line predicate (pi isImageLine :207-219) ---

    def test_termimg_is_image_line_matches_kitty_and_iterm2_sequences
      kitty = "\e_Ga=T,f=100,q=2;AAAA\e\\"
      iterm2 = "\e]1337;File=inline=1;size=4;width=3;height=auto:AAAA\a"
      assert TerminalImages.image_escape_line?(kitty), "kitty at line start (fast path)"
      assert TerminalImages.image_escape_line?(iterm2), "iterm2 at line start (fast path)"
      assert TerminalImages.image_escape_line?("pre #{kitty} tail"), "kitty elsewhere (slow path)"
      assert TerminalImages.image_escape_line?("pre #{iterm2}"), "iterm2 elsewhere (slow path)"
      assert TerminalImages.image_escape_line?("\e[3A#{kitty}"), "multi-row cursor-up prefix"
      refute TerminalImages.image_escape_line?("plain text"), "no escape → false"
      refute TerminalImages.image_escape_line?(""), "empty → false"
      # OSC-8 / other escapes are NOT image lines.
      refute TerminalImages.image_escape_line?("\e]8;;https://x\e\\pi\e]8;;\e\\")
      refute TerminalImages.image_escape_line?("\e]52;c;AAAA\a")
    end

    # --- the kitty letter (pi encodeKitty :226-274) ---

    def test_termimg_encode_kitty_letter_params_and_chunking
      # Single chunk: a=T,f=100,q=2 + C=1 + c/r/i in pi's push order.
      assert_equal "\e_Ga=T,f=100,q=2,C=1,c=3,r=5,i=7;#{PNG_3X5}\e\\",
        TerminalImages.encode_kitty(PNG_3X5, columns: 3, rows: 5, image_id: 7),
        "the single-chunk transmission literal"
      # moveCursor true → no C=1 (pi pushes C=1 only when moveCursor === false).
      assert_equal "\e_Ga=T,f=100,q=2,c=3,r=5,i=7;#{PNG_3X5}\e\\",
        TerminalImages.encode_kitty(PNG_3X5, columns: 3, rows: 5, image_id: 7, move_cursor: true)
      # Absent options ride off (pi's truthy guards).
      assert_equal "\e_Ga=T,f=100,q=2,C=1;#{PNG_3X5}\e\\", TerminalImages.encode_kitty(PNG_3X5)
      # Chunking: 4096-char base64 → m=1 first, m=1 middle, m=0 last;
      # params ride the FIRST command only; each chunk is a full command.
      big = "A" * 9000
      encoded = TerminalImages.encode_kitty(big, columns: 3, rows: 5, image_id: 7)
      chunks = encoded.split("\e\\").reject(&:empty?)
      assert_equal 3, chunks.length, "9000/4096 → 3 chunks"
      assert_equal "\e_Ga=T,f=100,q=2,C=1,c=3,r=5,i=7,m=1;#{"A" * 4096}", chunks[0]
      assert_equal "\e_Gm=1;#{"A" * 4096}", chunks[1]
      assert_equal "\e_Gm=0;#{"A" * 808}", chunks[2], "the last chunk carries the 808 remainder"
      # Exactly one chunk over the boundary stays single-chunk.
      assert_equal "\e_Ga=T,f=100,q=2,C=1;#{"A" * 4096}\e\\", TerminalImages.encode_kitty("A" * 4096)
      assert_equal "\e_Ga=T,f=100,q=2,C=1,m=1;#{"A" * 4096}\e\\\e_Gm=0;A\e\\",
        TerminalImages.encode_kitty("A" * 4097), "4097 chars → two chunks"
    end

    # --- the erase commands + the placement letter (:276-291, :321-456) ---

    def test_termimg_kitty_erase_commands_image_placements_all
      assert_equal "\e_Ga=d,d=I,i=42,q=2\e\\", TerminalImages.delete_kitty_image(42)
      assert_equal "\e_Ga=d,d=A,q=2\e\\", TerminalImages.delete_all_kitty_images
      assert_equal "\e_Ga=d,d=a,q=2\e\\", TerminalImages.delete_all_kitty_placements

      # The placement-only letter over the registered metadata: controls
      # filtered to the placement key set (a/f/q/m die), a=p,q=2 composed
      # fresh, rows from the transmission's explicit r=.
      sequence = TerminalImages.encode_kitty(PNG_3X5, columns: 3, rows: 5, image_id: 424_242)
      TerminalImages.register_kitty_metadata(
        image_id: 424_242, columns: 3, rows: 5, width_px: 3, height_px: 5
      )
      placement = TerminalImages.kitty_placement(sequence)
      assert_equal "\e_Ga=p,q=2,C=1,c=3,r=5,i=424242\e\\", placement[:sequence],
        "the filtered-control placement literal"
      assert_equal 5, placement[:rows], "the covered row count rides the metadata"
      assert_equal 424_242, placement[:image_id]
      # No metadata → no placement (pi getKittyImagePlacement → undefined).
      assert_nil TerminalImages.kitty_placement("\e_Ga=T,f=100,q=2,i=9;AAAA\e\\")
      assert_nil TerminalImages.kitty_placement("plain text")
      # The registry is bounded (pi :349-357): 1001 registrations leave
      # 1000 entries, the OLDEST dropped (the fresh registration above
      # survives; the unique id space keeps sibling pins out of the way).
      1002.times do |n|
        TerminalImages.register_kitty_metadata(image_id: 9_000_000 + n, columns: 1, rows: 1,
          width_px: 1, height_px: 1)
      end
      assert_nil TerminalImages.kitty_placement("\e_Ga=T,f=100,q=2,i=424242;AAAA\e\\"),
        "the 1001st-oldest registration was dropped (insertion-order bound)"
    end

    # --- the iterm2 letter (pi encodeITerm2 :293-319 + image.ts:131-133) ---

    def test_termimg_encode_iterm2_file_letter_params
      # inline=1; size= the DECODED byte length (the 3×5 header is 28 raw
      # bytes); width; height=auto; BEL.
      assert_equal "\e]1337;File=inline=1;size=28;width=3;height=auto:#{PNG_3X5}\a",
        TerminalImages.encode_iterm2(PNG_3X5, columns: 3), "the iterm2 transmission literal"
      # size counts the DECODED bytes (pi Buffer.byteLength(b64, "base64")):
      # "aGVsbG8=" is 5 raw bytes.
      assert_equal "\e]1337;File=inline=1;size=5;width=3;height=auto:aGVsbG8=\a",
        TerminalImages.encode_iterm2("aGVsbG8=", columns: 3)
      # No columns → no width param (pi's defined check).
      assert_equal "\e]1337;File=inline=1;size=28;height=auto:#{PNG_3X5}\a",
        TerminalImages.encode_iterm2(PNG_3X5)
      # The optional name rides base64 (pi Buffer.from(name).toString("base64")).
      assert_equal "\e]1337;File=inline=1;size=28;width=3;height=auto;name=eC5wbmc=:#{PNG_3X5}\a",
        TerminalImages.encode_iterm2(PNG_3X5, columns: 3, name: "x.png")
    end

    # --- the dimension sniffers (pi :529-668; D-HEADER-READ) ---

    def test_termimg_dimensions_png_jpeg_gif_webp_sniffers
      path = File.join(@dir, "blob.bin")
      sniff = lambda do |b64, mime|
        File.binwrite(path, b64.unpack1("m"))
        TerminalImages.image_dimensions(path, mime)
      end
      assert_equal({ width_px: 3, height_px: 5 }, sniff.call(PNG_3X5, "image/png"), "PNG IHDR at 16/20")
      assert_equal({ width_px: 3, height_px: 5 }, sniff.call("R0lGODlhAwAFAAAAAA==", "image/gif"),
        "GIF87a/89a LE u16 at 6/8")
      assert_equal({ width_px: 3, height_px: 5 }, sniff.call("/9j/wAARCAAFAAMAqrs=", "image/jpeg"),
        "JPEG SOF0-2 marker scan, BE u16")
      assert_equal({ width_px: 3, height_px: 5 }, sniff.call("UklGRh4AAABXRUJQVlA4IAoAAAAAAAAAAAADAAUA", "image/webp"),
        "WebP VP8 lossy")
      assert_equal({ width_px: 3, height_px: 5 }, sniff.call("UklGRh4AAABXRUJQVlA4TAoAAAAvAgABAAAAAAAA", "image/webp"),
        "WebP VP8L lossless")
      assert_equal({ width_px: 3, height_px: 5 }, sniff.call("UklGRh4AAABXRUJQVlA4WAoAAAAAAAAAAgAABAAA", "image/webp"),
        "WebP VP8X extended")
      # bmp → nil (pi has no bmp sniffer); unknown mime → nil; corrupt
      # payloads → nil (never a raise).
      assert_nil sniff.call("Qk0AAAAAAAAAAAAAAAAAAAAAAAAAAA==", "image/bmp")
      assert_nil sniff.call(PNG_3X5, "image/x-unknown")
      assert_nil sniff.call("AAAA", "image/png")
      # The bounded read (D-HEADER-READ): a 200 KB file sniffs from its
      # header alone — the sniffer never reads the tail.
      File.binwrite(path, PNG_3X5.unpack1("m") + ("\xAA" * 200_000).b)
      assert_equal({ width_px: 3, height_px: 5 }, TerminalImages.image_dimensions(path, "image/png"))
      # A missing file → nil (never a raise).
      assert_nil TerminalImages.image_dimensions(File.join(@dir, "absent.bin"), "image/png")
    end

    # --- the cell geometry (pi :472-527; D-NO-CELL-QUERY) ---

    def test_termimg_calculate_cell_size_and_rows_letter
      # The 9×18 default (D-NO-CELL-QUERY) — no query anywhere.
      assert_equal({ width_px: 9, height_px: 18 }, TerminalImages.cell_dimensions)
      dims = { width_px: 720, height_px: 480 }
      assert_equal({ columns: 60, rows: 20 }, TerminalImages.calculate_cell_size(dims, 60),
        "width-bound scale letter: 0.75 → 540×360 px → 60×20 cells")
      assert_equal 20, TerminalImages.calculate_rows(dims, 60), "calculate_rows is the rows-only form"
      # A height bound caps the rows (pi's maxHeightCells arm).
      assert_equal({ columns: 7, rows: 10 }, TerminalImages.calculate_cell_size(
        { width_px: 30, height_px: 90 }, 10, max_height_cells: 10
      ))
      # The aspect pass (pi :472-479 + :502-517): the less-distorted
      # neighbor drops rows 8 → 7 for the 30×44 @ 10-wide shape.
      tall = { width_px: 30, height_px: 44 }
      assert_equal({ columns: 10, rows: 8 }, TerminalImages.calculate_cell_size(tall, 10))
      assert_equal({ columns: 10, rows: 7 }, TerminalImages.calculate_cell_size(tall, 10, optimize_aspect: true))
      # choose_less_distorted_cell_count's floor: 1 stays 1.
      assert_equal 1, TerminalImages.choose_less_distorted_cell_count(1, 0.5)
      # The injectable seam (module state, restored — the D3 law).
      previous = TerminalImages.cell_dimensions
      TerminalImages.cell_dimensions = { width_px: 18, height_px: 36 }
      assert_equal({ columns: 30, rows: 10 }, TerminalImages.calculate_cell_size(dims, 30))
    ensure
      TerminalImages.cell_dimensions = previous
    end

    # --- the bottom-clip crop arithmetic (pi cropKittyImageLine :458-470) ---

    def test_termimg_crop_visible_rows_arithmetic
      metadata = { rows: 5, height_px: 90 }
      # hidden = 0 (bottom-edge clip only): source_y 0,
      # source_end = ceil(90·3/5) = 54, h = 54, r = 3.
      assert_equal({ y: 0, h: 54, r: 3 }, TerminalImages.crop_placement_rows(metadata, 3))
      assert_equal({ y: 0, h: 18, r: 1 }, TerminalImages.crop_placement_rows(metadata, 1),
        "one visible row crops to its 18 px source band (90/5)")
      assert_nil TerminalImages.crop_placement_rows(metadata, 5), "no crop when all rows visible"
      assert_nil TerminalImages.crop_placement_rows(metadata, 7), "over-visible clamps to no crop"
      assert_nil TerminalImages.crop_placement_rows(metadata, 0), "nothing visible → nil"
    end

    # --- the fallback row (pi imageFallback :750-762) ---

    def test_termimg_fallback_row_bytes_and_link_when_capable
      with_images("kitty") do
        with_hyperlinks("0") do
          row = TerminalImages.fallback_row(
            { mime_type: "image/png", path: "/tmp/pics/x.png", dimensions: { width_px: 3, height_px: 5 } }, 60
          )
          assert_equal " [Image: /tmp/pics/x.png [image/png] 3x5]", row_text(row),
            "the fallback literal (no links): [Image: <path> [mime] WxH]"
          assert_nil row_href(row), "hyperlinks off → no OSC-8 span"
          # The ~/ contraction (pi shortenImagePath).
          home_row = TerminalImages.fallback_row(
            { mime_type: "image/png", path: File.join(Dir.home, "pics", "x.png"),
              dimensions: { width_px: 3, height_px: 5 } }, 40
          )
          assert_includes row_text(home_row), "~/pics/x.png", "the home prefix contracts to ~/"

          with_hyperlinks("1") do
            linked = TerminalImages.fallback_row(
              { mime_type: "image/png", path: "/tmp/pics/x.png", dimensions: { width_px: 3, height_px: 5 } }, 40
            )
            assert_equal "file:///tmp/pics/x.png", row_href(linked),
              "hyperlinks on + absolute path → the file:// OSC-8 span"
            # Relative path → the plain display (pi isAbsolute gate).
            relative = TerminalImages.fallback_row(
              { mime_type: "image/png", path: "pics/x.png" }, 40
            )
            assert_nil row_href(relative), "a relative path never links"
          end

          # Clipped to the row's width budget (pi truncateToWidth) — the
          # clip stops inside the mime span at the content width.
          clipped = TerminalImages.fallback_row(
            { mime_type: "image/png", path: "/tmp/pics/x.png", dimensions: { width_px: 3, height_px: 5 } }, 10
          )
          assert_equal " [Image: ", row_text(clipped), "the visible run stops at the content width"
          at_width = TerminalImages.fallback_row(
            { mime_type: "image/png", path: "/tmp/pics/x.png", dimensions: { width_px: 3, height_px: 5 } }, 40
          )
          assert_equal " [Image: /tmp/pics/x.png [image/png] 3x", row_text(at_width),
            "the WxH tail clips at the 38-cell content width (40 − both pads)"
          # Dims absent → the mime-only shape (D-FALLBACK-ONLY-CAPABLE).
          plain = TerminalImages.fallback_row({ mime_type: "image/gif", path: "/tmp/pics/x.gif" }, 40)
          assert_equal " [Image: /tmp/pics/x.gif [image/gif]]", row_text(plain)
        end
      end
    end

    private

    def row_text(row)
      row.spans.map(&:content).join
    end

    def row_href(row)
      row.spans.filter_map { |span| TUI::LinkOverlay.span_href(span) if span.respond_to?(:style) }.first
    end
  end
end
