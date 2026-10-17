# frozen_string_literal: true

require_relative "test_helper"

module Tart
  # The markdown converter (AC4): every subset construct's observable
  # distinction, cited to the pi oracle
  # (repos/pi/packages/tui/src/components/markdown.ts).
  class MarkdownTest < Test
    S = Render::Markdown::Span

    # The owner's literal thinking payload (new_problems.md, 2026-10-16/17
    # — the "we somehow completely screwed up this content" render),
    # verbatim. The repeated-prefix explosion rode its items 5-6 slice
    # (`zai/* and openrouter/z-ai-*`).
    OWNER_PAYLOAD = <<~'PAYLOAD'.chomp.freeze
Everything is clear now. Summary of the space:

**The space**: 20261009-pi-port — porting the used parts of the pi coding harness to async-Ruby as "tart" (single-user daily driver on socketry async + ratatui_ruby, LLM wire owned by the space's own fast-completions gem). 64 iterations, all CONTINUE. Exact-parity bar (BRIEF §8): pi in one tab, tart in another, indistinguishable.

**Current state — quiescent, nothing running:**
- Looplog: no active runs. The last coordinator run finished ~23h ago (2026-10-16 01:30Z).
- The strict-sampling program (plan 20261015T223818Z) is COMPLETE: I63 (gem side, fast-llm) + I64 (tart consumer side) both judged CONTINUE all-AC and integrated.
- The owner's landing steps got done: gem 0.4.0 cut + tagged + pushed (ef79e82, PR #3 merged to fast-llm main), tart re-pinned to 0.4.0 (1b83e05 on project/pi-port, pushed — in sync with origin), live A/B confirmed PASS (problems.md @1b69ddb marked RESOLVED live-confirmed: bash timeout now emitted under strict wire).
- problems.md first item resolved — that was the root cause of the original "tart hangs forever" live bug (constrained-sampling/strict-tools wire gap).

**Loose ends I can see:**
1. fast-llm `main` is 1 commit ahead of origin: `ce19841 fix 0.4.1: streaming live-parse leak` — committed locally, NOT tagged (v0.4.1 tag doesn't exist), NOT pushed. So 0.4.1 is pending release/push.
2. tart repo has uncommitted Gemfile/Gemfile.lock changes on project/pi-port — a local working tweak restoring the FAST_COMPLETIONS_PATH env-path branch in the Gemfile (committed 1b83e05 had pin `0.4.0` only; the uncommitted edit re-adds the path-override conditional, and the lock drops the checksum for the local path). Uncommitted worktree — deliberate local convenience or leftover.
3. No open PRs on either repo (gh pr list empty for both jetpks/tart and jetpks/fast-llm). tart main is still at "Bootstrap" — project/pi-port has never been PR'd/merged to main. So the whole tart port lives on the project branch. Hmm — is that intended? The landing per skill: "write the PR body ... present paste-and-run block ... human runs when ready." Maybe the owner pushed but never opened the PR, or the workflow is trunk = project/pi-port. origin/project/pi-port exists and is in sync. No open PR. This may be intentional (owner merges periodically?). Note fast-llm got PR #3 merged, so fast-llm uses PRs. For tart, maybe an owner decision pending.
4. Known residuals (from ARCHITECT.md): pi-1.2.0 oracle drift (ORACLE_VERSION still pinned 1.1.0 while installed pi is 1.2.0 — rig gates exit 1 unknown-candidate; owner needs to re-pin), s18 standing declared-shape red, doc nits (README "13 keys" line → 14), the v0.4.1 fix above, problems.md remaining unchecked items (the unchecked bullets below the first resolved one: resize wrap issues — wait, those were I56; scroll lag I58; /thinking while streaming I54; queued messages hint I54; edit bg I57; paste markers I55 — those all got iterations. The unchecked appearance is just problems.md not being ticked off; the ARCHITECT.md says items closed. Not going to over-claim: the remaining bullets in problems.md after the first item are the historical live-run findings that iterations I54–I58 closed, but the file's checkboxes aren't ticked. Minor housekeeping.)
5. The space commits d926dcb/c5d0b80: model-window routing (z.ai peak schedule flips loop models between zai/* and openrouter/z-ai-*); architect.yaml currently on the zai/* side.
6. Env quirk affecting THIS session: BUNDLE_GEMFILE is exported pointing at repos/tart/Gemfile, which breaks every bare `architect` call (bundler picks tart's bundle, gem not included → error). Workaround: `env -u BUNDLE_GEMFILE architect ...`. Worth flagging to the human — likely leaked from a shell that ran tart/bundle. Also that's presumably why I was launched with it.

Also worth noting: the last thing in TL;DR says "Next: owner landing steps — the 0.4.0 cut, the D7 live A/B run, then the strict-sampling program CLOSES" — those are DONE per problems.md RESOLVED + tags + push. So the program is fully closed; the only follow-ons are the residuals + the 0.4.1 release + possibly the tart PR-to-main decision.

Now compose a concise answer. Structure:
- One-line: what the space is.
- Status: quiescent, last program closed & landed.
- What just happened (strict-sampling arc).
- What's sitting loose right now (0.4.1 unpushed/untagged; tart uncommitted Gemfile diff; no PRs open, tart main still bootstrap; pi-1.2.0 oracle re-pin residual; doc nits).
- Session-level gotcha: BUNDLE_GEMFILE leak breaking `architect` — flag it.

Keep it tight. No code changes needed. This is a "what's going on" question — conversational architect mode.
    PAYLOAD

    # The exploded items 5-6 slice — the exact bytes the owner's render
    # blew up on (derived, so the two pins can never drift apart).
    OWNER_PAYLOAD_SLICE = OWNER_PAYLOAD.slice(
      OWNER_PAYLOAD.index("5. The space commits")..OWNER_PAYLOAD.index("launched with it.") + "launched with it.".length - 1
    ).freeze

    def test_paragraph_is_default_styled_text
      assert_equal [[S.new(text: "plain words")]], Render::Markdown.rows("plain words")
    end

    def test_blank_source_line_renders_a_blank_row
      rows = Render::Markdown.rows("one\n\ntwo")
      assert_equal [[S.new(text: "one")], [], [S.new(text: "two")]], rows
    end

    def test_h1_is_yellow_bold_underlined
      assert_equal [[S.new(text: "Title", fg: :yellow, modifiers: %i[bold underlined])]],
        Render::Markdown.rows("# Title"), "h1 = heading(bold(underline)) (markdown.ts:481-483)"
    end

    def test_h2_is_yellow_bold_without_underline_or_prefix
      assert_equal [[S.new(text: "Title", fg: :yellow, modifiers: [:bold])]],
        Render::Markdown.rows("## Title")
    end

    def test_h3_plus_keeps_a_styled_hash_prefix
      assert_equal [[S.new(text: "### ", fg: :yellow, modifiers: [:bold]),
                     S.new(text: "deep", fg: :yellow, modifiers: [:bold])]],
        Render::Markdown.rows("### deep"), "h3+ renders the styled '#' prefix (markdown.ts:493)"
    end

    def test_heading_gets_a_blank_row_before_a_following_paragraph
      rows = Render::Markdown.rows("# H\ntext")
      assert_equal [], rows[1], "spacing after a heading unless a space token follows (markdown.ts:494-499)"
    end

    def test_bold_is_the_bold_modifier
      assert_equal [[S.new(text: "bold", modifiers: [:bold])]],
        Render::Markdown.rows("**bold**"), "strong → theme.bold (markdown.ts:683-687)"
    end

    def test_italic_is_the_italic_modifier
      assert_equal [[S.new(text: "em", modifiers: [:italic])]],
        Render::Markdown.rows("*em*"), "em → theme.italic (markdown.ts:689-693)"
    end

    def test_bold_and_italic_nest
      assert_equal [[S.new(text: "bold ", modifiers: [:bold]),
                     S.new(text: "nested", modifiers: %i[bold italic])]],
        Render::Markdown.rows("**bold *nested***")
    end

    def test_strikethrough_is_the_crossed_out_modifier
      assert_equal [[S.new(text: "gone", modifiers: [:crossed_out])]],
        Render::Markdown.rows("~~gone~~"), "del → theme.strikethrough (markdown.ts:725-729)"
    end

    def test_strikethrough_is_strict
      assert_equal [[S.new(text: "~~ padded ~~")]],
        Render::Markdown.rows("~~ padded ~~"),
        "padded delimiters stay literal (StrictStrikethroughTokenizer, markdown.ts:9-21)"
    end

    def test_inline_code_is_violet_and_unparsed
      assert_equal [[S.new(text: "x = 1", fg: :light_magenta)]],
        Render::Markdown.rows("`x = 1`"), "codespan → theme.code (markdown.ts:695-697)"
      assert_equal [[S.new(text: "*raw*", fg: :light_magenta)]], Render::Markdown.rows("`*raw*`")
    end

    def test_fenced_code_block_has_border_rows_and_indented_green_body
      rows = Render::Markdown.rows("```ruby\nputs 1\n```")
      assert_equal [[S.new(text: "```ruby", fg: :gray)],
                    [S.new(text: "  "), S.new(text: "puts 1", fg: :green)],
                    [S.new(text: "```", fg: :gray)]], rows,
        "codeBlockBorder fences + '  '-indented codeBlock body (markdown.ts:530-550)"
    end

    def test_blockquote_prefixes_with_border_and_grays_italics_content
      rows = Render::Markdown.rows("> quoted")
      assert_equal [[S.new(text: "│ ", fg: :gray),
                     S.new(text: "quoted", fg: :gray, modifiers: [:italic])]], rows,
        "quoteBorder('│ ') prefix + quote(italic(text)) (markdown.ts:566-606)"
    end

    def test_multiline_blockquote_is_one_row_per_source_line
      rows = Render::Markdown.rows("> a\n> b")
      assert_equal 2, rows.size
      assert_equal "│ ", rows[1].first.text
    end

    def test_hr_is_ashes_sized_to_width_capped_at_80
      assert_equal [[S.new(text: "─" * 80, fg: :gray)]], Render::Markdown.rows("---"),
        "theme.hr('─' * min(width, 80)) (markdown.ts:615-617)"
      assert_equal [[S.new(text: "─" * 10, fg: :gray)]], Render::Markdown.rows("***", width: 10)
    end

    def test_unordered_list_normalizes_to_dash_bullet
      rows = Render::Markdown.rows("* one\n+ two\n  wrapped")
      assert_equal [[S.new(text: "- ", fg: :light_magenta), S.new(text: "one")],
                    [S.new(text: "- ", fg: :light_magenta), S.new(text: "two")],
                    [S.new(text: "  "), S.new(text: "wrapped")]], rows,
        "bullets normalized to '- ', listBullet-styled, continuation indented to marker width (markdown.ts:775-789)"
    end

    def test_ordered_list_renumbers_from_the_list_start
      rows = Render::Markdown.rows("1. a\n2. b")
      assert_equal [[S.new(text: "1. ", fg: :light_magenta), S.new(text: "a")],
                    [S.new(text: "2. ", fg: :light_magenta), S.new(text: "b")]], rows
      assert_equal "3. ", Render::Markdown.rows("3. x").first.first.text, "start number honored (markdown.ts:776-777)"
    end

    def test_list_gets_no_trailing_blank_row_before_a_following_block
      rows = Render::Markdown.rows("- a\n\nnext")
      assert_equal [[S.new(text: "- ", fg: :light_magenta), S.new(text: "a")], [],
        [S.new(text: "next")]], rows,
        "exactly one blank row after a list — no list trailing spacing (markdown.ts:552-554)"
    end

    def test_nested_list_indents_and_bullets
      rows = Render::Markdown.rows("- a\n  - b")
      assert_equal [[S.new(text: "- ", fg: :light_magenta), S.new(text: "a")],
                    [S.new(text: "    "), S.new(text: "- ", fg: :light_magenta), S.new(text: "b")]], rows,
        "nested list: one indent level per depth, unprefixed (markdown.ts:794-798)"
    end

    def test_loose_list_inserts_blank_rows_between_items
      rows = Render::Markdown.rows("- a\n\n- b")
      assert_equal 3, rows.size
      assert_equal [], rows[1], "loose lists space their items (markdown.ts:799-802)"
    end

    def test_link_is_blue_underlined_with_the_url_fallback
      rows = Render::Markdown.rows("[pi](https://pi.dev)")
      assert_equal [[S.new(text: "pi", fg: :light_blue, modifiers: [:underlined]),
                     S.new(text: " (https://pi.dev)", fg: :gray)]], rows,
        "link(underline(text)) + linkUrl(' (href)') when text differs (markdown.ts:699-719)"
    end

    def test_link_with_text_equal_to_href_has_no_url_suffix
      assert_equal [[S.new(text: "https://pi.dev", fg: :light_blue, modifiers: [:underlined])]],
        Render::Markdown.rows("[https://pi.dev](https://pi.dev)"), "markdown.ts:712-714"
    end

    def test_escaped_delimiters_are_literal
      assert_equal [[S.new(text: "*not em*")]], Render::Markdown.rows("\\*not em\\*")
    end

    # --- I65 D1: the inline-scan reject emission ---

    # A rejected em pair with pre-text renders the delimiter AT ITS MATCH
    # POSITION, once — the pre-text stays emitted exactly once at the loop
    # top (the I06 flanking approximation is unchanged: the reject still
    # rejects; only the emission was the defect).
    def test_inline_scan_rejected_em_with_pre_text_renders_the_delimiter_once
      assert_equal [[S.new(text: "lead * padded * tail")]],
        Render::Markdown.rows("lead * padded * tail"),
        "no duplicated prefix, no dropped chars — the exact literal spans"
    end

    # The del family's reject-with-pre-text — the same emission cure.
    def test_inline_scan_rejected_del_with_pre_text_renders_the_delimiter_once
      assert_equal [[S.new(text: "lead ~~ padded ~~ tail")]],
        Render::Markdown.rows("lead ~~ padded ~~ tail")
    end

    # The advance lands at m.begin(0) + 1 — never before the match, never
    # scan-start+1 — so the remainder RE-SCANS: a later accepted pair in
    # the same source still processes.
    def test_inline_scan_rescans_after_a_reject_so_a_later_pair_still_processes
      assert_equal [[S.new(text: "x * padded * and "),
                     S.new(text: "em", modifiers: [:italic]),
                     S.new(text: " tail")]],
        Render::Markdown.rows("x * padded * and *em* tail"),
        "two rejects then an accept — the advance-past-the-delimiter semantics " \
        "(the accepted pair renders its inner alone)"
    end

    # The owner's minimal trigger: 42 bytes in, passthrough-exact out (the
    # base rendered 120 — the pre-match prefix re-emitted per loop).
    def test_inline_scan_minimal_owner_trigger_renders_passthrough_exact
      src = "between zai/* and openrouter/z-ai-*); tail"
      rows = Render::Markdown.rows(src, width: 94)

      assert_equal 1, rows.size, "one row, one source line"
      assert_equal src, rows.first.map(&:text).join
    end

    # The at-most-once cover walk: every non-empty span's text is a source
    # substring found at-or-after the previous span's window end — spans in
    # source order, no source character rendered twice. (Per-span, not
    # per-row: markup stripping — `**`, backticks — joins non-adjacent
    # source runs inside one row.) The I65 D1 explosion duplicates bytes
    # and cannot survive this walk.
    def assert_source_cover(spans_texts, source)
      cursor = 0
      spans_texts.reject { |text| text.strip.empty? }.each do |text|
        idx = source.index(text, cursor)
        refute_nil idx, "span #{text[0, 60].inspect} not found at-or-after #{cursor} — invented or duplicated bytes"
        cursor = idx + text.length
      end
    end

    # The owner's exploded items 5-6 slice covers its source exactly once.
    def test_inline_scan_owner_payload_slice_covers_the_source_exactly_once
      rows = Render::Markdown.rows(OWNER_PAYLOAD_SLICE, width: 94)
      spans = rows.flat_map { |row| row.map(&:text) }

      assert_source_cover(spans, OWNER_PAYLOAD_SLICE)
      assert_equal 1, spans.join.scan("zai/*").size,
        "the rejected opener renders literally ONCE (the second `*` opens the " \
        "accepted pair — its inner renders, delimiters consumed; the base " \
        "explosion rendered the fragment 30+ times)"
    end

    # The owner's FULL thinking payload through the converter: readable
    # rows, every span a source substring in source order, and the render
    # never exceeds the source's own size (the exploded render measured
    # 120 bytes for a 42-byte source).
    def test_inline_scan_owner_full_payload_covers_the_source_exactly_once
      rows = Render::Markdown.rows(OWNER_PAYLOAD, width: 94)
      spans = rows.flat_map { |row| row.map(&:text) }

      assert_source_cover(spans, OWNER_PAYLOAD)
      assert_operator spans.join.length, :<=, OWNER_PAYLOAD.length,
        "no render inflation — styling strips bytes, the explosion added them"
    end

    def test_converter_source_is_gem_neutral
      source = File.read(File.expand_path("../lib/tart/render/markdown.rb", __dir__))
      refute_includes source, "RatatuiRuby", "the tui-seam gate scans all of lib"
    end
  end
end
