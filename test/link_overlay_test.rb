# frozen_string_literal: true

require_relative "test_helper"

module Tart
  # The OSC-8 overlay (I111 — Grounds §1 ruling A): the emission bytes,
  # the (row identity, y) delta, the geometry epoch, wrapped fragments,
  # the two-link positions, the row-width clip, the file-URL letter, and
  # the tool-path href carrier. Every emission pin asserts COMPUTATION AND
  # BYTES against the pure overlay API — no pty, no wall-clock.
  class LinkOverlayTest < Test
    S = Render::Markdown::Span

    # A fresh overlay per frame-scenario (each pin controls its delta
    # state explicitly; the session-owned instance is the production
    # shape — tui_test pins the draw path).
    def fresh_overlay
      TUI::LinkOverlay.new
    end

    def link_line(prefix, text, url, fg: :light_blue, modifiers: [:underlined])
      TUI.markdown_line([S.new(text: prefix), S.new(text: text, fg: fg, modifiers: modifiers, href: url)])
    end

    # The frozen D-SGR byte shape: CUP, the SGR the gem's flush presents
    # for :light_blue + :underlined (38;5;12 after the 4m modifier —
    # crossterm presents LightBlue as indexed 12), the OSC-8 wrap, the
    # visible text, the close, the reset.
    def test_osc8_overlay_emits_exact_bytes_for_entering_link_row
      line = link_line("see ", "pi", "https://pi.dev")
      bytes = fresh_overlay.emissions([line], y0: 0, x0: 0, epoch: [80, 24])
      assert_equal "\e[1;5H\e[4m\e[38;5;12m\e]8;;https://pi.dev\e\\pi\e]8;;\e\\\e[0m", bytes,
        "x=5 (\"see \" is 4 cells), y=1; the exact cursor+SGR+OSC literal"
    end

    # Binding condition 1: an identity-stable, geometry-stable frame
    # emits ZERO escapes even when the buffer redrew underneath.
    def test_osc8_overlay_static_frame_emits_zero_bytes
      overlay = fresh_overlay
      line = link_line("see ", "pi", "https://pi.dev")
      overlay.emissions([line], y0: 0, x0: 0, epoch: [80, 24])
      assert_equal "", overlay.emissions([line], y0: 0, x0: 0, epoch: [80, 24]),
        "the same row object at the same y re-emits nothing"
    end

    # A row that MOVES (the same object at a new y — scroll) re-emits at
    # its new position; the departed y leaves silently.
    def test_osc8_overlay_row_move_reemits_at_new_y
      overlay = fresh_overlay
      pad = TUI.line("pad")
      line = link_line("see ", "pi", "https://pi.dev")
      overlay.emissions([pad, line], y0: 0, x0: 0, epoch: [80, 24])
      moved = overlay.emissions([line], y0: 0, x0: 0, epoch: [80, 24])
      assert_equal "\e[1;5H\e[4m\e[38;5;12m\e]8;;https://pi.dev\e\\pi\e]8;;\e\\\e[0m", moved,
        "the same row at the new y re-emits with the new CUP"
    end

    # Binding condition 5 (the geometry-epoch belt): any viewport change
    # re-bases the set — every visible link re-emits next frame. The same
    # evaluation compacts the carrier registries synchronously (binding
    # condition 3, GC.start'd deterministic prune).
    def test_osc8_overlay_geometry_epoch_change_reemits_all_visible
      overlay = fresh_overlay
      line = link_line("see ", "pi", "https://pi.dev")
      overlay.emissions([line], y0: 0, x0: 0, epoch: [80, 24])
      assert_equal "", overlay.emissions([line], y0: 0, x0: 0, epoch: [80, 24])

      dead = TUI.span("dead", fg: :red)
      TUI::LinkOverlay.record_span_href(dead, "https://dead.dev")
      before = TUI::LinkOverlay.registry_depths[:span]
      dead = nil
      GC.start
      reemitted = overlay.emissions([line], y0: 0, x0: 0, epoch: [79, 24])
      assert_equal "\e[1;5H\e[4m\e[38;5;12m\e]8;;https://pi.dev\e\\pi\e]8;;\e\\\e[0m", reemitted,
        "the epoch change re-bases: the visible link re-emits"
      assert_equal "", overlay.emissions([line], y0: 0, x0: 0, epoch: [79, 24]),
        "and the new epoch is the new baseline"
      assert_operator TUI::LinkOverlay.registry_depths[:span], :<, before,
        "the sweep compacted the dead carrier entry synchronously (GC.start'd, no wall-clock)"
    end

    # Binding condition 2: a sweep-rebuilt row is a NEW object — new
    # identity re-emits at the new row's positions (the live region's
    # per-delta rebuilt rows ride the same law).
    def test_osc8_overlay_rebuilt_row_identity_reemits_at_new_width
      overlay = fresh_overlay
      line = link_line("see ", "pi", "https://pi.dev")
      overlay.emissions([line], y0: 0, x0: 0, epoch: [80, 24])
      rebuilt = link_line("", "pipi", "https://pi.dev")
      bytes = overlay.emissions([rebuilt], y0: 0, x0: 0, epoch: [80, 24])
      assert_equal "\e[1;1H\e[4m\e[38;5;12m\e]8;;https://pi.dev\e\\pipi\e]8;;\e\\\e[0m", bytes,
        "a rebuilt row re-emits at its own x=1 and its own text"
    end

    # pi utils.ts:756 letter — a link split across wrapped rows is N
    # fragments, each wrapped open→text→close on its own row (the styled_row
    # regrouping keeps the href on every fragment).
    def test_osc8_overlay_wrapped_link_emits_fragment_per_row
      with_hyperlinks("1") do
        span = S.new(text: "aaaaaaaaaa", fg: :light_blue, modifiers: [:underlined],
          href: "https://pi.dev/very/long/url")
        rows = Render::Text.wrap_row([S.new(text: "see "), span], 6)
        lines = rows.map { |row| TUI.markdown_line(row) }
        fragments = lines.select { |line| line.spans.any? { |sp| TUI::LinkOverlay.span_href(sp) } }
        assert_equal 2, fragments.length, "the link hard-splits into two fragment rows"
        bytes = fresh_overlay.emissions(lines, y0: 0, x0: 0, epoch: [80, 24])
        refute_empty bytes
        chunks = bytes.split("\e[0m")
        fragments.each_with_index do |line, i|
          chunk = chunks[i]
          fragment = line.spans.find { |sp| TUI::LinkOverlay.span_href(sp) }
          assert_includes chunk, "\e]8;;https://pi.dev/very/long/url\e\\",
            "EVERY fragment row carries its own full OSC-8 wrap (pi utils.ts:756)"
          assert_includes chunk, fragment.content, "the fragment's visible text rides its own row"
        end
      end
    end

    # Two links on one row: entries at their span offsets, left-to-right,
    # each with its own URL (the NO-ALIASING law — the shared row never
    # crosses the hrefs).
    def test_osc8_overlay_positions_two_links_with_span_offsets
      line = TUI.markdown_line([
        S.new(text: "a "), S.new(text: "one", fg: :light_blue, modifiers: [:underlined], href: "https://one.dev"),
        S.new(text: " mid "), S.new(text: "two", fg: :light_blue, modifiers: [:underlined], href: "https://two.dev")
      ])
      bytes = fresh_overlay.emissions([line], y0: 0, x0: 0, epoch: [80, 24])
      first = "\e[1;3H\e[4m\e[38;5;12m\e]8;;https://one.dev\e\\one\e]8;;\e\\\e[0m"
      second = "\e[1;11H\e[4m\e[38;5;12m\e]8;;https://two.dev\e\\two\e]8;;\e\\\e[0m"
      assert_equal first + second, bytes, "x=3 and x=11 (cumulative widths), (y,x) ascending"
    end

    # D-clip: the visible text is clipped to the row's remaining width —
    # a post-edge write would wrap onto the next row and clobber it.
    def test_osc8_overlay_clips_link_text_to_row_width
      line = link_line("ab ", "cdefgh", "https://pi.dev")
      bytes = fresh_overlay.emissions([line], y0: 0, x0: 0, epoch: [7, 24])
      assert_equal "\e[1;4H\e[4m\e[38;5;12m\e]8;;https://pi.dev\e\\cdef\e]8;;\e\\\e[0m", bytes,
        "remaining width 4 from x=3 clips the text to the row edge (width 7)"
    end

    # The file-URL letter (pi linkPath over resolvePath): relative
    # resolves against the cwd, absolute passes through, the WHATWG path
    # percent-encoding (space %20, UTF-8 bytes, "#" "%23", "?" "%3F", "/"
    # kept) — the ~ contraction is display-only and never enters the URL.
    def test_osc8_file_url_letter_resolves_and_percent_encodes
      assert_equal "file:///tmp/x/a%20b/%E6%97%A5%E6%9C%AC.md",
        TUI::LinkOverlay.file_url("a b/日本.md", cwd: "/tmp/x"), "relative resolves + encodes"
      assert_equal "file:///abs/pa%20th%23q", TUI::LinkOverlay.file_url("/abs/pa th#q", cwd: "/tmp/x"),
        "absolute passes through; # escapes (the fragment edge)"
      assert_equal "file:///tmp/y/rel/q%3Fx", TUI::LinkOverlay.file_url("rel/q?x", cwd: "/tmp/y"),
        "? escapes (the query edge); / stays"
      assert_equal "file:///tmp/y/~h/x", TUI::LinkOverlay.file_url("/tmp/y/~h/x", cwd: "/tmp/y"),
        "the URL is the RAW path — no display contraction"
    end

    # The tool-path un-cut (binding condition 2's resolution order): the
    # read/write call rows carry the file:// href on the path span when
    # capable — the href FIELD wins over any registered array decoy —
    # and the OFF arm leaves the rows byte-identical (href nil).
    def test_osc8_tool_call_rows_carry_file_url_href
      with_hyperlinks("1") do
        path = "/tmp/osc8 dir/file.md" # short enough to hold one call row
        lines = Render::FileBlocks.read_call_rows({"file_path" => path}, 60)
        span = lines.flat_map(&:spans).find { |sp| TUI::LinkOverlay.span_href(sp) }
        refute_nil span, "the capable call row records the path span"
        assert_equal "file:///tmp/osc8%20dir/file.md", TUI::LinkOverlay.span_href(span),
          "the raw path resolves absolute + percent-encodes"
        assert_equal path, span.content, "the display keeps today's form"

        # The field-wins arm: a registered decoy on the source span's
        # modifiers array never overrides a field-carrying span.
        mods = [:bold]
        TUI::LinkOverlay.record_href_carrier(mods, "file:///decoy")
        src = S.new(text: "p", fg: :red, modifiers: mods, href: "file:///field")
        line = TUI.markdown_line([src])
        assert_equal "file:///field", TUI::LinkOverlay.span_href(line.spans.first),
          "the href field always wins; the registry is the fallback only"
      end
      with_hyperlinks("0") do
        lines = Render::FileBlocks.read_call_rows({"file_path" => "/tmp/x.md"}, 60)
        assert lines.flat_map(&:spans).none? { |sp| TUI::LinkOverlay.span_href(sp) },
          "capability-off records no carrier — zero cost, zero bytes"
      end
    end
  end
end
