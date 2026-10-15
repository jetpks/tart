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
        @transcript.enqueue_pending_tool_block("bash", {"command" => "sleep 6"})
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
        @transcript.enqueue_pending_tool_block("write", {"file_path" => "/tmp/x.rb", "content" => "puts 1"})
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
        @transcript.enqueue_pending_tool_block("read", {"path" => "AGENTS.md"})
        flush

        assert_equal ["", " read resource AGENTS.md (ctrl+o to", " expand)", ""], texts.drop(1),
          "pad + the compact call rows + pad — the settled collapsed shape under the pending bg"
        assert_equal Theme[:tool_pending_bg], @transcript.lines[2].spans[1].style.bg
      end

      # The pending generic block: the wrapped `  ⎿ <name>` call line
      # between the pads (ToolBlock.tool_line(name, nil) — no result yet).
      def test_pending_generic_renders_the_mark_line_alone
        @transcript.enqueue_pending_tool_block("grep", nil)
        flush

        assert_equal ["", "  ⎿ grep", ""], texts.drop(1), "blank + pad + ⎿ line + pad"
        assert_equal Theme[:tool_pending_bg], @transcript.lines[2].spans[1].style.bg
      end

      # Guard nil arguments the way enqueue_tool_block does.
      def test_pending_bash_guards_nil_args_to_the_placeholder_header
        @transcript.enqueue_pending_tool_block("bash", nil)
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
        @transcript.enqueue_pending_tool_block("bash", args)
        flush
        @transcript.finalize_tool_block("bash", args, "out", 1.0)
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
        @transcript.enqueue_pending_tool_block("bash", args)
        @transcript.finalize_tool_block("bash", args, "res", nil)
        flush

        assert_equal control_texts(history, "bash", args, "res", nil), texts,
          "the queued swap lands the final block in the echo's wake, byte-identical"
        refute_includes bgs, Theme[:tool_pending_bg]
      end

      # The I33 discipline: a block flushed AFTER the pending one shifts
      # with the row delta, and the toggle still rebuilds it in place.
      def test_flushed_settle_threads_the_row_delta_to_later_blocks
        args = {"command" => "sleep 6"}
        @transcript.enqueue_pending_tool_block("bash", args)
        flush
        @transcript.enqueue_user_bash_block("ls", content: "f", exit_code: 0, cancelled: false,
          truncated: false, full_output_path: nil, excluded: false)
        flush
        before = texts.length
        @transcript.finalize_tool_block("bash", args, "out", 1.0)
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
        @transcript.enqueue_pending_tool_block("grep", {})
        flush
        @transcript.finalize_tool_block("grep", {}, "hit", nil)
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
        @transcript.enqueue_pending_tool_block("bash", args)
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

      # A finalize with no live pending registration falls back to the
      # append (the replay path's shape).
      def test_finalize_without_a_pending_registration_appends
        @transcript.finalize_tool_block("bash", {"command" => "x"}, "out", nil)
        flush

        assert_equal control_texts([], "bash", {"command" => "x"}, "out", nil), texts
      end

      # A second enqueue while one is live appends sanely and SUPERSEDES
      # the registration (unreachable under sequential execution —
      # the executor's batch is the only concurrency; the documented caveat):
      # the superseded block renders on under the pending bg (its end
      # falls back to the append below it), the live one replaces.
      def test_second_pending_supersedes_and_the_stale_end_appends
        @transcript.enqueue_pending_tool_block("bash", {"command" => "first"})
        @transcript.enqueue_pending_tool_block("bash", {"command" => "second"})
        flush
        @transcript.finalize_tool_block("bash", {"command" => "first"}, "one", nil)
        flush
        assert_includes texts, " one", "the stale end falls back to the append"
        assert_includes texts.join, "$ second", "the live pending renders on"
        @transcript.finalize_tool_block("bash", {"command" => "second"}, "two", nil)
        flush
        assert_includes texts, " two", "the live end replaces in place"
        assert_includes bgs, Theme[:tool_pending_bg],
          "the superseded block rides on (the documented caveat — unreachable sequentially)"
      end

      # reset clears the pending registration with the buffer — the
      # post-reset finalize appends (the I33-class stale latent).
      def test_reset_clears_the_pending_registration
        @transcript.enqueue_pending_tool_block("bash", {"command" => "sleepy"})
        flush
        @transcript.reset
        @transcript.finalize_tool_block("bash", {"command" => "sleepy"}, "out", nil)
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

      # --- I56: the resize-live rebuild ---

      # rebuild_live_expandables re-invokes ONLY the resize_live-flagged
      # builders at the CURRENT toggle state and splices in place with the
      # flip's start/delta arithmetic: the live block's rows replace in
      # place, content BELOW shifts by the height delta, and non-live
      # registrations (a tool block) keep their rows byte-identical.
      def test_rebuild_live_expandables_replaces_the_live_block_and_shifts_later_rows
        live_rows = 1 # the live block's row count (the rebuild's height delta lever)
        @transcript.push_expandable(->(expanded) { live_rows.times.map { |i| TUI.line("header r#{i} expanded=#{expanded}") } },
          resize_live: true)
        @transcript.push_expandable(->(expanded) { [TUI.line("tool expanded=#{expanded}")] })
        @transcript.enqueue_scrollback("below the fold", fg: Theme[:dim])
        flush

        assert_equal ["header r0 expanded=false", "tool expanded=false", "below the fold"], texts

        live_rows = 2 # the rebuilt block is one row TALLER
        assert @transcript.rebuild_live_expandables, "the rebuild reports a live block rebuilt"

        assert_equal ["header r0 expanded=false", "header r1 expanded=false", "tool expanded=false", "below the fold"],
          texts, "the live block replaced in place at the current expand state; later content intact"
        assert_equal 4, @transcript.lines.size, "the height delta shifted the rows below"

        @transcript.set_tool_output_expanded(true)
        @transcript.rebuild_live_expandables
        assert_equal ["header r0 expanded=true", "header r1 expanded=true", "tool expanded=true", "below the fold"],
          texts, "the rebuild reads the CURRENT toggle state (no flip of its own)"
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

      # --- I57: the generic-family live-settle bg cure + the edit family ---

      # AC1 (the root-cause cure): the LIVE settle of a generic tool used
      # to compose bg-less rows (the nil-key forwarding suppressed
      # generic_panel_rows' default); now the finalize arm paints exactly
      # like the replay arm — success #254131, pads included.
      def test_generic_bg_live_settle_paints_the_success_bg
        @transcript.finalize_tool_block("grep", {}, "hit", nil)
        flush

        assert_equal ["", "", "  ⎿ grep: hit", ""], texts, "the generic shape is unchanged (pads are blank text)"
        assert_equal [Theme[:tool_success_bg]], bgs, "the pad + content rows ride the result bg"
      end

      # The error arm: a failed generic settle paints toolErrorBg.
      def test_generic_bg_live_settle_paints_the_error_bg
        @transcript.finalize_tool_block("grep", {}, { error: "boom" }, nil)
        flush

        assert_equal Theme[:tool_error_bg], bgs.first, "the error bg"
        assert_includes texts[2], "⎿ grep: boom"
      end

      # The pending arm's bytes are UNCHANGED by the cure (explicit bg).
      def test_generic_bg_pending_arm_stays_byte_frozen
        @transcript.enqueue_pending_tool_block("grep", {})
        flush

        assert_equal ["", "  ⎿ grep", ""], texts.drop(1), "the pending shape"
        assert_equal [Theme[:tool_pending_bg]], bgs, "the pending bg only"
      end

      # AC2/AC4: the edit dispatch settles from the call's details — the
      # pending block replaced IN PLACE with the EditBlock family (no ⎿
      # row, the diff from the details, the success bg).
      def test_edit_block_dispatch_settles_from_the_call_details
        args = { "path" => "f.txt" }
        @transcript.enqueue_pending_tool_block("edit", args)
        flush
        pending_size = @transcript.lines.size

        details = { diff: "-1 line two bravo\n+1 line two charlie", patch: "", firstChangedLine: 1 }
        @transcript.finalize_tool_block("edit", args, "Successfully replaced 1 block(s) in f.txt.", nil,
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
        @transcript.enqueue_pending_tool_block("edit", { "path" => "f.txt" })
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
