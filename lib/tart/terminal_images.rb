# frozen_string_literal: true

module Tart
  # The inline-image transmission module (I112, ENTRY 9): the protocol
  # letter of pi's terminal-image.ts, ported as pure functions + module
  # state. Grounds §2 — no transcoder (D-PNG-ONLY-KITTY: kitty transmits
  # PNG `f=100` only, iterm2 takes every ENTRY-1 mime inline), no
  # cell-size query (D-NO-CELL-QUERY: the 9×18 default is injectable), a
  # bounded 64 KiB sniffer read (D-HEADER-READ), and an 8 MiB inline
  # transmission cap (D-CAP) the callers gate on. The base64 of any
  # payload happens at most once per content generation (the overlay owns
  # that cache; this module never caches payloads). Stdlib only; no
  # Threads/Mutex/CV.
  module TerminalImages
    # D-CAP: the raw-byte cap on inline transmission — callers gate the
    # image region on it before any anchor is registered.
    INLINE_BYTE_CAP = 8 * 1024 * 1024

    # D-HEADER-READ: the dimension sniffers read at most this many bytes
    # (every pi sniffer decides within the first 30).
    HEADER_READ_BYTES = 64 * 1024

    # pi getCellDimensions' default (:41-48) — D-NO-CELL-QUERY keeps the
    # live `ESC[16t` query cut; the value is module state a caller (or a
    # pin) may set.
    DEFAULT_CELL_DIMENSIONS = { width_px: 9, height_px: 18 }.freeze

    # pi encodeKitty's CHUNK_SIZE (:230) — 4096-char base64 chunks.
    KITTY_CHUNK_SIZE = 4096

    # pi KITTY_PREFIX / ITERM2_PREFIX (:205-206).
    KITTY_PREFIX = "\e_G"
    ITERM2_PREFIX = "\e]1337;File="

    # pi KITTY_PLACEMENT_CONTROL_KEYS (:382-400) — the controls a
    # placement-only re-emit carries (note: `q`/`a`/`f`/`m` are NOT
    # members; the a=p,q=2 header is composed fresh).
    KITTY_PLACEMENT_CONTROL_KEYS = %w[i p x y w h X Y c r C U z P Q H V].freeze

    # pi registerKittyImageMetadata's bound (:349-357) — at most 1000
    # registered images, oldest (insertion order) dropped.
    METADATA_BOUND = 1000

    @cell_dimensions = DEFAULT_CELL_DIMENSIONS.dup
    @kitty_metadata = {}
    @kitty_transmission_generation = 0

    module_function

    # pi getCellDimensions/setCellDimensions (:41-48) — the module-state
    # seam; the default is the 9×18 constant above.
    def cell_dimensions
      @cell_dimensions
    end

    def cell_dimensions=(value)
      @cell_dimensions = value
    end

    # ── the line predicate ─────────────────────────────────────────

    # pi isImageLine (:207-219): the line starts with (fast path —
    # single-row images) or contains (slow path — multi-row images carry
    # a cursor-up prefix) a kitty or iterm2 escape opener.
    def image_escape_line?(line)
      line = line.to_s
      return true if line.start_with?(KITTY_PREFIX, ITERM2_PREFIX)

      line.include?(KITTY_PREFIX) || line.include?(ITERM2_PREFIX)
    end

    # ── the kitty letter ───────────────────────────────────────────

    # pi encodeKitty (:226-274): `a=T,f=100,q=2` + `C=1` (moveCursor false
    # — the image must not move the cursor) + `c=`/`r=`/`i=` when given;
    # payloads over the 4096-char chunk size ride `m=1` first/middle and
    # `m=0` last chunks, each a full `\e_G…\e\\` command; a single-chunk
    # payload rides ONE command (no `m=` at all).
    def encode_kitty(data_b64, columns: nil, rows: nil, image_id: nil, move_cursor: false)
      params = ["a=T", "f=100", "q=2"]
      params << "C=1" if move_cursor == false
      params << "c=#{columns}" if positive?(columns)
      params << "r=#{rows}" if positive?(rows)
      params << "i=#{image_id}" if positive?(image_id)

      return "\e_G#{params.join(',')};#{data_b64}\e\\" if data_b64.length <= KITTY_CHUNK_SIZE

      chunks = []
      offset = 0
      first = true
      while offset < data_b64.length
        chunk = data_b64[offset, KITTY_CHUNK_SIZE]
        last = offset + KITTY_CHUNK_SIZE >= data_b64.length
        if first
          chunks << "\e_G#{params.join(',')},m=1;#{chunk}\e\\"
          first = false
        elsif last
          chunks << "\e_Gm=0;#{chunk}\e\\"
        else
          chunks << "\e_Gm=1;#{chunk}\e\\"
        end
        offset += KITTY_CHUNK_SIZE
      end
      chunks.join
    end

    # pi deleteKittyImage (:276-281) — uppercase `d=I` also frees the
    # image data.
    def delete_kitty_image(image_id)
      "\e_Ga=d,d=I,i=#{image_id},q=2\e\\"
    end

    # pi deleteAllKittyImages (:283-287) — uppercase `d=A` frees every
    # uploaded image (the exit-cleanup command).
    def delete_all_kitty_images
      "\e_Ga=d,d=A,q=2\e\\"
    end

    # pi deleteAllKittyPlacements (:289-291) — lowercase `d=a` drops every
    # visible placement while RETAINING the uploaded data (the per-frame
    # erase; a re-place then needs no re-transmission).
    def delete_all_kitty_placements
      "\e_Ga=d,d=a,q=2\e\\"
    end

    # ── the iterm2 letter ──────────────────────────────────────────

    # pi encodeITerm2 (:293-319) over the Image component's call shape
    # (image.ts:131-133): `inline=1`, `size=` the DECODED byte length,
    # `width={columns}`, `height=auto`, optional base64 `name=`; the
    # terminator is BEL. (`preserveAspectRatio=0` is only composed when
    # explicitly disabled — pi's default true never emits it.)
    def encode_iterm2(data_b64, columns: nil, name: nil)
      params = ["inline=1", "size=#{decoded_byte_length(data_b64)}"]
      params << "width=#{columns}" unless columns.nil?
      params << "height=auto"
      params << "name=#{[name].pack('m0')}" if name
      "\e]1337;File=#{params.join(';')}:#{data_b64}\x07"
    end

    # ── the dimension sniffers (D-HEADER-READ: bounded reads) ──────

    # pi getImageDimensions (:670-688) dispatched over a BOUNDED header
    # read of the file at +path+. bmp → nil (pi has no bmp sniffer);
    # every failure → nil (the fallback row's shape).
    def image_dimensions(path, mime_type)
      buffer = File.binread(path.to_s, HEADER_READ_BYTES)
      return nil if buffer.nil?

      case mime_type
      when "image/png" then png_dimensions(buffer)
      when "image/jpeg" then jpeg_dimensions(buffer)
      when "image/gif" then gif_dimensions(buffer)
      when "image/webp" then webp_dimensions(buffer)
      end
    rescue StandardError
      nil
    end

    # pi getPngDimensions (:532-548): signature + IHDR's BE u32 at 16/20.
    def png_dimensions(buffer)
      return nil if buffer.bytesize < 24
      return nil unless png_signature?(buffer)

      { width_px: buffer.byteslice(16, 4).unpack1("N"), height_px: buffer.byteslice(20, 4).unpack1("N") }
    end

    # pi getJpegDimensions (:550-588): the 0xC0-0xC2 (SOF0-2) marker scan,
    # BE u16 height/width at marker+5/+7.
    def jpeg_dimensions(buffer)
      return nil if buffer.bytesize < 2
      return nil unless buffer.getbyte(0) == 0xff && buffer.getbyte(1) == 0xd8

      offset = 2
      while offset < buffer.bytesize - 9
        if buffer.getbyte(offset) != 0xff
          offset += 1
          next
        end

        marker = buffer.getbyte(offset + 1)
        if marker >= 0xc0 && marker <= 0xc2
          return { width_px: buffer.byteslice(offset + 7, 2).unpack1("n"),
                   height_px: buffer.byteslice(offset + 5, 2).unpack1("n") }
        end

        return nil if offset + 3 >= buffer.bytesize

        length = buffer.byteslice(offset + 2, 2).unpack1("n")
        # pi reads on without this floor (a length<2 segment would not
        # advance the offset); the bounded-read letter implies termination.
        return nil if length < 2

        offset += 2 + length
      end
      nil
    end

    # pi getGifDimensions (:590-608): GIF87a/89a signature, LE u16 at 6/8.
    def gif_dimensions(buffer)
      return nil if buffer.bytesize < 10

      signature = buffer.byteslice(0, 6)
      return nil unless signature == "GIF87a" || signature == "GIF89a"

      { width_px: buffer.byteslice(6, 2).unpack1("v"), height_px: buffer.byteslice(8, 2).unpack1("v") }
    end

    # pi getWebpDimensions (:610-668): RIFF/WEBP container, then the VP8 /
    # VP8L / VP8X chunk letters.
    def webp_dimensions(buffer)
      return nil if buffer.bytesize < 30
      return nil unless buffer.byteslice(0, 4) == "RIFF" && buffer.byteslice(8, 4) == "WEBP"

      chunk = buffer.byteslice(12, 4)
      if chunk == "VP8 "
        return { width_px: buffer.byteslice(26, 2).unpack1("v") & 0x3fff,
                 height_px: buffer.byteslice(28, 2).unpack1("v") & 0x3fff }
      elsif chunk == "VP8L"
        bits = buffer.byteslice(21, 4).unpack1("V")
        return { width_px: (bits & 0x3fff) + 1, height_px: ((bits >> 14) & 0x3fff) + 1 }
      elsif chunk == "VP8X"
        width = buffer.getbyte(24) | (buffer.getbyte(25) << 8) | (buffer.getbyte(26) << 16)
        height = buffer.getbyte(27) | (buffer.getbyte(28) << 8) | (buffer.getbyte(29) << 16)
        return { width_px: width + 1, height_px: height + 1 }
      end
      nil
    end

    # ── the cell geometry (D-NO-CELL-QUERY: injectable module state) ──

    # pi chooseLessDistortedCellCount (:472-479): pick upper vs lower
    # neighbor by the smaller max-ratio distortion to the ideal count.
    def choose_less_distorted_cell_count(upper_count, ideal_count)
      return upper_count if upper_count <= 1

      lower_count = upper_count - 1
      upper_distortion = [upper_count.fdiv(ideal_count), ideal_count.fdiv(upper_count)].max
      lower_distortion = [lower_count.fdiv(ideal_count), ideal_count.fdiv(lower_count)].max
      lower_distortion < upper_distortion ? lower_count : upper_count
    end

    # pi calculateImageCellSize (:481-519) EXACTLY: scale = min of the
    # width/height scales, columns/rows from the scaled pixel geometry,
    # then (when +optimize_aspect+) the less-distorted-neighbor pass.
    def calculate_cell_size(dims, max_width_cells, max_height_cells: nil, optimize_aspect: false)
      cell = cell_dimensions
      max_width = [1, max_width_cells.to_i].max
      max_height = max_height_cells.nil? ? nil : [1, max_height_cells.to_i].max
      image_width = [1, dims[:width_px].to_i].max
      image_height = [1, dims[:height_px].to_i].max

      width_scale = (max_width * cell[:width_px]).fdiv(image_width)
      height_scale = max_height.nil? ? width_scale : (max_height * cell[:height_px]).fdiv(image_height)
      scale = [width_scale, height_scale].min

      scaled_width_px = image_width * scale
      scaled_height_px = image_height * scale
      columns = [1, [max_width, (scaled_width_px / cell[:width_px]).ceil].min].max
      rows = [1, (scaled_height_px / cell[:height_px]).ceil].max
      rows = [max_height, rows].min unless max_height.nil?

      return { columns: columns, rows: rows } unless optimize_aspect

      if width_scale <= height_scale
        ideal_rows = (columns * cell[:width_px] * image_height).fdiv(image_width * cell[:height_px])
        rows = choose_less_distorted_cell_count(rows, ideal_rows)
      else
        ideal_columns = (rows * cell[:height_px] * image_width).fdiv(image_height * cell[:width_px])
        columns = choose_less_distorted_cell_count(columns, ideal_columns)
      end
      { columns: columns, rows: rows }
    end

    # pi calculateImageRows (:521-527) — the rows-only form (no height
    # bound, no aspect pass).
    def calculate_rows(dims, target_width_cells)
      calculate_cell_size(dims, target_width_cells)[:rows]
    end

    # ── the kitty metadata registry + placement letter ─────────────

    # pi registerKittyImageMetadata (:349-357): bump the transmission
    # generation, delete+set (insertion order = recency), bound at 1000
    # entries (the oldest dropped).
    def register_kitty_metadata(metadata)
      @kitty_transmission_generation += 1
      @kitty_metadata.delete(metadata[:image_id])
      @kitty_metadata[metadata[:image_id]] = metadata.merge(transmission_generation: @kitty_transmission_generation)
      @kitty_metadata.delete(@kitty_metadata.keys.first) if @kitty_metadata.size > METADATA_BOUND
      nil
    end

    # pi getKittyImagePlacement (:422-456) over the registered metadata:
    # the placement-only command `\e_Ga=p,q=2,{controls filtered to the
    # placement keys}\e\\` + the covered row count. +sequence+ is the
    # TRANSMISSION sequence as produced by {encode_kitty} (multi-chunk
    # payloads are walked to the real transmission end); nil when the
    # sequence is not a registered transmission.
    def kitty_placement(sequence)
      match = /\e_G([^;]*);/.match(sequence.to_s)
      return nil unless match

      metadata = registered_metadata_from_controls(match[1])
      return nil unless metadata

      command_start = match.begin(0)
      command_controls = match[1]
      transmission_end = nil
      loop do
        terminator = sequence.index("\e\\", command_start + KITTY_PREFIX.length)
        return nil unless terminator

        transmission_end = terminator + 2
        break unless chunked_command?(command_controls)

        command_start = transmission_end
        return nil unless sequence.byteslice(command_start, KITTY_PREFIX.length) == KITTY_PREFIX

        controls_end = sequence.index(";", command_start + KITTY_PREFIX.length)
        return nil unless controls_end

        command_controls = sequence[(command_start + KITTY_PREFIX.length)...controls_end]
      end

      controls = match[1].split(",").select do |control|
        KITTY_PLACEMENT_CONTROL_KEYS.include?(control.split("=", 2).first)
      end
      { sequence: "\e_Ga=p,q=2,#{controls.join(',')}\e\\",
        rows: explicit_rows_from_controls(match[1]) || metadata[:rows],
        image_id: metadata[:image_id] }
    end

    # pi cropKittyImageLine's arithmetic (:458-470), the tart clip letter:
    # the window clips at the BOTTOM edge only, so hidden = 0 —
    # `source_y = 0`, `source_end = ceil(height_px * visible / rows)`,
    # `h = max(1, min(height_px, source_end) - source_y)`, `r = visible`.
    # Returns {y:, h:, r:} for the placement's controls, or nil when no
    # crop applies (all rows visible — pi's early return).
    def crop_placement_rows(metadata, visible_rows)
      rows = metadata[:rows]
      height_px = metadata[:height_px]
      return nil if visible_rows.nil? || visible_rows <= 0 || !positive?(rows)

      cropped_rows = [visible_rows, rows].min
      return nil if cropped_rows == rows

      hidden = 0
      source_y = (height_px * hidden).fdiv(rows).floor
      source_end = (height_px * (hidden + cropped_rows)).fdiv(rows).ceil
      source_height = [1, [height_px, source_end].min - source_y].max
      { y: source_y, h: source_height, r: cropped_rows }
    end

    # ── the fallback row (D-FALLBACK-ONLY-CAPABLE: rendered only when
    # images are capable but the image is not transmittable) ─────────

    # pi imageFallback (:750-762): `[Image: {parts}]` — the `~/`-shortened
    # filename (an OSC-8 `file://` span via LinkOverlay.file_url when
    # hyperlinks are capable and the path is absolute — tool_path_href's
    # letter), `[mime]`, `WxH` when dimensions are known; the visible run
    # is clipped to the panel's content width (pi truncateToWidth,
    # image.ts:152-160). One row, toolOutput-fg, panel-bg'd when +bg+ is
    # given (the read block's box).
    def fallback_row(image_details, width, cwd: Dir.pwd, bg: nil)
      pad = Render::Panel::OUTPUT_PAD
      content_width = [width - pad.length * 2, 1].max
      spans = [Render::Markdown::Span.new(text: "[Image: ", fg: Theme[:tool_output], bg: bg)]
      path = image_details[:path]
      if path && !path.to_s.empty?
        display = shorten_home(path)
        if Capabilities.hyperlinks? && absolute_path?(path)
          spans << Render::Markdown::Span.new(text: display, fg: Theme[:tool_output], bg: bg,
            href: TUI::LinkOverlay.file_url(path, cwd: cwd))
        else
          spans << Render::Markdown::Span.new(text: display, fg: Theme[:tool_output], bg: bg)
        end
      end
      spans << Render::Markdown::Span.new(text: " [#{image_details[:mime_type]}]", fg: Theme[:tool_output], bg: bg)
      if (dims = image_details[:dimensions])
        spans << Render::Markdown::Span.new(text: " #{dims[:width_px]}x#{dims[:height_px]}",
          fg: Theme[:tool_output], bg: bg)
      end
      spans << Render::Markdown::Span.new(text: "]", fg: Theme[:tool_output], bg: bg)
      spans = clip_spans(spans, content_width)
      spans.compact!
      content_width = spans.sum { |span| TUI.text_width(span.text) }
      row = [Render::Markdown::Span.new(text: pad, bg: bg), *spans]
      # The bg tail rides as a Markdown::Span (the row goes through
      # TUI.markdown_line's duck-typed span map).
      row << Render::Markdown::Span.new(text: " " * [width - pad.length - content_width, 0].max, bg: bg) if bg
      TUI.markdown_line(row)
    end

    # ── internal ───────────────────────────────────────────────────

    def png_signature?(buffer)
      buffer.getbyte(0) == 0x89 && buffer.getbyte(1) == 0x50 &&
        buffer.getbyte(2) == 0x4e && buffer.getbyte(3) == 0x47
    end

    def chunked_command?(controls)
      /(?:\A|,)m=1(?:,|\z)/.match?(controls)
    end

    def registered_metadata_from_controls(controls)
      image_id = controls[/(?:\A|,)i=(\d+)(?:,|\z)/, 1]
      return nil if image_id.nil?

      @kitty_metadata[image_id.to_i]
    end

    def explicit_rows_from_controls(controls)
      rows = controls[/(?:\A|,)r=(\d+)(?:,|\z)/, 1]
      return nil if rows.nil?

      parsed = rows.to_i
      parsed.positive? ? parsed : nil
    end

    def positive?(value)
      value.respond_to?(:positive?) && value.positive?
    end

    # The DECODED byte length of a canonical (unwrapped, padded) base64
    # payload — pi Buffer.byteLength(base64Data, "base64") without the
    # full decode (the allocation-bounded letter).
    def decoded_byte_length(data_b64)
      pad = data_b64.end_with?("==") ? 2 : data_b64.end_with?("=") ? 1 : 0
      data_b64.length * 3 / 4 - pad
    end

    # pi shortenImagePath (:738-747): the home prefix contracts to `~/`.
    def shorten_home(path)
      path = path.to_s
      home = Dir.home.to_s
      return path if home.empty?
      return path unless path == home || path.start_with?("#{home}/")

      "~#{path[home.length..]}"
    end

    def absolute_path?(path)
      path.to_s.start_with?("/")
    end

    # pi truncateToWidth (image.ts:152-160) over the span run: the visible
    # run stops at +width+; the overflowing span is clipped, the rest die.
    def clip_spans(spans, width)
      out = []
      remaining = width
      spans.each do |span|
        break if remaining <= 0

        text_width = TUI.text_width(span.text)
        if text_width <= remaining
          out << span
          remaining -= text_width
        else
          out << span.class.new(text: Render::Text.clip_text(span.text, remaining), fg: span.fg,
            modifiers: span.modifiers, bg: span.bg, href: span.href)
          remaining = 0
        end
      end
      out
    end
  end
end
