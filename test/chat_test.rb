# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/mock_llm_server"
require "stringio"
require "tmpdir"
require "fileutils"

module Tart
  # The interactive chat surface (AC1-AC10): the fullscreen three-area
  # composition — transcript buffer tail, edit box with the status line in
  # its top border, footer — with streaming markdown render, buffer-backed
  # scrollback, input line, MOTD, and /new — hermetic via the headless
  # fullscreen test terminal (render, buffer readback) and ScriptedSession
  # + MockLLMServer (kernel-driven input/interrupt; the real test terminal
  # cannot feed the poller without a tty — I01 finding). The approval UI
  # is deleted (I14 AC1 — pi has no permissions system).
  class ChatTest < Test
    def setup
      @dir = Dir.mktmpdir("tart-chat-")
      @commands_output = []
    end

    def teardown
      FileUtils.rm_rf(@dir)
      @server&.stop
    end

    # --- render model (headless fullscreen test terminal, buffer readback) ---

    def test_streaming_deltas_grow_the_live_region
      with_chat do |chat, session|
        stream(chat, "hel")
        draw(chat, session)
        assert_includes live_region(session, chat), "hel"

        stream(chat, "lo", start: false)
        draw(chat, session)
        assert_includes live_region(session, chat), "hello",
          "the live region must grow with the deltas"
      end
    end

    def test_completed_message_lands_above_the_live_region_wrapped
      with_chat(width: 12) do |chat, session|
        stream(chat, "aaaa bbbb cccc dddd")
        finish_message(chat, "aaaa bbbb cccc dddd")
        draw(chat, session)

        # The completed message is in the buffer; the editor's input line
        # sits in the docked editor area below it. Every content row carries
        # pi's outputPad (I16) — the wrap hits the content width (width
        # minus paddingX both sides, markdown.ts:289).
        assert_equal [" aaaa bbbb", " cccc dddd"], transcript_lines(session, chat),
          "the completed text lands above the live region, wrapped to the content width"
        assert_equal [:reversed], session.cell_modifiers(0, input_row(session)),
          "the input line stays in the editor area (the empty line's fake cursor)"
      end
    end

    # Streaming reasoning (I13, pi assistant-message.ts:99-175): reasoning
    # deltas render dim (thinkingText, italic) above the live content while
    # it grows.
    def test_streaming_reasoning_renders_dim_above_the_live_content
      with_chat(width: 18) do |chat, session|
        chat.on_agent_event({type: :message_start, message: ChunkDouble.new})
        chat.on_agent_event({type: :message_update, chunk: thinking_chunk("pondering")})
        draw(chat, session)
        y = session.buffer_content.index { |row| row.include?("pondering") }
        x = session.buffer_content[y].index("p")
        assert_equal Theme[:thinkingText], session.cell_fg(x, y), "reasoning renders in the thinkingText token"
        assert_includes session.cell_modifiers(x, y), :italic

        chat.on_agent_event({type: :message_update, chunk: ChunkDouble.new("answer")})
        draw(chat, session)
        live = live_region(session, chat)
        assert live.index("pondering") < live.index("answer"), "reasoning renders before the live content"
      end
    end

    # At completion the joined thinking renders as a dim block BEFORE the
    # content in the transcript (pi assistant-message.ts render order;
    # no toggle/collapse — itemized cut). Text source: the live reasoning
    # buffer — the loop strips Message#thinking before :message_end.
    def test_completed_reasoning_lands_dim_before_the_content
      with_chat(width: 14) do |chat, session|
        chat.on_agent_event({type: :message_start, message: ChunkDouble.new})
        chat.on_agent_event({type: :message_update, chunk: thinking_chunk("pondering")})
        chat.on_agent_event({type: :message_update, chunk: ChunkDouble.new("hi")})
        chat.on_agent_event({type: :message_end, message: MessageDouble.new(:assistant, "hi")})
        draw(chat, session)

        lines = transcript_lines(session, chat)
        assert_equal [" pondering", " hi"], lines,
          "the thinking block lands in the transcript before the content, cleared from the live region"
        y = session.buffer_content.index { |row| row.include?("pondering") }
        x = session.buffer_content[y].index("p")
        assert_equal Theme[:thinkingText], session.cell_fg(x, y)
        assert_includes session.cell_modifiers(x, y), :italic
      end
    end

    # The live region renders the assistant message's SETTLED shape from
    # the first delta (pi updateContent runs while streaming — the leading
    # Spacer is a component child, not a completion-time insert): the
    # completed message occupies the row it streamed on, no 2nd-pass blank
    # shift.
    def test_completion_does_not_shift_the_streaming_content
      with_chat(width: 20, screen_height: 12) do |chat, session|
        send_message(chat, "hi")
        draw(chat, session)
        stream(chat, "hello")
        draw(chat, session)
        live_row = session.buffer_content.index { |row| row.include?("hello") }
        assert_equal "", session.buffer_content[live_row - 1].rstrip,
          "the leading blank rides the live region from the first delta"

        finish_message(chat, "hello")
        draw(chat, session)
        settled_row = session.buffer_content.index { |row| row.include?("hello") }
        assert_equal live_row, settled_row, "the completed message keeps its streamed row"
      end
    end

    # The between-runs blank (pi assistant-message.ts:172-174 — the Spacer
    # when content follows thinking) materializes when the content STARTS,
    # not at completion.
    def test_live_region_inserts_the_reasoning_content_blank_when_content_starts
      with_chat(width: 18, screen_height: 12) do |chat, session|
        chat.on_agent_event({type: :message_start, message: ChunkDouble.new})
        chat.on_agent_event({type: :message_update, chunk: thinking_chunk("pondering")})
        draw(chat, session)
        reasoning_row = session.buffer_content.index { |row| row.include?("pondering") }
        assert_equal "", session.buffer_content[reasoning_row - 1].rstrip, "the leading blank precedes the reasoning"

        chat.on_agent_event({type: :message_update, chunk: ChunkDouble.new("answer")})
        draw(chat, session)
        content_row = session.buffer_content.index { |row| row.include?("answer") }
        assert_equal "", session.buffer_content[content_row - 1].rstrip,
          "a blank separates the thinking run from the content while streaming"
      end
    end

    # The panel backgrounds survive the scrollbar overlay (the owner's
    # scrolling finding): the overlay clips every row to width−1, and the
    # trimmed fill spans must keep their bg (the full-width paddingY
    # blanks were the visible casualties).
    def test_panel_backgrounds_survive_the_scrollbar_overlay
      with_chat(width: 20, screen_height: 12) do |chat, session|
        send_message(chat, "hi")
        10.times { |i| finish_message(chat, "line#{i}") }
        draw(chat, session) # settle: the buffer flushes, follow pins to the end
        chat.scrollbar_hide_delay_ms = 10_000 # fresh for the duration of the test — no real sleeps
        wheel_to_top(chat) # scroll to the top; the echo is on screen
        draw(chat, session)
        assert_equal "│", session.cell_symbol(19, 3), "the rail is visible (the overlay is what clipped the bg away)"

        echo_top = session.buffer_content.index { |row| row.include?("hi") }
        assert_equal Theme[:user_message_bg], session.cell_bg(0, echo_top),
          "the echo's content row keeps the panel bg under the overlay"
        assert_equal Theme[:user_message_bg], session.cell_bg(0, echo_top - 1),
          "the echo's paddingY blank row keeps the panel bg (the full-width bg span clips)"
      end
    end

    # Spacing (item 2/AC2, pi assistant-message.ts:103-105, :172-174): a
    # blank sits between the reasoning block and the content when content
    # follows; a reasoning-only message gets NO trailing blank. Raw
    # readback — chat.transcript_lines keeps the blank rows.
    def test_blank_line_between_the_reasoning_block_and_the_content
      with_chat(width: 14) do |chat, session|
        chat.on_agent_event({type: :message_start, message: ChunkDouble.new})
        chat.on_agent_event({type: :message_update, chunk: thinking_chunk("pondering")})
        chat.on_agent_event({type: :message_update, chunk: ChunkDouble.new("hi")})
        chat.on_agent_event({type: :message_end, message: MessageDouble.new(:assistant, "hi")})
        draw(chat, session)

        assert_equal ["", " pondering", "", " hi"], chat.transcript_lines,
          "leading blank + reasoning + separator + content (pi updateContent order)"
      end
    end

    def test_reasoning_only_message_gets_no_trailing_blank
      with_chat(width: 14) do |chat, session|
        chat.on_agent_event({type: :message_start, message: ChunkDouble.new})
        chat.on_agent_event({type: :message_update, chunk: thinking_chunk("pondering")})
        chat.on_agent_event({type: :message_end, message: MessageDouble.new(:assistant, "")})
        draw(chat, session)

        assert_equal ["", " pondering"], chat.transcript_lines,
          "the reasoning-only message ends at the reasoning block (pi :172-174 gates the spacer on content)"
      end
    end

    # Between-item rule (item 7/AC2, pinned in PHASE 0: pi
    # assistant-message.ts:103-105 — every assistant message with visible
    # content opens with a blank line).
    def test_completed_assistant_messages_are_separated_by_a_blank_line
      with_chat do |chat, session|
        finish_message(chat, "one")
        finish_message(chat, "two")
        draw(chat, session)

        assert_equal ["", " one", "", " two"], chat.transcript_lines,
          "each assistant message opens with the blank line (the between-item separation)"
      end
    end

    # End-to-end through the real gem chunk shape (mock server reasoning
    #_content deltas — the gem parses them into chunk.thinking.text).
    def test_reasoning_streams_dim_through_the_real_gem_chunks
      @server = MockLLMServer.new.start
      @server.script([{type: :stream, reasoning_content: "pondering deeply", content: "done"}])
      kernel, chat, session = chat_with_server

      scenario = Thread.new do
        type(session, "hi")
        wait_until { chat.transcript_lines.join.include?("done") }
        kernel.stop!
      end
      kernel.run
      scenario.join

      lines = chat.transcript_lines
      assert lines.index { |line| line.include?("pondering deeply") } < lines.index { |line| line.include?("done") },
        "the joined thinking renders before the content (pi assistant-message.ts order)"
    end

    def test_tool_call_lifecycle_is_rendered
      with_chat(width: 40) do |chat, session|
        chat.on_agent_event({type: :agent_start})
        tool_start(chat, "grep")
        draw(chat, session)
        assert_includes editor_area(session, chat), "Working",
          "the border status is pi's constant working message while the tool runs"

        tool_end(chat, "grep", "done\nmore")
        draw(chat, session)
        assert_equal [:reversed], session.cell_modifiers(0, input_row(session)),
          "input line visible after tool end (the empty line's fake cursor)"
        # transcript_lines strips per-row whitespace (buffer rows are padded).
        assert_equal ["  ⎿ grep: done", "    more"], transcript_lines(session, chat),
          "the tool result lifecycle renders into the transcript as a multi-line excerpt"
      end
    end

    def test_tool_result_preview_is_bounded_multiline
      with_chat(width: 40) do |chat, session|
        tool_start(chat, "grep")
        tool_end(chat, "grep", "one\ntwo\nthree\nfour\nfive")
        draw(chat, session)
        assert_equal ["  ⎿ grep: one", "    two", "    three", "    …"], transcript_lines(session, chat),
          "the preview shows a bounded multi-line excerpt, then an ellipsis"
      end
    end

    # The style vocabulary (AC3): line kinds are distinguished by fg color
    # through the theme, proven by cell readback on the headless terminal
    # (not presence-greps).
    def test_user_assistant_tool_and_status_lines_read_back_distinct_fg_colors
      # screen_height 16: the generic tool block's paddingY panel rows
      # (pi Text(1,1)) take two more rows than the pre-panel shape.
      with_chat(width: 40, screen_height: 16) do |chat, session|
        chat.on_agent_event({type: :agent_start})
        stream(chat, "streaming")
        draw(chat, session)
        # The status renders in the editor's top border (after the corner
        # glyph) — scan cells, not lead cells. I37: the WORKING status's
        # spinner AND message ride the editor border color (pi's embedded
        # colorFn, interactive-mode.ts:2346-2359 — not the base border
        # title's dim); this fixture is non-reasoning → the off token.
        assert fg_cell?(session, ->(symbol, _x, _y) { Render::Chat::SPINNER.include?(symbol) }, Theme[:thinking_off]),
          "the working status renders the editor border color"

        finish_message(chat, "assistant answer") # transcript: assistant, terminal default
        tool_end(chat, "grep", "tool output")    # transcript: tool, muted
        chat.on_agent_event({type: :agent_end})
        "hi".each_char { |char| chat.on_event(TUI.key_event(char)) }
        chat.on_event(TUI.key_event("enter"))    # transcript: user echo
        draw(chat, session)

        leads = lead_cells(session)
        assert_includes leads, ["a", nil],
          "assistant prose renders the TERMINAL DEFAULT (pi's default-token resolution; the -e capture's plain emission)"
        assert_includes leads, ["⎿", Theme[:tool_output]],
          "the generic tool line renders the toolOutput token (muted var)"
        assert_includes leads, ["h", Theme[:user_message_text]],
          "the user echo renders userMessageText (dark.json:32 — text #dee0e1 on the bg panel)"
        # The input row's lead cell (column 0 — pi's full-width editor)
        # keeps the terminal default, visually apart from the colored echo.
        assert_nil session.cell_fg(0, input_row(session)),
          "the input line keeps the terminal default"
      end
    end

    # --- the time-gated spinner + the status spans/colors (I37, pi
    # loader.ts + interactive-mode.ts:2346-2359): the glyph derives from
    # the injected clock at render — renders alone never move it — and
    # the working status rides the editor border color while the
    # compaction indicator keeps its constructor defaults. ---

    def test_spinner_advances_on_time_not_renders
      now = 0.0
      with_chat(width: 40, clock: -> { now }) do |chat, session|
        chat.on_agent_event({type: :agent_start})
        stream(chat, "hi")
        draw(chat, session)
        assert_equal "⠋", status_spinner_glyph(session), "t=0 renders frame 0"

        now = 0.040
        draw(chat, session)
        assert_equal "⠋", status_spinner_glyph(session),
          "two renders within 80ms of the anchor show the SAME frame"

        now = 0.081
        draw(chat, session)
        assert_equal "⠙", status_spinner_glyph(session), "frame 1 at +81ms"

        now = 0.160
        draw(chat, session)
        assert_equal "⠹", status_spinner_glyph(session), "frame 2 (SPINNER[2]) at +160ms — exactly floor(160ms/80ms)"

        3.times { draw(chat, session) }
        assert_equal "⠹", status_spinner_glyph(session),
          "repeated renders without clock advance never move the glyph (the render counter is gone)"
      end
    end

    def test_spinner_reanchors_at_every_status_kind_restart
      now = 10.0
      with_chat(width: 40, clock: -> { now }) do |chat, session|
        chat.on_agent_event({type: :agent_start})
        now = 10.40 # mid-working, a late frame: floor(0.40/0.08) % 10 = 5
        draw(chat, session)
        assert_equal "⠴", status_spinner_glyph(session), "the late frame shows"

        chat.on_agent_event({type: :compaction_start, reason: :threshold})
        draw(chat, session)
        assert_equal "⠋", status_spinner_glyph(session),
          "compaction_start re-anchors (pi constructs a new Loader — frame 0)"

        chat.on_agent_event({type: :compaction, reason: :threshold, tokens_before: 100, summary: "s", entries: []})
        draw(chat, session)
        assert_equal "⠋", status_spinner_glyph(session),
          "the :compaction result re-anchors again (pi clearStatusIndicator → the next working indicator restarts)"
      end
    end

    def test_working_status_spans_read_the_editor_border_color
      now = 0.0
      with_chat(width: 40, clock: -> { now }) do |chat, session|
        chat.on_agent_event({type: :agent_start})
        draw(chat, session)
        y = status_border_row_index(session)
        assert_equal Theme[:thinking_off], session.cell_fg(3, y),
          "the spinner cell rides the editor border color (off-default fixture)"
        assert_equal Theme[:thinking_off], session.cell_fg(session.buffer_content[y].index("Working"), y),
          "the message cell rides it too (pi's embedded colorFn overrides both constructor defaults)"
      end
    end

    # pi updateEditorBorderColor in bash mode (:4516-4518): the embedded
    # working status rides the bashMode token too (the colorFn reads
    # editor.borderColor, not the ladder).
    def test_working_status_reads_the_bash_mode_token_in_bash_mode
      now = 0.0
      with_chat(width: 40, clock: -> { now }) do |chat, session|
        "!ech".each_char { |char| chat.on_event(TUI.key_event(char)) }
        chat.on_agent_event({type: :agent_start})
        draw(chat, session)
        y = status_border_row_index(session)
        assert_equal Theme[:bashMode], session.cell_fg(3, y),
          "the spinner cell rides the bashMode border color in bash mode"
        assert_equal Theme[:bashMode], session.cell_fg(session.buffer_content[y].index("Working"), y),
          "the message cell rides it too"
      end
    end

    def test_working_status_recolors_with_a_mid_turn_thinking_level_change
      now = 0.0
      with_chat(width: 40, clock: -> { now },
        footer_data: {cwd: @dir, model: "m", context_window: 1000, reasoning: true}) do |chat, session|
        chat.on_agent_event({type: :agent_start})
        chat.set_thinking_level("high")
        draw(chat, session)
        y = status_border_row_index(session)
        assert_equal Theme[:thinking_high], session.cell_fg(3, y), "the set level's ladder token"
        assert_equal Theme[:thinking_high], session.cell_fg(session.buffer_content[y].index("Working"), y),
          "both cells take the ladder token"

        chat.set_thinking_level("low") # mid-turn — pi's lazy borderColor deref
        draw(chat, session)
        assert_equal Theme[:thinking_low], session.cell_fg(3, y),
          "the same status recolors on the next draw"
        assert_equal Theme[:thinking_low], session.cell_fg(session.buffer_content[y].index("Working"), y)
      end
    end

    def test_compaction_status_reads_accent_spinner_and_muted_message
      now = 0.0
      with_chat(width: 40, clock: -> { now }) do |chat, session|
        chat.on_agent_event({type: :compaction_start, reason: :threshold})
        draw(chat, session)
        y = status_border_row_index(session)
        row = session.buffer_content[y]
        assert_includes row, "Auto-compacting...", "COMPACTION_LABELS text unchanged"
        assert_equal Theme[:accent], session.cell_fg(3, y),
          "the compaction spinner keeps the accent constructor default (no colorFn)"
        assert_equal Theme[:muted], session.cell_fg(row.index("Auto-compacting..."), y),
          "the compaction message keeps the muted constructor default"
      end
    end

    def test_working_border_row_matches_pis_single_space_layout
      now = 0.0
      with_chat(width: 40, clock: -> { now }) do |chat, session|
        chat.on_agent_event({type: :agent_start})
        draw(chat, session)
        assert_equal "── ⠋ Working #{"─" * 27}", status_border_row(session).rstrip,
          "── ⠋ Working + ONE space + dashes to width (pi custom-editor.ts:60-66 — the double flanks are gone)"
      end
    end

    def test_narrow_width_degrades_the_status_to_the_spinner_alone
      now = 0.0
      with_chat(width: 8, clock: -> { now }) do |chat, session|
        chat.on_agent_event({type: :agent_start})
        draw(chat, session)
        assert_equal "───⠋────", status_border_row(session).rstrip,
          "width < status + 5: the spinner alone between dashes (pi renderSpinnerInBorder, custom-editor.ts:66-67)"
        assert_equal Theme[:thinking_off], session.cell_fg(3, status_border_row_index(session)),
          "the lone glyph rides the spinner's color"
      end
    end

    def test_label_collision_degrades_the_status_to_the_spinner_alone
      now = 0.0
      with_chat(width: 24, screen_height: 12, clock: -> { now }) do |chat, session|
        "abcdefghi".each_char do |char|
          chat.on_event(TUI.key_event(char))
          chat.on_event(TUI.key_event("enter", modifiers: ["shift"])) unless char == "i"
        end
        chat.on_agent_event({type: :agent_start})
        draw(chat, session)
        y = session.buffer_content.index { |row| row.include?("⠋") } # the box grew — find the border row
        row = session.buffer_content[y]
        assert_includes row, "↑ 4 more", "the centered label renders"
        refute_includes row, "Working", "the full status degraded to the spinner alone (pi canFitOverflow refit)"
        assert_equal "── ⠋ ── ↑ 4 more ───────", row.rstrip, "pi's degraded centered form"
        assert_equal Theme[:thinking_off], session.cell_fg(row.index("⠋"), y), "the degraded glyph keeps the spinner's color"
      end
    end

    # The user echo's background (item 4, pi user-message.ts:40-51): the
    # echo rows carry the userMessageBg truecolor background.
    def test_user_echo_renders_the_userMessageBg_background
      with_chat(width: 40) do |chat, session|
        send_message(chat, "hi")
        draw(chat, session)
        y = buffer_row(chat, "hi")
        x = session.buffer_content[y].index("h")
        assert_equal Theme[:user_message_text], session.cell_fg(x, y)
        assert_equal Theme[:user_message_bg], session.cell_bg(x, y),
          "the echo renders userMessageText on the userMessageBg panel (dark.json:32-33 — the full-width Markdown block)"
      end
    end

    # Region padding (item 5/AC5, PHASE 0 rule set: user echo only when
    # the container is non-empty (interactive-mode.ts:3930-3931), tool
    # blocks unconditional (tool-execution.ts:85), compaction summaries
    # (:3903-3904), assistant messages with visible content
    # (assistant-message.ts:103-105) — raw readback keeps the blanks).
    def test_leading_blank_separates_every_scrollback_region
      with_chat(width: 40) do |chat, session|
        send_message(chat, "hi")                             # echo: container empty → no blank
        chat.on_agent_event({type: :message_start, message: ChunkDouble.new})
        chat.on_agent_event({type: :message_update, chunk: thinking_chunk("pondering")})
        chat.on_agent_event({type: :message_update, chunk: ChunkDouble.new("answer")})
        chat.on_agent_event({type: :message_end, message: MessageDouble.new(:assistant, "answer")})
        tool_end(chat, "grep", "done\nmore")                 # tool block (non-bash shape)
        send_message(chat, "again")                          # echo: container non-empty → blank
        finish_message(chat, "second")                       # assistant
        draw(chat, session) # the frame's flush moves every region into the buffer

        assert_equal ["", " hi", "", "", " pondering", "", " answer", "", "", "  ⎿ grep: done", "    more", "", "", "", " again", "", "", " second"],
          chat.transcript_lines,
          "pi's region padding: the first echo rides its padY wrap (no container spacer), later regions get the spacer + pad rows"
      end
    end

    # The bash tool block (I17, AC3 — pi's shell renderer over the
    # tool-turn component, bash.ts:31-149 + tool-execution.ts:85,87):
    # the capture's rows 11-18 — tool spacer, render-box pad, the bold
    # bashMode `$ <command>` header, blank, muted output, blank, muted
    # Took, box pad. `duration:` rides the frozen :tool_execution_end
    # contract (Float seconds; 0.0 legitimate).
    def test_bash_tool_block_renders_pis_shell_shapes
      with_chat(width: 40) do |chat, session|
        tool_end(chat, "bash", "pty-tester", duration: 0.0, arguments: {"command" => "echo pty-tester"})
        draw(chat, session)

        assert_equal ["", "", " $ echo pty-tester", "", " pty-tester", "", " Took 0.0s", ""],
          chat.transcript_lines,
          "the capture's rows 11-18: spacer, box pad, header, blank, output, blank, Took, box pad"
        # Cell reads scan the buffer (the 9-row transcript scrolls on the
        # 7-row viewport — transcript index ≠ buffer row).
        rows = session.buffer_content
        header = rows.index { |row| row.include?("$ echo pty-tester") }
        x = rows[header].index("$")
        assert_equal Theme[:toolTitle], session.cell_fg(x, header),
          "the header renders the toolTitle token (bash.ts:41-44 formatShellCall — the bold-default pin was the system-theme artifact)"
        assert_includes session.cell_modifiers(x, header), :bold, "the header is bold (bash.ts:36 theme.bold)"
        out = rows.index { |row| row.start_with?(" pty-tester") }
        assert_equal Theme[:tool_output], session.cell_fg(rows[out].index("p"), out),
          "the output line renders the toolOutput token color (muted var)"
        took = rows.index { |row| row.include?("Took 0.0s") }
        assert_equal Theme[:muted], session.cell_fg(rows[took].index("T"), took),
          "the Took line renders the muted token (bash.ts:106)"
      end
    end

    # Each output line is its own muted row, blank-separated from the
    # header (bash.ts:78-84 — the output Text children's leading "\n").
    def test_bash_block_output_renders_one_muted_row_per_line
      with_chat(width: 40) do |chat, session|
        tool_end(chat, "bash", "one\ntwo", duration: 0.0, arguments: {"command" => "echo one; echo two"})
        draw(chat, session)
        assert_equal ["", "", " $ echo one; echo two", "", " one", " two", "", " Took 0.0s", ""],
          chat.transcript_lines,
          "the output lines render blank-separated from the header, one row per line"
      end
    end

    # A nil/absent duration renders no Took line (bash.ts:105 — the
    # replay path's recorded gap, itemized; never invented).
    def test_bash_block_without_duration_omits_the_took_line
      with_chat(width: 40) do |chat, session|
        tool_end(chat, "bash", "pty-tester", arguments: {"command" => "echo pty-tester"})
        draw(chat, session)
        assert_equal ["", "", " $ echo pty-tester", "", " pty-tester", ""],
          chat.transcript_lines, "no duration → no Took line"
      end
    end

    # pi bash.ts:20-28 formatDuration through the rendered Took line
    # (ms = the contract's Float seconds × 1000): <60s → %.1fs (toFixed
    # rounds — 59_960ms → "60.0s"); <60m → Xm Ys; else Xh Ym Zs.
    def test_bash_took_line_format_matches_pis_format_duration
      {
        0.0 => "0.0s", 54.9 => "54.9s", 59.96 => "60.0s",
        61.5 => "1m 1s", 3725.4 => "1h 2m 5s",
      }.each do |seconds, expected|
        with_chat(width: 40) do |chat, session|
          tool_end(chat, "bash", "", duration: seconds, arguments: {"command" => "x"})
          draw(chat, session)
          assert_includes chat.transcript_lines, " Took #{expected}",
            "formatDuration(#{seconds}s = #{seconds * 1000}ms) renders #{expected.inspect} (bash.ts:20-28)"
        end
      end
    end

    # The bash block replays through the same shapes (I17): command from
    # the recorded arguments, output from the recorded result, NO Took —
    # the recorded entries carry no duration (the frozen contract's
    # replay gap, itemized).
    def test_resume_session_replays_the_bash_block_without_a_took_line
      dir = File.join(@dir, "sessions")
      FileUtils.mkpath(dir)
      recorded = File.join(dir, "bash_replay_test-session.jsonl")
      File.write(recorded, <<~JSONL)
        {"type":"session","version":3,"id":"bash-replay","timestamp":"2026-01-01T00:00:00.000Z","cwd":"#{@dir}"}
        {"type":"message","id":"e1","parentId":null,"timestamp":"2026-01-01T00:00:01.000Z","message":{"role":"user","content":"run the echo"}}
        {"type":"message","id":"e2","parentId":"e1","timestamp":"2026-01-01T00:00:02.000Z","message":{"role":"assistant","content":"","tool_calls":{"call_1":{"id":"call_1","name":"bash","arguments":{"command":"echo pty-tester"}}},"finish_reason":"tool_calls","input_tokens":10,"output_tokens":5}}
        {"type":"message","id":"e3","parentId":"e2","timestamp":"2026-01-01T00:00:03.000Z","message":{"role":"tool","content":"pty-tester","tool_call_id":"call_1"}}
      JSONL
      with_chat(width: 40, screen_height: 24) do |chat, session|
        chat.resume_session(recorded)
        draw(chat, session)
        assert_equal ["", " run the echo", "", "", "", " $ echo pty-tester", "", " pty-tester", ""],
          chat.transcript_lines.first(9),
          "the bash block replays through pi's shapes (header + blank + output); the recorded duration gap keeps no Took"
        refute chat.transcript_lines.any? { |row| row.include?("Took") }, "no invented duration on replay"
      end
    end

    # pi bash.ts:14,78-90 + visual-truncate.ts VisualLinePreview (keep
    # "end"): 12 lines collapse to the muted earlier-lines hint row + the
    # LAST 5 lines (the s4 shape — "... (7 earlier lines, ctrl+o to
    # expand)"); the ctrl+o binding itself is cut (backlog C).
    def test_bash_block_collapses_to_the_last_five_lines_plus_the_earlier_lines_hint
      output = Array.new(12) { |i| (i + 1).to_s }.join("\n")
      with_chat(width: 40, screen_height: 30) do |chat, session|
        tool_end(chat, "bash", output, duration: 0.0, arguments: {"command" => "seq 1 12"})
        draw(chat, session)

        assert_equal(
          ["", "", " $ seq 1 12", "", " ... (7 earlier lines, ctrl+o to expand)"] +
            Array.new(5) { |i| " #{i + 8}" } + ["", " Took 0.0s", ""],
          chat.transcript_lines,
          "the hint row rides before the last 5 lines (bash.ts:82-84 VisualLinePreview keep end)"
        )
        hint = session.buffer_content.index { |row| row.include?("earlier lines") }
        assert_equal Theme[:muted], session.cell_fg(1, hint),
          "the hint prefix renders the muted token (keyHint's description run)"
        key = session.buffer_content[hint].index("ctrl+o")
        assert_equal Theme[:dim], session.cell_fg(key, hint),
          "the ctrl+o key renders the dim token (keybinding-hints.ts:43 keyText)"
      end
    end

    # Exactly 5 lines render whole — no collapse, no hint (pi
    # truncateToVisualLines: allVisualLines <= maxVisualLines → no skip).
    def test_bash_block_renders_whole_at_exactly_five_lines
      output = Array.new(5) { |i| "line #{i + 1}" }.join("\n")
      with_chat(width: 40) do |chat, session|
        tool_end(chat, "bash", output, duration: 0.0, arguments: {"command" => "seq 1 5"})
        draw(chat, session)

        assert_equal(["", "", " $ seq 1 5", ""] + Array.new(5) { |i| " line #{i + 1}" } + ["", " Took 0.0s", ""],
                     chat.transcript_lines, "5 lines render in full, no hint row")
        refute chat.transcript_lines.any? { |row| row.include?("earlier lines") }, "no hint at the boundary"
      end
    end

    # Exactly 6 lines hints ONE earlier line — pi's singular-agnostic
    # bytes "(1 earlier lines," (bash.ts:83, no pluralization branch).
    def test_bash_block_hints_one_earlier_line_at_exactly_six_lines
      output = Array.new(6) { |i| "line #{i + 1}" }.join("\n")
      with_chat(width: 40) do |chat, session|
        tool_end(chat, "bash", output, duration: 0.0, arguments: {"command" => "seq 1 6"})
        draw(chat, session)

        assert_equal(["", "", " $ seq 1 6", "", " ... (1 earlier lines, ctrl+o to expand)"] +
                     Array.new(5) { |i| " line #{i + 2}" } + ["", " Took 0.0s", ""],
                     chat.transcript_lines, "the 6th line over the boundary hints 1 earlier line")
      end
    end

    # The preview counts VISUAL rows, not logical lines (visual-truncate.ts
    # truncateToVisualLines over the wrapped Text render): one long line
    # wrapping across the screen consumes multiple preview rows.
    def test_bash_block_collapse_counts_wrapped_visual_rows
      long_line = "x" * 100 # content width 38 → 3 wrapped rows
      output = [long_line, "a", "b", "c"].join("\n") # 6 visual rows
      with_chat(width: 40) do |chat, session|
        tool_end(chat, "bash", output, duration: 0.0, arguments: {"command" => "echo"})
        draw(chat, session)

        rows = chat.transcript_lines
        assert_equal " ... (1 earlier lines, ctrl+o to expand)", rows[4],
          "6 visual rows (3 wrapped + 3 short) hide exactly one"
        assert_equal [" a", " b", " c"], rows[7, 3], "the short tail rows are kept"
        assert_equal 2, rows.count { |row| row.include?("x" * 24) },
          "exactly two wrapped x-rows survive (the last wrapped rows, keep end)"
      end
    end

    # Trailing blank lines die at the trim before the preview (pi bash.ts:63
    # getTextOutput().trim() — VisualLinePreview itself trims nothing), so
    # they never pad the kept tail nor inflate the hidden count.
    def test_bash_block_trailing_blank_lines_trim_before_the_collapse
      output = (Array.new(8) { |i| "line #{i + 1}" }.join("\n") + "\n\n\n")
      with_chat(width: 40) do |chat, session|
        tool_end(chat, "bash", output, duration: 0.0, arguments: {"command" => "seq"})
        draw(chat, session)

        assert_equal [" ... (3 earlier lines, ctrl+o to expand)"] +
                     Array.new(5) { |i| " line #{i + 4}" },
          chat.transcript_lines[4, 6],
          "8 real lines collapse after the trim; the trailing blanks count nothing"
      end
    end

    # pi bash.ts:65-71 — the model-facing truncation footer splits OFF the
    # preview: the body collapses, the notice rows follow. The DISPLAYED
    # notice is pi's warnings composition (renderers/bash.ts:88-99 —
    # `[Full output: <path>. Truncated: showing N of M lines]`, joined on
    # one line, path FIRST), recomposed from the model footer's shape.
    def test_bash_block_truncation_notice_follows_the_collapsed_block
      output = Array.new(8) { |i| "line #{i + 1}" }.join("\n") +
               "\n\n[Showing lines 5-8 of 8. Full output: /tmp/full.txt]"
      with_chat(width: 40) do |chat, session|
        tool_end(chat, "bash", output, arguments: {"command" => "big"})
        draw(chat, session)

        assert_equal(
          ["", "", " $ big", "", " ... (3 earlier lines, ctrl+o to expand)"] +
            Array.new(5) { |i| " line #{i + 4}" } +
            ["", " [Full output: /tmp/full.txt.", " Truncated: showing 4 of 8 lines]", ""],
          chat.transcript_lines,
          "the notice is not swallowed into the kept five — it renders after the collapsed body"
        )
      end
    end

    # The bytes variant composes pi's else-branch warnings
    # (renderers/bash.ts:94-96): `Truncated: N lines shown (<limit> limit)`
    # — outputLines again, the limit carried from the footer.
    def test_bash_truncation_notice_bytes_variant_composes_the_shown_count
      output = Array.new(8) { |i| "line #{i + 1}" }.join("\n") +
               "\n\n[Showing lines 5-8 of 8 (50.0KB limit). Full output: /tmp/full.txt]"
      with_chat(width: 80) do |chat, session|
        tool_end(chat, "bash", output, arguments: {"command" => "big"})
        draw(chat, session)

        assert chat.transcript_lines.include?(" [Full output: /tmp/full.txt. Truncated: 4 lines shown (50.0KB limit)]"),
          "the bytes variant composes pi's `lines shown` warnings — got #{chat.transcript_lines.compact.reject(&:empty?).last.inspect}"
      end
    end

    # The partial-line footer ("Showing last … of line N") carries no
    # output-line count — the display renders it as-is (itemized
    # residual: pi composes `N lines shown` from the structured details
    # the port's render layer cannot see).
    def test_bash_truncation_notice_partial_line_footer_renders_as_is
      footer = "[Showing last 50.0KB of line 8 (line is 50.1KB). Full output: /tmp/full.txt]"
      output = Array.new(8) { |i| "line #{i + 1}" }.join("\n") + "\n\n#{footer}"
      with_chat(width: 120) do |chat, session|
        tool_end(chat, "bash", output, arguments: {"command" => "big"})
        draw(chat, session)

        assert chat.transcript_lines.include?(" #{footer}"),
          "the partial-line footer renders as-is — got #{chat.transcript_lines.compact.reject(&:empty?).last.inspect}"
      end
    end

    # The notice's fg (AC6, the I19 carry-forward): pi renders the
    # model-facing truncation notice in the warning fg (bash.ts:88-99
    # theme.fg("warning", ...)), not the inherited tool_output.
    def test_bash_truncation_notice_renders_the_warning_fg
      output = Array.new(8) { |i| "line #{i + 1}" }.join("\n") +
               "\n\n[Showing lines 5-8 of 8. Full output: /tmp/full.txt]"
      with_chat(width: 40) do |chat, session|
        tool_end(chat, "bash", output, arguments: {"command" => "big"})
        draw(chat, session)

        y = session.buffer_content.index { |row| row.include?("Full output") }
        assert_equal Theme[:warning], session.cell_fg(1, y),
          "the truncation notice renders pi's warning fg (bash.ts:88-99)"
      end
    end

    # The replay path shares enqueue_bash_block (I17's shape-sharing
    # ruling): the recorded 12-line output collapses through the same
    # rows, no Took (the recorded duration gap).
    def test_resume_session_replays_the_collapsed_bash_preview
      dir = File.join(@dir, "sessions")
      FileUtils.mkpath(dir)
      recorded = File.join(dir, "bash_collapse_replay_test-session.jsonl")
      lines = Array.new(12) { |i| (i + 1).to_s }.join("\\n")
      File.write(recorded, <<~JSONL)
        {"type":"session","version":3,"id":"bash-collapse","timestamp":"2026-01-01T00:00:00.000Z","cwd":"#{@dir}"}
        {"type":"message","id":"e1","parentId":null,"timestamp":"2026-01-01T00:00:01.000Z","message":{"role":"user","content":"seq it"}}
        {"type":"message","id":"e2","parentId":"e1","timestamp":"2026-01-01T00:00:02.000Z","message":{"role":"assistant","content":"","tool_calls":{"call_1":{"id":"call_1","name":"bash","arguments":{"command":"seq 1 12"}}},"finish_reason":"tool_calls","input_tokens":10,"output_tokens":5}}
        {"type":"message","id":"e3","parentId":"e2","timestamp":"2026-01-01T00:00:03.000Z","message":{"role":"tool","content":"#{lines}","tool_call_id":"call_1"}}
      JSONL
      with_chat(width: 40, screen_height: 24) do |chat, session|
        chat.resume_session(recorded)
        draw(chat, session)

        hint = chat.transcript_lines.index { |row| row.include?("earlier lines") }
        assert_equal [" ... (7 earlier lines, ctrl+o to expand)", " 8", " 9", " 10", " 11", " 12"],
          chat.transcript_lines[hint, 6],
          "the replayed block collapses through the same enqueue_bash_block rows"
        refute chat.transcript_lines.any? { |row| row.include?("Took") }, "no invented duration on replay"
      end
    end

    # ---- the write/read tool blocks (I18 — pi write.ts/read.ts
    # renderers over the tool-turn component). ----

    # The capture's rows 11-16: spacer, box pad, the bold toolTitle
    # `write` + renderToolPath header, blank, the content as toolOutput
    # rows, box pad. The SUCCESS result renders NOTHING (write.ts:128-143
    # — formatWriteResult is undefined unless error), so the block is the
    # call side alone.
    def test_write_tool_block_renders_pis_write_shapes
      with_chat(width: 40) do |chat, session|
        tool_end(chat, "write", "Successfully wrote to s3-tool-turn-note.txt",
                 arguments: {"path" => "s3-tool-turn-note.txt", "content" => "parity s3 sandbox note"})
        draw(chat, session)

        assert_equal ["", "", " write s3-tool-turn-note.txt", "", " parity s3 sandbox note", ""],
          chat.transcript_lines,
          "the capture's rows 11-16: spacer, box pad, header, blank, content, box pad — NO result row on success"
        rows = session.buffer_content
        header = rows.index { |row| row.include?("write s3-tool-turn-note.txt") }
        assert_equal Theme[:toolTitle], session.cell_fg(rows[header].index("w"), header),
          "the header renders the toolTitle token (write.ts:99 — toolTitle = text #dee0e1 under dark)"
        assert_includes session.cell_modifiers(rows[header].index("w"), header), :bold,
          "the header is bold (write.ts:99 theme.bold)"
        assert_equal Theme[:accent], session.cell_fg(rows[header].index("s3-tool-turn-note.txt"), header),
          "the path renders the accent token (renderToolPath)"
        content = rows.index { |row| row.include?("parity s3 sandbox note") }
        assert_equal Theme[:tool_output], session.cell_fg(rows[content].index("p"), content),
          "the content preview renders the toolOutput token color (muted var)"
      end
    end

    # pi write.ts:113-116 — at most 10 content lines unexpanded, then the
    # muted expand-hint row (the dim key + muted text bytes; the ctrl+o
    # binding itself is cut, backlog C).
    def test_write_block_previews_ten_lines_then_the_expand_hint
      content = Array.new(12) { |i| "line #{i + 1}" }.join("\n")
      with_chat(width: 40) do |chat, session|
        tool_end(chat, "write", "ok", arguments: {"path" => "big.txt", "content" => content})
        draw(chat, session)

        assert_equal(
          ["", "", " write big.txt", ""] +
            Array.new(10) { |i| " line #{i + 1}" } +
            [" ... (2 more lines, 12 total, ctrl+o to expand)", ""],
          chat.transcript_lines,
          "ten content lines, then the expand hint row (write.ts:113-122)"
        )
      end
    end

    # pi write.ts:115 trimTrailingEmptyLines — trailing blank lines drop
    # from the preview.
    def test_write_block_trims_trailing_empty_lines
      with_chat(width: 40) do |chat, session|
        tool_end(chat, "write", "ok", arguments: {"path" => "x.txt", "content" => "hello\n\n\n"})
        draw(chat, session)
        assert_equal ["", "", " write x.txt", "", " hello", ""], chat.transcript_lines,
          "trailing empty lines are trimmed (write.ts:115 trimTrailingEmptyLines)"
      end
    end

    # An absent content arg renders the call line alone (write.ts:107 —
    # no content block).
    def test_write_block_without_content_renders_the_call_line_alone
      with_chat(width: 40) do |chat, session|
        tool_end(chat, "write", "ok", arguments: {"path" => "x.txt"})
        draw(chat, session)
        assert_equal ["", "", " write x.txt", ""], chat.transcript_lines, "no content → call line alone"
      end
    end

    # A write ERROR renders its text in the error token after a blank
    # (write.ts:128-143 formatWriteResult — the leading "\n" + error fg).
    def test_write_block_error_renders_the_error_text
      with_chat(width: 40) do |chat, session|
        tool_end(chat, "write", {error: "Permission denied"}, arguments: {"path" => "x.txt", "content" => "hi"})
        draw(chat, session)
        assert_equal ["", "", " write x.txt", "", " hi", "", " Permission denied", ""],
          chat.transcript_lines, "the error text renders after a blank (write.ts:143)"
        rows = session.buffer_content
        error_row = rows.index { |row| row.include?("Permission denied") }
        assert_equal Theme[:error], session.cell_fg(rows[error_row].index("P"), error_row),
          "the error text renders the error token (write.ts:143)"
      end
    end

    # The renderToolPath display: the ~ contraction under home
    # (render-utils.ts:10-18 shortenPath), verbatim otherwise.
    def test_write_block_path_contracts_under_home
      with_chat(width: 40) do |chat, session|
        tool_end(chat, "write", "ok", arguments: {"path" => File.join(Dir.home, "notes.txt"), "content" => "hi"})
        draw(chat, session)
        assert_includes chat.transcript_lines, " write ~/notes.txt",
          "paths under home contract to ~/ (render-utils.ts shortenPath)"
      end
    end

    # The read call line (the capture's row 19): the bold toolTitle
    # `read` + renderToolPath. The result renders NOTHING unless error or
    # expanded (read.ts:68-70) — the settled screen is the call line
    # alone, even though the result carried text.
    def test_read_tool_block_renders_pis_read_call_shape
      with_chat(width: 40) do |chat, session|
        tool_end(chat, "read", "hello\nworld", arguments: {"path" => "notes.txt"})
        draw(chat, session)
        assert_equal ["", "", " read notes.txt", ""], chat.transcript_lines,
          "the capture's row 19: the read call line alone — the unexpanded result renders nothing (read.ts:68-70)"
      end
    end

    # pi read.ts:35-42 formatReadLineRange — offset/limit reads append
    # the warning-colored :start-end range.
    def test_read_block_line_range_renders_the_warning_suffix
      with_chat(width: 40) do |chat, session|
        tool_end(chat, "read", "hello", arguments: {"path" => "notes.txt", "offset" => 5, "limit" => 10})
        draw(chat, session)
        assert_includes chat.transcript_lines, " read notes.txt:5-14",
          "the :start-end range renders (formatReadLineRange)"
        rows = session.buffer_content
        y = rows.index { |line| line.include?(":5-14") }
        assert_equal Theme[:warning], session.cell_fg(rows[y].index(":5-14"), y),
          "the range renders the warning token (read.ts:38)"
      end
    end

    # A read ERROR renders its text as toolOutput rows (read.ts:68-73 —
    # the isError path bypasses the expanded gate).
    def test_read_block_error_renders_the_error_text_as_tool_output
      with_chat(width: 40) do |chat, session|
        tool_end(chat, "read", {error: "File not found: notes.txt"}, arguments: {"path" => "notes.txt"})
        draw(chat, session)
        assert_equal ["", "", " read notes.txt", "", " File not found: notes.txt", ""],
          chat.transcript_lines, "the error text renders as tool output rows (read.ts isError path)"
      end
    end

    # pi read.ts:63-88 getCompactReadClassification — the resource names
    # collapse to the compact `read resource` shape, SKILL.md to the
    # [skill] shape, both with the dim expand hint. pi's own-package docs
    # class is cut (no pi package root in the port — itemized).
    def test_read_block_compact_resource_shapes
      # pi's Text wraps the header to the viewport (40 cols): the hint's
      # tail word moves to its own row (the wrapped_call_rows shape).
      with_chat(width: 40) do |chat, session|
        tool_end(chat, "read", "guide", arguments: {"path" => "AGENTS.md"})
        draw(chat, session)
        y = chat.transcript_lines.index { |row| row.include?("read resource") }
        assert_equal [" read resource AGENTS.md (ctrl+o to", " expand)"],
          chat.transcript_lines[y, 2],
          "AGENTS.md collapses to the compact resource shape (read.ts:79-90), wrapped"
      end
      with_chat(width: 40) do |chat, session|
        tool_end(chat, "read", "guide", arguments: {"path" => "skills/parith/SKILL.md"})
        draw(chat, session)
        y = chat.transcript_lines.index { |row| row.include?("[skill]") }
        assert chat.transcript_lines[y].start_with?(" [skill] parith (ctrl+o to expand)"),
          "SKILL.md collapses to the [skill] shape (read.ts:81-83) — fits unwrapped"
      end
    end

    # The write/read blocks replay through the same shapes (I18): path
    # and content from the recorded arguments, results from the recorded
    # entries — NO ⎿ line, NO invented duration. The recorded result is a
    # bare string, so replay cannot distinguish a write error (the same
    # gap pi's own replay has — success renders nothing either way).
    def test_resume_session_replays_the_write_and_read_blocks
      dir = File.join(@dir, "sessions")
      FileUtils.mkpath(dir)
      recorded = File.join(dir, "file_replay_test-session.jsonl")
      File.write(recorded, <<~JSONL)
        {"type":"session","version":3,"id":"file-replay","timestamp":"2026-01-01T00:00:00.000Z","cwd":"#{@dir}"}
        {"type":"message","id":"e1","parentId":null,"timestamp":"2026-01-01T00:00:01.000Z","message":{"role":"user","content":"write then read"}}
        {"type":"message","id":"e2","parentId":"e1","timestamp":"2026-01-01T00:00:02.000Z","message":{"role":"assistant","content":"","tool_calls":{"call_1":{"id":"call_1","name":"write","arguments":{"path":"note.txt","content":"parity note"}},"call_2":{"id":"call_2","name":"read","arguments":{"path":"note.txt"}}},"finish_reason":"tool_calls","input_tokens":10,"output_tokens":5}}
        {"type":"message","id":"e3","parentId":"e2","timestamp":"2026-01-01T00:00:03.000Z","message":{"role":"tool","content":"Successfully wrote to note.txt","tool_call_id":"call_1"}}
        {"type":"message","id":"e4","parentId":"e3","timestamp":"2026-01-01T00:00:04.000Z","message":{"role":"tool","content":"parity note","tool_call_id":"call_2"}}
      JSONL
      with_chat(width: 40, screen_height: 24) do |chat, session|
        chat.resume_session(recorded)
        draw(chat, session)
        assert_equal ["", " write then read", "", "", "", " write note.txt", "", " parity note", "", "", "", " read note.txt"],
          chat.transcript_lines.first(12),
          "the write and read blocks replay through pi's shapes: call + blank + content, call — no result rows"
        refute chat.transcript_lines.any? { |row| row.include?("Took") || row.include?("⎿") },
          "no invented duration, no generic ⎿ line for write/read"
      end
    end

    # --- the PENDING tool block (I34 — pi tool-execution.ts:90-91 +
    # --- updateDisplay :271-277 isPartial; the event wiring pins) ---

    # AC1: the start event enqueues the pending block and it paints on
    # the next drawn frame while the tool "runs" — the four rows (PLAIN
    # blank, pending pad, bold toolTitle header, pending pad).
    def test_pending_block_paints_mid_flight
      with_chat(width: 40) do |chat, session|
        tool_start(chat, "bash", arguments: {"command" => "sleep 6"})
        draw(chat, session)

        assert_equal ["", "", " $ sleep 6", ""], chat.transcript_lines,
          "the pending block is the call rows alone — no output, no Took, no hint"
        rows = session.buffer_content
        header = rows.index { |row| row.include?("$ sleep 6") }
        x = rows[header].index("$")
        assert_equal Theme[:tool_pending_bg], session.cell_bg(x, header),
          "the header rides the pending bg #34383a (the I26 measured bytes)"
        assert_equal Theme[:toolTitle], session.cell_fg(x, header), "the header is toolTitle"
        assert_includes session.cell_modifiers(x, header), :bold, "the header is bold"
        assert_equal Theme[:tool_pending_bg], session.cell_bg(0, header - 1), "the opening pad"
        assert_equal Theme[:tool_pending_bg], session.cell_bg(0, header + 1), "the closing pad"
      end
    end

    # AC2, drained case: start → draw → end lands the final block
    # BYTE-IDENTICAL (rows and position) to a control chat that received
    # only the end event — no pending-bg row survives.
    def test_flushed_pending_settles_byte_identical_to_the_control
      control = with_chat(width: 40, screen_height: 24) do |chat, session|
        tool_end(chat, "bash", "out", duration: 1.0, arguments: {"command" => "sleep 6"})
        draw(chat, session)
        [chat.transcript_lines, session.buffer_content]
      end
      with_chat(width: 40, screen_height: 24) do |chat, session|
        tool_start(chat, "bash", arguments: {"command" => "sleep 6"})
        draw(chat, session)
        tool_end(chat, "bash", "out", duration: 1.0, arguments: {"command" => "sleep 6"})
        draw(chat, session)

        assert_equal control[0], chat.transcript_lines, "rows and position byte-identical"
        assert_equal control[1], session.buffer_content, "the drawn frame is byte-identical"
        refute buffer_bg_hit?(session, Theme[:tool_pending_bg]), "no pending bg survives the settle"
      end
    end

    # AC2, fast path: start → end with NO draw between — the queued
    # region swaps in place, the pending rows never reach the buffer.
    def test_queued_pending_settles_byte_identical_to_the_control
      control = with_chat(width: 40, screen_height: 24) do |chat, session|
        tool_end(chat, "bash", "res", arguments: {"command" => "fast"})
        draw(chat, session)
        [chat.transcript_lines, session.buffer_content]
      end
      with_chat(width: 40, screen_height: 24) do |chat, session|
        tool_start(chat, "bash", arguments: {"command" => "fast"})
        tool_end(chat, "bash", "res", arguments: {"command" => "fast"})
        draw(chat, session)

        assert_equal control[0], chat.transcript_lines
        assert_equal control[1], session.buffer_content
        refute buffer_bg_hit?(session, Theme[:tool_pending_bg]),
          "no pending rows ever painted"
      end
    end

    # AC4: ctrl+o mid-flight corrupts neither the buffer nor the registry
    # — the constant-size builder rebuilds the pending block identically,
    # and the settled block toggles normally afterward.
    def test_ctrl_o_mid_flight_and_the_settled_toggle
      with_chat(width: 40, screen_height: 24) do |chat, session|
        tool_start(chat, "bash", arguments: {"command" => "seq 1 12"})
        draw(chat, session)
        pending_rows = chat.transcript_lines
        chat.on_event(TUI.key_event("o", modifiers: ["ctrl"]))
        draw(chat, session)

        # The toggle reports in the tail status pair (pi showStatus) — the
        # pending block itself must rebuild identically at the buffer head
        # (constant-size builder) and the registry must still resolve.
        assert_equal pending_rows, chat.transcript_lines[0, pending_rows.length],
          "the toggle rebuilds the pending block identically (constant-size builder)"
        assert chat.transcript_lines.any? { |row| row.include?("Tool output: expanded") },
          "the registry resolved (the toggle state flipped)"
        tool_end(chat, "bash", (1..12).to_a.join("\n"), arguments: {"command" => "seq 1 12"})
        draw(chat, session)
        expanded = chat.transcript_lines
        refute_includes expanded.join, "earlier lines",
          "the finalize reads the toggle state at replacement time — the flipped state rides through"
        assert_includes expanded.join, " 12", "the whole output renders expanded"

        chat.on_event(TUI.key_event("o", modifiers: ["ctrl"]))
        draw(chat, session)
        collapsed = chat.transcript_lines
        assert_includes collapsed.join, "earlier lines", "the finalized block collapses"
        assert_operator collapsed.length, :<, expanded.length

        chat.on_event(TUI.key_event("o", modifiers: ["ctrl"]))
        draw(chat, session)
        assert_equal expanded, chat.transcript_lines, "the toggle round-trips"
      end
    end

    # AC4: the orphaned pending block finalizes at :agent_end's
    # interrupted arm pi's way (interactive-mode.ts:3573-3586) — the call
    # rows + "Operation aborted" under toolErrorBg; the interrupt
    # scrollback line stays.
    def test_interrupt_finalizes_the_orphaned_pending_block
      with_chat(width: 40) do |chat, session|
        tool_start(chat, "bash", arguments: {"command" => "sleep 6"})
        draw(chat, session)
        chat.on_agent_event({type: :agent_end, interrupted: true})
        draw(chat, session)

        rows = session.buffer_content
        aborted = rows.index { |row| row.include?("Operation aborted") }
        refute_nil aborted, "the orphan finalizes with pi's abort text"
        assert_equal Theme[:tool_error_bg], session.cell_bg(rows[aborted].index("O"), aborted),
          "the error text rides toolErrorBg"
        header = rows.index { |row| row.include?("$ sleep 6") }
        assert_equal Theme[:tool_error_bg], session.cell_bg(rows[header].index("$"), header),
          "the whole block re-renders the error bg (the same component, pi's updateResult)"
        assert_includes chat.transcript_lines, "interrupted", "the interrupt scrollback line stays"
        refute buffer_bg_hit?(session, Theme[:tool_pending_bg]), "no pending bg survives"
      end
    end

    # AC4: the error arm finalizes with the error's message.
    def test_error_finalizes_the_orphaned_pending_block_with_the_message
      with_chat(width: 40) do |chat, session|
        tool_start(chat, "bash", arguments: {"command" => "sleep 6"})
        draw(chat, session)
        chat.on_agent_event({type: :agent_end, error: StandardError.new("boom")})
        draw(chat, session)

        assert_includes chat.transcript_lines.join, "boom", "the error text lands in the block"
        assert_includes chat.transcript_lines, "error: boom", "the error scrollback line stays"
        refute buffer_bg_hit?(session, Theme[:tool_pending_bg])
      end
    end

    # AC3: the replay (resume) renders final blocks only — zero
    # pending-bg spans (the pending machinery never engages).
    def test_resume_replays_render_no_pending_bg
      dir = File.join(@dir, "sessions")
      FileUtils.mkpath(dir)
      recorded = File.join(dir, "pending_replay_test-session.jsonl")
      File.write(recorded, <<~JSONL)
        {"type":"session","version":3,"id":"pending-replay","timestamp":"2026-01-01T00:00:00.000Z","cwd":"#{@dir}"}
        {"type":"message","id":"e1","parentId":null,"timestamp":"2026-01-01T00:00:01.000Z","message":{"role":"user","content":"run the sleeper"}}
        {"type":"message","id":"e2","parentId":"e1","timestamp":"2026-01-01T00:00:02.000Z","message":{"role":"assistant","content":"","tool_calls":{"call_1":{"id":"call_1","name":"bash","arguments":{"command":"sleep 6"}}},"finish_reason":"tool_calls","input_tokens":10,"output_tokens":5}}
        {"type":"message","id":"e3","parentId":"e2","timestamp":"2026-01-01T00:00:03.000Z","message":{"role":"tool","content":"slept","tool_call_id":"call_1"}}
      JSONL
      with_chat(width: 40, screen_height: 24) do |chat, session|
        chat.resume_session(recorded)
        draw(chat, session)

        assert_includes chat.transcript_lines.join, "$ sleep 6", "the final block replays"
        refute buffer_bg_hit?(session, Theme[:tool_pending_bg]), "zero pending-bg spans on replay"
      end
    end

    # AC1 per family: write/read/generic pendings are the call rows alone
    # under the pending bg (each family interrupted off first — the
    # transcript keeps only the finished blocks below).
    def test_pending_shapes_per_family
      with_chat(width: 40) do |chat, session|
        tool_start(chat, "write", arguments: {"path" => "note.txt", "content" => "parity note"})
        draw(chat, session)
        assert_equal " write note.txt", chat.transcript_lines.reject(&:empty?).last, "the write call rows alone"
        write_row = session.buffer_content.index { |r| r.include?("write note.txt") }
        assert_equal Theme[:tool_pending_bg], session.cell_bg(1, write_row)

        chat.on_agent_event({type: :agent_end, interrupted: true}) # clear the orphan for the next family
        draw(chat, session)
        tool_start(chat, "read", arguments: {"path" => "note.txt"})
        draw(chat, session)
        assert_equal " read note.txt", chat.transcript_lines.reject(&:empty?).last, "the read call rows alone"
        read_row = session.buffer_content.index { |r| r.include?("read note.txt") }
        assert_equal Theme[:tool_pending_bg], session.cell_bg(1, read_row)

        chat.on_agent_event({type: :agent_end, interrupted: true})
        draw(chat, session)
        tool_start(chat, "grep")
        draw(chat, session)
        assert_equal "  ⎿ grep", chat.transcript_lines.reject(&:empty?).last, "the generic ⎿ call line alone"
        grep_row = session.buffer_content.index { |r| r.rstrip == "  ⎿ grep" }
        assert_equal Theme[:tool_pending_bg], session.cell_bg(2, grep_row)
      end
    end

    # AC4: a sequential multi-tool turn lands both blocks in order with
    # no pending residue — byte-identical to a control chat that received
    # only the end events.
    def test_sequential_multi_tool_turn_leaves_no_residue
      control = with_chat(width: 40, screen_height: 24) do |chat, session|
        tool_end(chat, "bash", "one", arguments: {"command" => "echo one"})
        tool_end(chat, "bash", "two", arguments: {"command" => "echo two"})
        draw(chat, session)
        chat.transcript_lines
      end
      with_chat(width: 40, screen_height: 24) do |chat, session|
        tool_start(chat, "bash", arguments: {"command" => "echo one"})
        draw(chat, session)
        tool_end(chat, "bash", "one", arguments: {"command" => "echo one"})
        draw(chat, session)
        tool_start(chat, "bash", arguments: {"command" => "echo two"})
        draw(chat, session)
        tool_end(chat, "bash", "two", arguments: {"command" => "echo two"})
        draw(chat, session)

        lines = chat.transcript_lines
        assert_equal control, lines, "two settled blocks, byte-identical to the control"
        one = lines.index(" $ echo one")
        two = lines.index(" $ echo two")
        refute_nil one
        refute_nil two
        assert_operator one, :<, two, "the blocks land in call order"
        refute buffer_bg_hit?(session, Theme[:tool_pending_bg])
      end
    end

    def test_chat_runs_inside_the_seam_lifecycle_and_restores
      TUI.run(headless: true, viewport: :fullscreen, width: 40, screen_height: 12) do |session|
        chat = Render::Chat.new(session:, kernel: IdleKernel.new, motd: false)
        stream(chat, "hi")
        draw(chat, session)
        assert_includes live_region(session, chat), "hi"
      end
      refute TUI::Session.active?, "terminal restored after the chat surface exits"
    end

    # --- the fullscreen composition (AC1): transcript above, bordered
    # editor (status in its top border), footer at the bottom. ---

    # Edit-box parity (item 5/AC5, pi editor.ts:511-621 + custom-editor.ts
    # :36-77): full-width from column 0, horizontal borders ONLY, no
    # prompt char — the I11 all-around border + "❯" prompt are deleted.
    def test_edit_box_is_full_width_with_horizontal_borders_only
      with_chat(width: 40, screen_height: 12, motd: false) do |chat, session|
        "hi".each_char { |char| chat.on_event(TUI.key_event(char)) }
        draw(chat, session)
        row = input_row(session)
        buffer = session.buffer_content
        assert_equal "h", session.cell_symbol(0, row), "the input starts at column 0 (full width)"
        assert_equal "─", buffer[row - 1][0], "the top border runs from column 0"
        assert_equal "─", buffer[row + 1][0], "the bottom border runs from column 0"
        top = buffer[row - 1]
        bottom = buffer[row + 1]
        assert top.match?(/─+\z/), "no east border on the top row"
        assert bottom.match?(/─+\z/), "no west/east borders — horizontal only (pi renderTopBorder/renderBottomBorder)"
        refute_includes editor_area(session, chat), "❯", "no prompt char (pi renders the bare text)"
      end
    end

    def test_fullscreen_composition_draws_transcript_editor_and_footer
      with_chat(width: 40, screen_height: 12, footer_data: {cwd: Dir.home, model: "test-model", context_window: 1000, auto_compact: true}, branch_reader: ->(_cwd) { "main" }) do |chat, session|
        send_message(chat, "hello")
        finish_message(chat, "answer")
        draw(chat, session)

        buffer = session.buffer_content
        top = transcript_height(session, chat)
        assert_includes buffer[0, top].join, "hello", "transcript on top"
        assert_equal "", buffer[top].rstrip, "the dock's widgets-above spacer row sits between transcript and editor"
        assert_includes buffer[top + 1, 3].join, "─", "the edit box below it"
        assert_equal "─", buffer[top + 3][0],
          "the editor's bottom border, full-width from column 0 (pi editor.ts)"
        refute_includes buffer[top + 1, 3].join, "│",
          "no east/west borders (pi: horizontal borders only)"
        footer = buffer[-2, 2].join
        assert_includes footer, "~ (main)", "the footer carries the ~-contracted cwd and branch"
        assert_includes footer, "0.0%/1.0k (auto)", "the footer carries context usage vs the resolved window (pi's 0.0% boot state)"
        assert_includes footer, "test-model", "the footer carries the model id"
      end
    end

    # The transcript viewport budget = pi's dock accounting (AC2):
    # dock = widgets-above Spacer(1) + editor + footer (chat-viewport.ts
    # :22-45; interactive-mode.ts:966-968 renderWidgetContainer
    # spacerWhenEmpty: true) — the blank dock row renders between the
    # transcript and the editor and the budget drops by one row.
    def test_dock_spacer_row_renders_between_transcript_and_editor
      with_chat(width: 40, screen_height: 12) do |chat, session|
        4.times { |i| finish_message(chat, "p#{i}") } # 8 display rows, viewport 6
        draw(chat, session)

        buffer = session.buffer_content
        assert_equal 2, chat.scroll_offset, "the settled window shows the last 6 of 8 buffer rows"
        assert_equal " p3", buffer[5].rstrip, "the transcript viewport ends at row 5 — the budget dropped one row"
        assert_equal "", buffer[6].rstrip, "the widgets-above default Spacer(1) renders a blank dock row"
        assert_equal "─", buffer[7][0], "the editor's top border follows the spacer row"
      end
    end

    # The Grounds' probe shape (AC1): buffer rows = viewport + 1 — the
    # settled follow-end window starts one row down; the top mark row is
    # scrolled off (the mechanism behind pi offset 2 / pre-I20 tart
    # offset 1 on the 25-paragraph probe).
    def test_settled_window_overflow_by_one_scrolls_the_top_mark_off
      with_chat(width: 40, screen_height: 13) do |chat, session| # viewport 7
        4.times { |i| finish_message(chat, "probe p0#{i + 1}") } # 8 display rows
        draw(chat, session)

        assert_equal 1, chat.scroll_offset, "overflow-by-one settles exactly one row down"
        view = transcript_view(session, chat)
        assert_equal " probe p01", view.first, "the window starts at the second buffer row — the top row is off-window"
        assert_equal " probe p04", view.last, "the window ends at the final reply"
      end
    end

    # Resize redraws without clobbering (AC1): the surface recomposes the
    # whole three-area layout from the session viewport every frame, so a
    # terminal resize repaints every row at the new geometry from surface
    # state — proven on the headless test terminal with the gem's
    # resize_terminal (ext mutations.rs:126).
    def test_resize_repaints_the_full_surface_at_the_new_geometry
      with_chat(width: 40, screen_height: 12) do |chat, session|
        send_message(chat, "hello")
        finish_message(chat, "answer")
        draw(chat, session)

        session.resize(60, 16)
        draw(chat, session)
        buffer = session.buffer_content
        assert_equal 16, buffer.size, "the redraw repaints the full screen at the new size"
        assert_equal 60, buffer.first.length
        assert_includes buffer[0, transcript_height(session, chat)].join, "hello",
          "the transcript survives the resize"
        assert_includes buffer[transcript_height(session, chat), 3].join, "─",
          "the edit box recomposes at the new geometry"
        assert_includes buffer[-2, 2].join, "~", "the footer recomposes at the new geometry"
      end
    end

    # --- kernel-driven input/approval/interrupt (ScriptedSession) ---

    def test_enter_submits_and_starts_a_turn_when_idle
      @server = MockLLMServer.new.start
      @server.script([{type: :message, content: "answer one"}])
      kernel, chat, session = chat_with_server

      scenario = Thread.new do
        type(session, "hi")
        wait_until { captured.size >= 1 }
        kernel.stop!
      end
      kernel.run
      scenario.join

      request = captured.first
      assert_equal "hi", request["messages"].select { |m| m["role"] == "user" }.last["content"]
      assert_equal ["", " hi", ""], chat.transcript_lines,
        "the submitted prompt is echoed into the transcript (paddingY wrap, outputPad)"
    end

    def test_enter_while_running_steers
      @server = MockLLMServer.new.start
      # The first response streams slowly so the run is verifiably in flight
      # when "second" is submitted (a fast mock answer would race the
      # busy? probe — the whole turn finishes between two polls).
      @server.script([
        {type: :slow_stream, content: "first answer"},
        {type: :message, content: "second answer"},
      ])
      kernel, chat, session = chat_with_server

      scenario = Thread.new do
        type(session, "first")
        wait_until { chat.busy? }
        type(session, "second")
        wait_until { captured.size >= 2 }
        kernel.stop!
      end
      kernel.run
      scenario.join

      request = captured.last
      assert_equal "second", request["messages"].select { |m| m["role"] == "user" }.last["content"],
        "a message typed mid-run must steer the running agent"
    end

    def test_kernel_interrupt_during_streaming_cancels_and_leaves_render_coherent
      @server = MockLLMServer.new.start
      @server.script([{type: :slow_stream, content: "x" * 40}])
      kernel, chat, session = chat_with_server

      scenario = Thread.new do
        type(session, "long stream")
        wait_until { chat.busy? }
        # Backlog C: the interrupt is ESCAPE (pi app.interrupt — the
        # editor's onEscape → interrupt_work!); ctrl+c is the editor's
        # clear/exit (the loop is not the decider — the loop_test pin).
        session.push_event(TUI.key_event("esc"))
        wait_until { !chat.busy? }
        wait_until { chat.transcript_lines.join.include?("interrupted") }
        kernel.stop!
      end
      kernel.run
      scenario.join

      refute kernel.interrupted?, "the escape interrupt never stops the loop (I15)"
      assert chat.agent.interrupted?
      refute kernel.poller&.thread&.alive?, "no orphan poller"
      assert_includes chat.transcript_lines.join, "interrupted",
        "the interrupted turn renders coherently"
    end

    # --- the submit seam: slash commands (I10) ---

    # A real Commands::Handler with stub callables; skills load from the
    # tmp project dir.
    def with_commands_handler(chat)
      FileUtils.mkpath(File.join(@dir, ".tart", "skills", "greet"))
      File.write(File.join(@dir, ".tart", "skills", "greet", "SKILL.md"),
        "---\nname: greet\ndescription: Says hello\n---\nHello body.")
      skills = Skills.load(cwd: @dir, root: @dir, claude_dir: File.join(@dir, "claude-skills")).skills
      outputs = []
      handler = Commands::Handler.new(
        skills:, settings: {}, output: ->(text) { outputs << text },
        spawn: ->(&block) { block.call }, agent: -> { chat.agent },
        reset: -> {}, quit: -> {}
      )
      chat.commands = handler
      outputs
    end

    def kernel_runs(chat)
      chat.instance_variable_get(:@kernel).submitted
    end

    # Runs (and drains) the agent-run blocks the idle submit branch queued.
    # A real reactor: the user-bash block bridges to a worker thread and
    # waits on an Async::Queue — no reactor, no wait.
    def drain_runs(chat)
      kernel_runs(chat).slice!(0..).each do |block|
        Async do |root|
          root.async { block.call }.wait
        end
      end
    end

    # Records agent.run calls (the idle branch wraps the run in a kernel
    # task — IdleKernel captures the block; the test runs it).
    def with_recording_agent(chat)
      runs = []
      agent = Object.new.tap do |a|
        a.define_singleton_method(:run) { |text| runs << text }
        a.define_singleton_method(:push_message) { |text| runs << [:steer, text] }
      end
      chat.agent = agent
      runs
    end

    def test_slash_builtin_is_consumed_before_any_agent_call
      with_headless_chat do |chat|
        outputs = with_commands_handler(chat)
        runs = with_recording_agent(chat)
        send_message(chat, "/help")

        assert_empty kernel_runs(chat), "a dispatched builtin never starts an agent run"
        assert outputs.last.is_a?(String) && outputs.last.include?("/help"),
          "command output renders through the chat-line surface"
        assert_empty runs
      end
    end

    # AC3 regression (the I13 live-run NoMethodError): /skills submitted
    # through the exact bin/tart:185-191 handler wiring — output routed
    # through the surface's command_line — renders the listing.
    def test_skills_command_renders_the_listing_through_the_bin_wiring
      @server = MockLLMServer.new.start
      kernel, chat, session = chat_with_server
      FileUtils.mkpath(File.join(@dir, ".tart", "skills", "greet"))
      File.write(File.join(@dir, ".tart", "skills", "greet", "SKILL.md"),
        "---\nname: greet\ndescription: Says hello\n---\nHello body.")
      skills = Skills.load(cwd: @dir, root: @dir, claude_dir: File.join(@dir, "claude-skills")).skills
      chat.commands = Commands::Handler.new(
        skills:, settings: {},
        output: ->(text) { chat.command_line(text) },
        spawn: ->(&block) { kernel.async(&block) },
        agent: -> { chat.agent },
        reset: -> { chat.new_session },
        quit: -> { kernel.stop! }
      )

      scenario = Thread.new do
        type(session, "/skills")
        wait_until { chat.transcript_lines.join.include?("greet") }
        kernel.stop!
      end
      kernel.run
      scenario.join

      assert_includes chat.transcript_lines.join, "1 skills:", "the /skills listing renders"
      assert_includes chat.transcript_lines.join, "greet: Says hello"
    end

    # --- the startup MOTD (item 12/AC9) and /new (item 11/AC8) ---

    # The MOTD block on the first frame (tart-mode): the owner's art,
    # version, hints (the PORT's real keys), then [Context] (the config
    # sources the port actually loads — fixture roots only) and [Skills]
    # (sorted names, dim, one wrapped compact list — pi formatCompactList).
    # pi's [Prompts], [Extensions], [Themes], package-updates and expand
    # machinery are cut — the port loads none of them, itemized. Every
    # content row carries the outputPad; the header rides its Spacer(1)
    # pair (interactive-mode.ts:1075-1077).
    def test_motd_renders_logo_version_hints_context_and_skills
      FileUtils.mkpath(File.join(@dir, ".tart", "skills", "greet"))
      File.write(File.join(@dir, ".tart", "skills", "greet", "SKILL.md"),
        "---\nname: greet\ndescription: Says hello\n---\nHello body.")
      File.write(File.join(@dir, ".tart", "settings.json"), "{}")
      skills = Skills.load(cwd: @dir, root: @dir, claude_dir: File.join(@dir, "claude-skills")).skills
      source = Render::SlashSource.new(commands: {"new" => {description: "x"}}, skills: skills)
      TUI.run(headless: true, viewport: :fullscreen, width: 60, screen_height: 24) do |session|
        chat = Render::Chat.new(session:, kernel: IdleKernel.new, motd: true,
          settings_root: @dir, autocomplete: source, identity: "tart", skills:,
          footer_data: {cwd: @dir})
        draw(chat, session)
        lines = chat.transcript_lines

        assert_equal "", lines.first, "the header container opens with its Spacer(1)"
        art = Dir[File.join(Render::Motd::LOGOS_DIR, "*.txt")].map { |f| File.readlines(f, chomp: true) }
        assert art.any? { |piece| (piece.map { |line| " #{line}" } - lines).empty? },
          "a random logo piece from the owner's collection renders in full (padded)"
        assert_includes lines, " tart v#{Tart::VERSION}", "the version line renders Tart::VERSION (padded)"
        assert_includes lines.join, "/ commands", "the hints line carries the port's real keys"
        refute_includes lines.join, "! ", "no `!` hint on the FROZEN compact line (the expanded header lists it — I33)"

        context_i = lines.index { |line| line.include?("[Context]") }
        skills_i = lines.index { |line| line.include?("[Skills]") }
        refute_nil context_i, "the [Context] section renders"
        refute_nil skills_i, "the [Skills] section renders"
        # The compact list word-wraps (pi formatCompactList); every wrapped
        # row re-carries the outputPad, so the joined rows read the path
        # with pad spaces at the breaks.
        assert_includes lines[context_i + 1, 3].join.delete(" "), File.join(@dir, ".tart", "settings.json"),
          "the loaded project settings file is listed"
        assert_includes lines[skills_i + 1].strip, "greet", "the loaded skills are listed"
        refute_includes lines.join, "[Prompts]", "the sections the port doesn't load are cut"
        refute_includes lines.join, "[Extensions]"
        refute_includes lines.join, "[Themes]"

        skills_y = session.buffer_content.index { |row| row.include?("[Skills]") }
        body_x = session.buffer_content[skills_y + 1].index("greet")
        assert_equal Theme[:dim], session.cell_fg(body_x, skills_y + 1),
          "the skills list renders the dim token (pi formatCompactList — interactive-mode.ts:1790)"
      end
    end

    def test_motd_is_omitted_sections_when_nothing_loaded
      TUI.run(headless: true, viewport: :fullscreen, width: 60, screen_height: 24) do |session|
        chat = Render::Chat.new(session:, kernel: IdleKernel.new, motd: true,
          settings_root: @dir, footer_data: {cwd: @dir}, identity: "tart")
        draw(chat, session)
        lines = chat.transcript_lines
        assert_includes lines.join, "tart v#{Tart::VERSION}", "the art + version always render"
        refute_includes lines.join, "[Skills]", "no skills → no section (pi gates each on entries)"
      end
    end

    # --- I33: the startup-help flip, the section flip, and the
    # showStatus transcript rows ---

    # AC1: ctrl+o after boot expands the startup header IN PLACE to pi's
    # expanded shape (the live-oracle capture, hint 1 on the mark's line,
    # hints 2–19 one per row, the notice gone); a second ctrl+o restores
    # the collapsed bytes exactly and reports collapsed. The header block
    # registers at BOOT (before any turn) — the flip exercises the
    # boot-time expandable range.
    def test_ctrl_o_flips_the_startup_header_in_place
      TUI.run(headless: true, viewport: :fullscreen, width: 120, screen_height: 40) do |session|
        chat = Render::Chat.new(session:, kernel: IdleKernel.new, motd: true, settings_root: @dir,
          footer_data: {cwd: @dir})
        draw(chat, session)
        collapsed = chat.transcript_lines

        chat.on_event(TUI.key_event("o", modifiers: ["ctrl"]))
        draw(chat, session)
        expanded = chat.transcript_lines
        assert_equal " ▀▀█  v#{Identity::ORACLE_VERSION}", expanded[1], "the mark + version lead"
        assert_equal " █▀ █ escape to interrupt", expanded[2], "hint 1 rides the mark's second line"
        assert_equal " ctrl+c to clear", expanded[3], "hints 2–19 one per row"
        assert_equal " drop files to attach", expanded[20]
        assert_equal "", expanded[21]
        assert_equal " #{Render::Motd::PI_ONBOARDING_LINE}", expanded[22]
        refute_includes expanded.join, Render::Motd::PI_NOTICE_LINE, "the notice renders ONLY collapsed"
        assert_equal "", expanded[-2], "the status pair's leading Spacer"
        assert_equal " Tool output: expanded", expanded[-1], "the toggle status is a transcript tail row (AC4)"

        chat.on_event(TUI.key_event("o", modifiers: ["ctrl"]))
        draw(chat, session)
        restored = chat.transcript_lines
        assert_equal collapsed, restored[0, collapsed.size], "the second press restores the collapsed bytes exactly"
        assert_equal " Tool output: collapsed", restored[-1]
      end
    end

    # AC2: the loaded-resource sections flip with the same toggle —
    # expanded bodies in pi's shapes ([Context] display paths, the scope
    # groups, /name entries), compact bodies restored on the flip-back.
    def test_ctrl_o_flips_the_resource_sections_in_place
      FileUtils.mkpath(File.join(@dir, ".tart", "skills"))
      File.write(File.join(@dir, ".tart", "settings.json"), "{}")
      File.write(File.join(@dir, ".tart", "skills", "demo.md"), "---\nname: demo\ndescription: d\n---\nb")
      skills = Skills.load(cwd: @dir, root: @dir, claude_dir: File.join(@dir, "claude-skills")).skills
      template = Prompts::Template.new(name: "council", description: "d", content: "b",
        file_path: File.join(@dir, ".tart", "prompts", "council.md"))
      TUI.run(headless: true, viewport: :fullscreen, width: 120, screen_height: 40) do |session|
        chat = Render::Chat.new(session:, kernel: IdleKernel.new, motd: true, settings_root: @dir,
          identity: "tart", footer_data: {cwd: @dir}, skills:, prompts: [template], extensions: [])
        draw(chat, session)
        collapsed = chat.transcript_lines

        chat.on_event(TUI.key_event("o", modifiers: ["ctrl"]))
        draw(chat, session)
        expanded = chat.transcript_lines
        assert_includes expanded.join, "  project", "the scope-group label renders (pi formatScopeGroups)"
        assert_includes expanded.join, "    #{File.join(@dir, '.tart', 'skills', 'demo.md')}",
          "the skill's full display path renders"
        assert_includes expanded.join, "    /council", "the prompt renders as /name"
        assert_includes expanded.join, "  #{File.join(@dir, '.tart', 'settings.json')}",
          "the [Context] display path renders"
        refute_includes expanded.join, "  demo
", "no compact list survives the flip"

        chat.on_event(TUI.key_event("o", modifiers: ["ctrl"]))
        draw(chat, session)
        assert_equal collapsed, chat.transcript_lines[0, collapsed.size], "the compact bodies restore byte-exact"
      end
    end

    # AC2: /new drops the resource sections entirely (pi
    # renderCurrentSessionState clears loadedResourcesContainer — boot-
    # once) and re-enqueues the header block at the CURRENT toggle state.
    def test_new_session_rerenders_the_header_alone_at_the_current_state
      FileUtils.mkpath(File.join(@dir, ".tart", "skills"))
      File.write(File.join(@dir, ".tart", "skills", "demo.md"), "---\nname: demo\ndescription: d\n---\nb")
      skills = Skills.load(cwd: @dir, root: @dir, claude_dir: File.join(@dir, "claude-skills")).skills
      TUI.run(headless: true, viewport: :fullscreen, width: 120, screen_height: 40) do |session|
        chat = Render::Chat.new(session:, kernel: IdleKernel.new, motd: true, settings_root: @dir,
          identity: "tart", footer_data: {cwd: @dir}, skills:)
        draw(chat, session)
        assert_includes chat.transcript_lines.join, "[Skills]", "the boot renders the sections"

        chat.on_event(TUI.key_event("o", modifiers: ["ctrl"])) # flip BEFORE /new
        chat.new_session
        draw(chat, session)
        lines = chat.transcript_lines
        refute_includes lines.join, "[Skills]", "the sections are boot-once (pi's cleared container)"
        refute_includes lines.join, "pgup/pgdn scroll", "the header re-enqueued EXPANDED (the current state — no compact line)"
        assert_includes lines.join, " !! to run bash (no context)", "the expanded hint list rode the re-enqueue"
      end
    end

    # AC2: the compaction rebuild restores the header AT ITS CURRENT
    # expansion state — and never resurrects the sections (I31 ruling).
    def test_compaction_rebuild_restores_the_header_at_its_current_state
      with_chat(width: 60, screen_height: 24, motd: true,
        footer_data: {cwd: @dir, model: "m", context_window: 1000, auto_compact: true}) do |chat, session|
        draw(chat, session)
        chat.on_event(TUI.key_event("o", modifiers: ["ctrl"])) # flip BEFORE the compaction
        chat.on_agent_event({type: :compaction, reason: :threshold, tokens_before: 100, summary: "s", entries: []})
        draw(chat, session)

        lines = chat.transcript_lines
        refute_includes lines.join, Render::Motd::PI_NOTICE_LINE,
          "the header rebuilt EXPANDED (pi's live header rides the toggle)"
        assert_includes lines.join, " drop files to attach"
      end
    end

    # AC4: the persistent statuses render as pi's showStatus — a blank row
    # then a dim one-pad row at the tail, REPLACED in place while still
    # the tail — and the editor border never carries them.
    def test_statuses_render_as_transcript_tail_rows_replaced_in_place
      with_chat(width: 60, screen_height: 24, models: model_catalog,
        footer_data: {cwd: @dir, model: "boot-model", default_provider: "openai"}) do |chat, session|
        chat.switch_model(provider: "glm", id: "glm-5.3", name: "GLM 5.3", reasoning: false,
          context_window: 200_000, max_tokens: nil)
        draw(chat, session)
        lines = chat.transcript_lines
        assert_equal "", lines[-2], "the status pair's blank row"
        assert_equal " Model: glm-5.3", lines[-1], "the dim status row at the tail"
        refute_includes editor_area(session, chat), "Model:", "the editor border never carries the status"

        chat.set_thinking_level("high") # a second status while the pair is still the tail
        draw(chat, session)
        lines = chat.transcript_lines
        assert_equal " Thinking level: high", lines[-1], "replaced in place (pi showStatus's tail rule)"
        refute_includes lines.join, "Model: glm-5.3", "the replaced status is GONE (pi updates the same line)"

        draw(chat, session) # a later frame — the status persists at settle
        assert_includes chat.transcript_lines.join, "Thinking level: high", "statuses are persistent history"
      end
    end

    # The status row renders the dim token (pi showStatus's theme.fg("dim")).
    def test_status_row_renders_dim
      with_chat(width: 60, screen_height: 24, models: model_catalog,
        footer_data: {cwd: @dir, model: "boot-model", default_provider: "openai"}) do |chat, session|
        chat.switch_model(provider: "glm", id: "glm-5.3", name: "GLM 5.3", reasoning: false,
          context_window: 200_000, max_tokens: nil)
        draw(chat, session)
        status_y = session.buffer_content.rindex { |row| row.include?("Model: glm-5.3") }
        assert_equal Theme[:dim], session.cell_fg(1, status_y), "the status renders dim"
      end
    end
    # pi-mode's MOTD (I16 AC2): the oracle's built-in header bytes — the
    # half-block mark with the tracked oracle version on its first line,
    # the hints on its second, the ctrl+o notice, then the onboarding
    # line (pi interactive-mode.ts:1028-1063). The loaded-resource
    # sections render below when resources exist (pi showLoadedResources
    # — the owner's missing [Context]/[Skills]/[Prompts]/[Extensions]
    # block); none loaded here → none render. No tart art/version/hints.
    def test_motd_renders_pi_header_bytes_in_pi_mode
      TUI.run(headless: true, viewport: :fullscreen, width: 120, screen_height: 24) do |session|
        chat = Render::Chat.new(session:, kernel: IdleKernel.new, motd: true,
          settings_root: @dir, footer_data: {cwd: @dir})
        draw(chat, session)
        lines = chat.transcript_lines

        assert_equal "", lines.first, "the header container opens with its Spacer(1)"
        hints_text = Render::Motd::PI_HINTS.flat_map.with_index do |(key, description), index|
          [key, " #{description}#{index == Render::Motd::PI_HINTS.length - 1 ? "" : " · "}"]
        end.join
        assert_equal " ▀▀█  v#{Identity::ORACLE_VERSION}", lines[1], "the mark's first line carries the version"
        assert_equal " █▀ █ #{hints_text}", lines[2], "the mark's second line carries the hints (the byte-identical join over the span family)"
        assert_equal " #{Render::Motd::PI_NOTICE_LINE}", lines[3], "the ctrl+o notice"
        assert_equal "", lines[4], "the header text's blank row"
        assert_equal " #{Render::Motd::PI_ONBOARDING_LINE}", lines[5], "the onboarding line"
        assert_equal "", lines[6], "the header container closes with its Spacer(1)"
        assert_empty lines[7..], "no resources loaded → no sections (pi gates each on entries)"

        mark = session.buffer_content[1]
        assert_equal Theme[:logoCoral], session.cell_fg(1, 1), "the top pixel renders coral (pi-logo.ts)"
        assert_equal Theme[:logoBlue], session.cell_bg(1, 1), "the top pixel's blue under-half"
        assert_equal Theme[:logoYellow], session.cell_fg(4, 2), "the bottom mark's yellow pixel"
        assert_equal Theme[:dim], session.cell_fg(6, 1), "the version renders the dim token (interactive-mode.ts:1018)"
        hints_row = session.buffer_content[2]
        assert_equal Theme[:dim], session.cell_fg(hints_row.index("escape"), 2),
          "the hint keys render the dim token (keyHint — keybinding-hints.ts:43)"
        assert_equal Theme[:muted], session.cell_fg(hints_row.index("interrupt"), 2),
          "the hint descriptions render the muted token (keyHint's description run)"
      end
    end

    # The loaded-resource sections ride BOTH identities (pi
    # showLoadedResources renders for any): [Prompts] lists the loaded
    # templates as /name (pi promptCompactList :1896), [Extensions] the
    # MCP server names — sorted, dim, blank-separated like [Skills].
    def test_motd_renders_prompt_and_extension_sections
      template = Prompts::Template.new(name: "council", description: "d", content: "body", file_path: "/x/council.md")
      TUI.run(headless: true, viewport: :fullscreen, width: 60, screen_height: 24) do |session|
        chat = Render::Chat.new(session:, kernel: IdleKernel.new, motd: true,
          settings_root: @dir, footer_data: {cwd: @dir},
          prompts: [template], extensions: ["memory", "notify"])
        draw(chat, session)
        lines = chat.transcript_lines

        prompts_i = lines.index { |line| line.include?("[Prompts]") }
        extensions_i = lines.index { |line| line.include?("[Extensions]") }
        refute_nil prompts_i, "the [Prompts] section renders"
        refute_nil extensions_i, "the [Extensions] section renders"
        assert_includes lines[extensions_i - 1], "", "sections stay blank-separated"
        assert lines[extensions_i - 1].strip.empty?, "a blank precedes each section header"
        assert_includes lines[prompts_i + 1].strip, "/council", "the template renders as /name"
        assert_equal ["memory", "notify"], lines[extensions_i + 1].strip.split(", "),
          "the extension names render sorted, comma-joined"
      end
    end

    # /new (item 11/AC8): the Commands handler's reset seam — pi
    # handleClearCommand → renderCurrentSessionState clears the chat
    # container, then the accent "✓ New session started" line
    # (interactive-mode.ts:6926-6936, 2209-2216). Kernel-driven: synthetic
    # keys through the real poller, the handler wired exactly as bin/tart
    # wires it (reset: -> { surface.new_session }).
    def test_new_command_clears_the_transcript_and_renders_the_motd
      @server = MockLLMServer.new.start
      @server.script([{type: :message, content: "answer"}])
      kernel, chat, session = chat_with_server(motd: true, identity: "tart")
      chat.commands = Commands::Handler.new(
        skills: [], settings: {},
        output: ->(text) { chat.command_line(text) },
        spawn: ->(&block) { kernel.async(&block) },
        agent: -> { chat.agent },
        reset: -> { chat.new_session },
        quit: -> { kernel.stop! }
      )

      scenario = Thread.new do
        type(session, "hi")
        wait_until { chat.transcript_lines.join.include?("answer") }
        type(session, "/new")
        wait_until { chat.transcript_lines.join.include?("New session started") }
        kernel.stop!
      end
      kernel.run
      scenario.join

      lines = chat.transcript_lines
      refute_includes lines.join, "answer", "the transcript buffer cleared"
      assert_includes lines.join, "tart v#{Tart::VERSION}", "the MOTD block re-renders"
      # Style readback through the drawn widget tree (ScriptedSession keeps
      # the widgets — no cells to read).
      line = widget_lines_with_spans(session.drawn.last)
        .find { |l| l.spans.map(&:content).join.include?("New session started") }
      refute_nil line, "the confirmation line renders in the drawn tree"
      assert_equal Theme[:accent], line.spans.first.style.fg, "the confirmation line is accent (dark.json:16)"
    end

    def test_skill_invocation_sends_the_expanded_block_to_the_agent
      with_headless_chat do |chat|
        with_commands_handler(chat)
        runs = with_recording_agent(chat)
        send_message(chat, "/skill:greet")
        drain_runs(chat)

        assert_equal 1, runs.size
        assert_includes runs.first, "<skill name=\"greet\""
        assert_includes runs.first, "Hello body.", "the model receives the expanded block"
      end
    end

    # The skill invocation renders as its OWN collapsible panel (pi
    # skill-invocation-message.ts + interactive-mode.ts:3936-3948) —
    # collapsed "[skill] greet (ctrl+o to expand)" on the
    # customMessageBg container, the trailing user message echoing below
    # as a normal echo — the submission echo does NOT carry the expanded
    # block (the owner's blow-up finding).
    def test_skill_invocation_renders_the_collapsed_panel_and_the_prompt_below
      with_headless_chat(width: 60) do |chat, session|
        with_commands_handler(chat)
        runs = with_recording_agent(chat)
        send_message(chat, "/skill:greet hello world")
        drain_runs(chat)
        draw(chat, session)

        lines = chat.transcript_lines
        assert_includes lines.join, "[skill] greet (ctrl+o to expand)", "the collapsed panel renders"
        refute_includes lines.join, "<skill", "the expanded block never renders as the echo"
        assert_includes lines.join, "hello world", "the trailing prompt echoes below the panel"

        y_abs = session.buffer_content.index { |buffer_row| buffer_row.include?("[skill]") }
        buffer_row = session.buffer_content[y_abs]
        assert_equal Theme[:custom_message_label], session.cell_fg(buffer_row.index("["), y_abs)
        assert_includes session.cell_modifiers(buffer_row.index("["), y_abs), :bold
        assert_equal Theme[:custom_message_text], session.cell_fg(buffer_row.index("greet"), y_abs)
        assert_equal Theme[:dim], session.cell_fg(buffer_row.index("(ctrl+o"), y_abs)
        # The bg is per-SPAN in the gem's emission — every styled cell of
        # the row carries the panel bg, not just the pad/tail (the
        # transparent-text defect: an unstyled span resets it, ^[[49m).
        assert_equal Theme[:custom_message_bg], session.cell_bg(0, y_abs),
          "the pad cell rides the customMessageBg container"
        assert_equal Theme[:custom_message_bg], session.cell_bg(buffer_row.index("greet"), y_abs),
          "the NAME cell rides the panel bg too"
        assert_equal Theme[:custom_message_bg], session.cell_bg(buffer_row.index("(ctrl+o"), y_abs),
          "the hint cell rides the panel bg too"
        prompt_y = session.buffer_content.index { |buffer_row| buffer_row.include?("hello world") }
        assert_equal Theme[:user_message_bg], session.cell_bg(0, prompt_y),
          "the prompt below echoes as a normal user message"
      end
    end

    # ctrl+o expands the skill panel in place (pi
    # component.setExpanded(this.toolOutputExpanded) in the global
    # toggle's sweep) — the bold name header + the content as
    # customMessageText prose — and collapses again.
    def test_ctrl_o_expands_the_skill_panel
      with_headless_chat(width: 60) do |chat, session|
        with_commands_handler(chat)
        with_recording_agent(chat)
        send_message(chat, "/skill:greet")
        drain_runs(chat)
        draw(chat, session)

        chat.on_event(TUI.key_event("o", modifiers: ["ctrl"]))
        draw(chat, session)
        lines = chat.transcript_lines
        assert_includes lines.join, "greet", "the bold markdown name header renders expanded"
        assert_includes lines.join, "Hello body.", "the skill content renders expanded"
        refute_includes lines.join, "(ctrl+o to expand)", "the hint dies expanded"

        chat.on_event(TUI.key_event("o", modifiers: ["ctrl"]))
        draw(chat, session)
        assert_includes chat.transcript_lines.join, "(ctrl+o to expand)", "the second press collapses again"
      end
    end

    # The replay renders the recorded skill submission through the same
    # panel (pi renderSessionEntries' user case parses the skill block).
    def test_replayed_skill_submission_renders_the_panel
      with_headless_chat do |chat, session|
        chat.resume_session(skill_session_file)
        draw(chat, session)

        assert_includes chat.transcript_lines.join, "[skill] greet (ctrl+o to expand)",
          "the recorded skill submission renders as the panel"
        assert_includes chat.transcript_lines.join, "the follow-up", "the recorded prompt echoes below"
      end
    end

    # A recorded session file carrying one skill-block submission (the
    # recorder's message shape — the expansion + args as ONE user text).
    def skill_session_file
      path = File.join(@dir, "session_skill_test.jsonl")
      File.write(path, [
        JSON.generate({type: "session", version: 1, id: "abc123", timestamp: "t", cwd: @dir}),
        JSON.generate({type: "message", message: {role: "user", content:
          "<skill name=\"greet\" location=\"/tmp/greet/SKILL.md\">\nHello body.\n</skill>\n\nthe follow-up"}})
      ].join("\n") << "\n")
      path
    end

    def test_unknown_skill_and_unknown_command_pass_through_as_plain_text
      with_headless_chat do |chat|
        with_commands_handler(chat)
        runs = with_recording_agent(chat)
        send_message(chat, "/skill:missing")
        drain_runs(chat)
        send_message(chat, "/nope")
        drain_runs(chat)

        assert_equal ["/skill:missing", "/nope"], runs,
          "pi: unknown skill passes through (:2155); an unmatched /command is just a message"
      end
    end

    def test_slash_text_while_running_steers_like_any_message
      @server = MockLLMServer.new.start
      @server.script([
        {type: :slow_stream, content: "first answer"},
        {type: :message, content: "second answer"},
      ])
      kernel, chat, session = chat_with_server
      with_commands_handler(chat)

      scenario = Thread.new do
        type(session, "first")
        wait_until { chat.busy? }
        type(session, "/compact")
        wait_until { captured.size >= 2 }
        kernel.stop!
      end
      kernel.run
      scenario.join

      request = captured.last
      assert_equal "/compact", request["messages"].select { |m| m["role"] == "user" }.last["content"],
        "the reduced deviation: slash text mid-turn steers instead of dispatching"
    end

    # --- markdown seam (I06/AC5): assistant completions render through the
    # converter into the transcript — styled cells proven by readback; the
    # live region stays verbatim streaming text. ---

    def test_assistant_completion_renders_markdown_styled_in_transcript
      with_chat(width: 40) do |chat, session|
        finish_message(chat, "# Heading\n\nplain **bold** text")
        draw(chat, session)

        cells = transcript_cells(session, chat) # [y, x, symbol, fg, modifiers]
        heading = cells.find { |cell| cell[2] == "H" }
        assert_equal Theme[:md_heading], heading[3], "the markdown heading renders mdHeading (yellow var)"
        assert_equal %i[bold underlined], heading[4], "h1 is bold+underlined (markdown.ts:481-483)"
        bold = cells.find { |cell| cell[2] == "b" }
        assert_equal [:bold], bold[4], "strong renders the bold modifier (markdown.ts:683-687)"
        plain = cells.find { |cell| cell[2] == "p" }
        assert_equal [nil, []], plain[3, 2],
          "plain prose renders the TERMINAL DEFAULT (pi getMarkdownTheme has no prose callback — theme.ts:1022-1031)"
        assert_equal 4, chat.transcript_lines.size,
          "the leading blank (pi between-item rule), the heading, its spacing row, and the paragraph occupy four transcript rows"
      end
    end

    # Live markdown (item 3, pi interactive-mode.ts:3519-3535 +
    # assistant-message.ts:107-109): the live region re-renders as
    # markdown on every delta — proven by styled readback BEFORE
    # :message_end; since I37 the reasoning block above the content rides
    # the same converter (the dim-markdown routing — the I13 cut
    # retired).
    def test_live_region_renders_markdown_mid_stream
      with_chat do |chat, session|
        chat.on_agent_event({type: :message_start, message: ChunkDouble.new})
        chat.on_agent_event({type: :message_update, chunk: thinking_chunk(nil, "pondering")})
        chat.on_agent_event({type: :message_update, chunk: ChunkDouble.new("**bo** ld")})
        draw(chat, session)

        cells = transcript_cells(session, chat)
        bold = cells.find { |cell| cell[2] == "b" }
        assert_equal [:bold], bold[4], "the streamed content renders markdown mid-stream (before :message_end)"
        thinking = cells.find { |cell| cell[2] == "p" }
        assert_equal Theme[:thinkingText], thinking[3], "the reasoning block stays plain dim"
        assert_includes thinking[4], :italic
        refute_includes live_region(session, chat), "**",
          "no raw markdown markers survive into the live region's rendered rows"
      end
    end

    # --- reasoning as dim markdown (I37, pi assistant-message.ts:99-176):
    # ONE converter path for the live, completed, and replay shapes — the
    # thinkingText+italic prose default over the markdown theme, structure
    # spans keeping their theme fns. The I13 cut retires. ---

    # Reasoning fixture with a bold run, an inline code span, and a list.
    REASONING_MD = "**bold** and `code`\n\n- item one"

    def test_reasoning_renders_as_dim_markdown_mid_stream
      with_chat(width: 40) do |chat, session|
        chat.on_agent_event({type: :agent_start})
        chat.on_agent_event({type: :message_start, message: ChunkDouble.new})
        chat.on_agent_event({type: :message_update, chunk: thinking_chunk(nil, REASONING_MD)})
        draw(chat, session)
        assert_reasoning_markdown_cells(session, chat)
        live = live_region(session, chat)
        refute_includes live, "**", "no raw markers in the live region"
        refute_includes live, "`"
      end
    end

    def test_reasoning_renders_as_dim_markdown_at_completion
      with_chat(width: 40) do |chat, session|
        chat.on_agent_event({type: :message_start, message: ChunkDouble.new})
        chat.on_agent_event({type: :message_update, chunk: thinking_chunk(nil, REASONING_MD)})
        chat.on_agent_event({type: :message_update, chunk: ChunkDouble.new("answer")})
        chat.on_agent_event({type: :message_end, message: MessageDouble.new(:assistant, "answer")})
        draw(chat, session)
        assert_reasoning_markdown_cells(session, chat)
      end
    end

    def test_reasoning_renders_as_dim_markdown_on_replay
      dir = File.join(@dir, "sessions")
      FileUtils.mkpath(dir)
      recorded = File.join(dir, "reasoning_md_replay_test-session.jsonl")
      File.write(recorded, <<~JSONL)
        {"type":"session","version":3,"id":"reasoning-md-replay","timestamp":"2026-01-01T00:00:00.000Z","cwd":"#{@dir}"}
        {"type":"message","id":"e1","parentId":null,"timestamp":"2026-01-01T00:00:01.000Z","message":{"role":"user","content":"go"}}
        {"type":"message","id":"e2","parentId":"e1","timestamp":"2026-01-01T00:00:02.000Z","message":{"role":"assistant","content":"answer","thinking":#{REASONING_MD.to_json}}}
      JSONL
      with_chat(width: 40, screen_height: 24) do |chat, session|
        chat.resume_session(recorded)
        draw(chat, session)
        assert_reasoning_markdown_cells(session, chat)
      end
    end

    # The shared cell readback (the [y, x, symbol, fg, modifiers] scan):
    # bold rides thinkingText+italic, the codespan and the list marker
    # keep their theme fns (no prose styling), plain prose rides
    # thinkingText+italic, and no raw markers survive.
    def assert_reasoning_markdown_cells(session, chat)
      cells = transcript_cells(session, chat)
      bold = cells.find { |cell| cell[2] == "b" }
      assert_equal Theme[:thinkingText], bold[3], "the bold run rides the thinkingText prose color"
      assert_equal [:bold, :italic], bold[4], "bold + the italic default (pi defaultTextStyle inside strong)"
      code = cells.find { |cell| cell[2] == "c" }
      assert_equal Theme[:md_code], code[3], "the codespan keeps its theme fn (no prose styling)"
      refute_includes code[4], :italic
      marker = cells.find { |cell| cell[2] == "-" }
      assert_equal Theme[:md_list_bullet], marker[3], "the list marker keeps its theme fn"
      refute_includes marker[4], :italic
      prose = cells.find { |cell| cell[2] == "a" } # the "and" run — before any content rows
      assert_equal Theme[:thinkingText], prose[3], "plain prose rides thinkingText"
      assert_includes prose[4], :italic
      rows = chat.transcript_lines.join
      refute_includes rows, "**", "no raw markdown markers survive into the rendered rows"
      refute_includes rows, "`"
    end

    # pi thinking.trim() (assistant-message.ts:125): leading/trailing
    # delta whitespace strips before the markdown routing — no blank edge
    # rows.
    def test_reasoning_delta_whitespace_strips_to_no_blank_edge_rows
      with_chat(width: 40) do |chat, session|
        chat.on_agent_event({type: :message_start, message: ChunkDouble.new})
        chat.on_agent_event({type: :message_update, chunk: thinking_chunk(nil, "\n\n pondering \n\n")})
        chat.on_agent_event({type: :message_end, message: MessageDouble.new(:assistant, "")})
        draw(chat, session)
        assert_equal ["", " pondering"], chat.transcript_lines,
          "the strip kills the blank edge rows the delta whitespace would render"
      end
    end

    def test_assistant_markdown_renders_through_the_kernel_loop
      @server = MockLLMServer.new.start
      @server.script([{type: :message, content: "# Title\n\nplain body"}])
      kernel, chat, session = chat_with_server

      scenario = Thread.new do
        type(session, "hi")
        wait_until { chat.transcript_lines.join.include?("Title") }
        kernel.stop!
      end
      kernel.run
      scenario.join

      assert_equal ["", " hi", "", "", " Title", " ", " plain body"], chat.transcript_lines,
        "the assistant reply renders as markdown rows in the transcript (the echo's padY bottom + the message's leading blank, then the spacing row between blocks)"
    end

    # The footer's token counters (AC4): session-cumulative usage totals
    # accumulated at assistant completions; the context segment goes "?"
    # until the first usage and after a compaction (pi's post-compaction
    # "?"), with warning/error thresholds above 70%/90%.
    def test_footer_counters_accumulate_from_assistant_completions
      with_chat(width: 40, screen_height: 12,
        footer_data: {cwd: @dir, model: "m", context_window: 1000, auto_compact: false},
        branch_reader: ->(_cwd) { nil }) do |chat, session|
        draw(chat, session)
        assert_includes footer_text(session), "0.0%/1.0k", "no usage yet: pi's 0.0% boot state (getContextUsage estimate 0)"

        assistant_done(chat, TokensDouble.new(10, 5, 0, 0))
        draw(chat, session)
        footer = footer_text(session)
        assert_includes footer, "↑10", "input totals accumulate"
        assert_includes footer, "↓5", "output totals accumulate"
        assert_includes footer, "1.5%/1.0k", "context usage uses the resolved window"
        assert_includes footer, "m", "the model id renders"

        chat.on_agent_event({type: :compaction, reason: :threshold, tokens_before: 900, summary: "s"})
        draw(chat, session)
        assert_includes footer_text(session), "?/1.0k", "after compaction the context segment is '?' again"
      end
    end

    def test_footer_context_thresholds_color_the_segment
      with_chat(width: 40, screen_height: 12,
        footer_data: {cwd: @dir, model: "m", context_window: 100}) do |chat, session|
        assistant_done(chat, TokensDouble.new(0, 0, 71, 0))
        draw(chat, session)
        row = footer_stats_row(session)
        cells = (0...40).filter_map { |x| [x, session.cell_fg(x, row)] if session.cell_symbol(x, row) != " " }
        assert cells.any? { |_x, fg| fg == Theme[:warning] }, "context >70% renders warning"

        assistant_done(chat, TokensDouble.new(0, 0, 91, 0))
        draw(chat, session)
        cells = (0...40).filter_map { |x| [x, session.cell_fg(x, row)] if session.cell_symbol(x, row) != " " }
        assert cells.any? { |_x, fg| fg == Theme[:error] }, "context >90% renders error"
      end
    end

    # The footer's model segment (I16, pi footer.ts:226-258): the level
    # rides as +model • <level>+ ONLY when the model is reasoning-capable
    # (state.model?.reasoning), and the provider label prefixes the
    # segment — +(<provider>) <model>+.
    def test_footer_renders_the_thinking_level_right_aligned
      with_chat(width: 40, screen_height: 12,
        footer_data: {cwd: @dir, model: "m", context_window: 1000, thinking_level: "high", reasoning: true}) do |chat, session|
        draw(chat, session)
        assert_includes footer_text(session), "m • high", "model • <level> on the right side"
        assert session.buffer_content[footer_stats_row(session)].rstrip.end_with?("m • high"),
          "the model+level right-aligns (footer.ts padding rule)"

        chat.footer_data = {cwd: @dir, model: "m", context_window: 1000, thinking_level: "high"}
        draw(chat, session)
        assert_includes footer_text(session), "m", "the model alone"
        refute_includes footer_text(session), "•", "no level bullet without reasoning capability"
      end
    end

    # The provider label NEVER renders (pi footer.ts:246-258 — the
    # prefix is gated on >1 available provider; the port resolves one
    # static provider — the owner's live "(openai) " finding).
    def test_footer_never_renders_the_provider_label
      with_chat(width: 40, screen_height: 12,
        footer_data: {cwd: @dir, model: "m", context_window: 1000, provider: "mock"}) do |chat, session|
        draw(chat, session)
        refute_includes footer_text(session), "(mock)", "no provider prefix at any gate"
        assert session.buffer_content[footer_stats_row(session)].rstrip.end_with?("m"),
          "the bare model right-aligns"
      end
    end

    # pi footer.ts:238 — level "off" renders the spelled-out
    # "thinking off", not the bare token.
    def test_footer_renders_thinking_off_spelled_out
      with_chat(width: 40, screen_height: 12,
        footer_data: {cwd: @dir, model: "m", context_window: 1000, thinking_level: "off", reasoning: true}) do |chat, session|
        draw(chat, session)
        assert session.buffer_content[footer_stats_row(session)].rstrip.end_with?("m • thinking off"),
          'the off level renders as "thinking off"'
      end
    end

    # /thinking's runtime seam (pi selectThinkingLevel :5165-5177 —
    # footer.invalidate + updateEditorBorderColor + showStatus): the
    # session level drives the footer segment AND the editor border
    # color, live; the border status reports.
    def test_thinking_command_updates_the_footer_and_border_live
      with_chat(width: 40, screen_height: 12,
        footer_data: {cwd: @dir, model: "m", context_window: 1000, thinking_level: "medium", reasoning: true}) do |chat, session|
        handler = Commands::Handler.new(
          skills: [], settings: {}, output: ->(text) { @commands_output << text },
          spawn: ->(&block) { block.call }, agent: -> { nil }, reset: -> {},
          thinking: ->(arg) { chat.set_thinking_level(arg) },
          thinking_menu: -> { chat.open_thinking_menu },
          quit: -> {}
        )

        handler.dispatch("/thinking high")
        draw(chat, session)
        assert session.buffer_content[footer_stats_row(session)].rstrip.end_with?("m • high"),
          "the footer shows the runtime level"
        border_row = session.buffer_content.rindex { |row| row.include?("─") }
        assert_equal Theme[:thinking_high], session.cell_fg(0, border_row),
          "the editor border follows the level (getThinkingBorderColor — the bottom border row is all glyph cells)"

        handler.dispatch("/thinking")
        assert chat.menu_open?, "the bare command opens the thinking selector (pi showThinkingSelector)"
        assert_equal "high", chat.menu_selection&.fetch(:value), "the menu opens on the current level"
        chat.on_event(TUI.key_event("esc"))
        refute chat.menu_open?, "escape cancels the menu"
        draw(chat, session)
        assert session.buffer_content[footer_stats_row(session)].rstrip.end_with?("m • high"),
          "a cancelled selection leaves the level alone"

        handler.dispatch("/thinking nope")
        assert @commands_output.last.include?("Unknown thinking level"), "unknown levels error, the level holds"
      end
    end

    # The shift+tab cycle (I27, app.thinking.cycle — keybindings.ts:33-35):
    # the in-session level cycle stays when bare /thinking became the menu.
    def test_shift_tab_cycles_the_thinking_level
      with_chat(width: 40, screen_height: 12,
        footer_data: {cwd: @dir, model: "m", context_window: 1000, thinking_level: "medium", reasoning: true}) do |chat, session|
        chat.on_event(TUI.key_event("tab", modifiers: ["shift"]))
        draw(chat, session)
        assert session.buffer_content[footer_stats_row(session)].rstrip.end_with?("m • high"),
          "shift+tab cycles medium → high"
      end
    end

    # I36 AC3: every selection path lands on the AGENT seam —
    # apply_thinking_selection drives Agent::Loop#set_thinking_level, so
    # /thinking, the shift+tab cycle, and the menu apply to the next
    # request without restart (unit-pinned with a spy on the seam).
    def test_thinking_selections_reach_the_agent_seam
      with_chat(width: 40, screen_height: 16,
        footer_data: {cwd: @dir, model: "m", context_window: 1000, thinking_level: "medium", reasoning: true}) do |chat, session|
        levels = []
        chat.agent = Object.new.tap do |agent|
          agent.define_singleton_method(:set_thinking_level) { |level| levels << level }
        end
        chat.commands = Commands::Handler.new(
          skills: [], settings: {}, output: ->(text) { @commands_output << text },
          spawn: ->(&block) { block.call }, agent: -> { chat.agent }, reset: -> {},
          thinking: ->(arg) { chat.set_thinking_level(arg) },
          thinking_menu: -> { chat.open_thinking_menu }, quit: -> {}
        )

        send_message(chat, "/thinking low")
        assert_equal ["low"], levels, "the /thinking command rides the agent seam"

        chat.on_event(TUI.key_event("tab", modifiers: ["shift"]))
        assert_equal ["low", "medium"], levels, "the shift+tab cycle rides the agent seam"

        chat.open_thinking_menu
        chat.on_event(TUI.key_event("down"))
        chat.on_event(TUI.key_event("enter"))
        assert_equal ["low", "medium", "high"], levels, "the menu selection rides the agent seam"
      end
    end

    # pi cycleThinkingLevel (:2641-2653): a stored level OUTSIDE the gated
    # set (a switch re-laddered under it) cycles to the FIRST rung — the
    # JS `indexOf → -1` makes `(−1 + 1) % size` land on index 0, not on
    # the rung after the floor.
    def test_cycle_from_an_out_of_set_level_lands_on_the_first_rung
      with_chat(width: 40, screen_height: 16,
        footer_data: {cwd: @dir, model: "m", context_window: 1000, thinking_level: "max", reasoning: true}) do |chat, session|
        levels = []
        chat.agent = Object.new.tap do |agent|
          agent.define_singleton_method(:set_thinking_level) { |level| levels << level }
        end

        assert_equal "off", chat.cycle_thinking_level,
          "the wrap lands on the first rung (the map-less ladder has no max)"
        assert_equal ["off"], levels, "the wrapped cycle rides the agent seam"
      end
    end

    # --- the selector menus (I27): key routes, dispatch wiring, the
    # switch seams — pi showSelector/app.model.select/app.models.save ---

    def model_catalog
      Models::Config.new(
        providers: {
          "glm" => {name: "GLM", base_url: nil, api_key: nil, api: nil,
                    models: [{provider: "glm", id: "glm-5.3", name: "GLM 5.3", reasoning: true,
                              context_window: 200_000, max_tokens: nil}]},
          "zai" => {name: "Z.ai", base_url: nil, api_key: nil, api: nil,
                    models: [{provider: "zai", id: "glm-5-air", name: "Air", reasoning: false,
                              context_window: 130_000, max_tokens: nil}]}
        },
        default: nil, error: nil
      )
    end

    # ctrl+l opens the model menu over the real catalog (the boot model
    # is not in it → no current flag, the provider sort leads).
    def test_ctrl_l_opens_the_model_menu
      with_headless_chat(models: model_catalog,
        footer_data: {cwd: @dir, model: "boot-model", default_provider: "openai"}) do |chat|
        chat.on_event(TUI.key_event("l", modifiers: ["ctrl"]))

        assert chat.menu_open?, "ctrl+l opens the model menu (app.model.select)"
        assert_equal "glm-5.3", chat.menu_selection&.fetch(:id), "the menu opens on the first sorted row"
      end
    end

    # The degenerate catalog (no models.json): the boot model alone — so
    # ctrl+s set-as-default works out of the box (itemized extension).
    def test_model_menu_degenerates_to_the_boot_model_without_a_catalog
      with_headless_chat(footer_data: {cwd: @dir, model: "boot-model", default_provider: "openai"}) do |chat|
        chat.on_event(TUI.key_event("l", modifiers: ["ctrl"]))

        assert chat.menu_open?
        assert_equal "boot-model", chat.menu_selection&.fetch(:id),
          "the boot model is the single entry"
      end
    end

    def test_model_menu_enter_switches_the_model_and_refreshes_the_surface
      with_chat(width: 40, screen_height: 16, models: model_catalog,
        footer_data: {cwd: @dir, model: "boot-model", context_window: 1000,
                      default_provider: "openai", thinking_level: "medium", reasoning: false}) do |chat, session|
        switched = []
        chat.agent = Object.new.tap do |agent|
          agent.define_singleton_method(:switch_model) do |model_id, provider:, context_window: nil,
                                                           model_reasoning: nil, thinking_level_map: nil|
            switched << {model_id:, provider:, context_window:, model_reasoning:, thinking_level_map:}
          end
          # The I40 switch seam also re-clamps the stored level onto the
          # loop (pi setModel → setThinkingLevel); inert for this pin,
          # which asserts the switch_model kwargs alone.
          agent.define_singleton_method(:set_thinking_level) do |_level| end
        end

        chat.open_model_menu
        chat.on_event(TUI.key_event("enter"))
        draw(chat, session)

        refute chat.menu_open?, "the selection closes the menu (the editor is restored)"
        assert_equal [{model_id: "glm-5.3", provider: "openai", context_window: 200_000,
                       model_reasoning: true, thinking_level_map: nil}], switched,
          "the loop seam swaps the runtime chat model (the wire provider — the port's " \
          "single chat-completions seam), re-resolves the window, and carries the " \
          "switched entry's composed reasoning facts (known-tables-second)"
        assert session.buffer_content[footer_stats_row(session)].rstrip.end_with?("glm-5.3 • medium"),
          "the footer model segment refreshed (the entry's reasoning flag rides along)"
        assert_includes chat.transcript_lines.join, "Model: glm-5.3",
          "the status reports pi's showStatus text (the transcript tail row, I33)"
      end
    end

    # The reasoning capability re-ladders the editor border: the switched
    # entry's reasoning flag flows through the footer view
    # (getThinkingBorderColor — pi updateEditorBorderColor).
    def test_model_switch_re_ladders_the_editor_border
      with_chat(width: 40, screen_height: 16, models: model_catalog,
        footer_data: {cwd: @dir, model: "boot-model", context_window: 1000,
                      default_provider: "openai", reasoning: false}) do |chat, session|
        chat.switch_model(provider: "glm", id: "glm-5.3", name: "GLM 5.3", reasoning: true,
          context_window: 200_000, max_tokens: nil)
        draw(chat, session)

        border_row = session.buffer_content.rindex { |row| row.include?("─") }
        assert_equal Theme[:thinking_off], session.cell_fg(0, border_row)
      end
    end

    # ctrl+s in the model menu: the set-as-default persistence (pi
    # app.models.save → settingsManager.setDefaultModelAndProvider) —
    # the write preserves unknown keys, the status reports the pair.
    def test_model_menu_ctrl_s_persists_the_default_model
      with_chat(width: 40, screen_height: 16, models: model_catalog,
        footer_data: {cwd: @dir, model: "boot-model", context_window: 1000,
                      default_provider: "openai"}) do |chat, session|
        FileUtils.mkpath(@dir)
        File.write(File.join(@dir, "settings.json"), '{"unknownKey": true, "thinkingLevel": "high"}')

        chat.open_model_menu
        chat.on_event(TUI.key_event("s", modifiers: ["ctrl"]))
        draw(chat, session)

        refute chat.menu_open?, "ctrl+s selects-and-persists and closes (pi selectLevel → done)"
        saved = JSON.parse(File.read(File.join(@dir, "settings.json")))
        assert_equal "glm", saved["defaultProvider"], "defaultProvider persisted"
        assert_equal "glm-5.3", saved["defaultModel"], "defaultModel persisted"
        assert_equal true, saved["unknownKey"], "unknown keys survive the write"
        assert_equal "high", saved["thinkingLevel"], "unmodified keys survive"
        assert_includes chat.transcript_lines.join, "Default model: glm/glm-5.3",
          "the persisted status reports the pair (the transcript tail row, I33)"
      end
    end

    # ctrl+s in the thinking menu persists the default level (pi
    # app.thinking.save → setThinkingLevel {persist:true}).
    def test_thinking_menu_ctrl_s_persists_the_default_level
      with_chat(width: 40, screen_height: 16,
        footer_data: {cwd: @dir, model: "m", context_window: 1000, thinking_level: "medium", reasoning: true}) do |chat, session|
        chat.open_thinking_menu
        chat.on_event(TUI.key_event("s", modifiers: ["ctrl"]))
        draw(chat, session)

        refute chat.menu_open?
        saved = JSON.parse(File.read(File.join(@dir, "settings.json")))
        assert_equal "medium", saved["thinkingLevel"], "the settings default persisted"
        assert_includes chat.transcript_lines.join, "Default thinking level: medium",
          "the persisted status reports the level (the transcript tail row, I33)"
      end
    end

    # The click-to-select mount (pi select-list.ts:109-134): the press
    # moves the selection, the release on the same row selects and
    # closes.
    def test_model_menu_click_to_select
      with_chat(width: 40, screen_height: 16, models: model_catalog,
        footer_data: {cwd: @dir, model: "boot-model", context_window: 1000,
                      default_provider: "openai"}) do |chat, session|
        chat.open_model_menu
        draw(chat, session)

        # The first list row sits at the menu area's list window top
        # (area top + top border + list_offset); the catalog (no current
        # flag — the boot model is not in it) sorts glm-5.3 first.
        menu = chat.instance_variable_get(:@menu)
        list_top = (16 - 2 - (menu.widget_rows + 2)) + 1 + menu.list_offset
        chat.on_event(TUI.mouse_event(kind: "down", x: 2, y: list_top, button: "left"))
        chat.on_event(TUI.mouse_event(kind: "up", x: 2, y: list_top, button: "left"))
        draw(chat, session)

        refute chat.menu_open?, "the click selected and closed (pi click → onSelect)"
        assert_includes chat.transcript_lines.join, "Model: glm-5.3",
          "the clicked entry switched (the drawn frame's flush renders the status)"
      end
    end

    # --- the I27-verdict residuals (I28 AC4) ---

    # A mock-provider catalog (the model keyed under a NON-native
    # endpoint key) + an env boot whose TART_PROVIDER is the native wire
    # slug: the ✓/· markers must cross-resolve the wire provider onto
    # the catalog key (the boot pair {openai, mock-1} vs the entry
    # {mock, mock-1}).
    def mock_native_catalog
      Models::Config.new(
        providers: {
          "mock" => {name: "Mock", base_url: nil, api_key: nil, api: nil,
                     models: [{provider: "mock", id: "mock-1", name: "Mock 1", reasoning: true,
                               context_window: 33_000, max_tokens: nil}]}
        },
        default: nil, error: nil
      )
    end

    def test_model_menu_markers_match_the_runtime_model_across_the_wire_provider
      with_chat(width: 40, screen_height: 16, models: mock_native_catalog,
        footer_data: {cwd: @dir, model: "mock-1", default_provider: "openai"}) do |chat, session|
        chat.open_model_menu
        draw(chat, session)

        selection = chat.menu_selection
        assert_equal "mock-1", selection&.fetch(:id), "sorted to the top row (current first)"
        assert selection[:current], "the ✓ marker cross-resolves the boot pair's wire provider"
        assert selection[:default], "the · default badge cross-resolves too"
        rows = TUI.widget_lines(chat.renderer.call).join("\n")
        assert_includes rows, "✓ mock-1 [mock]"
        assert_includes rows, "· default"
      end
    end

    # pi getAvailableThinkingLevels (agent-session.ts:2657 →
    # getSupportedThinkingLevels, models.ts:1224): a non-reasoning model
    # offers [off] alone — the menu gates, and the /thinking arg error
    # lists the GATED set (handleThinkingCommand :5153-5155). The ✓ rides
    # EXACT equality (thinking-selector.ts:69-73, I40): the fixture's
    # stored "medium" is outside the gated set, so NO row is marked (the
    # preselect falls to index 0 — buildSelectList :101-107).
    def test_thinking_menu_gates_to_off_for_a_non_reasoning_runtime_model
      with_chat(width: 40, screen_height: 16,
        footer_data: {cwd: @dir, model: "m", context_window: 1000, thinking_level: "medium", reasoning: false}) do |chat, session|
        chat.open_thinking_menu
        draw(chat, session)

        menu = chat.instance_variable_get(:@menu)
        assert_equal %w[off], menu.instance_variable_get(:@items).map { |item| item[:value] },
          "the gated set is [off] alone"
        assert_equal "off", chat.menu_selection&.fetch(:value), "the preselect lands on index 0"
        rows = TUI.widget_lines(chat.renderer.call).join("\n")
        refute_includes rows, "✓", "exact equality: the out-of-set stored level marks NO row (I40)"
        refute_includes rows, "minimal", "no ungated levels render"
      end
    end

    def test_thinking_menu_lists_the_mapless_rule_for_a_reasoning_runtime_model
      with_chat(width: 40, screen_height: 16,
        footer_data: {cwd: @dir, model: "m", context_window: 1000, thinking_level: "medium", reasoning: true}) do |chat, session|
        chat.open_thinking_menu

        menu = chat.instance_variable_get(:@menu)
        assert_equal %w[off minimal low medium high], menu.instance_variable_get(:@items).map { |item| item[:value] },
          "no map = pi's map-less rule: the ladder without xhigh/max (models.ts:1224-1231)"
      end
    end

    # The runtime map filters the ladder (I36 — the I27 "xhigh/max never
    # filter" deviation retired): a mapped model offers exactly
    # Models.supported_thinking_levels.
    def test_thinking_menu_gates_by_the_boot_map
      with_chat(width: 40, screen_height: 16,
        footer_data: {cwd: @dir, model: "m", context_window: 1000, thinking_level: "medium", reasoning: true,
                      thinking_level_map: {off: nil, minimal: nil, low: "low", medium: nil, high: "high",
                                           xhigh: nil, max: "max"}}) do |chat, session|
        chat.open_thinking_menu

        menu = chat.instance_variable_get(:@menu)
        assert_equal %w[low high max], menu.instance_variable_get(:@items).map { |item| item[:value] },
          "null values mark levels unsupported (pi getSupportedThinkingLevels)"
      end
    end

    # The switch overlay carries the switched entry's map: the ladder
    # re-gates after a /model switch (pi setModel → _clampThinkingLevel).
    def test_thinking_ladder_re_gates_on_the_switched_entrys_map
      with_chat(width: 40, screen_height: 16, models: model_catalog,
        footer_data: {cwd: @dir, model: "boot-model", context_window: 1000,
                      default_provider: "openai", reasoning: true,
                      thinking_level_map: {off: "low", low: "low", medium: "medium", high: "high",
                                           xhigh: "xhigh", max: "max"}}) do |chat, session|
        chat.open_thinking_menu
        menu = chat.instance_variable_get(:@menu)
        assert_equal Settings::THINKING_LEVELS, menu.instance_variable_get(:@items).map { |item| item[:value] },
          "the boot map offers the whole ladder"
        chat.on_event(TUI.key_event("esc"))

        chat.switch_model(provider: "glm", id: "glm-5.3", name: "GLM 5.3", reasoning: true,
          context_window: 200_000, max_tokens: nil, thinking_level_map: nil)
        chat.open_thinking_menu
        menu = chat.instance_variable_get(:@menu)
        assert_equal %w[off minimal low medium high], menu.instance_variable_get(:@items).map { |item| item[:value] },
          "the switched entry's map-less shape re-gates (the overlay replaces the boot map)"
      end
    end

    # --- I40: the stored level re-clamps on the switch (pi setModel,
    # the named I28 residual) ---

    # The loop-seam spy: records the switch call ORDER (pi setModel swaps
    # the model first, agent-session.ts:2484-2494, then setThinkingLevel
    # :2610) and the levels the seam received.
    def switching_agent(levels)
      calls = []
      spy = Object.new.tap do |agent|
        agent.define_singleton_method(:switch_model) do |*|
          calls << :switch_model
        end
        agent.define_singleton_method(:set_thinking_level) do |level|
          calls << :set_thinking_level
          levels << level
        end
      end
      [spy, calls]
    end

    # pi setModel (agent-session.ts:2477-2496) resolves a level FOR THE
    # SWITCH — _getThinkingLevelForModelSwitch (:2670-2679, the session
    # level when no settings FILE declares a default) — and
    # setThinkingLevel (:2610-2634) re-clamps it through the SWITCHED
    # model's supported set: a stored xhigh no longer survives a switch
    # to a map-less reasoning model (the map-less rule tops out at high,
    # models.ts:1224-1231). The clamped level rides the loop seam AFTER
    # switch_model (pi's order) and re-renders the footer.
    def test_switch_re_clamps_a_stored_level_through_the_switched_model
      with_chat(width: 40, screen_height: 16, models: model_catalog,
        footer_data: {cwd: @dir, model: "boot-model", context_window: 1000,
                      default_provider: "openai", thinking_level: "xhigh", reasoning: false}) do |chat, session|
        levels = []
        agent, calls = switching_agent(levels)
        chat.agent = agent

        chat.switch_model(provider: "glm", id: "glm-5.3", name: "GLM 5.3", reasoning: true,
          context_window: 200_000, max_tokens: nil, thinking_level_map: nil)

        assert_equal "high", chat.instance_variable_get(:@thinking_level),
          "the stored xhigh re-clamps through the map-less rule (pi _clampThinkingLevel)"
        assert_equal ["high"], levels, "the loop seam carries the clamped level"
        assert_equal %i[switch_model set_thinking_level], calls,
          "pi swaps the model first, then sets the level (agent-session.ts:2484-2494)"
        draw(chat, session)
        assert session.buffer_content[footer_stats_row(session)].rstrip.end_with?("glm-5.3 • high"),
          "the footer renders the clamped level (the overlay view)"
      end
    end

    # A non-reasoning switch re-clamps to off (pi: ["off"] is the whole
    # supported set when reasoning is false, models.ts:1225).
    def test_switch_to_a_non_reasoning_model_clamps_the_level_to_off
      with_chat(width: 40, screen_height: 16, models: model_catalog,
        footer_data: {cwd: @dir, model: "boot-model", context_window: 1000,
                      default_provider: "openai", thinking_level: "high", reasoning: true}) do |chat|
        levels = []
        agent, = switching_agent(levels)
        chat.agent = agent

        chat.switch_model(provider: "zai", id: "glm-5-air", name: "Air", reasoning: false,
          context_window: 130_000, max_tokens: nil, thinking_level_map: nil)

        assert_equal "off", chat.instance_variable_get(:@thinking_level),
          "the stored high re-clamps to the non-reasoning floor"
        assert_equal ["off"], levels
      end
    end

    # The declared-default tier (pi _getThinkingLevelForModelSwitch
    # :2676-2677 — getDefaultThinkingLevel() ?? this.thinkingLevel): a
    # FILE-declared default re-applies on EVERY switch and wins over the
    # session level (settings-manager.ts:758-760 — only a file declares
    # it; the baked DEFAULTS never counts).
    def test_switch_prefers_the_declared_default_over_the_session_level
      with_chat(width: 40, screen_height: 16, models: model_catalog,
        footer_data: {cwd: @dir, model: "boot-model", context_window: 1000,
                      default_provider: "openai", thinking_level: "high", reasoning: true}) do |chat|
        FileUtils.mkpath(@dir)
        File.write(File.join(@dir, "settings.json"), '{"thinkingLevel": "low"}')
        levels = []
        agent, = switching_agent(levels)
        chat.agent = agent

        chat.switch_model(provider: "glm", id: "glm-5.3", name: "GLM 5.3", reasoning: true,
          context_window: 200_000, max_tokens: nil, thinking_level_map: nil)

        assert_equal "low", chat.instance_variable_get(:@thinking_level),
          "the declared default wins over the session level (pi getDefaultThinkingLevel)"
        assert_equal ["low"], levels
      end
    end

    # No file default: an in-set session level carries across the switch
    # unchanged (pi's ?? this.thinkingLevel tier).
    def test_switch_keeps_an_in_set_session_level_without_a_declared_default
      with_chat(width: 40, screen_height: 16, models: model_catalog,
        footer_data: {cwd: @dir, model: "boot-model", context_window: 1000,
                      default_provider: "openai", thinking_level: "medium", reasoning: false}) do |chat|
        levels = []
        agent, = switching_agent(levels)
        chat.agent = agent

        chat.switch_model(provider: "glm", id: "glm-5.3", name: "GLM 5.3", reasoning: true,
          context_window: 200_000, max_tokens: nil, thinking_level_map: nil)

        assert_equal "medium", chat.instance_variable_get(:@thinking_level),
          "the in-set session level survives (the clamp's exact-pass branch)"
        assert_equal ["medium"], levels
      end
    end

    # The clamp applies to whatever the resolution yields: an out-of-set
    # DECLARED default clamps through the new model too (pi setThinkingLevel
    # runs on the composed level, not only on the stored one).
    def test_switch_clamps_an_out_of_set_declared_default
      with_chat(width: 40, screen_height: 16, models: model_catalog,
        footer_data: {cwd: @dir, model: "boot-model", context_window: 1000,
                      default_provider: "openai", thinking_level: "low", reasoning: true}) do |chat|
        FileUtils.mkpath(@dir)
        File.write(File.join(@dir, "settings.json"), '{"thinkingLevel": "xhigh"}')
        levels = []
        agent, = switching_agent(levels)
        chat.agent = agent

        chat.switch_model(provider: "glm", id: "glm-5.3", name: "GLM 5.3", reasoning: true,
          context_window: 200_000, max_tokens: nil, thinking_level_map: nil)

        assert_equal "high", chat.instance_variable_get(:@thinking_level),
          "the declared xhigh clamps to the map-less ceiling"
        assert_equal ["high"], levels
      end
    end

    # pi setModel shows ONLY the model status (interactive-mode.ts
    # :5347-5351); the level change rides thinking_level_changed, which
    # refreshes footer + border without a status row (:3495-3498).
    def test_switch_enqueues_no_thinking_status_row
      with_chat(width: 40, screen_height: 16, models: model_catalog,
        footer_data: {cwd: @dir, model: "boot-model", context_window: 1000,
                      default_provider: "openai", thinking_level: "xhigh", reasoning: false}) do |chat, session|
        levels = []
        agent, = switching_agent(levels)
        chat.agent = agent

        chat.switch_model(provider: "glm", id: "glm-5.3", name: "GLM 5.3", reasoning: true,
          context_window: 200_000, max_tokens: nil, thinking_level_map: nil)
        draw(chat, session)

        tail = chat.transcript_lines.join
        assert_includes tail, "Model: glm-5.3", "the switch reports pi's showStatus text"
        refute_includes tail, "Thinking level:", "no level status on the switch path"
        refute_includes tail, "Default thinking level:"
      end
    end

    # The ✓ letter (pi thinking-selector.ts:69-73): EXACT equality — a
    # stored level OUTSIDE the gated set marks NO row; the sealed
    # constructor's preselect falls to index 0 (buildSelectList :101-107).
    def test_thinking_menu_marks_no_row_for_an_out_of_set_stored_level
      with_chat(width: 40, screen_height: 16,
        footer_data: {cwd: @dir, model: "m", context_window: 1000, thinking_level: "xhigh", reasoning: true}) do |chat|
        chat.open_thinking_menu

        menu = chat.instance_variable_get(:@menu)
        refute menu.instance_variable_get(:@items).any? { |item| item[:current] },
          "no ✓ row: the map-less ladder has no xhigh (exact equality, no display floor)"
        assert_equal "off", chat.menu_selection&.fetch(:value), "the preselect lands on index 0"
      end
    end

    # The /thinking arg gate lives on the surface (pi handleThinkingCommand
    # is interactive-mode code; the frozen Commands::Handler renders the
    # full ladder) — routed through chat submit's dispatch seam.
    def thinking_chat(footer_data)
      with_chat(width: 40, screen_height: 16, footer_data:) do |chat, session|
        chat.commands = Commands::Handler.new(
          skills: [], settings: {}, output: ->(text) { @commands_output << text },
          spawn: ->(&block) { block.call }, agent: -> { nil }, reset: -> {},
          thinking: ->(level) { chat.set_thinking_level(level) },
          thinking_menu: -> { chat.open_thinking_menu }, quit: -> {}
        )
        draw(chat, session)
        yield chat, session
      end
    end

    def test_thinking_command_rejects_ungated_levels_with_the_gated_set
      thinking_chat({cwd: @dir, model: "m", context_window: 1000, thinking_level: "off", reasoning: false}) do |chat, session|
        send_message(chat, "/thinking high")
        draw(chat, session)

        assert_includes chat.transcript_lines.join, 'Unknown thinking level "high". Available levels: off.',
          "the error lists the GATED set (pi handleThinkingCommand :5153-5155)"
        assert_nil chat.instance_variable_get(:@thinking_level), "the level holds (no status rode)"
        refute_includes chat.transcript_lines.join, "Thinking level:", "no selection status rendered"
      end
    end

    def test_thinking_command_accepts_gated_levels_and_switching_re_gates
      with_chat(width: 40, screen_height: 16, models: mock_native_catalog,
        footer_data: {cwd: @dir, model: "mock-1", default_provider: "openai",
                      context_window: 33_000, thinking_level: "off", reasoning: true}) do |chat, session|
        chat.switch_model(provider: "mock", id: "mock-1", name: "Mock 1", reasoning: false,
          context_window: 33_000, max_tokens: nil)
        draw(chat, session)

        chat.open_thinking_menu
        menu = chat.instance_variable_get(:@menu)
        assert_equal %w[off], menu.instance_variable_get(:@items).map { |item| item[:value] },
          "the runtime switch re-gates (the entry's reasoning flag rides the footer view)"
      end
    end

    # pi cycleThinkingLevel (:2645-2646): no thinking support → undefined
    # (the shift+tab cycle is a no-op).
    def test_shift_tab_cycle_is_a_noop_for_a_non_reasoning_runtime_model
      with_chat(width: 40, screen_height: 12,
        footer_data: {cwd: @dir, model: "m", context_window: 1000, reasoning: false}) do |chat, session|
        chat.on_event(TUI.key_event("tab", modifiers: ["shift"]))
        draw(chat, session)

        assert_nil chat.instance_variable_get(:@thinking_level), "cycled nothing"
        assert session.buffer_content[footer_stats_row(session)].rstrip.end_with?("m"),
          "the footer's model segment stays the bare model"
      end
    end

    # The /model dispatch wiring through the bin-shaped handler: bare →
    # the menu, exact → the direct switch, unknown → the menu pre-seeded
    # (pi handleModelCommand).
    def test_model_command_dispatch_menu_exact_and_seeded
      with_headless_chat(models: model_catalog,
        footer_data: {cwd: @dir, model: "boot-model", default_provider: "openai"}) do |chat|
        chat.commands = Commands::Handler.new(
          skills: [], settings: {}, output: ->(text) { @commands_output << text },
          spawn: ->(&block) { block.call }, agent: -> { nil }, reset: -> {},
          models: model_catalog, model: ->(entry) { chat.switch_model(entry) },
          model_menu: ->(seed) { chat.open_model_menu(seed) },
          thinking_menu: -> { chat.open_thinking_menu }, quit: -> {}
        )

        send_message(chat, "/model")
        assert chat.menu_open?, "the bare command opens the menu"
        chat.on_event(TUI.key_event("esc"))
        refute chat.menu_open?

        send_message(chat, "/model glm/glm-5.3")
        refute chat.menu_open?, "an exact match switches directly"

        send_message(chat, "/model air")
        assert chat.menu_open?, "an unknown arg opens the menu pre-seeded"
        assert_equal "glm-5-air", chat.menu_selection&.fetch(:id),
          "the seed filtered the catalog to the match at the top row"
      end
    end

    # The footer's pwd line renders the dim token (pi footer.ts:282 —
    # theme.fg("dim", pwd); the line-level fg was silently dropped by the
    # span-array path — the default-fg pwd/branch defect).
    def test_footer_pwd_renders_the_dim_token
      with_chat(width: 40, screen_height: 12,
        footer_data: {cwd: "/tmp", model: "m", context_window: 1000}, branch_reader: ->(_cwd) { "main" }) do |chat, session|
        draw(chat, session)
        pwd_row = session.buffer_content.index { |row| row.include?("(") && row.include?("main") }
        text = session.buffer_content[pwd_row]
        assert_equal Theme[:dim], session.cell_fg(text.index("/"), pwd_row), "the pwd renders dim"
        assert_equal Theme[:dim], session.cell_fg(text.index("main"), pwd_row), "the branch renders dim"
      end
    end

    # The footer's dim analog (item 9): pi dims the WHOLE footer
    # (footer.ts:280-288) — every span renders the dim token except the
    # context segment over the thresholds.
    def test_footer_stats_render_dim_except_the_threshold_segment
      with_chat(width: 40, screen_height: 12,
        footer_data: {cwd: @dir, model: "m", context_window: 1000}) do |chat, session|
        draw(chat, session)
        row = footer_stats_row(session)
        model_x = (0...40).find { |x| session.buffer_content[row][x] == "m" }
        assert_equal Theme[:dim], session.cell_fg(model_x, row),
          "the model renders the dim token color (pi footer.ts:282 — dimStatsLeft)"
      end
    end

    def test_footer_branch_is_cached_and_invalidated_per_turn
      with_chat(width: 40, screen_height: 12, footer_data: {cwd: @dir, model: "m", context_window: 1000},
        branch_reader: branch_counter) do |chat, session|
        draw(chat, session)
        draw(chat, session)
        assert_equal 1, @branch_calls, "the branch is cached across frames"

        send_message(chat, "new turn")
        draw(chat, session)
        assert_equal 2, @branch_calls, "a submission invalidates the branch cache"

        chat.on_agent_event({type: :agent_start})
        draw(chat, session)
        assert_equal 3, @branch_calls, "an agent start invalidates the branch cache"
      end
    end

    # --- input line (minimal: chars, backspace, enter, paste) ---

    def test_input_line_edits_and_submits
      chat_idle_kernel = IdleKernel.new
      TUI.run(headless: true, viewport: :fullscreen, width: 40, screen_height: 12) do |session|
        chat = Render::Chat.new(session:, kernel: chat_idle_kernel, motd: false)
        "hi".each_char { |char| chat.on_event(TUI.key_event(char)) }
        chat.on_event(TUI.paste_event(" there"))
        chat.on_event(TUI.key_event("backspace"))
        assert_equal "hi ther", chat.input, "backspace removes the last character"
        chat.on_event(TUI.key_event("e", modifiers: ["ctrl"]))
        assert_equal "hi ther", chat.input, "ctrl+e moves to line end without editing"
        chat.on_event(TUI.key_event("enter"))
        assert_equal "", chat.input, "enter submits and clears the input line"
        draw(chat, session) # the frame's flush moves the echo into the buffer
        assert_equal ["", " hi ther", ""], chat.transcript_lines,
          "the submitted prompt is echoed into the transcript"
        assert_equal 1, chat_idle_kernel.submitted.size, "an idle submit starts an agent run"
      end
    end

    # --- cursor (I06/AC2): the insertion point is cell-readback-visible at
    # all times — pi's fake cursor: the grapheme under it renders
    # inverse-video, at end-of-input a highlighted trailing space (tui.ts
    # renderFakeCursor via editor.ts:583-597); the port carries the
    # reversed modifier. ---

    def test_cursor_reads_back_at_end_of_input
      with_chat(width: 40) do |chat, session|
        "hi".each_char { |char| chat.on_event(TUI.key_event(char)) }
        draw(chat, session)
        row = input_row(session)
        assert_equal [" ", [:reversed]], cursor_cell(session, 2, row),
          "end-of-input cursor: highlighted trailing space after 'hi'"
        assert session.cell_modifiers(1, row).empty?, "the grapheme left of the cursor is unhighlighted"
      end
    end

    def test_cursor_reads_back_mid_input_and_tracks_left_right
      with_chat(width: 40) do |chat, session|
        "hi".each_char { |char| chat.on_event(TUI.key_event(char)) }
        chat.on_event(TUI.key_event("left"))
        draw(chat, session)
        row = input_row(session)
        assert_equal ["i", [:reversed]], cursor_cell(session, 1, row),
          "after cursor-left the insertion point sits on the 'i'"
        assert session.cell_modifiers(2, row).empty?, "the trailing space is no longer highlighted"

        chat.on_event(TUI.key_event("right"))
        draw(chat, session)
        assert_equal [" ", [:reversed]], cursor_cell(session, 2, row),
          "cursor-right returns the insertion point to end-of-input"
      end
    end

    # --- history (I06/AC3): pi's editor.ts addToHistory/navigateHistory —
    # most recent first, draft restored, recalled entries editable. The
    # editor-state halves of these moved to test/render/editor_test.rb
    # (driving Editor directly); the submit-cycle halves stay here — the
    # echo/agent assertions run through Chat's public surface. ---

    def test_recalled_history_entry_is_editable_and_sends_as_edited
      chat_idle_kernel = IdleKernel.new
      TUI.run(headless: true, viewport: :fullscreen, width: 40, screen_height: 12) do |session|
        chat = Render::Chat.new(session:, kernel: chat_idle_kernel, motd: false)
        send_message(chat, "A")
        send_message(chat, "B")
        chat.on_event(TUI.key_event("up"))
        chat.on_event(TUI.key_event("up")) # "A", cursor at line start (pi: cursorPlacement start)
        chat.on_event(TUI.key_event("X"))
        # A LEADING bang would now be the user-bash intercept (backlog C)
        # — the edit types a plain char at the cursor instead.
        assert_equal "XA", chat.input, "a recalled entry is editable at the cursor"
        chat.on_event(TUI.key_event("enter"))
        draw(chat, session) # the frame's flush moves the echo into the buffer
        # Echo 1 on an empty container: padY wrap only (no leading spacer,
        # interactive-mode.ts:3930-3931); later echoes get the spacer too.
        assert_equal ["", " A", "", "", "", " B", "", "", "", " XA", ""], chat.transcript_lines,
          "the edited recall sends as edited (after the two original echoes: padY wrap + spacer + pad rows)"
      end
    end

    # app.exit (pi custom-editor.ts:118-125, keybindings.ts:28 — the gem
    # delivers ctrl+d as code "d" + ctrl): empty editor exits, non-empty
    # deletes forward.
    def test_ctrl_d_on_empty_input_exits_the_run
      TUI.run(headless: true, viewport: :fullscreen, width: 40, screen_height: 12) do |session|
        kernel = IdleKernel.new
        chat = Render::Chat.new(session:, kernel:, motd: false)
        chat.on_event(TUI.key_event("d", modifiers: ["ctrl"]))
        assert kernel.stopped?, "ctrl+d on an empty editor exits via the kernel's stop! (the /quit path)"
      end
    end

    def test_ctrl_d_with_content_deletes_forward
      with_headless_chat do |chat|
        "hi".each_char { |char| chat.on_event(TUI.key_event(char)) }
        chat.on_event(TUI.key_event("left")) # the char after the cursor is what dies
        chat.on_event(TUI.key_event("d", modifiers: ["ctrl"]))
        assert_equal "h", chat.input, "ctrl+d with content falls through to delete-char-forward (pi custom-editor.ts:123-125)"
      end
    end

    # ---- the !-prefix user bash (backlog C — pi handleBashCommand over
    # the BashExecutionComponent). ----

    # The block renders bordered in the bashMode key with the header,
    # muted output, and NO user echo (the component is the display — pi
    # handleSubmit :3347-3360).
    def test_bang_bash_runs_and_renders_the_bordered_block
      with_chat(width: 60) do |chat, session|
        send_message(chat, "! echo hi")
        drain_runs(chat)
        draw(chat, session)

        rows = chat.transcript_lines
        top = rows.index { |row| row.include?("─") }
        assert top, "the block renders its top border"
        assert_equal "─" * 60, rows[top].strip, "the border spans the viewport"
        header = rows.index { |row| row.include?("$ echo hi") }
        assert_equal " $ echo hi", rows[header], "the bold bashMode header"
        assert rows.any? { |row| row.strip == "hi" }, "the command output renders below"
        refute rows.any? { |row| row.include?("! echo hi") },
          "the ! text never echoes as a user message (the block is the display)"
      end
    end

    # pi's colorKey: "!!" marks the excluded execution dim (the component's
    # border and header), the plain ! renders bashMode.
    def test_bang_bang_renders_the_dim_keyed_block
      with_chat(width: 60) do |chat, session|
        send_message(chat, "!! echo secret")
        drain_runs(chat)
        draw(chat, session)

        buffer = session.buffer_content
        border_row = buffer.index { |row| row.include?("─") }
        assert_equal Theme[:dim], session.cell_fg(0, border_row),
          "the !! block's border renders the dim token (excludeFromContext — bash-execution.ts:38 colorKey)"
      end
    end

    # pi's isBashRunning gate: a second ! while one runs shows the warning
    # and runs nothing (showWarning's text, handleBashCommand's gate).
    def test_bang_bash_single_flight_warns
      with_chat(width: 60) do |chat, session|
        send_message(chat, "! echo one")
        send_message(chat, "! echo two")
        draw(chat, session)

        assert chat.transcript_lines.any? { |row| row.include?("already running") },
          "the single-flight warning renders pi's text (wrapped to the pane)"
        assert_equal 1, drain_runs(chat).size, "only the first execution queued"
      end
    end

    # The completed execution records a bashExecution entry (pi
    # recordBashResult — the pi-shaped message hash, the file-creation
    # gate included).
    def test_bang_bash_records_a_bash_execution_entry
      recorder = Agent::Session::Recorder.new(cwd: @dir, root: @dir)
      with_chat(width: 60) do |chat, session|
        chat.agent = Object.new.tap do |a|
          a.define_singleton_method(:record_bash_execution) { |m| recorder.append_bash_execution(m) }
          a.define_singleton_method(:push_message) { |*| raise "not reached" }
        end
        send_message(chat, "! echo hi")
        drain_runs(chat)
      end

      entries = File.readlines(recorder.path).map { |line| JSON.parse(line) }
      message = entries.last.fetch("message")
      assert_equal "bashExecution", message["role"]
      assert_equal "echo hi", message["command"]
      # pi's appendText keeps the raw trailing newline (the display's
      # trailing blank row and the context text's shape both derive
      # from it) — recorded verbatim.
      assert_equal "hi\n", message["output"]
      assert_equal 0, message["exitCode"]
      refute message["cancelled"]
      refute message["truncated"]
      refute message["excludeFromContext"]
    end

    # The recorded execution replays through the same block shape (pi
    # addMessageToChat's bashExecution case).
    def test_resume_replays_the_bash_execution_block
      recorded = File.join(@dir, "bash-exec-replay.jsonl")
      File.write(recorded, <<~JSONL)
        {"type":"session","version":3,"id":"bash-exec","timestamp":"2026-01-01T00:00:00.000Z","cwd":"#{@dir}"}
        {"type":"message","id":"e1","parentId":null,"timestamp":"2026-01-01T00:00:01.000Z","message":{"role":"bashExecution","command":"echo hi","output":"hi","exitCode":0,"cancelled":false,"truncated":false,"fullOutputPath":null,"timestamp":"2026-01-01T00:00:02.000Z","excludeFromContext":false}}
      JSONL
      with_chat(width: 60, screen_height: 24) do |chat, session|
        chat.resume_session(recorded)
        draw(chat, session)

        assert chat.transcript_lines.any? { |row| row.include?("$ echo hi") },
          "the replayed block renders from the record"
      end
    end

    # app.clear (pi handleCtrlC :6840-6848): the first press clears the
    # editor; a second within 500 ms exits; the interrupt stays with
    # escape.
    def test_ctrl_c_clears_the_input_and_double_press_exits
      with_headless_chat do |chat, _session|
        kernel = chat.kernel
        "abc".each_char { |char| chat.on_event(TUI.key_event(char)) }
        chat.on_event(TUI.key_event("c", modifiers: ["ctrl"]))
        assert_equal "", chat.input, "the first ctrl+c clears the editor"
        refute kernel.stopped?, "one press never exits"

        chat.on_event(TUI.key_event("c", modifiers: ["ctrl"]))
        assert kernel.stopped?, "the double press exits (handleCtrlC's 500 ms window)"
      end
    end

    # pi onEscape :3076-3080 — bash mode clears the input (the border
    # announces the mode; escape backs out of it).
    def test_escape_clears_bash_mode_input
      with_headless_chat do |chat|
        "!ech".each_char { |char| chat.on_event(TUI.key_event(char)) }
        chat.on_event(TUI.key_event("esc"))
        assert_equal "", chat.input, "escape in bash mode clears the input"
      end
    end

    # A RUNNING user bash cancels on escape (pi abortBash — the
    # single-flight warning names the binding): the checkpoint flag flips,
    # the tool kills the group at its next check, and the cancelled block
    # renders with the partial output.
    def test_escape_cancels_the_running_user_bash
      with_chat(width: 60) do |chat, session|
        send_message(chat, "!sleep 5")
        workers = chat.kernel.submitted.slice!(0..)
        reactor = Thread.new do
          Async do |root|
            workers.each { |block| root.async { block.call } }
          end
        end
        sleep 0.3 # the command is running
        chat.on_event(TUI.key_event("esc"))
        reactor.join(5)
        draw(chat, session)

        assert chat.transcript_lines.any? { |row| row.include?("cancelled") },
          "the escape cancelled the running user bash"
      end
    end

    # pi updateEditorBorderColor :1109-1117 — the editor's border renders
    # the bashMode token while the input starts with "!".
    def test_bash_mode_border_renders_the_bash_mode_token
      with_chat(width: 40) do |chat, session|
        "!ech".each_char { |char| chat.on_event(TUI.key_event(char)) }
        draw(chat, session)

        buffer = session.buffer_content
        border_row = buffer.index { |row| row.include?("─") }
        assert_equal Theme[:bashMode], session.cell_fg(0, border_row),
          "the editor border announces bash mode (getBashModeBorderColor)"
      end
    end

    # ---- the ctrl+o global tool-output toggle (pi app.tools.expand,
    # setToolsExpanded :6810-6826) ----

    # The bash block rebuilds in place: collapsed = the hint + last 5,
    # expanded = all rows, no hint; the truncation notice and Took ride
    # in both states; the border status reports (pi showStatus).
    def test_ctrl_o_expands_and_collapses_the_bash_block
      output = Array.new(8) { |i| "line #{i + 1}" }.join("\n")
      with_chat(width: 40) do |chat, session|
        tool_end(chat, "bash", output, duration: 0.0, arguments: {"command" => "seq"})
        draw(chat, session)
        assert_equal [" ... (3 earlier lines, ctrl+o to expand)", " line 4", " line 5", " line 6", " line 7", " line 8"],
          chat.transcript_lines[4, 6], "collapsed at enqueue (the I19 shape)"

        chat.on_event(TUI.key_event("o", modifiers: ["ctrl"]))
        draw(chat, session)
        assert_equal [" line 1", " line 2", " line 3", " line 4", " line 5", " line 6", " line 7", " line 8"],
          chat.transcript_lines[4, 8],
          "expanded in place — all rows, no hint, no re-enqueue"
        assert chat.transcript_lines.none? { |row| row.include?("earlier lines") },
          "the expand hint dies expanded"

        chat.on_event(TUI.key_event("o", modifiers: ["ctrl"]))
        draw(chat, session)
        assert_equal [" ... (3 earlier lines, ctrl+o to expand)", " line 4"],
          chat.transcript_lines[4, 2], "the second press collapses again"
      end
    end

    # The toggle works MID-STREAM (pi tui-alt-screen: the app.tools.expand
    # action is not idle-gated): a tool block in the buffer + a live
    # region growing, ctrl+o rebuilds the block in place.
    def test_ctrl_o_works_while_a_message_is_streaming
      output = Array.new(8) { |i| "line #{i + 1}" }.join("\n")
      with_chat(width: 40) do |chat, session|
        tool_end(chat, "bash", output, duration: 0.0, arguments: {"command" => "seq"})
        draw(chat, session)
        chat.on_agent_event({type: :agent_start})
        chat.on_agent_event({type: :message_start, message: ChunkDouble.new})
        chat.on_agent_event({type: :message_update, chunk: ChunkDouble.new("streaming away")})
        draw(chat, session)
        assert chat.busy?, "the turn is in flight"

        chat.on_event(TUI.key_event("o", modifiers: ["ctrl"]))
        draw(chat, session)
        assert_includes chat.transcript_lines.join, " line 1",
          "the block rebuilds mid-stream"
        assert chat.transcript_lines.none? { |row| row.include?("earlier lines") },
          "the collapsed hint is gone mid-stream"
      end
    end

    def test_ctrl_o_reports_the_toggle_in_the_border_status
      with_chat(width: 40) do |chat, session|
        tool_end(chat, "bash", "out", arguments: {"command" => "x"})
        draw(chat, session)

        chat.on_event(TUI.key_event("o", modifiers: ["ctrl"]))
        draw(chat, session)
        assert chat.renderer.call.to_s.include?("Tool output: expanded"),
          "the border status reports the toggle (pi showStatus)"

        chat.on_event(TUI.key_event("o", modifiers: ["ctrl"]))
        draw(chat, session)
        assert chat.renderer.call.to_s.include?("Tool output: collapsed"),
          "the border status reports the collapse"
      end
    end

    # The write block's content preview uncaps expanded (write.ts:117) —
    # and the LATER blocks keep their transcript positions through the
    # splice (the registry's start/size bookkeeping).
    def test_ctrl_o_expands_the_write_preview_and_keeps_later_blocks_in_place
      content = Array.new(12) { |i| "wline #{i + 1}" }.join("\n")
      with_chat(width: 40) do |chat, session|
        tool_end(chat, "write", "", arguments: {"path" => "n.txt", "content" => content})
        tool_end(chat, "bash", "tail-output", arguments: {"command" => "tail"})
        draw(chat, session)
        assert_equal 10, chat.transcript_lines.count { |row| row.include?("wline") },
          "collapsed: the 10-line cap"
        assert chat.transcript_lines.any? { |row| row.include?("2 more lines, 12 total,") },
          "the write hint"

        chat.on_event(TUI.key_event("o", modifiers: ["ctrl"]))
        draw(chat, session)
        assert_equal 12, chat.transcript_lines.count { |row| row.include?("wline") },
          "expanded: the whole content"
        assert chat.transcript_lines.any? { |row| row.include?("tail-output") },
          "the later block survives the splice"
        refute chat.transcript_lines.any? { |row| row.include?("more lines") },
          "the hint dies expanded"
      end
    end

    # The read block expanded: the PLAIN call line forces over the compact
    # shape (read.ts:155) and the content renders uncapped
    # (formatReadResult:130).
    def test_ctrl_o_expands_the_read_block_to_content_rows
      with_chat(width: 40) do |chat, session|
        tool_end(chat, "read", "file body", arguments: {"path" => "AGENTS.md"})
        draw(chat, session)
        assert chat.transcript_lines.any? { |row| row.include?("read resource") },
          "collapsed: the compact resource shape"
        refute chat.transcript_lines.any? { |row| row.include?("file body") },
          "collapsed: the content renders nothing (read.ts:121)"

        chat.on_event(TUI.key_event("o", modifiers: ["ctrl"]))
        draw(chat, session)
        assert chat.transcript_lines.any? { |row| row.include?(" read AGENTS.md") },
          "expanded: the plain call line (the compact shape is gated on !expanded)"
        assert chat.transcript_lines.any? { |row| row.include?("file body") },
          "expanded: the content rows render"
      end
    end

    # The user-bash block expands too (pi's expandable children include
    # the BashExecutionComponent): whole output + the collapse hint.
    def test_ctrl_o_expands_the_user_bash_block
      with_chat(width: 60) do |chat, session|
        send_message(chat, "!echo hi")
        drain_runs(chat)
        draw(chat, session)
        refute chat.transcript_lines.any? { |row| row.include?("to collapse") },
          "collapsed: the hidden count is 0 — no hint either way"

        chat.on_event(TUI.key_event("o", modifiers: ["ctrl"]))
        draw(chat, session)
        assert chat.transcript_lines.any? { |row| row.include?("$ echo hi") },
          "the block survives the rebuild"
      end
    end

    # ---- the user-bash live stream (I38 — pi's BashExecutionComponent:
    # the running block exists from BEFORE execution, appendOutput +
    # requestRender per chunk, setComplete in place; handleBashCommand
    # :6987-7062). Mid-flight drives the manual-reactor idiom (the
    # escape-cancel test's shape): the IdleKernel task block runs in a
    # side reactor thread while the test thread draws. ----

    # Runs the queued user-bash task block in a side reactor thread (the
    # bridge's queue pop needs a real reactor); returns the thread.
    def run_user_bash_task(chat)
      workers = chat.kernel.submitted.slice!(0..)
      Thread.new do
        Async do |root|
          workers.each { |block| root.async { block.call } }
        end
      end
    end

    def row_texts(lines)
      lines.map { |line| line.spans.map(&:content).join }
    end

    # The live loader row's spans (nil when no running block is on screen).
    def loader_row_spans(chat)
      chat.display_lines.map(&:spans).find { |spans| spans.map(&:content).join.include?("Running...") }
    end

    # AC1: mid-flight the live region renders the running family below the
    # transcript content while the transcript itself has NO block. The
    # settled-flush pins live in the main-thread tests below — the side
    # reactor thread owns no terminal (the escape-cancel idiom's known
    # artifact: the task's finish dies at the block_sink viewport read;
    # the explicit stream_end clear has already run).
    def test_running_user_bash_renders_the_streaming_block_midflight
      with_chat(width: 60, screen_height: 24) do |chat, session|
        send_message(chat, "!printf 'alpha\\n'; sleep 0.5; printf 'beta\\n'")
        reactor = run_user_bash_task(chat)
        sleep 0.2 # the first chunk has landed; the second has not
        draw(chat, session)

        rows = row_texts(chat.display_lines)
        assert chat.user_bash_streaming?, "the run is in flight"
        assert rows.any? { |row| row == " $ printf 'alpha\\n'; sleep 0.5; printf 'beta\\n'" },
          "the running block's header renders (the block exists before execution, :7000-7012)"
        assert rows.any? { |row| row == " alpha" }, "the landed chunk renders mid-flight"
        refute rows.any? { |row| row == " beta" }, "only the accumulated text renders"
        assert rows.any? { |row| row.include?("Running... (escape/ctrl+c to cancel)") },
          "the loader row renders pi's bytes"
        refute chat.transcript_lines.any? { |row| row.include?("$ printf") },
          "the transcript has NO block mid-flight (the live rows are transient)"

        reactor.join(5)
        draw(chat, session)
        refute chat.user_bash_streaming?, "the terminal path cleared the live rows"
        refute row_texts(chat.display_lines).any? { |row| row.include?("Running...") },
          "zero live rows after the run (AC2)"
      end
    end

    # AC2: the completed block flushes byte-identical (rows + position) to
    # a control chat that received only the enqueue with the same fields.
    def test_completed_block_flush_is_byte_identical_to_a_control_enqueue
      settled = nil
      with_chat(width: 60) do |chat, session|
        send_message(chat, "!echo settle-check")
        drain_runs(chat)
        draw(chat, session)
        settled = chat.transcript_lines
        refute chat.user_bash_streaming?
        assert_equal settled, row_texts(chat.display_lines), "zero live rows at the outcome terminal (AC2)"
      end

      with_chat(width: 60) do |chat, session|
        chat.instance_variable_get(:@transcript_state).enqueue_user_bash_block(
          "echo settle-check", content: "settle-check\n", exit_code: 0, cancelled: false,
          truncated: false, full_output_path: nil, excluded: false)
        draw(chat, session)
        assert_equal settled, chat.transcript_lines,
          "the flushed block is byte-identical in rows and position (AC2)"
      end
    end

    # AC3 mid-flight: the appendOutput join, string-buffer equivalent — an
    # unterminated trailing line renders as its own row and the next
    # chunk's first piece continues it. The settled bytes re-run through
    # the main-thread drain (the side reactor owns no terminal).
    def test_user_bash_chunks_join_through_the_string_buffer
      with_chat(width: 60, screen_height: 24) do |chat, session|
        send_message(chat, "!printf 'par'; sleep 0.3; printf 'tial\\r\\nline2'; sleep 0.3; printf 'tail'")
        reactor = run_user_bash_task(chat)
        sleep 0.45 # chunks 1-2 have landed ("par" + "tial\nline2")
        draw(chat, session)

        rows = row_texts(chat.display_lines)
        assert rows.any? { |row| row == " partial" }, "the unterminated first line joined across chunks"
        assert rows.any? { |row| row == " line2" }, "the chunk's newline opened the second row"
        refute rows.any? { |row| row == " tial" }, "no split fragment row (the appendOutput join)"

        reactor.join(5)
        send_message(chat, "!printf 'par'; printf 'tial\\r\\nline2'; printf 'tail'")
        drain_runs(chat)
        draw(chat, session)
        assert chat.transcript_lines.any? { |row| row == " line2tail" },
          "the trailing chunk continued the unterminated row (settled bytes agree)"
      end
    end

    # AC3: CR-only chunk text vanishes — CR is REMOVED, never mapped.
    def test_user_bash_cr_only_chunks_vanish
      with_chat(width: 60, screen_height: 24) do |chat, session|
        send_message(chat, "!printf 'x\\ry'; sleep 0.4; printf ' end'")
        reactor = run_user_bash_task(chat)
        sleep 0.15
        draw(chat, session)

        rows = row_texts(chat.display_lines)
        assert rows.any? { |row| row == " xy" }, "the CR-only piece vanished; the line joins through"
        refute rows.any? { |row| row.include?("\r") }, "no CR anywhere mid-flight"

        reactor.join(5)
        send_message(chat, "!printf 'x\\ry'; sleep 0.3; printf ' end'")
        drain_runs(chat)
        draw(chat, session)
        assert chat.transcript_lines.any? { |row| row == " xy end" },
          "the settled block carries the same joined bytes (the trailing chunk continues the row)"
      end
    end

    # AC2: the worker-error terminal (the ENOENT arm) clears the live rows
    # too — the error line renders, no block, zero live rows.
    def test_worker_error_clears_the_live_rows
      Dir.chdir(@dir) do
        # footer_data pins the cwd: the deleted-cwd trick must not trip the
        # footer's Dir.pwd fallback mid-test.
        with_chat(width: 60, screen_height: 24, footer_data: {cwd: @dir}) do |chat, session|
          send_message(chat, "!echo boom") # the tool captured the (still-live) cwd
          FileUtils.rmdir(@dir) # the cwd dies before the worker runs — the ENOENT arm
          drain_runs(chat)
          draw(chat, session)

          refute chat.user_bash_streaming?, "the worker-error terminal cleared the live rows"
          refute row_texts(chat.display_lines).any? { |row| row.include?("Running...") },
            "zero Running... anywhere (AC2)"
          assert chat.transcript_lines.any? { |row| row.include?("bash: No such file or directory") },
            "the worker error surfaced as the error line (the ENOENT arm)"
          refute chat.transcript_lines.any? { |row| row.include?("$ echo boom") },
            "no block renders on a worker error"
        end
      end
    end

    # AC2: the escape-cancel terminal clears the live rows; the cancelled
    # block keeps its partial output (existing behavior).
    def test_escape_cancel_clears_the_live_rows_and_keeps_partial_output
      with_chat(width: 60, screen_height: 24) do |chat, session|
        send_message(chat, "!printf 'kept\\n'; sleep 5")
        reactor = run_user_bash_task(chat)
        sleep 0.3
        draw(chat, session)
        assert chat.user_bash_streaming?, "the run is mid-flight"

        chat.on_event(TUI.key_event("esc"))
        reactor.join(5)
        draw(chat, session)

        refute chat.user_bash_streaming?, "the cancel terminal cleared the live rows"
        refute row_texts(chat.display_lines).any? { |row| row.include?("Running...") },
          "zero Running... anywhere (AC2)"
        assert chat.transcript_lines.any? { |row| row.include?("kept") },
          "the cancelled block keeps its partial output"
        assert chat.transcript_lines.any? { |row| row.include?("cancelled") },
          "the cancelled status row renders"
      end
    end

    # AC4: the glyph advances across draws with NO chunk between (the
    # animation window is open for the run) while @busy stays false — no
    # border Working status renders from a bash run.
    def test_bash_loader_glyph_advances_across_draws_without_busy
      t = 0.0
      clock = -> { t }
      kernel = RecordingKernel.new
      with_chat(width: 60, screen_height: 24, clock:, kernel:) do |chat, session|
        send_message(chat, "!sleep 2")
        reactor = run_user_bash_task(chat)
        sleep 0.2

        refute chat.busy?, "@busy stays false — a bash run is no agent turn"
        draw(chat, session)
        assert_equal "⠋", loader_row_spans(chat)[1].content, "frame 0 at the run-start anchor"
        animate_after_first_draw = kernel.animate_calls.length
        assert_operator animate_after_first_draw, :>=, 1, "the animation window is open for the run"

        t += Render::Chat::SPINNER_INTERVAL_SECONDS
        draw(chat, session) # no chunk between the draws — the glyph advances on TIME
        assert_equal "⠙", loader_row_spans(chat)[1].content

        t += Render::Chat::SPINNER_INTERVAL_SECONDS
        draw(chat, session)
        assert_equal "⠹", loader_row_spans(chat)[1].content

        assert_operator kernel.animate_calls.length, :>, animate_after_first_draw,
          "frames keep pacing while the run is in flight"
        refute chat.busy?, "still no agent turn"
        draw(chat, session)
        refute session.buffer_content.any? { |row| row.include?("Working") },
          "no border Working status renders from a bash run (mid-flight)"
        reactor.join(5)
      end
    end

    # AC4: the bash loader's anchor resets at each run start (pi: one
    # Loader per component) and is independent of the border status's
    # anchor — no bash run ever re-anchors the border spinner.
    def test_bash_loader_anchor_resets_at_run_start_independent_of_the_border_anchor
      t = 0.0
      clock = -> { t }
      with_chat(width: 60, screen_height: 24, clock:) do |chat, session|
        send_message(chat, "!sleep 2")
        reactor = run_user_bash_task(chat)
        sleep 0.2
        draw(chat, session)
        assert_equal "⠋", loader_row_spans(chat)[1].content
        reactor.join(5)

        # The second run starts with the clock advanced one dwell: a stale
        # anchor (the first run's) would show ⠙; the reset shows ⠋.
        t += Render::Chat::SPINNER_INTERVAL_SECONDS
        send_message(chat, "!sleep 2")
        reactor = run_user_bash_task(chat)
        sleep 0.2
        draw(chat, session)
        assert_equal "⠋", loader_row_spans(chat)[1].content,
          "the anchor resets at each run start (pi: one Loader per component)"
        assert_nil chat.instance_variable_get(:@spinner_started_at),
          "the border-status anchor is untouched by bash runs"
        reactor.join(5)
      end
    end

    # The colorKey: "!!" marks the excluded execution — the RUNNING
    # block's border and spinner ride dim (Grounds 6, the component's
    # constructor colorKey).
    def test_bang_bang_running_block_rides_dim_midflight
      with_chat(width: 60, screen_height: 24) do |chat, session|
        send_message(chat, "!!sleep 2")
        reactor = run_user_bash_task(chat)
        sleep 0.2
        draw(chat, session)

        buffer = session.buffer_content
        border_row = buffer.index { |row| row.include?("─" * 60) }
        assert_equal Theme[:dim], session.cell_fg(0, border_row),
          "the running block's border renders dim (excludeFromContext colorKey)"
        loader = buffer.index { |row| row.include?("Running...") }
        assert loader, "the loader row is on screen"
        assert_equal Theme[:dim], session.cell_fg(1, loader), "the spinner rides dim too"
        reactor.join(5)
      end
    end

    # Grounds 6f: mid-run ctrl+o reaches the RUNNING component — the
    # preview toggles (collapsed last-20 ↔ whole), and NO hidden-lines
    # hint renders in either state (pi's running branch replaces the
    # status block).
    def test_ctrl_o_toggles_the_running_preview_without_a_hint
      with_chat(width: 60, screen_height: 24) do |chat, session|
        send_message(chat, "!seq 1 25; sleep 2")
        reactor = run_user_bash_task(chat)
        sleep 0.2 # seq has printed all 25 lines; the run is mid-flight
        draw(chat, session)

        rows = row_texts(chat.display_lines)
        assert rows.any? { |row| row == " 25" }, "the output tail renders mid-flight"
        refute rows.any? { |row| row == " 1" }, "collapsed: the last-20 preview (AC1)"
        refute rows.any? { |row| row.include?("more lines") }, "NO hidden-lines hint mid-flight"

        chat.on_event(TUI.key_event("o", modifiers: ["ctrl"]))
        draw(chat, session)
        assert row_texts(chat.display_lines).any? { |row| row == " 1" },
          "expanded mid-run: the whole output (pi setToolsExpanded reaches the running component)"

        chat.on_event(TUI.key_event("o", modifiers: ["ctrl"]))
        draw(chat, session)
        refute row_texts(chat.display_lines).any? { |row| row == " 1" }, "collapsed again mid-run"
        reactor.join(5)
      end
    end

    # AC2: the replay path never sees mid-flight state — a recorded
    # bashExecution entry renders zero loader rows.
    def test_replay_renders_no_loader_rows
      recorded = File.join(@dir, "bash-replay-i38.jsonl")
      File.write(recorded, <<~JSONL)
        {"type":"session","version":3,"id":"i38","timestamp":"2026-01-01T00:00:00.000Z","cwd":"#{@dir}"}
        {"type":"message","id":"e1","parentId":null,"timestamp":"2026-01-01T00:00:01.000Z","message":{"role":"bashExecution","command":"echo hi","output":"hi","exitCode":0,"cancelled":false,"truncated":false,"fullOutputPath":null,"timestamp":"2026-01-01T00:00:02.000Z","excludeFromContext":false}}
      JSONL
      with_chat(width: 60) do |chat, session|
        chat.resume_session(recorded)
        draw(chat, session)

        rows = row_texts(chat.display_lines)
        assert rows.any? { |row| row.include?("$ echo hi") }, "the replayed block renders"
        refute rows.any? { |row| row.include?("Running...") }, "replay renders zero loader rows (AC2)"
      end
    end

    # (A byte-identical duplicate of the bash-mode border test above
    # shadowed it at HEAD — the second definition won, the first never
    # ran; dropped, the suite's run count reconciles with its source.)
    def test_ctrl_w_deletes_word_backward_through_the_key_surface
      with_headless_chat do |chat|
        "hello world".each_char { |char| chat.on_event(TUI.key_event(char)) }
        chat.on_event(TUI.key_event("w", modifiers: ["ctrl"]))
        assert_equal "hello ", chat.input, "ctrl+w removes the trailing word, keeping the separator"
        chat.on_event(TUI.key_event("w", modifiers: ["ctrl"]))
        assert_equal "", chat.input, "second ctrl+w removes the word plus trailing whitespace"
      end
    end

    # --- the emacs kill ring (I26, pi keybindings.ts:129-135): ctrl+u/k
    # kill, ctrl+y yanks, alt+y pops — driven through the key surface.

    def test_ctrl_u_kills_to_line_start_and_ctrl_y_yanks_it_back
      with_headless_chat do |chat|
        "hello world".each_char { |char| chat.on_event(TUI.key_event(char)) }
        chat.on_event(TUI.key_event("a", modifiers: ["ctrl"]))
        6.times { chat.on_event(TUI.key_event("right")) }
        chat.on_event(TUI.key_event("u", modifiers: ["ctrl"]))
        assert_equal "world", chat.input, "ctrl+u deletes to line start"
        chat.on_event(TUI.key_event("y", modifiers: ["ctrl"]))
        assert_equal "hello world", chat.input, "ctrl+y yanks the killed span"
      end
    end

    def test_ctrl_k_kills_to_line_end
      with_headless_chat do |chat|
        "hello world".each_char { |char| chat.on_event(TUI.key_event(char)) }
        chat.on_event(TUI.key_event("a", modifiers: ["ctrl"]))
        5.times { chat.on_event(TUI.key_event("right")) }
        chat.on_event(TUI.key_event("k", modifiers: ["ctrl"]))
        assert_equal "hello", chat.input, "ctrl+k deletes to line end"
        chat.on_event(TUI.key_event("y", modifiers: ["ctrl"]))
        assert_equal "hello world", chat.input, "ctrl+y restores the killed span"
      end
    end

    def test_consecutive_ctrl_k_kills_accumulate_and_alt_y_cycles
      with_headless_chat do |chat|
        %w[first second third].each do |word|
          word.each_char { |char| chat.on_event(TUI.key_event(char)) }
          chat.on_event(TUI.key_event("a", modifiers: ["ctrl"]))
          chat.on_event(TUI.key_event("k", modifiers: ["ctrl"])) # ctrl+k at line end is a no-op (single-line)
        end
        chat.on_event(TUI.key_event("y", modifiers: ["ctrl"]))
        assert_equal "third", chat.input, "yank takes the most recent entry"
        chat.on_event(TUI.key_event("y", modifiers: ["alt"]))
        assert_equal "second", chat.input, "alt+y cycles oldest-ward"
        chat.on_event(TUI.key_event("y", modifiers: ["alt"]))
        assert_equal "first", chat.input
        chat.on_event(TUI.key_event("y", modifiers: ["alt"]))
        assert_equal "third", chat.input, "the cycle wraps"
      end
    end

    def test_alt_y_is_a_no_op_without_a_prior_yank
      with_headless_chat do |chat|
        "first".each_char { |char| chat.on_event(TUI.key_event(char)) }
        chat.on_event(TUI.key_event("a", modifiers: ["ctrl"]))
        chat.on_event(TUI.key_event("k", modifiers: ["ctrl"]))
        "x".each_char { |char| chat.on_event(TUI.key_event(char)) } # typing closes the yank window
        chat.on_event(TUI.key_event("y", modifiers: ["alt"]))
        assert_equal "x", chat.input, "alt+y without a preceding yank does nothing"
      end
    end

    # --- undo (I39, pi keybindings.ts:142 tui.editor.undo = ctrl+-):
    # the arm fires with the list open (pi matches undo BEFORE the
    # autocomplete block, editor.ts:751-755); bare - types; submit
    # clears the stack (pi submitValue editor.ts:1373).

    def test_ctrl_minus_undoes_the_last_edit_through_the_key_surface
      with_headless_chat do |chat|
        "hello world".each_char { |char| chat.on_event(TUI.key_event(char)) }
        chat.on_event(TUI.key_event("-", modifiers: ["ctrl"]))
        assert_equal "hello", chat.input, "ctrl+- undoes the ' world' unit (the space captured pre-space)"
        chat.on_event(TUI.key_event("-", modifiers: ["ctrl"]))
        assert_equal "", chat.input, "'hello' is one typing unit"
      end
    end

    def test_bare_minus_still_types
      with_headless_chat do |chat|
        "a-b".each_char { |char| chat.on_event(TUI.key_event(char)) }
        assert_equal "a-b", chat.input, "bare - inserts (the arm's printable fall-through)"
      end
    end

    def test_alt_minus_stays_a_no_op
      with_headless_chat do |chat|
        "ab".each_char { |char| chat.on_event(TUI.key_event(char)) }
        chat.on_event(TUI.key_event("-", modifiers: ["alt"]))
        assert_equal "ab", chat.input, "alt+- is the modifier-guard no-op"
      end
    end

    def test_ctrl_minus_with_the_list_open_leaves_the_list_open
      with_headless_chat(autocomplete: slash_source("new", "help")) do |chat|
        chat.on_event(TUI.key_event("/"))
        assert_equal ["new", "help"], chat.suggestions.map { |item| item[:value] }
        chat.on_event(TUI.key_event("-", modifiers: ["ctrl"]))
        assert_equal "", chat.input, "undo fires with the list open (pi editor.ts:751-755)"
        assert chat.suggestions, "the list is neither cancelled nor re-filtered by undo"
      end
    end

    def test_submit_clears_the_undo_stack
      with_headless_chat do |chat|
        "hello world".each_char { |char| chat.on_event(TUI.key_event(char)) }
        chat.on_event(TUI.key_event("enter"))
        chat.on_event(TUI.key_event("-", modifiers: ["ctrl"]))
        assert_equal "", chat.input, "after submit, ctrl+- is a no-op (pi submitValue clears the stack)"
      end
    end

    # Regression pins (I26): ctrl+a/ctrl+e are settled surface (base) —
    # the kill-ring wiring must not have shifted them.
    def test_ctrl_a_and_ctrl_e_still_move_to_line_start_and_end
      with_headless_chat do |chat|
        "hello".each_char { |char| chat.on_event(TUI.key_event(char)) }
        chat.on_event(TUI.key_event("a", modifiers: ["ctrl"]))
        chat.on_event(TUI.key_event("X"))
        assert_equal "Xhello", chat.input, "ctrl+a still moves to line start"
        chat.on_event(TUI.key_event("e", modifiers: ["ctrl"]))
        chat.on_event(TUI.key_event("Y"))
        assert_equal "XhelloY", chat.input, "ctrl+e still moves to line end"
      end
    end

    # Regression pins (I26 Grounds 3 audit): alt+backspace/alt+d are the
    # deleteWordBackward/Forward defaults — already bound at base, pinned
    # so the kill-ring wiring keeps them that way.
    def test_alt_backspace_and_alt_d_delete_words
      with_headless_chat do |chat|
        "hello world".each_char { |char| chat.on_event(TUI.key_event(char)) }
        chat.on_event(TUI.key_event("a", modifiers: ["ctrl"]))
        5.times { chat.on_event(TUI.key_event("right")) }
        chat.on_event(TUI.key_event("d", modifiers: ["alt"]))
        assert_equal "hello", chat.input, "alt+d deletes the word forward (keybindings.ts:128)"
        chat.on_event(TUI.key_event("backspace", modifiers: ["alt"]))
        assert_equal "", chat.input, "alt+backspace deletes the word backward (keybindings.ts:124)"
      end
    end

    # --- autocomplete (AC1, I12): the /-triggered fuzzy suggestion list,
    # with pi's key precedence (the list owns up/down/escape/enter while
    # active — history and interrupt yield). ---

    def test_typing_slash_opens_the_fuzzy_list_below_the_input
      with_headless_chat(autocomplete: slash_source("new", "compact", "architect"), width: 50) do |chat, session|
        chat.on_event(TUI.key_event("/"))
        draw(chat, session)
        input_y, rows = editor_rows(session)
        assert_includes session.buffer_content[input_y - 1], "─", "the list renders inside the edit box (below the top border)"
        assert_equal 3, chat.suggestions.size
        assert_match(/\A→ new\s+new description\z/, rows[0], "the selection marker on the first item")
        assert_match(/\A  compact\s+compact description\z/, rows[1], "descriptions render beside the labels")
        assert_equal Theme[:accent], session.cell_fg(1, input_y + 1), "the selected row is accent (pi theme.ts:1063-1064)"
        assert_equal Theme[:muted], session.cell_fg(14, input_y + 2),
          "the description column renders the muted token color"
      end
    end

    def test_autocomplete_default_offers_nothing
      with_headless_chat do |chat|
        "/ar".each_char { |char| chat.on_event(TUI.key_event(char)) }
        assert_equal "/ar", chat.input
        assert_nil chat.suggestions, "no provider = no list (headless tests stay deterministic)"
      end
    end

    def test_further_typing_refilters_and_dismisses_the_list
      with_headless_chat(autocomplete: slash_source("new", "compact", "architect")) do |chat|
        "/co".each_char { |char| chat.on_event(TUI.key_event(char)) }
        assert_equal ["compact"], chat.suggestions.map { |item| item[:value] }, "the prefix filters fuzzily"
        chat.on_event(TUI.key_event("m"))
        chat.on_event(TUI.key_event("p"))
        assert_equal ["compact"], chat.suggestions.map { |item| item[:value] }, "typing re-filters"
        chat.on_event(TUI.key_event("z"))
        assert_nil chat.suggestions, "a token matching nothing dismisses the list"
        chat.on_event(TUI.key_event("backspace"))
        assert_equal ["compact"], chat.suggestions.map { |item| item[:value] }, "backspace re-triggers in context (pi editor.ts:1449-1463)"
      end
    end

    def test_up_down_navigate_the_list_instead_of_history
      with_headless_chat(autocomplete: slash_source("new", "help", "quit")) do |chat|
        "older message".each_char { |char| chat.on_event(TUI.key_event(char)) }
        chat.on_event(TUI.key_event("enter")) # lands in history
        "/".each_char { |char| chat.on_event(TUI.key_event(char)) }
        chat.on_event(TUI.key_event("down"))
        assert_equal "/", chat.input, "down does NOT browse history while the list is active"
        assert_equal 1, chat.suggestions_index, "down moves the selection"
        chat.on_event(TUI.key_event("up"))
        assert_equal 0, chat.suggestions_index
        chat.on_event(TUI.key_event("up"))
        assert_equal 2, chat.suggestions_index, "up wraps to the last item (pi select-list.ts:146-155)"
      end
    end

    def test_tab_applies_the_selection_without_submitting
      with_headless_chat(autocomplete: slash_source("architect"), width: 50) do |chat, session|
        "/ar".each_char { |char| chat.on_event(TUI.key_event(char)) }
        chat.on_event(TUI.key_event("tab"))
        assert_equal "/architect ", chat.input, "pi applyCompletion: /<value> with a trailing space"
        assert_nil chat.suggestions, "the list closes on apply"
        draw(chat, session)
        input_y, = editor_rows(session)
        # The fake cursor (reversed) sits on input position 11 — the
        # applied value's trailing space.
        assert_equal [:reversed], session.cell_modifiers(11, input_y), "the cursor lands after the applied value"
        assert_empty transcript_lines(session, chat).grep(/description/),
          "the transcript holds no submission echo — tab never submits"
      end
    end

    def test_enter_applies_and_submits_the_selection
      with_headless_chat(autocomplete: slash_source("architect")) do |chat, session|
        "/ar".each_char { |char| chat.on_event(TUI.key_event(char)) }
        chat.on_event(TUI.key_event("enter"))
        assert_equal "", chat.input
        draw(chat, session)
        assert_equal [" /architect"], transcript_lines(session, chat),
          "enter applies AND submits (pi editor.ts:790-816 — a /-prefix completion falls through to submit, trimmed)"
      end
    end

    # The live tab path (I13): /ar + tab through the kernel's synthetic
    # dispatch completes to the port's skill routing shape (commands.rb
    # /skill:<name>); the catalog is the real SlashSource over a skill.
    def test_tab_completes_a_skill_through_the_kernel_dispatch
      @server = MockLLMServer.new.start
      skill = Skills::Skill.new(name: "architect", description: "Runs the loop",
        file_path: "/fixtures/architect/SKILL.md", base_dir: "/fixtures/architect",
        disable_model_invocation: false)
      kernel, chat, session = chat_with_server(
        autocomplete: Render::SlashSource.new(commands: Commands::BUILTINS, skills: [skill]))

      scenario = Thread.new do
        "/ar".each_char { |char| session.push_event(TUI.key_event(char)) }
        session.push_event(TUI.key_event("tab"))
        wait_until { chat.input == "/skill:architect " }
        kernel.stop!
      end
      kernel.run
      scenario.join

      assert_equal "/skill:architect ", chat.input
    end

    def test_escape_cancels_the_list_without_interrupting_the_run
      with_headless_chat(autocomplete: slash_source("architect")) do |chat|
        chat.on_agent_event({type: :agent_start})
        "/ar".each_char { |char| chat.on_event(TUI.key_event(char)) }
        chat.on_event(TUI.key_event("esc"))
        assert_nil chat.suggestions, "escape cancels the list"
        assert_equal "/ar", chat.input, "the input is untouched"
        assert chat.busy?, "the run is NOT interrupted (pi custom-editor.ts:103-111)"
      end
    end

    def test_escape_with_no_list_leaves_the_run_alone_and_is_a_noop
      with_headless_chat do |chat|
        chat.on_event(TUI.key_event("esc"))
        assert_equal "", chat.input, "the port binds no escape action outside the list"
      end
    end

    def test_typing_a_space_dismisses_the_list
      with_headless_chat(autocomplete: slash_source("new")) do |chat|
        "/new".each_char { |char| chat.on_event(TUI.key_event(char)) }
        assert chat.suggestions
        chat.on_event(TUI.key_event(" "))
        assert_nil chat.suggestions, "a space means argument completion — none exist (pi autocomplete.ts:340-341)"
        assert_equal "/new ", chat.input
      end
    end

    def test_list_windows_at_five_items_with_a_scroll_info_line
      names = %w[one two three four five six seven]
      with_headless_chat(autocomplete: slash_source(*names), width: 50) do |chat, session|
        chat.on_event(TUI.key_event("/"))
        draw(chat, session)
        _, rows = editor_rows(session)
        assert_equal 7, chat.suggestions.size, "the full filtered list is held"
        assert_match(/\A→ one\s+one description\z/, rows[0], "the window opens at the top...")
        assert_match(/\A  five/, rows[4], "...five items deep (maxVisible 5, fixed)")
        assert_match(/\(1\/7\)/, rows[5], "the (i/N) scroll-info line renders (select-list.ts:107-110)")
        5.times { chat.on_event(TUI.key_event("down")) }
        draw(chat, session)
        _, rows = editor_rows(session)
        assert_match(/\A  five/, rows[2], "the window slides with the selection (centered, pi getVisibleRange)")
        assert_match(/\A→ six/, rows[3])
        assert_match(/\A  seven/, rows[4])
        assert_match(/\(6\/7\)/, rows[5])
      end
    end

    # --- transcript scrolling (AC2, I12): pi ScrollView follow-end + the
    # auto scrollbar. The user-scroll seam is the WHEEL since I35 — the
    # page keys page the editor now (I35 OPTION A, pi pageScroll; the
    # I12 page-key mapping retired). ---

    # The wheel seam scrolled one VIEWPORT back (6 rows at these tests'
    # 12-row screen — the same window the I12 page key used to land on;
    # the page keys page the editor since I35). One line per event (pi
    # lines-per-event default 1).
    def wheel_page_back(chat)
      6.times { chat.on_event(TUI.mouse_event(kind: "scroll_up", x: 0, y: 0)) }
    end

    # The wheel seam scrolled to the very top — generous on purpose: the
    # wheel clamps at 0 and a clamped no-op neither moves nor re-marks
    # (pi scrollBy: moved === 0).
    def wheel_to_top(chat)
      40.times { chat.on_event(TUI.mouse_event(kind: "scroll_up", x: 0, y: 0)) }
    end

    def wheel_to_end(chat)
      40.times { chat.on_event(TUI.mouse_event(kind: "scroll_down", x: 0, y: 0)) }
    end

    def test_scrolling_up_pans_the_transcript_and_the_tail_refollows
      with_chat(width: 20, screen_height: 12) do |chat, session|
        20.times { |i| finish_message(chat, "line#{i}") }
        draw(chat, session)
        assert_equal " line19", transcript_view(session, chat).last, "following: the tail is visible"

        wheel_page_back(chat)
        draw(chat, session)
        visible = transcript_view(session, chat)
        refute_includes visible, "line19", "a scroll away from the end detaches"
        assert_equal 28, chat.scroll_offset, "scrolled to the top (34 buffer lines off a 6-row viewport)"
        assert_includes visible, " line14", "the window sits a viewport back into the transcript"

        28.times { chat.on_event(TUI.mouse_event(kind: "scroll_down", x: 0, y: 0)) }
        draw(chat, session)
        assert_equal " line19", transcript_view(session, chat).last,
          "scrolling back to the end re-follows"
      end
    end

    def test_a_scrolled_up_view_stays_put_as_new_output_arrives
      with_chat(width: 20, screen_height: 12) do |chat, session|
        20.times { |i| finish_message(chat, "line#{i}") }
        draw(chat, session)
        wheel_page_back(chat)
        draw(chat, session)

        finish_message(chat, "late")
        draw(chat, session)
        assert_equal 28, chat.scroll_offset,
          "the detached view stays put while output streams"
        refute_includes transcript_view(session, chat), "late"

        chat.on_event(TUI.mouse_event(kind: "scroll_down", x: 0, y: 0))
        draw(chat, session)
        refute_includes transcript_view(session, chat), "late", "a scroll down pans one line, not to the end"
        wheel_to_end(chat)
        draw(chat, session)
        assert_equal " late", transcript_view(session, chat).last,
          "landing at the end re-follows the new output"
      end
    end

    def test_wheel_scrolling_needs_no_overflow
      with_chat(width: 20, screen_height: 12) do |chat, session|
        chat.on_agent_event({type: :agent_start})
        "ar".each_char { |char| chat.on_event(TUI.key_event(char)) } # no slash: no list
        chat.on_event(TUI.mouse_event(kind: "scroll_up", x: 0, y: 0))
        assert_equal 0, chat.scroll_offset, "wheeling with nothing to scroll is a no-op"
      end
    end

    # The auto rail's transient semantics (AC2, pi scroll-view.ts): it
    # paints ONLY while scroll activity is fresh — a settled screen never
    # shows it, even on overflow (the I19-era "renders when the view
    # overflows" shape is retired; pi isScrollbarVisible :74-78).
    def test_scrollbar_is_hidden_at_settle_and_when_content_fits
      with_chat(width: 20, screen_height: 12) do |chat, session, _kernel|
        2.times { |i| finish_message(chat, "line#{i}") }
        draw(chat, session)
        (0...transcript_height(session, chat)).each do |y|
          assert_equal " ", session.cell_symbol(19, y), "no rail glyphs when the view fits (scroll-view.ts:74-78)"
        end

        20.times { |i| finish_message(chat, "line#{i}") }
        draw(chat, session)
        (0...transcript_height(session, chat)).each do |y|
          assert_equal " ", session.cell_symbol(19, y),
            "no rail glyphs at settle even on overflow — the transient rail never painted (scroll-view.ts:74-78)"
        end
      end
    end

    def test_scrollbar_shows_while_fresh_and_hides_after_the_delay
      with_chat(width: 20, screen_height: 12) do |chat, session, kernel|
        20.times { |i| finish_message(chat, "line#{i}") }
        draw(chat, session) # settle: the buffer flushes, follow pins to the end
        chat.scrollbar_hide_delay_ms = 10_000 # fresh for the duration of the test — no real sleeps
        wheel_page_back(chat)
        draw(chat, session)
        assert_equal "┃", session.cell_symbol(19, 4), "the thumb paints the last column while activity is fresh (offset 28 of 34 → thumb rows 3-4)"
        assert_equal Theme[:scrollbarThumb], session.cell_fg(19, 4), "the thumb routes through the theme (pi's blue-tinted token)"
        assert_equal "│", session.cell_symbol(19, 0), "the track fills above the thumb"
        assert_equal "│", session.cell_symbol(19, 5), "the track fills below the thumb"
        assert_equal Theme[:scrollbarTrack], session.cell_fg(19, 0)

        chat.scrollbar_hide_delay_ms = 0 # the timer reads the delay at fire time
        kernel.fire_timers
        draw(chat, session)
        assert_equal " ", session.cell_symbol(19, 4),
          "auto-hidden after scrollbarHideDelayMs (scroll-view.ts:55, 97-118) — the hide frame repaints rail-less"
      end
    end

    # Mark sites (AC2): the user-scroll seam (the wheel — the page keys
    # page the editor since I35) marks activity; the render-time
    # follow-end adjustment never does (pi updateLayout :180-192), and a
    # clamped no-op scroll marks nothing (pi scrollBy: moved === 0).
    def test_user_scroll_marks_scrollbar_activity_follow_end_does_not
      with_chat(width: 20, screen_height: 12) do |chat, session, kernel|
        20.times { |i| finish_message(chat, "line#{i}") }
        chat.scrollbar_hide_delay_ms = 10_000 # fresh for the duration of the test — no real sleeps

        finish_message(chat, "late") # new output lands while following
        draw(chat, session)
        assert_equal " ", session.cell_symbol(19, 5),
          "the follow-end adjustment never marks activity (pi updateLayout)"

        wheel_page_back(chat)
        draw(chat, session)
        assert_equal "┃", session.cell_symbol(19, 4), "the wheel seam marks"
        assert_equal "│", session.cell_symbol(19, 5), "the thumb is not pinned at the bottom — the view is detached"
        chat.scrollbar_hide_delay_ms = 0 # the timer reads the delay at fire time
        kernel.fire_timers
        draw(chat, session)
        assert_equal " ", session.cell_symbol(19, 5), "the timer hid the rail again"

        chat.scrollbar_hide_delay_ms = 10_000 # re-mark with a fresh window
        chat.on_event(TUI.mouse_event(kind: "scroll_up", x: 0, y: 0))
        draw(chat, session)
        assert_equal "┃", session.cell_symbol(19, 4), "the wheel seam marks"
        chat.scrollbar_hide_delay_ms = 0
        kernel.fire_timers

        chat.on_event(TUI.mouse_event(kind: "scroll_down", x: 0, y: 0)) # clamped while following
        draw(chat, session)
        assert_equal " ", session.cell_symbol(19, 4), "a clamped no-op scroll marks nothing (pi: moved === 0)"
      end
    end

    # Overlay, not carved column (AC2, B2): content wraps the FULL width
    # for "auto" (scroll-view.ts:80-82 getContentWidth — only "always"
    # reserves a column); the rail REPLACES the last column's cells while
    # visible (layout.ts:307-330 replaceScrollbarCell) and leaves no
    # trailing pad on the rows when hidden.
    def test_scrollbar_overlays_the_last_column_without_a_carved_gutter
      with_chat(width: 20, screen_height: 12) do |chat, session, _kernel|
        20.times { |i| finish_message(chat, "line#{i}") }
        chat.scrollbar_hide_delay_ms = 10_000 # fresh for the duration of the test — no real sleeps
        draw(chat, session)
        rows = TUI.widget_lines(chat.renderer.call)
        assert_equal " line19", rows[5], "content ends at content — no carved column pads overflow rows"
        assert_equal "", rows[4], "the settled window's rows carry no padding"

        wheel_page_back(chat)
        draw(chat, session)
        rows = TUI.widget_lines(chat.renderer.call)
        assert_equal "│", rows[0][-1], "the track paints the last column while visible"
        assert_equal " line14", rows[1][0, 7], "the row's content survives under the overlay (clipped at width−1, padded, then the glyph)"
      end
    end

    # --- mouse: wheel scroll + transcript selection (I14 items 6/10,
    # driven through the synthetic-seam event shapes) ---

    # --- I35 OPTION A (AC5): the page keys page the EDITOR's visual
    # rows (pi pageScroll, editor.ts:1961-1973) — the transcript pans
    # only through the wheel (the re-pointed family above); the I12
    # page-key mapping is retired with Viewport#scroll_page. ---

    def test_page_up_down_page_the_editor_and_the_transcript_does_not_move
      with_chat(width: 20, screen_height: 12) do |chat, session|
        20.times { |i| finish_message(chat, "line#{i}") }
        draw(chat, session)
        9.times do |n|
          chat.on_event(TUI.key_event("e"))
          chat.on_event(TUI.key_event("enter", modifiers: ["shift"])) unless n == 8
        end
        draw(chat, session)
        editor = chat.instance_variable_get(:@editor)
        assert_equal 9, editor.lines.length, "the setup: 9 visual rows in the editor"
        following = chat.scroll_offset

        chat.on_event(TUI.key_event("page_up"))
        draw(chat, session)
        assert_equal following, chat.scroll_offset, "the transcript does not move on page_up"
        assert_equal [3, 1], [editor.cursor_line, editor.cursor_col],
          "the editor pages up 5 visual rows (max(5, floor(12*0.3))) with the sticky move"

        chat.on_event(TUI.key_event("page_down"))
        draw(chat, session)
        assert_equal following, chat.scroll_offset, "the transcript does not move on page_down"
        assert_equal [8, 1], [editor.cursor_line, editor.cursor_col], "the editor pages back down, clamped"
      end
    end

    def test_viewport_has_no_scroll_page_and_the_wheel_still_pans
      with_chat(width: 20, screen_height: 12) do |chat, session|
        refute Render::Viewport.method_defined?(:scroll_page), "the retired I12 mapping is gone"
        20.times { |i| finish_message(chat, "line#{i}") }
        draw(chat, session)
        max = chat.scroll_offset
        chat.on_event(TUI.key_event("page_up")) # pages the editor, not the transcript
        draw(chat, session)
        assert_equal max, chat.scroll_offset
        chat.on_event(TUI.mouse_event(kind: "scroll_up", x: 0, y: 0))
        draw(chat, session)
        assert_equal max - 1, chat.scroll_offset, "the wheel still pans the transcript"
      end
    end

    # --- test list (5): the box grows with the wrapped rows, caps at
    # the maxVisible window, keeps the cursor row visible, and composes
    # the ↑/↓ borders (pi createScrollBorder). ---

    def test_the_editor_box_grows_with_wrapped_rows_and_the_transcript_cedes
      with_chat(width: 20, screen_height: 12) do |chat, session|
        20.times { |i| finish_message(chat, "line#{i}") }
        draw(chat, session)
        assert_equal 6, transcript_height(session, chat)

        "aaaa bbbb cccc dddd eeee".each_char { |char| chat.on_event(TUI.key_event(char)) }
        draw(chat, session)
        # Layout: transcript 0-4 (a row ceded), spacer 5, editor 6-9
        # (border, 2 rows, border), footer 10-11.
        assert_equal " line19", session.buffer_content[4].rstrip, "the transcript ceded a row to the wrapped editor"
        # Layout: transcript 0-4, spacer 5, editor 6-9 (border, 2 rows, border), footer 10-11.
        assert_equal "─" * 20, session.buffer_content[6].rstrip, "no hidden rows: a plain top border"
        assert_equal "aaaa bbbb cccc", session.buffer_content[7].rstrip, "content row 1"
        assert_equal "dddd eeee", session.buffer_content[8].rstrip, "content row 2 — the box grew"
        assert_equal " ", session.cell_symbol(9, 8), "the cursor's trailing space sits past the row end"
        assert session.cell_modifiers(9, 8).include?(:reversed), "the fake cursor marks the wrapped row"
        assert_equal "─" * 20, session.buffer_content[9].rstrip, "no hidden rows: a plain bottom border"
      end
    end

    def test_the_window_caps_the_box_and_the_borders_compose
      with_chat(width: 20, screen_height: 12) do |chat, session|
        "abcdefghi".each_char do |char|
          chat.on_event(TUI.key_event(char))
          chat.on_event(TUI.key_event("enter", modifiers: ["shift"])) unless char == "i"
        end
        draw(chat, session)
        editor = chat.instance_variable_get(:@editor)
        assert_equal 9, editor.lines.length
        # maxVisible = max(5, floor(12*0.3)) = 5 → the box caps at 7 rows;
        # the cursor row (8) pins the window at scroll 4. Layout: 2
        # transcript rows, the spacer, editor 3-9 (border + 5 rows +
        # border), the footer.
        assert_equal 5, editor.rendered_rows
        assert_equal 4, editor.scroll_offset
        assert_equal "───── ↑ 4 more ─────", session.buffer_content[3].rstrip, "the ↑ border composes (createScrollBorder)"
        assert_equal "─" * 20, session.buffer_content[9].rstrip, "nothing hidden below: a plain bottom border"
        assert session.cell_modifiers(1, 8).include?(:reversed), "the cursor row stays visible under the cap"

        chat.on_event(TUI.key_event("page_up"))
        draw(chat, session)
        assert_equal 3, editor.scroll_offset, "the editor paged up one window (the cursor row pins the top)"
        assert_equal "───── ↓ 1 more ─────", session.buffer_content[9].rstrip, "the ↓ border composes"
      end
    end

    # --- test list (7) through the dispatch: the newline keys route to
    # addNewLine BEFORE the submit path (pi editor.ts:889-919). ---

    def test_newline_keys_insert_newlines_without_submitting
      with_chat(width: 20, screen_height: 12) do |chat, session|
        "  a".each_char { |char| chat.on_event(TUI.key_event(char)) }
        chat.on_event(TUI.key_event("enter", modifiers: ["shift"]))
        assert_equal "  a\n", chat.input, "shift+enter inserts a newline (tui.input.newLine)"
        chat.on_event(TUI.key_event("enter", modifiers: ["alt"]))
        assert_equal "  a\n\n", chat.input, "alt+enter is pi's terminal fallback"
        chat.on_event(TUI.key_event("j", modifiers: ["ctrl"]))
        assert_equal "  a\n\n\n", chat.input, "ctrl+j inserts a newline (keybindings.ts:143)"
        "b  ".each_char { |char| chat.on_event(TUI.key_event(char)) }
        chat.on_event(TUI.key_event("enter"))
        assert_equal "", chat.input, "plain enter submits"
        draw(chat, session)
        lines = chat.transcript_lines
        assert_includes lines, " a", "the echo carried the joined text (leading-trimmed)"
        assert_includes lines, " b", "...and the trailing spaces are gone (pi submitValue trims)"
        chat.on_event(TUI.key_event("up")) # empty editor: straight into history
        assert_equal "a\n\n\nb", chat.input,
          "submit sent the JOINED TRIMMED text — the interior blanks survive the trim (pi submitValue)"
      end
    end

    def test_the_backslash_enter_idiom_inserts_a_newline
      with_headless_chat do |chat|
        "hello\\".each_char { |char| chat.on_event(TUI.key_event(char)) }
        chat.on_event(TUI.key_event("enter"))
        assert_equal "hello\n", chat.input, "the backslash-enter workaround (pi editor.ts:906-917)"
        refute_includes chat.input, "\\", "the backslash was deleted, not kept"
        chat.on_event(TUI.key_event("enter"))
        assert_equal "", chat.input, "a second enter submits (trimmed join)"
      end
    end

    def test_multi_line_paste_normalizes_through_the_dispatch
      with_headless_chat do |chat|
        chat.on_event(TUI.paste_event("x\r\ny\tz\x01"))
        assert_equal "x\ny    z", chat.input, "pi normalizeText + the non-printable filter"
        editor = chat.instance_variable_get(:@editor)
        assert_equal ["x", "y    z"], editor.lines
      end
    end

    def test_multi_line_history_recall_edits_and_submits_as_text
      TUI.run(headless: true, viewport: :fullscreen, width: 40, screen_height: 12) do |session|
        chat = Render::Chat.new(session:, kernel: IdleKernel.new, motd: false)
        send_message(chat, "A1")
        "B1".each_char { |char| chat.on_event(TUI.key_event(char)) }
        chat.on_event(TUI.key_event("enter", modifiers: ["shift"]))
        "B2".each_char { |char| chat.on_event(TUI.key_event(char)) }
        chat.on_event(TUI.key_event("enter"))
        chat.on_event(TUI.key_event("up")) # empty editor: straight into history
        assert_equal ["B1", "B2"], chat.instance_variable_get(:@editor).lines,
          "the multi-line entry recalls all rows"
        chat.on_event(TUI.key_event("end"))
        chat.on_event(TUI.key_event("X"))
        assert_equal "B1X\nB2", chat.input, "the recalled entry edits at the cursor"
        chat.on_event(TUI.key_event("enter"))
        draw(chat, session)
        assert_includes chat.transcript_lines.join("\n"), "B1X", "the edited multi-line entry submits as text"
      end
    end

    def test_slash_context_stays_line_zero_only_through_the_dispatch
      with_headless_chat(autocomplete: slash_source("help")) do |chat|
        "/he".each_char { |char| chat.on_event(TUI.key_event(char)) }
        assert chat.suggestions, "the list opens in slash context on line 0"
        chat.on_event(TUI.key_event("enter", modifiers: ["shift"]))
        assert_nil chat.suggestions, "the newline cancelled the list (pi addNewLine)"
        "l".each_char { |char| chat.on_event(TUI.key_event(char)) }
        assert_nil chat.suggestions, "no list off line 0 (pi isSlashMenuAllowed)"
      end
    end

    def test_wheel_scrolls_one_line_per_event_and_alt_wheel_five
      with_chat(width: 20, screen_height: 12) do |chat, session|
        20.times { |i| finish_message(chat, "line#{i}") }
        draw(chat, session)
        max = chat.scroll_offset # following: pinned at the end
        assert_operator max, :>, 0, "the transcript overflows"

        chat.on_event(TUI.mouse_event(kind: "scroll_up", x: 0, y: 0))
        draw(chat, session)
        assert_equal max - 1, chat.scroll_offset, "one wheel notch = one line (pi lines-per-event default 1)"

        chat.on_event(TUI.mouse_event(kind: "scroll_up", x: 0, y: 0, modifiers: ["alt"]))
        draw(chat, session)
        assert_equal max - 6, chat.scroll_offset, "alt+wheel moves 5x (tui-alt-screen.ts:79)"
      end
    end

    def test_wheeling_back_down_to_the_end_re_arms_follow
      with_chat(width: 20, screen_height: 12) do |chat, session|
        20.times { |i| finish_message(chat, "line#{i}") }
        draw(chat, session)
        3.times { chat.on_event(TUI.mouse_event(kind: "scroll_up", x: 0, y: 0)) }
        draw(chat, session)

        3.times { chat.on_event(TUI.mouse_event(kind: "scroll_down", x: 0, y: 0)) }
        draw(chat, session)
        finish_message(chat, "late")
        draw(chat, session)
        assert_equal " late", transcript_view(session, chat).last,
          "landing at the end re-arms follow-end (scroll-view.ts:127-135)"
      end
    end

    def test_mouse_drag_selects_with_inverse_highlight_and_copies_on_release
      with_chat(width: 20, screen_height: 12) do |chat, session|
        finish_message(chat, "hello world")
        draw(chat, session)
        y = buffer_row(chat, "hello world")

        chat.on_event(TUI.mouse_event(kind: "down", x: 7, y:, button: "left"))
        chat.on_event(TUI.mouse_event(kind: "drag", x: 11, y:, button: "left"))
        draw(chat, session)
        (7..11).each do |x|
          assert_equal [:reversed], session.cell_modifiers(x, y), "cell #{x} is inverse-highlighted"
        end
        assert_empty session.cell_modifiers(6, y), "the cell before the anchor is unhighlighted"
        assert_empty session.cell_modifiers(12, y), "the cell after the focus is unhighlighted"

        copied = capture_stdout do
          chat.on_event(TUI.mouse_event(kind: "up", x: 11, y:, button: "left"))
        end
        assert_equal "world", copied_text(copied), "copy-on-select copies the drag range (OSC 52)"
      end
    end

    def test_double_click_selects_the_word_with_path_and_kebab_boundaries
      with_chat(width: 30, screen_height: 12) do |chat, session|
        finish_message(chat, "see docs/foo/bar-baz now")
        draw(chat, session)
        y = buffer_row(chat, "docs/foo/bar-baz")
        word_start = chat.transcript_lines[y].index("docs")

        2.times do
          chat.on_event(TUI.mouse_event(kind: "down", x: word_start + 10, y:, button: "left"))
        end
        draw(chat, session)
        (word_start...(word_start + "docs/foo/bar-baz".length)).each do |x|
          assert_equal [:reversed], session.cell_modifiers(x, y), "word cell #{x} is highlighted"
        end
        assert_empty session.cell_modifiers(word_start - 1, y), "the boundary before the word is clear"
        assert_empty session.cell_modifiers(word_start + "docs/foo/bar-baz".length, y),
          "the boundary after the word is clear"

        copied = capture_stdout do
          chat.on_event(TUI.mouse_event(kind: "up", x: word_start + 10, y:, button: "left"))
        end
        assert_equal "docs/foo/bar-baz", copied_text(copied),
          "the word selection keeps paths and kebab-case whole (tui-alt-screen.ts:85)"
      end
    end

    def test_triple_click_selects_the_whole_line
      with_chat(width: 20, screen_height: 12) do |chat, session|
        finish_message(chat, "all of it")
        draw(chat, session)
        y = buffer_row(chat, "all of it")
        line_width = "all of it".length

        3.times do
          chat.on_event(TUI.mouse_event(kind: "down", x: 4, y:, button: "left"))
        end
        draw(chat, session)
        # The line's outputPad is part of the row (and of the selection).
        (0...(line_width + 1)).each do |x|
          assert_equal [:reversed], session.cell_modifiers(x, y), "line cell #{x} is highlighted"
        end
        assert_empty session.cell_modifiers(line_width + 1, y), "nothing beyond the line"
      end
    end

    def test_a_plain_click_drops_the_selection
      with_chat(width: 20, screen_height: 12) do |chat, session|
        finish_message(chat, "hello world")
        draw(chat, session)
        y = buffer_row(chat, "hello world")
        capture_stdout do
          chat.on_event(TUI.mouse_event(kind: "down", x: 6, y:, button: "left"))
          chat.on_event(TUI.mouse_event(kind: "drag", x: 10, y:, button: "left"))
          chat.on_event(TUI.mouse_event(kind: "up", x: 10, y:, button: "left"))
        end

        copied = capture_stdout do
          chat.on_event(TUI.mouse_event(kind: "down", x: 0, y:, button: "left"))
          chat.on_event(TUI.mouse_event(kind: "up", x: 0, y:, button: "left"))
        end
        assert_empty copied, "a plain click copies nothing"
        draw(chat, session)
        assert_empty session.cell_modifiers(6, y), "a click without a drag collapses the selection"
      end
    end

    def test_selection_survives_wheel_scrolling
      with_chat(width: 20, screen_height: 12) do |chat, session|
        20.times { |i| finish_message(chat, "line#{i}") }
        draw(chat, session)
        offset = chat.scroll_offset
        y = (0...transcript_height(session, chat)).find do |r|
          chat.transcript_lines[offset + r].to_s.include?("line")
        end
        capture_stdout do
          chat.on_event(TUI.mouse_event(kind: "down", x: 0, y:, button: "left"))
          chat.on_event(TUI.mouse_event(kind: "drag", x: 6, y:, button: "left"))
          chat.on_event(TUI.mouse_event(kind: "up", x: 6, y:, button: "left"))
        end

        offset = chat.scroll_offset
        chat.on_event(TUI.mouse_event(kind: "scroll_up", x: 0, y: 0))
        draw(chat, session)
        assert_equal [:reversed], session.cell_modifiers(0, y + offset - chat.scroll_offset),
          "the selection is anchored to buffer rows (pi getScrollSelectionPoint :1133-1155)"
      end
    end

    # --- whole-screen selection (I28, AC1/AC2 — pi getSelectionPoint's
    # non-scrollview branch :1145-1152 + getSelectionSourceLine :1165:
    # every rendered row selects; the port composes the dock rows from
    # the same builders that render them, itemized) ---
    #
    # Geometry at width 40 / screen_height 12: transcript rows 0-5, the
    # dock spacer 6, the editor block 7 (top border) / 8 (input) /
    # 9 (bottom border), the footer 10-11.

    def test_mouse_drag_selects_and_highlights_over_a_footer_row
      with_chat(width: 40, screen_height: 12, footer_data: {cwd: @dir, model: "m", context_window: 1000}) do |chat, session|
        draw(chat, session)
        pwd = Render::Text.format_cwd(@dir)

        chat.on_event(TUI.mouse_event(kind: "down", x: 1, y: 10, button: "left"))
        chat.on_event(TUI.mouse_event(kind: "drag", x: 5, y: 10, button: "left"))
        draw(chat, session)
        (1..5).each do |x|
          assert_equal [:reversed], session.cell_modifiers(x, 10), "footer cell #{x} is inverse-highlighted"
        end
        assert_empty session.cell_modifiers(6, 10), "the cell after the focus is unhighlighted"

        copied = capture_stdout do
          chat.on_event(TUI.mouse_event(kind: "up", x: 5, y: 10, button: "left"))
        end
        assert_equal pwd[1..5], copied_text(copied), "copy-on-release over the footer row (OSC 52)"
      end
    end

    def test_mouse_drag_selects_and_highlights_over_the_input_row
      with_chat(width: 40, screen_height: 12) do |chat, session|
        "hello world".chars.each { |char| chat.on_event(TUI.key_event(char)) }
        draw(chat, session)
        y = input_row(session)

        chat.on_event(TUI.mouse_event(kind: "down", x: 0, y:, button: "left"))
        chat.on_event(TUI.mouse_event(kind: "drag", x: 4, y:, button: "left"))
        draw(chat, session)
        (0..4).each do |x|
          assert_equal [:reversed], session.cell_modifiers(x, y), "input cell #{x} is inverse-highlighted"
        end

        copied = capture_stdout do
          chat.on_event(TUI.mouse_event(kind: "up", x: 4, y:, button: "left"))
        end
        assert_equal "hello", copied_text(copied), "copy-on-release over the input row"

        2.times do
          chat.on_event(TUI.mouse_event(kind: "down", x: 6, y:, button: "left"))
        end
        draw(chat, session)
        (6..10).each do |x|
          assert_equal [:reversed], session.cell_modifiers(x, y), "word cell #{x} is highlighted"
        end
      end
    end

    def test_selection_text_over_the_editor_border_row_answers_the_composed_border
      with_chat(width: 40, screen_height: 12) do |chat, session|
        draw(chat, session)

        chat.on_event(TUI.mouse_event(kind: "down", x: 0, y: 7, button: "left"))
        chat.on_event(TUI.mouse_event(kind: "drag", x: 9, y: 7, button: "left"))
        copied = capture_stdout do
          chat.on_event(TUI.mouse_event(kind: "up", x: 9, y: 7, button: "left"))
        end
        # The gem Block renders the titleless top border as dashes to width
        # (byte-verified) — the drag's slice is its first ten cells.
        assert_equal "─" * 10, copied_text(copied),
          "the border row's reader answers the composed border (previousScreen analog)"
      end
    end

    def test_double_and_triple_click_work_over_a_footer_row
      with_chat(width: 40, screen_height: 12,
        footer_data: {cwd: File.join(Dir.home, "wordy-dir", "child"), model: "m", context_window: 1000}) do |chat, session|
        draw(chat, session)
        # Under home → the ~-contracted pwd row (format_cwd); no branch.
        pwd = "~/wordy-dir/child"
        word_start = pwd.index("wordy")

        2.times do
          chat.on_event(TUI.mouse_event(kind: "down", x: word_start + 2, y: 10, button: "left"))
        end
        draw(chat, session)
        # The word run joins across "/" and "-" (paths and kebab stay
        # whole) — from the "/" after the ~ boundary to the row's end.
        (1...(word_start + "wordy-dir/child".length)).each do |x|
          assert_equal [:reversed], session.cell_modifiers(x, 10), "word cell #{x} is highlighted"
        end
        copied = capture_stdout do
          chat.on_event(TUI.mouse_event(kind: "up", x: word_start + 2, y: 10, button: "left"))
        end
        assert_equal "/wordy-dir/child", copied_text(copied),
          "the word selection keeps paths and kebab-case whole over a footer row"
      end
    end

    def test_triple_click_selects_the_whole_footer_row
      with_chat(width: 40, screen_height: 12,
        footer_data: {cwd: File.join(Dir.home, "wordy-dir", "child"), model: "m", context_window: 1000}) do |chat, session|
        draw(chat, session)
        word_start = "~/wordy-dir/child".index("wordy")

        3.times do
          chat.on_event(TUI.mouse_event(kind: "down", x: word_start + 2, y: 10, button: "left"))
        end
        copied = capture_stdout do
          chat.on_event(TUI.mouse_event(kind: "up", x: word_start + 2, y: 10, button: "left"))
        end
        assert_equal "~/wordy-dir/child", copied_text(copied),
          "the triple-click line selection spans the footer row"
      end
    end

    # --- app.message.copy (I28 AC3, pi keybindings.ts:63 ctrl+x →
    # handleCopyCommand {flashConfirmation: true, preferSelection: true}) ---

    def test_ctrl_x_copies_the_active_selection_else_the_last_assistant
      with_chat(width: 40, screen_height: 12) do |chat, session|
        finish_message(chat, "assistant says hi")
        draw(chat, session)

        copied = capture_stdout { chat.on_event(TUI.key_event("x", modifiers: ["ctrl"])) }
        assert_equal "assistant says hi", copied_text(copied), "no selection → the last assistant message"

        y = buffer_row(chat, "assistant says hi")
        capture_stdout do
          chat.on_event(TUI.mouse_event(kind: "down", x: 1, y:, button: "left"))
          chat.on_event(TUI.mouse_event(kind: "drag", x: 9, y:, button: "left"))
          chat.on_event(TUI.mouse_event(kind: "up", x: 9, y:, button: "left"))
        end
        copied = capture_stdout { chat.on_event(TUI.key_event("x", modifiers: ["ctrl"])) }
        assert_equal "assistant", copied_text(copied), "the active selection wins"
      end
    end

    def test_ctrl_x_without_a_copy_source_shows_the_error_line
      with_chat(width: 40) do |chat, session|
        draw(chat, session)
        capture_stdout { chat.on_event(TUI.key_event("x", modifiers: ["ctrl"])) }
        draw(chat, session)

        assert_includes chat.transcript_lines, "Error: No agent messages to copy yet.",
          "pi's showError (interactive-mode.ts:6651-6653)"
      end
    end

    # pi's flash (alt-screen-flash.ts): a reversed " Copied! " composited
    # at the finished screen's top-right for DEFAULT_DURATION_MS 1000,
    # then one redraw.
    def test_ctrl_x_flashes_the_confirmation_for_its_dwell
      with_chat(width: 40, screen_height: 12) do |chat, session, kernel|
        chat.flash_seconds = 0
        finish_message(chat, "hi")
        draw(chat, session)
        capture_stdout { chat.on_event(TUI.key_event("x", modifiers: ["ctrl"])) }
        draw(chat, session)

        row0 = session.buffer_content[0]
        assert_includes row0, "Copied!", "the flash composites at the screen's top-right"
        assert_equal [:reversed], session.cell_modifiers(row0.rindex("Copied!"), 0)

        kernel.fire_timers
        draw(chat, session)
        refute session.buffer_content[0].include?("Copied!"), "cleared after the dwell"
      end
    end

    # The buffer row currently displaying the transcript line containing
    # +text+ (the tests keep the view following, so the mapping is direct).
    def buffer_row(chat, text)
      chat.transcript_lines.index { |line| line.include?(text) } or
        raise "transcript line not found: #{text.inspect}"
    end

    def capture_stdout
      previous = $stdout
      $stdout = StringIO.new
      yield
      $stdout.string
    ensure
      $stdout = previous
    end

    # The OSC 52 payload's text (pi tui-alt-screen.ts:1483 — base64 under
    # a bell terminator, buffer "c"), re-encoded for comparison (unpack1
    # yields ASCII-8BIT; non-ASCII payloads need the source encoding).
    def copied_text(stdout)
      stdout[/\e\]52;c;(.*?)\a/, 1]&.unpack1("m")&.force_encoding(Encoding::UTF_8)
    end

    # --- compaction-start border status (AC3, I12): the frozen event
    # contract consumed synthetically (the house on_agent_event pattern). ---

    def test_compaction_start_shows_pi_s_label_per_reason
      with_chat(width: 60) do |chat, session|
        chat.on_agent_event({type: :compaction_start, reason: :manual})
        draw(chat, session)
        assert_includes editor_area(session, chat), "Compacting context..."

        chat.on_agent_event({type: :compaction_start, reason: :threshold})
        draw(chat, session)
        assert_includes editor_area(session, chat), "Auto-compacting..."

        chat.on_agent_event({type: :compaction_start, reason: :overflow})
        draw(chat, session)
        assert_includes editor_area(session, chat), "Context overflow detected, Auto-compacting..."
        refute_includes editor_area(session, chat), "cancel",
          "the cancel hint is cut — ctrl+c aborts the whole run in the port (BRIEF §5.1)"
      end
    end

    def test_compaction_status_clears_on_compaction_and_agent_end
      with_chat(width: 60) do |chat, session|
        chat.on_agent_event({type: :compaction_start, reason: :manual})
        chat.on_agent_event({type: :compaction, reason: :manual, tokens_before: 100, summary: "s"})
        draw(chat, session)
        refute_includes editor_area(session, chat), "Compacting context...", "cleared by the result event"

        chat.on_agent_event({type: :compaction_start, reason: :threshold})
        chat.on_agent_event({type: :agent_end})
        draw(chat, session)
        refute_includes editor_area(session, chat), "Auto-compacting...", "cleared by the run end"
      end
    end

    # --- the compaction panel + live rebuild (I30, pi
    # compaction-summary-message.ts + compaction_end's result arm):
    # the frozen payload shape injected directly (the lane contract). ---

    # Collapsed panel bytes (AC1): the label row, the bg'd inner Spacer,
    # then the three-fg-run hint row — customMessageText / dim ctrl+o /
    # customMessageText — over the customMessageBg container (the
    # skill-panel precedent), the dim ✻ scrollback line gone.
    def test_compaction_renders_the_collapsed_panel_bytes
      with_chat(width: 60) do |chat, session|
        chat.on_agent_event({type: :compaction, reason: :threshold, tokens_before: 12_345, summary: "kept"})
        draw(chat, session)

        lines = chat.transcript_lines
        assert_includes lines.join, "[compaction]", "the label row renders"
        assert_includes lines.join, "Compacted from 12,345 tokens (ctrl+o to expand)",
          "the grouped tokens hint row renders (toLocaleString grouping)"
        refute_includes lines.join, "✻ compacted", "the dim scrollback line is replaced by the panel"

        y_abs = session.buffer_content.index { |row| row.include?("[compaction]") }
        row = session.buffer_content[y_abs]
        assert_equal Theme[:custom_message_label], session.cell_fg(row.index("["), y_abs)
        assert_includes session.cell_modifiers(row.index("["), y_abs), :bold
        assert_equal Theme[:custom_message_bg], session.cell_bg(0, y_abs),
          "the label row rides the customMessageBg container"

        hint_y = session.buffer_content.index { |row| row.include?("Compacted from") }
        hint_row = session.buffer_content[hint_y]
        assert_equal Theme[:custom_message_text], session.cell_fg(hint_row.index("Compacted"), hint_y)
        assert_equal Theme[:dim], session.cell_fg(hint_row.index("ctrl+o"), hint_y),
          "the key rides the dim run (pi's three-fg-run split)"
        assert_equal Theme[:custom_message_text], session.cell_fg(hint_row.index(" to expand"), hint_y)
        assert_equal Theme[:custom_message_bg], session.cell_bg(hint_row.index("ctrl+o"), hint_y),
          "the hint row rides the panel bg too"
      end
    end

    # ctrl+o expands the compaction panel in place (the GLOBAL expand
    # family — pi setExpanded(this.toolOutputExpanded) in the toggle's
    # sweep): the bold markdown header + the summary as
    # customMessageText prose, and back.
    def test_ctrl_o_expands_the_compaction_panel
      with_chat(width: 60) do |chat, session|
        chat.on_agent_event({type: :compaction, reason: :manual, tokens_before: 15, summary: "earlier context"})
        draw(chat, session)

        chat.on_event(TUI.key_event("o", modifiers: ["ctrl"]))
        draw(chat, session)
        lines = chat.transcript_lines
        assert_includes lines.join, "Compacted from 15 tokens", "the bold markdown header renders expanded"
        assert_includes lines.join, "earlier context", "the summary renders over the panel"
        refute_includes lines.join, "(ctrl+o to expand)", "the hint dies expanded"

        chat.on_event(TUI.key_event("o", modifiers: ["ctrl"]))
        draw(chat, session)
        assert_includes chat.transcript_lines.join, "(ctrl+o to expand)", "the second press collapses again"
      end
    end

    # The live rebuild (AC1, pi compaction_end's result arm): the CHAT
    # container clears — the kept entries re-render chronologically
    # through the replay machinery, the panel appends LAST — while the
    # HEADER container survives (interactive-mode.ts:633-639, sibling
    # containers; the s7 capture: art + help ride again, and the
    # port-only resource listings die with the wipe, not resurrected).
    # The footer invalidates (the "?") without resetting the usage
    # totals; the border status clears.
    def test_compaction_rebuilds_kept_entries_then_the_panel
      FileUtils.mkpath(File.join(@dir, ".tart"))
      File.write(File.join(@dir, ".tart", "settings.json"), "{}") # the [Context] section's input
      with_chat(width: 60, screen_height: 24, motd: true,
        footer_data: {cwd: @dir, model: "m", context_window: 1000, auto_compact: true}) do |chat, session|
        draw(chat, session)
        assert_includes chat.transcript_lines.join, "[Context]", "the boot MOTD renders before the compaction"
        finish_message(chat, "kept reply")
        assistant_done(chat, TokensDouble.new(10, 5, 0, 0))
        send_message(chat, "hello")

        chat.on_agent_event({type: :compaction_start, reason: :threshold})
        chat.on_agent_event({type: :compaction, reason: :threshold, tokens_before: 100, summary: "the summary",
                             entries: [
                               {"type" => "message", "message" => {"role" => "user", "content" => "hello"}},
                               {"type" => "message", "message" => {"role" => "assistant", "content" => "kept reply"}}
                             ]})
        draw(chat, session)

        lines = chat.transcript_lines
        joined = lines.join("\n")
        refute_includes joined, "✻ compacted", "the dim line is replaced by the rebuild"
        assert_includes joined, Render::Motd::PI_NOTICE_LINE,
          "the header survives the rebuild (pi's headerContainer, the chatContainer clear's untouched sibling)"
        assert_includes joined, Render::Motd::PI_ONBOARDING_LINE, "the onboarding row survives with it"
        refute_includes joined, "[Context]", "the port-only resource listings are NOT resurrected"
        header_y = lines.index { |line| line.include?(Render::Motd::PI_NOTICE_LINE) }
        assert_operator header_y, :<, lines.rindex { |line| line.include?("kept reply") },
          "the header rides ABOVE the kept entries (pi's container order)"
        assert_includes joined, " hello", "the kept user entry re-renders through the replay machinery"
        assert_includes joined, "kept reply", "the kept assistant entry re-renders"
        panel_y = lines.index { |line| line.include?("Compacted from 100 tokens") }
        assert panel_y, "the panel renders"
        assert_operator panel_y, :>, lines.rindex { |line| line.include?("kept reply") },
          "the panel appends LAST (pi addMessageToChat after renderSessionEntries)"
        refute_includes editor_area(session, chat), "Auto-compacting",
          "the border status clears on the result (the frozen I12 contract)"
      end
    end

    # The rebuild's footer half (AC2): usage NOT reset (invalidate, not
    # /new's reset) — the accumulated totals survive and the context
    # numerator goes stale (pi's post-compaction "?").
    def test_compaction_rebuild_invalidates_the_footer_without_resetting_usage
      with_chat(width: 60, screen_height: 12,
        footer_data: {cwd: @dir, model: "m", context_window: 1000, auto_compact: true}) do |chat, session|
        assistant_done(chat, TokensDouble.new(10, 5, 0, 0))
        draw(chat, session)
        assert_includes footer_text(session), "↑10", "sanity: the totals accumulate"

        chat.on_agent_event({type: :compaction, reason: :threshold, tokens_before: 100, summary: "s",
                             entries: [{"type" => "message", "message" => {"role" => "assistant", "content" => "kept reply"}}]})
        draw(chat, session)
        footer = footer_text(session)
        assert_includes footer, "↑10 ↓5", "the usage totals are NOT reset (pi invalidate, not /new)"
        assert_includes footer, "?/1.0k (auto)", "the context numerator is stale (pi's post-compaction ?)"
      end
    end

    # The rebuild does not duplicate editor history (pi's rebuild passes
    # populateHistory: false — the pre-compaction entries are already
    # there): the up-walk stops at the oldest entry instead of
    # re-walking rebuilt copies.
    def test_compaction_rebuild_does_not_duplicate_editor_history
      with_headless_chat do |chat|
        send_message(chat, "older")
        send_message(chat, "newer")
        chat.on_agent_event({type: :compaction, reason: :manual, tokens_before: 10, summary: "s",
                             entries: [{"type" => "message", "message" => {"role" => "user", "content" => "older"}},
                                       {"type" => "message", "message" => {"role" => "user", "content" => "newer"}}]})
        chat.on_event(TUI.key_event("up"))
        assert_equal "newer", chat.input
        chat.on_event(TUI.key_event("up"))
        assert_equal "older", chat.input
        chat.on_event(TUI.key_event("up"))
        assert_equal "older", chat.input, "the walk stops at the oldest — no rebuilt duplicates"
      end
    end

    # An absent `entries` (the pre-integration worktree: the loop does
    # not carry the payload yet) degrades gracefully — the panel renders
    # over the cleared transcript (an empty replay, a blank transcript).
    def test_compaction_without_entries_renders_the_panel_over_a_cleared_transcript
      with_chat(width: 60) do |chat, session|
        finish_message(chat, "pre-compaction reply")
        draw(chat, session)
        chat.on_agent_event({type: :compaction, reason: :overflow, tokens_before: 7, summary: "s"})
        draw(chat, session)
        lines = chat.transcript_lines
        refute_includes lines.join, "pre-compaction reply", "the transcript cleared"
        assert_includes lines.join, "[compaction]", "the panel still renders"
        assert_includes lines.join, "Compacted from 7 tokens (ctrl+o to expand)",
          "the panel rides the payload it carries (0 entries renders no rows)"
      end
    end

    # The replay panel (AC1, pi renderSessionEntries case
    # compactionSummary): a persisted compaction entry renders the
    # panel — Spacer(1) + the collapsible container — at its
    # chronological position, replacing the bare-markdown render; the
    # compaction-count status line survives (pi renderInitialMessages
    # :4209-4225 renders it after the entries).
    def test_resume_renders_the_persisted_compaction_entry_as_the_panel
      recorded = recorded_session_fixture
      File.open(recorded, "a") do |file|
        file.write("\n")
        file.write(JSON.generate(
          type: "compaction", id: "c1", parentId: "e4", timestamp: Agent::Session.now_iso,
          summary: "earlier context", firstKeptEntryId: "e4", tokensBefore: 12_345, details: {}
        ))
      end
      with_chat(width: 60, screen_height: 24) do |chat, session|
        chat.resume_session(recorded)
        draw(chat, session)
        lines = chat.transcript_lines
        assert_includes lines.join, "[compaction]", "the panel renders for the persisted entry"
        assert_includes lines.join, "Compacted from 12,345 tokens (ctrl+o to expand)",
          "the grouped tokens hint renders on the replay path too"
        panel_y = lines.index { |line| line.include?("[compaction]") }
        assert_operator panel_y, :>, lines.index { |line| line.include?("The file contains") },
          "the panel renders at its chronological position (after the earlier entries)"
        assert_includes lines.join, "Session compacted 1 time",
          "the count status survives alongside the panels (pi renderInitialMessages)"
      end
    end

    def test_grouped_tokens_matches_pi_s_locale_grouping
      assert_equal "15", Render::Transcript.grouped_tokens(15)
      assert_equal "12,345", Render::Transcript.grouped_tokens(12_345)
      assert_equal "1,000,000", Render::Transcript.grouped_tokens(1_000_000)
      assert_equal "0", Render::Transcript.grouped_tokens(0)
    end

    def test_escape_while_running_cancels_only_the_list_kernel_driven
      @server = MockLLMServer.new.start
      @server.script([{type: :slow_stream, content: "answer"}])
      kernel, chat, session = chat_with_server(autocomplete: slash_source("new", "compact"))

      scenario = Thread.new do
        type(session, "hi")
        wait_until { chat.busy? }
        session.push_event(TUI.key_event("/")) # a bare slash: opens the list (no submit)
        wait_until { chat.suggestions }
        session.push_event(TUI.key_event("esc"))
        wait_until { chat.suggestions.nil? }
        wait_until { chat.transcript_lines.join.include?("answer") }
        kernel.stop!
      end
      kernel.run
      scenario.join

      assert_includes chat.transcript_lines.join, "answer",
        "the turn completed — escape with an active list never interrupts the run"
    end

    # Escape interrupts a streaming run (item 5/AC6, pi app.interrupt —
    # keybindings.ts:26, custom-editor.ts:103-110 → onEscape aborts the
    # generation, interactive-mode.ts:3070-3090): through the kernel's
    # existing interrupt path (Task#stop — the ctrl+c mechanism).
    def test_escape_interrupts_a_streaming_run_through_the_kernel_path
      @server = MockLLMServer.new.start
      @server.script([{type: :slow_stream, content: "x" * 40}])
      kernel, chat, session = chat_with_server

      scenario = Thread.new do
        type(session, "long stream")
        wait_until { chat.busy? }
        session.push_event(TUI.key_event("esc"))
        wait_until { !chat.busy? }
        wait_until { chat.transcript_lines.join.include?("interrupted") }
        @agent_interrupted = chat.agent.interrupted?
        type(session, "still there") # the loop must still be alive to submit
        wait_until { captured.any? { |req| req["messages"].select { |m| m["role"] == "user" }.last["content"] == "still there" } }
        kernel.stop!
      end
      kernel.run
      scenario.join

      assert @agent_interrupted, "the agent saw the cancel (the ctrl+c interrupt path)"
      assert_includes chat.transcript_lines.join, "interrupted"
    end

    def test_idle_escape_is_a_noop_kernel_driven
      @server = MockLLMServer.new.start
      kernel, chat, session = chat_with_server

      scenario = Thread.new do
        session.push_event(TUI.key_event("esc"))
        type(session, "still there") # the loop must still be alive to submit
        wait_until { !captured.empty? }
        kernel.stop!
      end
      kernel.run
      scenario.join

      request = captured.first
      assert_equal "still there", request["messages"].select { |m| m["role"] == "user" }.last["content"],
        "idle escape neither quit the loop nor disturbed the editor"
      assert_equal ["", " still there", ""], chat.transcript_lines, "only the echo — no interrupt residue"
    end

    # --- /resume picker (item 2/AC2, pi SessionSelectorComponent reduced)
    # and the resume replay (item 3/AC3). The picker's state behavior
    # (navigation wrap, esc-cancel) moved to test/render/picker_test.rb,
    # driving Picker directly; the wiring (open_session_picker +
    # on_resume) and the in-place rendering stay here. ---

    def test_picker_enter_fires_the_resume_seam
      with_headless_chat do |chat|
        resumed = []
        chat.on_resume = ->(path) { resumed << path }
        chat.open_session_picker([{path: "/a", label: "first"}, {path: "/b", label: "second"}])
        chat.on_event(TUI.key_event("down"))
        chat.on_event(TUI.key_event("enter"))
        assert_equal ["/b"], resumed, "enter resumes the selection (pi onSelect)"
        assert_nil chat.picker_items, "the picker closes on resume"
      end
    end

    def test_picker_renders_the_session_list_in_place_of_the_editor
      with_chat(width: 50, screen_height: 14) do |chat, session|
        chat.open_session_picker([{path: "/a", label: "first session"}, {path: "/b", label: "second session"}])
        draw(chat, session)
        buffer = session.buffer_content.join
        assert_includes buffer, "Resume Session (Current Folder)", "pi's selector title (session-selector.ts:147)"
        assert_match(/→ first session/, buffer, "the selection marker on the newest session")
        assert_includes buffer, "second session"
      end
    end

    # The replay (item 3/AC3): a recorded fixture session (real recorder
    # shapes — Message#to_h entries, see the report's fixture dump)
    # replays through the live-turn shapes + "Resumed session"; no MOTD.
    def test_resume_session_replays_the_recorded_entries
      recorded = recorded_session_fixture
      with_chat(width: 60, screen_height: 24) do |chat, session|
        chat.resume_session(recorded)
        draw(chat, session)
        lines = chat.transcript_lines
        joined = lines.join("\n")
        assert_includes joined, "what is in notes.txt?", "the user echo replays"
        assert_includes joined, "Let me look.", "the assistant markdown replays"
        assert_includes joined, " read notes.txt", "the read block replays through pi's read.ts call shape (I18)"
        assert_includes joined, "The file contains: hello", "the follow-up replays"
        assert_includes joined, "Resumed session", "the status line renders (interactive-mode.ts:5756)"
        refute_includes joined, "tart v#{Tart::VERSION}", "NO fresh MOTD on resume (itemized cut)"
        # The echo replay carries the bg span shape.
        y = buffer_row(chat, "what is in notes.txt?")
        assert_equal Theme[:user_message_text], line_fg(session, y, "what")
        assert_equal Theme[:user_message_bg], session.cell_bg(session.buffer_content[y].index("what"), y)
      end
    end

    def test_resume_session_reports_the_compaction_count
      recorded = recorded_session_fixture
      File.open(recorded, "a") do |file|
        file.write(JSON.generate(
          type: "compaction", id: "c1", parentId: "x", timestamp: Agent::Session.now_iso,
          summary: "earlier context", firstKeptEntryId: "x", tokensBefore: 100, details: {}
        ))
        file.write("\n")
      end
      with_chat(width: 60, screen_height: 24) do |chat, session|
        chat.resume_session(recorded)
        draw(chat, session)
        assert_includes chat.transcript_lines.join, "Session compacted 1 time",
          "the compaction count renders (interactive-mode.ts:4226-4232)"
      end
    end

    # /resume end-to-end through the kernel + command wiring (AC2): the
    # dispatched builtin opens the picker, enter fires the resume seam,
    # and the replayed transcript + status land — the same surface shape
    # the CLI --resume path renders (bin/tart wires both through one
    # lambda).
    def test_slash_resume_through_the_kernel_dispatch
      @server = MockLLMServer.new.start
      kernel, chat, session = chat_with_server
      chat.commands = Commands::Handler.new(
        skills: [], settings: {},
        output: ->(text) { chat.command_line(text) },
        spawn: ->(&block) { kernel.async(&block) },
        agent: -> { chat.agent },
        reset: -> { chat.new_session },
        resume: lambda do
          chat.open_session_picker([{path: recorded_session_fixture, label: "fixture session"}])
        end,
        quit: -> { kernel.stop! }
      )
      resumed = Queue.new
      chat.on_resume = ->(path) { resumed << path; chat.resume_session(path) }

      scenario = Thread.new do
        type(session, "/resume")
        wait_until { chat.picker_items }
        session.push_event(TUI.key_event("enter"))
        wait_until { !resumed.empty? }
        wait_until { chat.transcript_lines.join.include?("Resumed session") }
        kernel.stop!
      end
      kernel.run
      scenario.join

      assert_equal recorded_session_fixture, resumed.pop
      joined = chat.transcript_lines.join("\n")
      assert_includes joined, "what is in notes.txt?", "the replay landed through the dispatch"
      assert_includes joined, "Resumed session"
    end

    # A recorded fixture session (the report's dump shapes): user turn,
    # assistant with a tool call, the tool result, the follow-up assistant.
    def recorded_session_fixture
      dir = File.join(@dir, "sessions")
      FileUtils.mkpath(dir)
      path = File.join(dir, "fixture_test-session.jsonl")
      File.write(path, <<~JSONL)
        {"type":"session","version":3,"id":"test-session","timestamp":"2026-01-01T00:00:00.000Z","cwd":"#{@dir}"}
        {"type":"message","id":"e1","parentId":null,"timestamp":"2026-01-01T00:00:01.000Z","message":{"role":"user","content":"what is in notes.txt?"}}
        {"type":"message","id":"e2","parentId":"e1","timestamp":"2026-01-01T00:00:02.000Z","message":{"role":"assistant","content":"Let me look.","tool_calls":{"call_1":{"id":"call_1","name":"read","arguments":{"path":"notes.txt"}}},"finish_reason":"tool_calls","input_tokens":10,"output_tokens":5}}
        {"type":"message","id":"e3","parentId":"e2","timestamp":"2026-01-01T00:00:03.000Z","message":{"role":"tool","content":"hello","tool_call_id":"call_1"}}
        {"type":"message","id":"e4","parentId":"e3","timestamp":"2026-01-01T00:00:04.000Z","message":{"role":"assistant","content":"The file contains: hello","tool_calls":{},"finish_reason":"stop","input_tokens":10,"output_tokens":5}}
      JSONL
      path
    end

    # The fg of the first cell carrying +glyph+ on buffer row +y+ (the
    # ScriptedSession keeps no cells; this runs on the real test terminal).
    def line_fg(session, y, glyph)
      x = session.buffer_content[y].index(glyph)
      session.cell_fg(x, y)
    end

    private

    # A chat surface on the headless fullscreen test terminal for key-surface
    # tests (draw/readback assertions use with_chat; these only need the
    # editor's key path, which never draws).
    def with_headless_chat(autocomplete: nil, width: 40, models: nil, settings_root: nil, footer_data: nil)
      TUI.run(headless: true, viewport: :fullscreen, width:, screen_height: 12) do |session|
        yield Render::Chat.new(session:, kernel: IdleKernel.new, autocomplete:, motd: false,
          models:, settings_root: settings_root || @dir, footer_data:), session
      end
    end

    # Render-only tests: the real headless fullscreen test terminal (buffer
    # readback). Width 9 makes wrapping observable ("aaaa bbbb" is exactly 9
    # cells). motd: false — the MOTD block is pinned by its own tests.
    # kernel: injectable (the I38 animation-window pins record animate
    # calls; default IdleKernel unchanged).
    def with_chat(width: 9, screen_height: 12, footer_data: nil, branch_reader: nil, motd: false,
      models: nil, settings_root: nil, clock: nil, kernel: nil)
      TUI.run(headless: true, viewport: :fullscreen, width:, screen_height:) do |session|
        kernel ||= IdleKernel.new
        kwargs = {session:, kernel:, footer_data:, branch_reader: branch_reader || ->(_cwd) { nil }, motd:,
          models:, settings_root: settings_root || @dir}
        kwargs[:clock] = clock if clock # the spinner's fake-time seam (pi's 80ms dwell pinned, zero sleeps)
        chat = Render::Chat.new(**kwargs)
        yield(chat, session, kernel)
      end
    end

    # Kernel-driven tests: ScriptedSession feeds the real poller/frame loop.
    # (motd: false — the MOTD block is pinned by its own tests; these pin
    # transcript/editor behavior. The bin/tart default renders it.)
    def chat_with_server(tools: {}, autocomplete: nil, motd: false, identity: Identity::DEFAULT)
      session = ScriptedSession.new(width: 80, height: 24)
      kernel = Core::Loop.new(session:)
      chat = Render::Chat.new(session:, kernel:, branch_reader: nil, autocomplete:, motd:, identity:)
      chat.agent = Agent::Loop.new(
        chat: TestChat.build(@server, tools: tools.values, system_prompt: "test"),
        tools:, on_event: ->(event) { chat.on_agent_event(event) }
      )
      kernel.renderer = chat.renderer
      kernel.on_event = ->(event, source) { chat.on_event(event, source) }
      [kernel, chat, session]
    end

    # Fake agent-event flow (no LLM): the same shapes the I03 surface emits.
    def stream(chat, text, start: true)
      chat.on_agent_event({type: :message_start, message: ChunkDouble.new(text)}) if start
      chat.on_agent_event({type: :message_update, chunk: ChunkDouble.new(text)})
    end

    def finish_message(chat, content)
      chat.on_agent_event({type: :message_end, message: MessageDouble.new(:assistant, content)})
    end

    def assistant_done(chat, tokens)
      chat.on_agent_event({type: :message_end, message: MessageDouble.new(:assistant, "done", tokens)})
    end

    def tool_start(chat, name, arguments: {})
      chat.on_agent_event({type: :tool_execution_start, tool_call: ToolCallDouble.new(name, arguments)})
    end

    # `duration:` rides the frozen :tool_execution_end contract (Float
    # seconds, nil = absent); bash blocks read the call's arguments.
    def tool_end(chat, name, result, duration: nil, arguments: {})
      chat.on_agent_event({type: :tool_execution_end, tool_call: ToolCallDouble.new(name, arguments), result:,
                           duration:})
    end

    # Types +text+ into the input line and presses Enter (direct key events
    # — the render-level editor path, no kernel).
    def send_message(chat, text)
      text.chars.each { |char| chat.on_event(TUI.key_event(char)) }
      chat.on_event(TUI.key_event("enter"))
    end

    # A streaming reasoning delta double carrying the gem's real Thinking
    # value object (ruby_llm 2.1.0 protocols/chat_completions/streaming.rb
    # :28-29 — the shape the surface reads).
    def thinking_chunk(content, text = "pondering")
      ChunkDouble.new(content, RubyLLM::Thinking.new(text:))
    end

    # Types +text+ into the input line and presses Enter (synthetic events —
    # the kernel dispatches them to the chat).
    def type(session, text)
      text.chars.each { |char| session.push_event(TUI.key_event(char)) }
      session.push_event(TUI.key_event("enter"))
    end

    def draw(chat, session)
      session.draw(chat.renderer.call)
    end

    # Layout geometry of the fullscreen composition (the driving values,
    # mirrored from Render::Chat::FOOTER_ROWS/MIN_EDITOR_ROWS/
    # DOCK_SPACER_ROWS): transcript rows on top, then the dock — the blank
    # widgets-above spacer row, the 3-row edit box (top border, input row,
    # bottom border — pi's horizontal-borders-only shape), the 2-row
    # footer.
    def transcript_height(session, chat)
      session.buffer_content.size - 6
    end

    # The transcript area (the surface-owned buffer's visible tail with the
    # streaming source at its end).
    def live_region(session, chat)
      session.buffer_content[0, transcript_height(session, chat)].join
    end

    # The transcript rows with the scrollbar gutter glyph shaved — the
    # overflow layout's dedicated column rides the row tail.
    def transcript_view(session, chat)
      transcript_lines(session, chat).map do |line|
        (line.end_with?("│") || line.end_with?("┃")) ? line[..-2].rstrip : line
      end
    end

    # The edit box's input row and the suggestion-list rows below it: the
    # input row is the fake cursor's row (the only [:reversed] cells on
    # screen); the list rows run down to (excluding) the block's bottom
    # border (always h-3: the 2-row footer docks below).
    def editor_rows(session)
      h = session.buffer_content.size
      input = input_row(session)
      [input, ((input + 1)...(h - 3)).map { |y| session.buffer_content[y].rstrip }]
    end

    # The buffer's transcript rows, stripped and non-empty.
    def transcript_lines(session, chat)
      session.buffer_content[0, transcript_height(session, chat)].map(&:rstrip).reject(&:empty?)
    end

    # Whether any buffer cell renders +bg+ (the I34 pending-survival scan:
    # no #34383a span may survive a settle or appear on the replay path).
    def buffer_bg_hit?(session, bg)
      session.buffer_content.each_with_index.any? do |row, y|
        row.chars.each_index.any? { |x| session.cell_bg(x, y) == bg }
      end
    end

    # The editor area rows (block borders + inner content).
    # Line objects (with their spans) of a drawn widget tree — the style
    # readback for kernel-driven tests, where ScriptedSession keeps the
    # widgets but exposes no cells.
    def widget_lines_with_spans(widget)
      if widget.respond_to?(:text)
        widget.text.is_a?(String) ? [] : widget.text
      elsif widget.respond_to?(:children)
        widget.children.flat_map { |child| widget_lines_with_spans(child) }
      else
        []
      end
    end

    def editor_area(session, chat)
      h = session.buffer_content.size
      session.buffer_content[(h - 5)..(h - 3)].join
    end

    # The editor's top border row while the 3-row box holds (the status
    # line's row — pi custom-editor.ts renderTopBorder).
    def status_border_row(session)
      session.buffer_content[status_border_row_index(session)]
    end

    def status_border_row_index(session)
      session.buffer_content.size - 5
    end

    # The status's spinner glyph: "── " prefix, then the glyph (pi's
    # single-space border layout).
    def status_spinner_glyph(session)
      status_border_row(session)[3]
    end

    def footer_text(session)
      session.buffer_content[-2, 2].join
    end

    def footer_stats_row(session)
      session.buffer_content.size - 1
    end

    # [y, x, symbol, fg, modifiers] of every non-blank cell in the
    # transcript rows — the markdown-seam style readback.
    def transcript_cells(session, chat)
      h = session.buffer_content.size
      (0...(h - 5)).flat_map do |y|
        (0...session.buffer_content[y].length).filter_map do |x|
          symbol = session.cell_symbol(x, y)
          next if symbol == " "

          [y, x, symbol, session.cell_fg(x, y), session.cell_modifiers(x, y)]
        end
      end
    end

    # [symbol, fg] of every non-blank screen cell — the style readback for
    # cell-position-independent assertions.
    def all_cells(session)
      session.buffer_content.each_with_index.flat_map do |row, y|
        row.chars.each_with_index.filter_map do |symbol, x|
          next if symbol == " "

          [symbol, session.cell_fg(x, y)]
        end
      end
    end

    # The dim attribute's cell readback (pi's dimTokens render ESC[2m —
    # Theme[:dim] maps to the modifier, the fg stays nil).
    def dim_cell?(session, match)
      session.buffer_content.each_with_index.any? do |row, y|
        row.chars.each_with_index.any? do |symbol, x|
          match.call(symbol, x, y) && session.cell_modifiers(x, y).include?(:dim)
        end
      end
    end

    # A cell matching +match+ carries the +fg+ color (the token-color
    # successor of the dim-attribute probe — dark has no dimTokens).
    def fg_cell?(session, match, fg)
      session.buffer_content.each_with_index.any? do |row, y|
        row.chars.each_with_index.any? do |symbol, x|
          match.call(symbol, x, y) && session.cell_fg(x, y) == fg
        end
      end
    end

    # [symbol, fg] of the first non-blank cell of every non-blank screen row
    # — the style readback for line-kind assertions (lead glyphs ❯ / ⎿ /
    # spinner make the row kind identifiable).
    def lead_cells(session)
      session.buffer_content.each_with_index.filter_map do |row, y|
        col = row.chars.index { |cell| cell != " " }
        next unless col

        [session.cell_symbol(col, y), session.cell_fg(col, y)]
      end
    end

    def drawn_text(session)
      widget = session.drawn.last
      widget ? TUI.widget_lines(widget).join("\n") : ""
    end

    # The input line's row: the fake cursor's [:reversed] cells are the
    # only reversed cells on screen (3-row block when no list is open:
    # input at h-4).
    def input_row(session)
      h = session.buffer_content.size
      h.times.find { |row| reversed_row?(session, row) } || h - 4
    end

    def reversed_row?(session, y)
      row = session.buffer_content[y]
      row.chars.each_with_index.any? { |_char, x| session.cell_modifiers(x, y).include?(:reversed) }
    end

    def cursor_cell(session, x, row)
      [session.cell_symbol(x, row), session.cell_modifiers(x, row)]
    end

    # A SlashSource over bare builtin names (description = "<name>
    # description") — the synthetic catalog for the editor's key paths.
    def slash_source(*names)
      Render::SlashSource.new(
        commands: names.each_with_object({}) { |name, table| table[name] = {description: "#{name} description"} },
        skills: []
      )
    end

    # A branch reader that counts reads (the footer cache proof).
    def branch_counter
      @branch_calls = 0
      lambda do |_cwd|
        @branch_calls += 1
        "counted-branch"
      end
    end

    # Accumulating view of the mock server's captured request bodies.
    # captured_requests DRAINS the server's queue, so polling it directly
    # inside wait_until loses earlier requests — accumulate instead.
    def captured
      @captured ||= []
      @captured.concat(@server.captured_requests)
    end

    ChunkDouble = Struct.new(:content, :thinking)
    MessageDouble = Struct.new(:role, :content, :tokens)
    ToolCallDouble = Struct.new(:name, :arguments) do
      def initialize(name, arguments = {})
        super
      end
    end
    TokensDouble = Struct.new(:input, :output, :cache_read, :cache_write)

    # A kernel double for render-only tests (chat opens animation windows and
    # submits runs through the real one in kernel-driven tests).
    class IdleKernel
      attr_reader :submitted

      def initialize
        @submitted = []
        @timers = []
      end

      def animate(duration:) = nil

      def request_draw = nil

      # Reactor-task stand-in: records the submitted blocks (the submit
      # seam's agent runs AND the one-shot timers — drain_runs runs them
      # inside a real reactor; fire_timers stays for the timer-shape
      # tests). Returns SELF — the task role: the escape-cancel's
      # #stop lands here as a no-op (a real task raises the cancel in
      # its fiber; the double's block is driven synchronously).
      def async(&block)
        @submitted << block
        self
      end

      def fire_timers
        submitted, @submitted = @submitted, []
        submitted.each(&:call)
      end

      # The /quit path (bin/tart wires quit: -> { kernel.stop! }) — ctrl+d's
      # exit route (pi app.exit).
      def stop!
        @stopped = true
      end

      def stopped? = !!@stopped

      # The task role (async returns self).
      def stop = nil
    end

    # The idle kernel plus an animation-window recording (the I38
    # frame-pacing pins: the bash loader's window opens without busy?).
    class RecordingKernel < IdleKernel
      attr_reader :animate_calls

      def initialize
        super
        @animate_calls = []
      end

      def animate(duration:)
        @animate_calls << duration
        nil
      end
    end
  end
end
