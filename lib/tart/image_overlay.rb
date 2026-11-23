# frozen_string_literal: true

require "weakref"

module Tart
  # The inline-image overlay (I112, Grounds §5 — the owner's erase/redraw
  # ruling, the I111 post-flush idiom's sibling): images NEVER live in the
  # scrollback buffer. The buffer renders image regions as BLANK reserved
  # rows; a render-time carrier (the anchor registry below) records
  # (produced Line → anchor spec); per frame, +Session#draw+ — AFTER
  # +RatatuiRuby.draw+ returns, through the SAME injectable writer as the
  # link overlay — walks the submitted window rows and emits the image
  # escapes. Per the delta law:
  #
  #   STATIC frame (the visible anchor set, the geometry epoch, and every
  #   content generation unchanged) → ZERO bytes.
  #   Any change → kitty: `delete_all_kitty_placements` FIRST, then per
  #   visible anchor in (y, x) order `\e[{y};{x}H` + the TRANSMISSION
  #   (first sighting of the content generation) or the PLACEMENT-ONLY
  #   command (cropped r/y/h at the bottom edge); iterm2: `\e[{y};{x}H` +
  #   the CACHED encoded sequence (no re-encode; erase is by construction
  #   — inline images are in-flow cells).
  #
  # The transmission cache is keyed on the anchor spec's content identity
  # ([path, bytes, mime]; a passthrough anchor keys on its raw sequence)
  # and bounded at 16 entries / 32 MiB transmission bytes / 64 MiB
  # estimated decoded bytes (pi tui-alt-screen.ts:78-80); eviction
  # (offscreen generations first) emits `delete_kitty_image(id)`. The
  # base64 happens ONCE per generation — never per frame. No wall-clock
  # anywhere; no Threads/Mutex/CV.
  class ImageOverlay
    # pi tui-alt-screen.ts:78-80 — the offscreen cache bounds.
    MAX_CACHED_TRANSMISSIONS = 16
    MAX_CACHED_TRANSMISSION_BYTES = 32 * 1024 * 1024
    MAX_CACHED_DECODED_BYTES = 64 * 1024 * 1024

    # ── the anchor registry (render-time writes, overlay reads; the
    # LinkOverlay carrier pattern — WeakRef identity keys, synchronous
    # compaction at every evaluation, growth bounded by the live rows) ──

    # Records +spec+ for the produced Line +row+ (identity-keyed). +spec+
    # is the anchor spec: the tool block's {path, mime_type, bytes,
    # width_px, height_px, columns, rows, x_offset} — or the passthrough's
    # {sequence, rows: 1, x_offset: 0}.
    def self.record_anchor(row, spec)
      return unless row

      @anchors[WeakRef.new(row)] = spec
    end

    # @return [Hash, nil] the anchor spec registered for +row+ by OBJECT
    #   IDENTITY (value-equal lines never match).
    def self.anchor_for(row)
      lookup(@anchors, row)
    end

    # Synchronous compaction (the I111 law): drops entries whose WeakRef
    # target died. Called at EVERY overlay evaluation.
    def self.compact!
      @anchors.each_key do |ref|
        @anchors.delete(ref) unless ref.weakref_alive?
      end
      @anchors
    rescue StandardError
      @anchors
    end

    # The pins' readback (test-facing only — the overlay never consults
    # sizes).
    def self.anchor_count
      compact!.size
    end

    # The registries are IDENTITY-keyed (compare_by_identity — WeakRef
    # delegates hash/== to its target, so value-equal lines would collide).
    @anchors = {}.compare_by_identity

    class << self
      private

      def lookup(registry, target)
        compact!
        registry.each do |ref, spec|
          return spec if ref.weakref_alive? && ref.__getobj__.equal?(target)
        rescue ReferenceError
          next
        end
        nil
      end
    end

    # ── the per-session delta state ─────────────────────────────────

    def initialize
      @last_epoch = nil
      @last_entries = []
      @cache = {}     # content identity → transmission entry (below)
      @generation = 0 # the session's transmission generation counter
    end

    # One frame's emission bytes ("" when the delta says static). +rows+
    # are the submitted final window rows (in order), +y0+/+x0+ the
    # transcript area's screen origin (0-based), +epoch+ the session
    # viewport's [width, height].
    def emissions(rows, y0:, x0:, epoch:)
      protocol = Capabilities.images?
      return "" unless protocol

      entries = compute_entries(rows, y0, x0, protocol)
      static = epoch == @last_epoch && same_visible?(entries)
      @last_epoch = epoch
      @last_entries = entries
      return "" if static

      bytes = +""
      bytes << TerminalImages.delete_all_kitty_placements if protocol == "kitty"
      bytes << evict_cache(entries.map(&:generation)) if protocol == "kitty"
      entries.sort_by { |entry| [entry.y, entry.x] }.each do |entry|
        bytes << entry.emit(protocol, epoch)
      end
      ImageOverlay.compact!
      bytes
    end

    private

    # One visible anchor: +row+ (the registered Line, by IDENTITY), +y+/
    # +x+ the 0-based screen position, +spec+ the anchor spec, +sequence+
    # the cached transmission, +fresh+ true when THIS frame transmitted it
    # (first sighting of the content generation).
    Entry = Struct.new(:row, :y, :x, :spec, :sequence, :fresh, :generation) do
      # CUP is 1-based.
      def cup
        "\e[#{y + 1};#{x + 1}H"
      end

      # kitty: the TRANSMISSION on first sighting of the content
      # generation (uncropped — the terminal clips the overflow; pi's own
      # path renders the transmission line unclipped), the PLACEMENT-ONLY
      # command otherwise — cropped r/y/h when the anchor's bottom edge
      # passes the viewport bottom (contract-2's crop arithmetic, visible
      # rows only). iterm2: the CACHED encoded sequence at (y, x) — no
      # re-encode, no crop (pi renders the full escape and lets the
      # terminal clip).
      def emit(protocol, epoch)
        return cup + sequence if protocol != "kitty" || fresh

        placement = TerminalImages.kitty_placement(sequence)
        body = if placement
          crop = TerminalImages.crop_placement_rows(spec, epoch[1] - y)
          crop ? cropped_placement(placement[:sequence], crop) : placement[:sequence]
        else
          # No registered metadata (a passthrough transmission): the raw
          # sequence re-emits (pi getKittyImagePlacement → undefined has
          # no placement letter).
          sequence
        end
        cup + body
      end

      # pi cropKittyImageLine's control rewrite: drop the source y/h/r
      # controls, push the cropped ones (the a=p,q=2 header re-composed).
      # The a=p sequence carries NO payload — its controls run to the ST
      # terminator (no `;` delimiter to stop at).
      def cropped_placement(sequence, crop)
        # The a=p header's own controls (a=, q=) are dropped — the header
        # re-composes them; the source y/h/r controls die with the crop.
        controls = sequence[/\e_G([^\e]*)\e\\/, 1].split(",").reject { |control| control =~ /\A(?:y|h|r|a|q)=/ }
        "\e_Ga=p,q=2,#{(controls + ["y=#{crop[:y]}", "h=#{crop[:h]}", "r=#{crop[:r]}"]).join(',')}\e\\"
      end
    end

    # The STATIC-frame verdict: same epoch and a positionally identical
    # visible set — row IDENTITY (equal?, never value equality —
    # LinkOverlay's law), plus (y, x, sequence-content generation).
    def same_visible?(entries)
      return false unless entries.length == @last_entries.length

      entries.each_with_index.all? do |entry, i|
        last = @last_entries[i]
        entry.row.equal?(last.row) && entry.y == last.y && entry.x == last.x &&
          entry.sequence.equal?(last.sequence)
      end
    end

    # Walks the rows in order: every registered row yields one entry at
    # y = y0 + index, x = x0 + the registered x offset (the tool block's
    # content pad; 0 for the passthrough).
    def compute_entries(rows, y0, x0, protocol)
      entries = []
      rows.each_with_index do |row, i|
        spec = ImageOverlay.anchor_for(row)
        next unless spec

        sequence, fresh, generation = cached_transmission(spec, protocol)
        entries << Entry.new(row, y0 + i, x0 + spec[:x_offset].to_i, spec, sequence, fresh, generation)
      end
      entries
    end

    # The transmission cache read/insert. First sighting of a content
    # identity ([path, bytes, mime]; the passthrough keys on its raw
    # sequence) reads the payload, base64s it ONCE, encodes the
    # transmission, and registers the kitty metadata; every re-sighting
    # rides the cache (the placement-only letter).
    def cached_transmission(spec, protocol)
      key = spec[:path] ? [spec[:path], spec[:bytes], spec[:mime_type]] : spec[:sequence]
      cached = @cache[key]
      return [cached[:sequence], false, cached[:generation]] if cached

      @generation += 1
      sequence = encode_transmission(spec, protocol)
      @cache[key] = {
        sequence: sequence, generation: @generation, image_id: sequence_image_id(sequence, protocol),
        transmission_bytes: sequence.bytesize,
        decoded_bytes: spec[:width_px].to_i * spec[:height_px].to_i * 4
      }
      [sequence, true, @generation]
    end

    def encode_transmission(spec, protocol)
      # The passthrough anchor: the raw escape line IS the transmission
      # (authored upstream; carried verbatim).
      return spec[:sequence] if spec[:sequence]

      data_b64 = [File.binread(spec[:path])].pack("m0")
      if protocol == "kitty"
        id = image_id
        sequence = TerminalImages.encode_kitty(data_b64, columns: spec[:columns], rows: spec[:rows],
          image_id: id, move_cursor: false)
        TerminalImages.register_kitty_metadata(image_id: id, columns: spec[:columns], rows: spec[:rows],
          width_px: spec[:width_px], height_px: spec[:height_px])
        sequence
      else
        TerminalImages.encode_iterm2(data_b64, columns: spec[:columns])
      end
    end

    # pi allocateImageId (:221-224): a random id in [1, 0xffffffff] —
    # collisions across module instances are the hazard it answers.
    def image_id
      rand(1..0xfffffffe)
    end

    # The cache entry's kitty image id — parsed back out of the cached
    # transmission (a passthrough transmission is id-less unless we
    # encoded it; the metadata registry keyed by `i=` answers).
    def sequence_image_id(sequence, protocol)
      return nil unless protocol == "kitty"

      sequence[/\e_G([^;]*);/, 1][/(?:\A|,)i=(\d+)(?:,|\z)/, 1]&.to_i
    end

    # The bounds law (16 / 32 MiB / 64 MiB, pi :78-80): offscreen
    # generations evict first (insertion order), then the oldest entries;
    # each eviction emits `delete_kitty_image(id)`.
    def evict_cache(visible_generations)
      deletions = +""
      while over_cache_bounds?
        victim_key = offscreen_key(visible_generations) || @cache.keys.first
        break unless victim_key

        entry = @cache.delete(victim_key)
        deletions << TerminalImages.delete_kitty_image(entry[:image_id]) if entry[:image_id]
      end
      deletions
    end

    def over_cache_bounds?
      @cache.size > MAX_CACHED_TRANSMISSIONS ||
        @cache.values.sum { |entry| entry[:transmission_bytes] } > MAX_CACHED_TRANSMISSION_BYTES ||
        @cache.values.sum { |entry| entry[:decoded_bytes] } > MAX_CACHED_DECODED_BYTES
    end

    def offscreen_key(visible_generations)
      @cache.keys.find do |key|
        !visible_generations.include?(@cache[key][:generation])
      end
    end
  end
end
