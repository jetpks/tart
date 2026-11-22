# frozen_string_literal: true

require_relative "../test_helper"

module Tart
  module Render
    # The pending tool-block surface (I34 — pi renders the running call's
    # block under toolPendingBg mid-flight, tool-execution.ts:90-91 +
    # updateDisplay :271-277 isPartial): the enqueue/finalize lifecycle on
    # the Transcript — the per-family pending shapes, the in-place
    # replacement in both drain cases (the I33 delta discipline), the
    # orphaned-block finalize, the reset, and the replay path's purity.
    # Builder-level pins; the event wiring lives in chat_test.
    class TranscriptTest < Test
      WIDTH = 40

      # The owner's exploded items 5-6 slice (new_problems.md, 2026-10-16/17
      # — the thinking text the repeated-prefix render blew up on), verbatim
      # — the markdown_test OWNER_PAYLOAD slice's exact bytes.
      OWNER_PAYLOAD_SLICE = <<~'PAYLOAD'.chomp.freeze
5. The space commits d926dcb/c5d0b80: model-window routing (z.ai peak schedule flips loop models between zai/* and openrouter/z-ai-*); architect.yaml currently on the zai/* side.
6. Env quirk affecting THIS session: BUNDLE_GEMFILE is exported pointing at repos/tart/Gemfile, which breaks every bare `architect` call (bundler picks tart's bundle, gem not included → error). Workaround: `env -u BUNDLE_GEMFILE architect ...`. Worth flagging to the human — likely leaked from a shell that ran tart/bundle. Also that's presumably why I was launched with it.
      PAYLOAD

      def setup
        @transcript = Transcript.new(
          width_reader: -> { WIDTH }, history_sink: ->(_text) {}, reseed_sink: ->(_message) {}
        )
      end

      # The transcript's rows as stripped text (the byte pins).
      def texts
        @transcript.lines.map { |line| line.spans.map(&:content).join.rstrip }
      end

      # Every bg the buffer's spans carry (the pending-survival scan).
      def bgs
        @transcript.lines.flat_map { |line| line.spans.map { |span| span.style&.bg } }.compact.uniq
      end

      def flush
        @transcript.flush_scrollback
      end

      # --- AC1: the pending shapes per family ---

      # The four pending rows (Grounds 5 — the measured bytes): PLAIN
      # Spacer blank, pending pad, the bold toolTitle `$ <command>`
      # header, pending pad. No output, no Took, no hint.
      def test_pending_bash_renders_the_call_rows_under_the_pending_bg
        @transcript.enqueue_pending_tool_block("c1", "bash", {"command" => "sleep 6"})
        flush

        assert_equal ["", " $ sleep 6", ""], texts.drop(1), "blank + pad + header + pad"
        assert_equal [nil], @transcript.lines[0].spans.map { |span| span.style&.bg }.uniq,
          "the Spacer blank stays PLAIN (bash_block.rb:46)"
        [@transcript.lines[1], @transcript.lines[3]].each do |pad|
          assert_equal Theme[:tool_pending_bg], pad.spans[0].style.bg, "the pads ride #34383a"
        end
        header = @transcript.lines[2].spans
        assert_equal Theme[:tool_pending_bg], header[1].style.bg
        assert_equal Theme[:toolTitle], header[1].style.fg, "the header renders the toolTitle token"
        assert_includes header[1].style.modifiers, :bold, "the header is bold (the I26 measured bytes)"
        assert_equal 4, @transcript.lines.length, "no output, no Took, no expand hint"
      end

      # The pending write block: the call rows alone (the content exists
      # mid-call but pi renders renderCall only).
      def test_pending_write_renders_the_call_rows_alone
        @transcript.enqueue_pending_tool_block("c1", "write", {"file_path" => "/tmp/x.rb", "content" => "puts 1"})
        flush

        assert_equal [" write /tmp/x.rb", ""], texts.drop(2), "pad + call row + pad"
        assert_equal 4, @transcript.lines.length
        call = @transcript.lines[2].spans
        assert_equal Theme[:toolTitle], call[1].style.fg, "the write header is toolTitle"
        assert_includes call[1].style.modifiers, :bold
        assert_equal Theme[:tool_pending_bg], call[1].style.bg
      end

      # The pending read block: the compact classification gate is
      # !expanded — the pending call renders the collapsed resource shape
      # (wrapped at width 40, exactly as the settled collapsed call).
      def test_pending_read_renders_the_collapsed_call
        @transcript.enqueue_pending_tool_block("c1", "read", {"path" => "AGENTS.md"})
        flush

        assert_equal ["", " read resource AGENTS.md (ctrl+o to", " expand)", ""], texts.drop(1),
          "pad + the compact call rows + pad — the settled collapsed shape under the pending bg"
        assert_equal Theme[:tool_pending_bg], @transcript.lines[2].spans[1].style.bg
      end

      # The pending generic block: the wrapped `  ⎿ <name>` call line
      # between the pads (ToolBlock.tool_line(name, nil) — no result yet).
      def test_pending_generic_renders_the_mark_line_alone
        @transcript.enqueue_pending_tool_block("c1", "grep", nil)
        flush

        assert_equal ["", "  ⎿ grep", ""], texts.drop(1), "blank + pad + ⎿ line + pad"
        assert_equal Theme[:tool_pending_bg], @transcript.lines[2].spans[1].style.bg
      end

      # Guard nil arguments the way enqueue_tool_block does.
      def test_pending_bash_guards_nil_args_to_the_placeholder_header
        @transcript.enqueue_pending_tool_block("c1", "bash", nil)
        flush

        assert_equal " $ ...", texts[2], "the empty command renders the ... placeholder"
      end

      # --- AC2: the settle replaces in place; bytes identical to the control ---

      # Control transcript: the same history, only the end event (today's
      # append path — no pending machinery engaged).
      def control_texts(history, name, args, result, duration)
        control = Transcript.new(
          width_reader: -> { WIDTH }, history_sink: ->(_text) {}, reseed_sink: ->(_message) {}
        )
        history.each { |step| step.call(control) }
        control.enqueue_tool_block(name, args, result, duration)
        control.flush_scrollback
        control.lines.map { |line| line.spans.map(&:content).join.rstrip }
      end

      # The drained case: pending flushed to the buffer (registered), the
      # finalize splices the final rows at the recorded start.
      def test_flushed_pending_settles_byte_identical_to_the_control
        args = {"command" => "sleep 6"}
        @transcript.enqueue_pending_tool_block("c1", "bash", args)
        flush
        @transcript.finalize_tool_block("c1", "bash", args, "out", 1.0)
        flush

        assert_equal control_texts([], "bash", args, "out", 1.0), texts, "rows and position byte-identical"
        refute_includes bgs, Theme[:tool_pending_bg], "no pending-bg row survives the settle"
      end

      # The queued case: no flush between start and end — the queued
      # region swaps in place, the buffer never paints the pending rows.
      def test_queued_pending_settles_byte_identical_to_the_control
        args = {"command" => "fast"}
        history = [->(t) { t.enqueue_user_submission("run it") }]
        history.each { |step| step.call(@transcript) }
        @transcript.enqueue_pending_tool_block("c1", "bash", args)
        @transcript.finalize_tool_block("c1", "bash", args, "res", nil)
        flush

        assert_equal control_texts(history, "bash", args, "res", nil), texts,
          "the queued swap lands the final block in the echo's wake, byte-identical"
        refute_includes bgs, Theme[:tool_pending_bg]
      end

      # The I33 discipline: a block flushed AFTER the pending one shifts
      # with the row delta, and the toggle still rebuilds it in place.
      def test_flushed_settle_threads_the_row_delta_to_later_blocks
        args = {"command" => "sleep 6"}
        @transcript.enqueue_pending_tool_block("c1", "bash", args)
        flush
        @transcript.enqueue_user_bash_block("ls", content: "f", exit_code: 0, cancelled: false,
          truncated: false, full_output_path: nil, excluded: false)
        flush
        before = texts.length
        @transcript.finalize_tool_block("c1", "bash", args, "out", 1.0)
        flush

        assert_operator texts.length, :>, before, "the final block is taller than the pending one"
        assert_includes texts, " $ ls", "the later block survives the delta threading"
        assert_operator texts.index(" $ sleep 6"), :<, texts.index(" $ ls"), "order preserved"
        assert @transcript.set_tool_output_expanded(true), "the registry still resolves"
        assert_equal texts.length, texts.length
        assert_includes texts, " $ ls", "the toggle rebuilds the shifted block at its updated start"
        refute_includes bgs, Theme[:tool_pending_bg]
      end

      # The generic family's final block is a plain region (no builder) —
      # the settle drops the pending registration instead of registering
      # the final block.
      def test_generic_settle_drops_the_registration_and_matches_the_control
        @transcript.enqueue_pending_tool_block("c1", "grep", {})
        flush
        @transcript.finalize_tool_block("c1", "grep", {}, "hit", nil)
        flush

        assert_equal control_texts([], "grep", {}, "hit", nil), texts
        assert @transcript.set_tool_output_expanded(true), "the registry survives the dropped entry"
        assert_equal control_texts([], "grep", {}, "hit", nil), texts, "the toggle rebuilds nothing else"
      end

      # --- AC4: lifecycle discipline ---

      # The orphaned pending finalize (pi interactive-mode.ts:3573-3586):
      # the call rows + the error text under toolErrorBg — the settled
      # error block, same position.
      def test_orphaned_pending_finalizes_as_the_error_block
        args = {"command" => "sleepy"}
        @transcript.enqueue_pending_tool_block("c1", "bash", args)
        flush
        @transcript.finalize_pending_as_error("Operation aborted")
        flush

        assert_includes texts, " Operation aborted"
        refute_includes bgs, Theme[:tool_pending_bg], "the pending bg is gone"
        error_row = @transcript.lines.find { |line| line.spans.map(&:content).join.include?("Operation aborted") }
        assert_equal Theme[:tool_error_bg], error_row.spans[1].style.bg, "the error text rides toolErrorBg"
        header = @transcript.lines[2].spans
        assert_equal Theme[:tool_error_bg], header[1].style.bg, "the whole block re-renders the error bg"
        refute_includes texts.join, "Took", "no duration — the abort carries none (pi's updateResult)"
      end

      # The id-MISS finalize (an unknown id — no live registration; also
      # the replay path, which never engages the pending machinery) falls
      # back to today's append (pi :3645-3652's get-by-id miss arm).
      def test_pending_registry_id_miss_finalize_appends
        @transcript.finalize_tool_block("c1", "bash", {"command" => "x"}, "out", nil)
        flush

        assert_equal control_texts([], "bash", {"command" => "x"}, "out", nil), texts
      end

      # --- I65 D2: the id-keyed pending registry (pi's pendingTools Map
      # --- keyed by toolCallId — interactive-mode.ts:3611-3621/:3645-3652) ---

      # REPLACES the I34 supersede pin (test_second_pending_supersedes_and
      # _the_stale_end_appends — the supersede WAS the defect: the owner's
      # parallel batch orphaned the superseded block, its end appended, and
      # grey rows survived forever). N=2 concurrent calls, B completing
      # FIRST: each block settles IN PLACE — exactly one block per call,
      # start order kept, zero pending-bg survivors, no appended duplicate.
      def test_pending_registry_two_concurrent_calls_settle_in_place_b_first
        @transcript.enqueue_pending_tool_block("a", "bash", {"command" => "sleep 3"})
        @transcript.enqueue_pending_tool_block("b", "bash", {"command" => "echo hi"})
        flush
        @transcript.finalize_tool_block("b", "bash", {"command" => "echo hi"}, "hi", 0.01)
        flush
        @transcript.finalize_tool_block("a", "bash", {"command" => "sleep 3"}, "done", 3.0)
        flush

        assert_equal 1, texts.count { |row| row.include?("sleep 3") }, "A settles in place, never appended"
        assert_equal 1, texts.count { |row| row.include?("echo hi") }
        assert_operator texts.index(" $ sleep 3"), :<, texts.index(" $ echo hi"), "blocks stay in START order"
        refute_includes bgs, Theme[:tool_pending_bg], "zero pending-bg rows survive"
      end

      # The same batch, A completing first — BOTH completion orders settle
      # identically.
      def test_pending_registry_two_concurrent_calls_settle_in_place_a_first
        @transcript.enqueue_pending_tool_block("a", "bash", {"command" => "sleep 3"})
        @transcript.enqueue_pending_tool_block("b", "bash", {"command" => "echo hi"})
        flush
        @transcript.finalize_tool_block("a", "bash", {"command" => "sleep 3"}, "done", 3.0)
        flush
        @transcript.finalize_tool_block("b", "bash", {"command" => "echo hi"}, "hi", 0.01)
        flush

        assert_equal 1, texts.count { |row| row.include?("sleep 3") }
        assert_equal 1, texts.count { |row| row.include?("echo hi") }
        assert_operator texts.index(" $ sleep 3"), :<, texts.index(" $ echo hi")
        refute_includes bgs, Theme[:tool_pending_bg]
      end

      # The case [name, args] equality could not discriminate: identical
      # calls with DISTINCT ids each settle their own block in place,
      # byte-identical to two sequential settles.
      def test_pending_registry_identical_calls_distinct_ids_settle_in_place
        args = {"command" => "same"}
        control = Transcript.new(
          width_reader: -> { WIDTH }, history_sink: ->(_text) {}, reseed_sink: ->(_message) {}
        )
        control.enqueue_tool_block("bash", args, "first", nil)
        control.enqueue_tool_block("bash", args, "second", nil)
        control.flush_scrollback

        @transcript.enqueue_pending_tool_block("call_1", "bash", args)
        @transcript.enqueue_pending_tool_block("call_2", "bash", args)
        flush
        @transcript.finalize_tool_block("call_2", "bash", args, "second", nil)
        flush
        @transcript.finalize_tool_block("call_1", "bash", args, "first", nil)
        flush

        assert_equal control.lines.map { |line| line.spans.map(&:content).join.rstrip }, texts,
          "two settled blocks, one per call id, in start order"
        refute_includes bgs, Theme[:tool_pending_bg]
      end

      # The QUEUED variant: neither region drained yet — B's finalize swaps
      # ITS OWN region in the queue (the registry holds every entry's
      # region; the I34 slot swapped only the current one), then A's.
      def test_pending_registry_queued_settles_swap_the_right_region
        @transcript.enqueue_pending_tool_block("a", "bash", {"command" => "sleep 3"})
        @transcript.enqueue_pending_tool_block("b", "bash", {"command" => "echo hi"})
        @transcript.finalize_tool_block("b", "bash", {"command" => "echo hi"}, "hi", nil)
        @transcript.finalize_tool_block("a", "bash", {"command" => "sleep 3"}, "done", nil)
        flush

        assert_equal 1, texts.count { |row| row.include?("sleep 3") }
        assert_equal 1, texts.count { |row| row.include?("echo hi") }
        assert_operator texts.index(" $ sleep 3"), :<, texts.index(" $ echo hi"),
          "start order preserved through the queue swaps"
        refute_includes bgs, Theme[:tool_pending_bg], "no pending rows ever painted"
      end

      # finalize_pending_as_error loops EVERY live pending (pi :3573-3586's
      # abort arm walks the whole Map): both blocks settle in place as the
      # error block, then a later finalize appends — the registry cleared.
      def test_pending_registry_error_finalize_settles_both_and_clears
        @transcript.enqueue_pending_tool_block("a", "bash", {"command" => "sleep 3"})
        @transcript.enqueue_pending_tool_block("b", "bash", {"command" => "echo hi"})
        flush
        @transcript.finalize_pending_as_error("Operation aborted")
        flush

        assert_equal 2, texts.count { |row| row.include?("Operation aborted") }, "BOTH pendings settle"
        assert_equal 2, texts.count { |row| row.include?("$ sleep 3") || row.include?("$ echo hi") },
          "each block keeps its call rows"
        refute_includes bgs, Theme[:tool_pending_bg]
        @transcript.finalize_tool_block("a", "bash", {"command" => "sleep 3"}, "late", nil)
        flush
        assert_includes texts, " late", "the post-error finalize appends — the registry cleared"
      end

      # --- I65 D1: the reasoning seam rides the cured converter (inline_scan) ---

      # The at-most-once cover walk over the reasoning seam's spans (the
      # markdown_test twin, pad/indent spans skipped): every non-whitespace
      # span a source substring at-or-after the previous span's window end.
      def assert_source_cover(spans_texts, source)
        cursor = 0
        spans_texts.reject { |text| text.strip.empty? }.each do |text|
          idx = source.index(text, cursor)
          refute_nil idx, "span #{text[0, 60].inspect} not found at-or-after #{cursor} — invented or duplicated bytes"
          cursor = idx + text.length
        end
      end

      # The owner's exploded items 5-6 slice through Transcript.reasoning_lines
      # (the live reasoning buffer's seam): readable wrapped rows — every
      # row's display width fits the width, every span a source substring
      # in source order, the trigger fragment rendered once (no explosion).
      def test_inline_scan_owner_payload_reasoning_lines_cover_the_source
        lines = Transcript.reasoning_lines(OWNER_PAYLOAD_SLICE, 94)
        spans = lines.flat_map { |line| line.spans.map(&:content) }

        assert_source_cover(spans, OWNER_PAYLOAD_SLICE)
        lines.each do |line|
          assert_operator TUI.text_width(line.spans.map(&:content).join), :<=, 94,
            "row fits the width: #{line.spans.map(&:content).join[0, 40].inspect}"
        end
        assert_operator lines.size, :>, 1, "the payload wraps into readable rows"
        assert_equal 1, spans.join.scan("zai/*").size, "the trigger fragment renders once — no explosion"
      end

      # The minimal trigger through the same seam — passthrough text, once.
      def test_inline_scan_minimal_trigger_reasoning_lines_render_once
        src = "between zai/* and openrouter/z-ai-*); tail"
        lines = Transcript.reasoning_lines(src, 94)
        joined = lines.flat_map { |line| line.spans.map(&:content) }.join

        assert_includes joined, src
        assert_equal 1, joined.scan("between zai/").size, "the pre-text renders exactly once"
      end

      # reset clears the whole registry with the buffer — the
      # post-reset finalize appends (the I33-class stale latent).
      def test_pending_registry_reset_clears_and_the_post_reset_finalize_appends
        @transcript.enqueue_pending_tool_block("c1", "bash", {"command" => "sleepy"})
        flush
        @transcript.reset
        @transcript.finalize_tool_block("c1", "bash", {"command" => "sleepy"}, "out", nil)
        flush

        assert_equal control_texts([], "bash", {"command" => "sleepy"}, "out", nil), texts,
          "no stale registration survives the reset"
      end

      # --- AC3: the replay path never engages the pending machinery ---

      def test_replay_entries_render_final_blocks_only
        entries = [
          {"type" => "message", "message" => {"role" => "user", "content" => "run the tool"}},
          {"type" => "message", "message" => {"role" => "assistant", "content" => nil,
                                              "tool_calls" => {"c1" => {"id" => "c1", "name" => "bash",
                                                                       "arguments" => {"command" => "echo hi"}}}}},
          {"type" => "message", "message" => {"role" => "tool", "tool_call_id" => "c1", "content" => "hi"}}
        ]
        @transcript.replay_entries(entries, update_footer: false, populate_history: false)
        flush

        assert_equal control_texts([->(t) { t.enqueue_user_submission("run the tool") }],
          "bash", {"command" => "echo hi"}, "hi", nil), texts,
          "the replay dispatches through the append path — final blocks only"
        refute_includes bgs, Theme[:tool_pending_bg], "zero pending-bg spans on the replay path"
      end

      # --- I60 error_transcript: the failure row on replay (D4) --------------

      # AC2: a recorded failure entry renders the pad-led error-fg row AFTER
      # its content — the same region shape the live arm enqueues (pi :184-198,
      # the one component serving live AND replay).
      def test_error_transcript_replays_a_failure_row_after_its_content
        entries = [
          {"type" => "message", "message" => {"role" => "user", "content" => "hello"}},
          {"type" => "message", "message" => {"role" => "assistant", "content" => "partial words",
                                              "tool_calls" => {}, "finish_reason" => "error",
                                              "error_message" => "400: boom detail"}},
        ]
        @transcript.replay_entries(entries, update_footer: false, populate_history: false)
        flush

        texts_after_user = texts.drop_while { |row| !row.include?("hello") }
        assert_includes texts_after_user.join, "partial words", "the content row renders first"
        content_index = texts_after_user.index { |row| row.include?("partial words") }
        error_index = texts_after_user.index { |row| row.include?("Error: 400: boom detail") }
        refute_nil content_index
        assert_operator error_index, :>, content_index, "the error row renders AFTER its content"
        error_rows = texts_after_user.grep(/Error: 400: boom detail/)
        assert_equal 1, error_rows.size, "exactly ONE error row"
        assert error_rows[0].start_with?(" "), "pad-led"
        error_line = @transcript.lines.find { |line| line.spans.map(&:content).join.include?("Error: 400: boom detail") }
        assert_equal Theme[:error], error_line.spans.map { |span| span.style&.fg }.compact.first,
          "the row rides the error fg"
      end

      # AC2: the s18 shape — an EMPTY-content failure entry (the pre-stream
      # synthesis) renders the row alone; the leading spacer gate stays shut
      # (no visible content preceded, pi :103-105).
      def test_error_transcript_replays_the_empty_content_failure_row_alone
        entries = [
          {"type" => "message", "message" => {"role" => "user", "content" => "hello"}},
          {"type" => "message", "message" => {"role" => "assistant", "content" => "",
                                              "tool_calls" => {}, "finish_reason" => "error",
                                              "error_message" => "400: boom"}},
        ]
        @transcript.replay_entries(entries, update_footer: false, populate_history: false)
        flush

        texts_after_user = texts.drop_while { |row| !row.include?("hello") }
        error_rows = texts_after_user.grep(/Error: 400: boom/)
        assert_equal 1, error_rows.size, "the row renders with no content above it"
      end

      # AC2: pre-I60 files — a finish_reason "error" WITHOUT the
      # error_message key (and every keyless plain assistant) reads
      # has_error false: the old guard, byte-identical renders.
      def test_error_transcript_pre_i60_files_render_byte_identically
        entries = [
          {"type" => "message", "message" => {"role" => "user", "content" => "hello"}},
          {"type" => "message", "message" => {"role" => "assistant", "content" => "done",
                                              "tool_calls" => {}, "finish_reason" => "stop"}},
          {"type" => "message", "message" => {"role" => "assistant", "content" => "",
                                              "tool_calls" => {}, "finish_reason" => "error"}},
        ]
        @transcript.replay_entries(entries, update_footer: false, populate_history: false)
        flush

        refute texts.join.include?("Error: "), "no error row without the error_message key"
        assert_includes texts.join, "done", "the plain assistant unchanged"
      end

      # --- I105: the winch sweep (the whole-transcript re-wrap; the I56
      # resize-live half-state pins above it are superseded — Grounds S3) ---

      # The mutable width seam: the width_reader closes over a LOCAL,
      # flipped between flush and sweep (the Chat latch's unit-level
      # stand-in — the sweep's builders read {viewport_width} fresh).
      def sweep_transcript(width)
        w = width
        transcript = Transcript.new(width_reader: -> { w }, history_sink: ->(_text) {}, reseed_sink: ->(_message) {})
        [transcript, ->(new_width) { w = new_width }]
      end

      # The widest rendered row (span content summed — the cell width the
      # buffer row occupies).
      def widest_line(lines)
        lines.map { |line| TUI.text_width(line.spans.map(&:content).join) }.max
      end

      # The rows' byte signatures (per-span content + fg + modifiers +
      # bg) — the constant-width comparisons' key.
      def line_bytes(lines)
        lines.map do |line|
          line.spans.map { |span| [span.content, span.style&.fg, span.style&.modifiers&.to_a, span.style&.bg] }
        end
      end

      # One region per scrollback family (AC1's enumeration, transcript-
      # level: the MOTD header + sections ride chat_test's harness). The
      # 40→20 sweep re-derives EVERY family: every width-derived row fits
      # 20 cells and word breaks land; the two collapsed one-line labels
      # (skill panel, compaction hint — the port's width-INDEPENDENT
      # byte-frozen shapes, over-wide at ANY width ≤ their content) are
      # re-derived byte-stable, proven by the CONTROL transcript built at
      # 20 directly. No lost rows, no blank-alignment residue (the whole
      # buffer equals the control, byte for byte).
      def test_resize_sweep_rewraps_every_scrollback_family
        transcript, set_width = sweep_transcript(40)
        skill = %(<skill name="deploy" location="/tmp/deploy.md">\nDeploy the service with the pipeline now please.\n</skill>)
        transcript.enqueue_message("prose **with markup** that certainly outgrows the narrow width", reasoning: "thinking through the wrap arithmetic closely")
        transcript.enqueue_scrollback("plain scrollback text long enough to wrap twice over here", fg: Theme[:dim])
        transcript.enqueue_user_submission("user echo text that certainly wraps when narrowed down")
        transcript.enqueue_user_submission(skill)
        transcript.enqueue_user_bash_block("echo hi", content: "bash output line one longer\nbash output line two", exit_code: 0,
          cancelled: false, truncated: false, full_output_path: nil, excluded: false)
        transcript.enqueue_tool_block("bash", {"command" => "ls -la"}, "file one\nfile two", 1.0)
        transcript.enqueue_tool_block("grep", {}, "generic hit line longer than twenty", nil)
        transcript.enqueue_compaction_panel("compaction summary prose long enough to wrap at the narrow width", 12_345)
        transcript.enqueue_custom_block("memory-recall", "memory content long enough to wrap at the narrower width")
        transcript.enqueue_status("Tool output: expanded status text long enough to wrap at twenty")
        transcript.flush_scrollback

        control, = sweep_transcript(20) # the same families, built AT 20
        [
          ->(t) { t.enqueue_message("prose **with markup** that certainly outgrows the narrow width", reasoning: "thinking through the wrap arithmetic closely") },
          ->(t) { t.enqueue_scrollback("plain scrollback text long enough to wrap twice over here", fg: Theme[:dim]) },
          ->(t) { t.enqueue_user_submission("user echo text that certainly wraps when narrowed down") },
          ->(t) { t.enqueue_user_submission(skill) },
          ->(t) { t.enqueue_user_bash_block("echo hi", content: "bash output line one longer\nbash output line two", exit_code: 0, cancelled: false, truncated: false, full_output_path: nil, excluded: false) },
          ->(t) { t.enqueue_tool_block("bash", {"command" => "ls -la"}, "file one\nfile two", 1.0) },
          ->(t) { t.enqueue_tool_block("grep", {}, "generic hit line longer than twenty", nil) },
          ->(t) { t.enqueue_compaction_panel("compaction summary prose long enough to wrap at the narrow width", 12_345) },
          ->(t) { t.enqueue_custom_block("memory-recall", "memory content long enough to wrap at the narrower width") },
          ->(t) { t.enqueue_status("Tool output: expanded status text long enough to wrap at twenty") },
        ].each { |step| step.call(control) }
        control.flush_scrollback

        set_width.call(20)
        assert transcript.rebuild_scrollback, "the sweep reports the rebuild"

        assert_equal line_bytes(control.lines), line_bytes(transcript.lines),
          "every family re-derived exactly the rows a width-20 boot composes (no stale-width row, no residue)"
        joining = transcript.lines.map { |line| line.spans.map(&:content).join }
        over = joining.reject { |text| TUI.text_width(text) <= 20 }.map(&:strip).sort
        assert_equal ["Compacted from 12,345 tokens (ctrl+o to expand)", "[skill] deploy (ctrl+o to expand)"], over,
          "the only over-20 rows are the two COLLAPSED one-line labels — the port's width-INDEPENDENT byte-frozen shapes; every width-derived row fits 20"
        joined = joining.join("\n")
        assert_includes joined, "outgrows the", "the message wrapped, breaks land"
        assert_includes joined, "narrowed down", "the echo's word-led continuation row"
        assert_includes joined, "wrap twice over", "the plain scrollback continuation"
        assert_includes joined, "to wrap at twenty", "the status pair re-wrapped"
      end

      # An item enqueued at the old width but UNFLUSHED at the winch lands
      # at the NEW width: the drain materializes it (registering its
      # builder), the sweep re-invokes at the latched width — no
      # boot-width residue.
      def test_resize_sweep_covers_queued_unflushed_items
        transcript, set_width = sweep_transcript(40)
        transcript.enqueue_user_submission("queued before the winch so the drain lands me fresh")

        set_width.call(20)
        transcript.flush_scrollback # the drain-materialize at the winch
        assert transcript.rebuild_scrollback, "the sweep covers the drained item"

        joining = transcript.lines.map { |line| line.spans.map(&:content).join }
        joined = joining.join("\n")
        assert_includes joined, "winch so the drain", "the unflushed item materialized"
        assert_includes joined, "lands me fresh", "its tail row at 20"
        refute_includes joined, "queued before the winch so", "no width-40 row survived"
        assert_operator widest_line(transcript.lines), :<=, 20
      end

      # The sweep carries the row DELTA to every later registration, and
      # a subsequent ctrl+o walk — BOTH directions — rebuilds every
      # expanding block at the CURRENT width with correct start/size
      # (supersedes the I56 live-block pin, Grounds S3). Oracle: the
      # control transcript built at the narrow width directly.
      def test_resize_sweep_carries_the_delta_to_later_blocks_and_the_ctrl_o_walk
        history = [
          ->(t) { t.enqueue_user_submission("the block above grows when narrowed") },
          ->(t) { t.enqueue_user_bash_block("echo tail", content: "output row alpha continuing long\noutput row beta", exit_code: 0,
            cancelled: false, truncated: false, full_output_path: nil, excluded: false) },
          ->(t) { t.enqueue_tool_block("bash", {"command" => "below"}, "later block below the grower", 2.0) },
          ->(t) { t.enqueue_scrollback("the tail line after both blocks", fg: Theme[:dim]) },
        ]
        transcript, set_width = sweep_transcript(40)
        history.each { |step| step.call(transcript) }
        transcript.flush_scrollback

        set_width.call(20)
        assert transcript.rebuild_scrollback, "the grower grew"
        control, = sweep_transcript(20)
        history.each { |step| step.call(control) }
        control.flush_scrollback
        assert_equal line_bytes(control.lines), line_bytes(transcript.lines),
          "later starts shifted by the delta — the whole buffer equals a width-20 boot"

        # The ctrl+o walk under delta, BOTH directions, at the CURRENT
        # width: expanded then collapsed byte-match the width-20 controls.
        transcript.set_tool_output_expanded(true)
        control.set_tool_output_expanded(true)
        assert_equal line_bytes(control.lines), line_bytes(transcript.lines), "the walk rebuilds every expanding block (expanded)"
        transcript.set_tool_output_expanded(false)
        control.set_tool_output_expanded(false)
        assert_equal line_bytes(control.lines), line_bytes(transcript.lines), "the walk rebuilds every expanding block (collapsed)"
      end

      # The purity law's no-op proof (supersedes the I56 no-live-blocks
      # pin): a sweep at the SAME width reproduces byte-identical rows.
      def test_resize_sweep_is_byte_identical_at_constant_width
        transcript, set_width = sweep_transcript(40)
        transcript.enqueue_message("constant width means the sweep changes nothing at all", reasoning: "")
        transcript.enqueue_tool_block("grep", {}, "generic hit", nil)
        transcript.enqueue_status("Tool output: collapsed")
        transcript.flush_scrollback
        before = line_bytes(transcript.lines)

        set_width.call(40) # the winch at CONSTANT dims
        assert transcript.rebuild_scrollback, "the sweep ran (the no-op is by construction, not skipped)"

        assert_equal before, line_bytes(transcript.lines), "byte-identical at constant width"
      end

      # Once per winch, never per frame (AC2): a counting builder — the
      # push materializes ONCE, the drain adds nothing, N sweeps invoke
      # exactly N rebuilds, and drain/reads at constant width invoke
      # nothing (the materialized-rows architecture stands).
      def test_rebuilds_once_per_winch_never_per_frame
        transcript, set_width = sweep_transcript(40)
        count = 0
        transcript.push_expandable(->(expanded) { count += 1; [TUI.line("counted #{count} expanded=#{expanded}")] })
        assert_equal 1, count, "the push materializes the rows once"

        transcript.flush_scrollback
        assert_equal 1, count, "the drain-materialize does not double-count"

        3.times do
          set_width.call(20)
          transcript.rebuild_scrollback
          transcript.flush_scrollback # a frame's drain at constant width
          transcript.lines.map { |line| line.spans.map(&:content).join } # a render reads rows
        end
        assert_equal 4, count, "exactly one rebuild invocation per winch (3 sweeps + the push)"
        assert_includes transcript.lines.map { |line| line.spans.map(&:content).join }.first, "counted 4", "the last sweep's rows landed"
      end

      # GROW re-wraps (AC1): 40→80 re-merges the previously-split rows;
      # the round trip restores the width-40 bytes exactly.
      def test_grow_rewrap_merges_rows
        transcript, set_width = sweep_transcript(40)
        transcript.enqueue_user_submission("grow the window and the previously split echo rows re-merge into one single long row again, wider than two rows at forty")
        transcript.flush_scrollback
        narrow_lines = transcript.lines.dup
        assert_operator narrow_lines.size, :>, 5, "the echo wrapped at 40"
        narrow_bytes = line_bytes(narrow_lines)

        set_width.call(80)
        assert transcript.rebuild_scrollback, "the sweep re-wraps on grow"

        joining = transcript.lines.map { |line| line.spans.map(&:content).join }
        assert joining.any? { |row| row.include?("re-merge into one single") },
          "the split rows re-merged — the row now spans the old width-40 break"
        assert_operator transcript.lines.size, :<, narrow_lines.size,
          "the grow collapsed the row count"

        set_width.call(40)
        transcript.rebuild_scrollback
        assert_equal narrow_bytes, line_bytes(transcript.lines), "the round trip restores the width-40 bytes"
      end

      # --- I57: the generic-family live-settle bg cure + the edit family ---

      # AC1 (the root-cause cure): the LIVE settle of a generic tool used
      # to compose bg-less rows (the nil-key forwarding suppressed
      # generic_panel_rows' default); now the finalize arm paints exactly
      # like the replay arm — success #254131, pads included.
      def test_generic_bg_live_settle_paints_the_success_bg
        @transcript.finalize_tool_block("c1", "grep", {}, "hit", nil)
        flush

        assert_equal ["", "", "  ⎿ grep: hit", ""], texts, "the generic shape is unchanged (pads are blank text)"
        assert_equal [Theme[:tool_success_bg]], bgs, "the pad + content rows ride the result bg"
      end

      # The error arm: a failed generic settle paints toolErrorBg.
      def test_generic_bg_live_settle_paints_the_error_bg
        @transcript.finalize_tool_block("c1", "grep", {}, { error: "boom" }, nil)
        flush

        assert_equal Theme[:tool_error_bg], bgs.first, "the error bg"
        assert_includes texts[2], "⎿ grep: boom"
      end

      # The pending arm's bytes are UNCHANGED by the cure (explicit bg).
      def test_generic_bg_pending_arm_stays_byte_frozen
        @transcript.enqueue_pending_tool_block("c1", "grep", {})
        flush

        assert_equal ["", "  ⎿ grep", ""], texts.drop(1), "the pending shape"
        assert_equal [Theme[:tool_pending_bg]], bgs, "the pending bg only"
      end

      # AC2/AC4: the edit dispatch settles from the call's details — the
      # pending block replaced IN PLACE with the EditBlock family (no ⎿
      # row, the diff from the details, the success bg).
      def test_edit_block_dispatch_settles_from_the_call_details
        args = { "path" => "f.txt" }
        @transcript.enqueue_pending_tool_block("c1", "edit", args)
        flush
        pending_size = @transcript.lines.size

        details = { diff: "-1 line two bravo\n+1 line two charlie", patch: "", firstChangedLine: 1 }
        @transcript.finalize_tool_block("c1", "edit", args, "Successfully replaced 1 block(s) in f.txt.", nil,
                                        details: details)
        flush

        assert_operator @transcript.lines.size, :>, pending_size, "the diff rows landed"
        joined = texts.join("\n")
        assert_includes joined, " edit f.txt", "the header"
        assert_includes joined, "-1 line two bravo", "the removed row"
        assert_includes joined, "+1 line two charlie", "the added row"
        refute_includes joined, "⎿ edit:", "the generic defect row is gone"
        assert_includes bgs, Theme[:tool_success_bg], "the success bg"
      end

      # The replay arm: the recorded details string-key hash renders the
      # same family from the recorded session.
      def test_edit_block_replay_renders_from_the_recorded_details
        entries = [
          { "type" => "message", "message" => { "role" => "user", "content" => "write then edit" } },
          { "type" => "message", "message" => { "role" => "assistant", "content" => nil,
                                                "tool_calls" => { "c1" => { "id" => "c1", "name" => "edit",
                                                                            "arguments" => { "path" => "f.txt" } } } } },
          { "type" => "message", "message" => { "role" => "tool", "content" => "ok", "tool_call_id" => "c1",
                                                "details" => { "diff" => "-1 a bravo", "patch" => "",
                                                               "firstChangedLine" => 1 } } },
        ]
        @transcript.replay_entries(entries, update_footer: false, populate_history: false)
        flush

        joined = texts.join("\n")
        assert_includes joined, " edit f.txt"
        assert_includes joined, "-1 a bravo"
        assert_includes bgs, Theme[:tool_success_bg]
      end

      # Sessions recorded pre-I57 (no details) replay HEADER-ONLY.
      def test_edit_block_replay_without_recorded_details_renders_header_only
        entries = [
          { "type" => "message", "message" => { "role" => "assistant", "content" => nil,
                                                "tool_calls" => { "c1" => { "id" => "c1", "name" => "edit",
                                                                            "arguments" => { "path" => "f.txt" } } } } },
          { "type" => "message", "message" => { "role" => "tool", "content" => "ok", "tool_call_id" => "c1" } },
        ]
        @transcript.replay_entries(entries, update_footer: false, populate_history: false)
        flush

        joined = texts.join("\n")
        assert_includes joined, " edit f.txt"
        refute_includes joined, "⎿ edit:", "still the edit family, not the generic row"
        assert_equal 4, @transcript.lines.size, "spacer + pad + header + pad"
      end

      # AC3: the pending edit block — the header alone under the pending
      # bg (the preview cut, Grounds §6).
      def test_edit_block_pending_renders_the_header_under_the_pending_bg
        @transcript.enqueue_pending_tool_block("c1", "edit", { "path" => "f.txt" })
        flush

        assert_equal ["", "", " edit f.txt", ""], texts, "the 4-row pending frame"
        assert_equal [Theme[:tool_pending_bg]], bgs, "the pending bg only"
      end
      end
    # --- I47: the custom-message block (pi CustomMessageComponent's
    # default rendering — the Grounds section-6 staged-pi capture is the
    # row-shape oracle) ---

    def test_custom_block_renders_the_label_and_the_markdown_content
      @transcript.enqueue_custom_block("memory-recall",
        "[project memory] index loaded at session start; use the memory tool (read/list) for topic files:\n" \
        "- deploy (deploy.md): deploys via herdr pipeline, stage first")
      flush

      rows = texts
      assert_equal "", rows[0], "the component's own Spacer(1) opens the block"
      bg = Theme[:custom_message_bg]
      assert_equal bg, @transcript.lines[1].spans[0].style.bg, "the Box paddingY top"
      label = @transcript.lines[2].spans
      assert_equal "[memory-recall]", label[1].content, "the bold label row (one-column padded)"
      assert_equal Theme[:custom_message_label], label[1].style.fg
      assert_includes label[1].style.modifiers, :bold
      assert_equal bg, label[1].style.bg
      assert_equal "", rows[3], "the Box's inner Spacer"
      body = rows[4]
      assert_includes body, "index loaded at session start", "the content rides the markdown path"
      assert_includes rows[5], "deploy (deploy.md)", "the link renders text (href)"
      assert_equal bg, @transcript.lines[4].spans[1].style.bg, "the content rows carry customMessageText's bg"
      assert_equal Theme[:custom_message_text], @transcript.lines[4].spans[1].style.fg
      assert_equal "", rows[-1], "the Box paddingY bottom closes the block"
    end

    def test_custom_block_replay_renders_the_same_rows
      @transcript.replay_entry({"type" => "custom_message", "customType" => "memory-recall",
                                "content" => "- [a](a.md): one", "display" => true},
        {}, update_footer: false, populate_history: false)
      flush

      rows = texts
      assert_includes rows, "[memory-recall]"
      assert_includes rows[4], "- [a](a.md): one"
    end

    def test_custom_block_replay_skips_undisplayed_entries
      @transcript.replay_entry({"type" => "custom_message", "customType" => "quiet", "content" => "x",
                                "display" => false},
        {}, update_footer: false, populate_history: false)
      flush

      assert_empty @transcript.lines, "display false renders nothing (pi's display gate)"
    end

    # --- I105 dead-letter note (do NOT revive, do NOT delete here) ---
    # The defs below (and the I47 custom-block trio above) sit at
    # Tart::Render MODULE level: a stray `end` at line ~603 closes
    # TranscriptTest early — a pre-existing latent defect at the base, so
    # these defs NEVER EXECUTE (the file runs 32 of its 37 defs). They
    # are kept (not deleted) so the frozen suite-par gate's self-derived
    # `sup` stays truthful (sup=2 → want=1664 = actual membership); they
    # never run, so the retired rebuild_live_expandables API they name is
    # never invoked. Follow-up ledger (driver-owned, out of this lane):
    # repair the stray `end`, decide resurrect-vs-delete for the five
    # silently-dead tests, re-baseline the suite-par arithmetic.

    # --- I56: the resize-live rebuild ---

    # rebuild_live_expandables re-invokes ONLY the resize_live-flagged
    # builders at the CURRENT toggle state and splices in place with the
    # flip's start/delta arithmetic: the live block's rows replace in
    # place, content BELOW shifts by the height delta, and non-live
    # registrations (a tool block) keep their rows byte-identical.
    def test_rebuild_live_expandables_replaces_the_live_block_and_shifts_later_rows
      generation = "a"
      @transcript.push_expandable(->(expanded) { [TUI.line("header #{generation} expanded=#{expanded}")] },
        resize_live: true)
      @transcript.push_expandable(->(expanded) { [TUI.line("tool expanded=#{expanded}")] })
      @transcript.enqueue_scrollback("below the fold", fg: Theme[:dim])
      flush

      assert_equal ["header a expanded=false", "tool expanded=false", "below the fold"], texts

      generation = "bb" # the rebuilt header is one row TALLER
      assert @transcript.rebuild_live_expandables, "the rebuild reports a live block rebuilt"

      assert_equal ["header bb expanded=false", "tool expanded=false", "below the fold"], texts,
        "the live block replaced in place at the current expand state; later content intact"
      assert_equal 4, @transcript.lines.size, "the height delta shifted the rows below"

      @transcript.set_tool_output_expanded(true)
      generation = "cc"
      @transcript.rebuild_live_expandables
      assert_equal ["header cc expanded=true", "tool expanded=true", "below the fold"], texts,
        "the rebuild reads the CURRENT toggle state (no flip of its own)"
    end

    # resize_live defaults FALSE — every pre-I56 push_expandable caller
    # byte-identical — and rebuild_live_expandables no-ops (returns
    # false, rows untouched) when only non-live blocks are registered.
    def test_rebuild_live_expandables_defaults_false_and_no_ops_without_live_blocks
      @transcript.push_expandable(->(_expanded) { [TUI.line("tool block")] })
      flush

      refute @transcript.rebuild_live_expandables, "no live blocks → nothing rebuilt"
      assert_equal ["tool block"], texts, "the rows are untouched"
      assert_equal 1, @transcript.lines.size
    end
  end
end
