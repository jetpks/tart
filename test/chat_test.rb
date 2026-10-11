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
        3.times { chat.on_event(TUI.key_event("page_up")) } # scroll to the top; the echo is on screen
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
        assert_includes editor_area(session, chat), "tool: grep",
          "the tool name renders in the editor's status border while it runs"

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
        # glyph) — scan cells, not lead cells. The dim TOKEN color (dark
        # has no dimTokens — the attribute pin was the system-theme
        # artifact; pi's border title rides theme.fg("dim")).
        assert fg_cell?(session, ->(symbol, _x, _y) { Render::Chat::SPINNER.include?(symbol) }, Theme[:dim]),
          "the status line renders the dim token color"

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
          settings_root: @dir, autocomplete: source, identity: "tart",
          footer_data: {cwd: @dir})
        draw(chat, session)
        lines = chat.transcript_lines

        assert_equal "", lines.first, "the header container opens with its Spacer(1)"
        art = Dir[File.join(Render::Chat::LOGOS_DIR, "*.txt")].map { |f| File.readlines(f, chomp: true) }
        assert art.any? { |piece| (piece.map { |line| " #{line}" } - lines).empty? },
          "a random logo piece from the owner's collection renders in full (padded)"
        assert_includes lines, " tart v#{Tart::VERSION}", "the version line renders Tart::VERSION (padded)"
        assert_includes lines.join, "/ commands", "the hints line carries the port's real keys"
        refute_includes lines.join, "! ", "no `!` bash hint — the port has no bash mode"

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
        hints_text = Render::Chat::PI_HINTS.flat_map.with_index do |(key, description), index|
          [key, " #{description}#{index == Render::Chat::PI_HINTS.length - 1 ? "" : " · "}"]
        end.join
        assert_equal " ▀▀█  v#{Identity::ORACLE_VERSION}", lines[1], "the mark's first line carries the version"
        assert_equal " █▀ █ #{hints_text}", lines[2], "the mark's second line carries the hints (the byte-identical join over the span family)"
        assert_equal " #{Render::Chat::PI_NOTICE_LINE}", lines[3], "the ctrl+o notice"
        assert_equal "", lines[4], "the header text's blank row"
        assert_equal " #{Render::Chat::PI_ONBOARDING_LINE}", lines[5], "the onboarding line"
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
    # assistant-message.ts:107-109): the live region's CONTENT re-renders
    # as markdown on every delta — proven by styled readback BEFORE
    # :message_end; the reasoning block above it stays plain dim italic
    # (the I13 standing ruling, itemized).
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
          thinking: ->(arg) { arg == :cycle ? chat.cycle_thinking_level : chat.set_thinking_level(arg) },
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
        draw(chat, session)
        assert session.buffer_content[footer_stats_row(session)].rstrip.end_with?("m • xhigh"),
          "the bare command cycles to the next level"

        handler.dispatch("/thinking nope")
        assert @commands_output.last.include?("Unknown thinking level"), "unknown levels error, the level holds"
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

    def test_ctrl_w_deletes_word_backward_through_the_key_surface
      with_headless_chat do |chat|
        "hello world".each_char { |char| chat.on_event(TUI.key_event(char)) }
        chat.on_event(TUI.key_event("w", modifiers: ["ctrl"]))
        assert_equal "hello ", chat.input, "ctrl+w removes the trailing word, keeping the separator"
        chat.on_event(TUI.key_event("w", modifiers: ["ctrl"]))
        assert_equal "", chat.input, "second ctrl+w removes the word plus trailing whitespace"
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
    # auto scrollbar (pageUp/pageDown per keybindings.ts:114-115 — the gem
    # spells the codes page_up/page_down). ---

    def test_page_up_pans_the_transcript_and_the_tail_refollows
      with_chat(width: 20, screen_height: 12) do |chat, session|
        20.times { |i| finish_message(chat, "line#{i}") }
        draw(chat, session)
        assert_equal " line19", transcript_view(session, chat).last, "following: the tail is visible"

        chat.on_event(TUI.key_event("page_up"))
        draw(chat, session)
        visible = transcript_view(session, chat)
        refute_includes visible, "line19", "a page up detaches from the end"
        assert_equal 28, chat.scroll_offset, "one page = the transcript viewport rows (6 off 34)"
        assert_includes visible, " line14", "the window sits a page back into the transcript"

        chat.on_event(TUI.key_event("page_down"))
        draw(chat, session)
        assert_equal " line19", transcript_view(session, chat).last,
          "a page down from the page-up position lands at the end and re-follows"
      end
    end

    def test_a_scrolled_up_view_stays_put_as_new_output_arrives
      with_chat(width: 20, screen_height: 12) do |chat, session|
        20.times { |i| finish_message(chat, "line#{i}") }
        draw(chat, session)
        chat.on_event(TUI.key_event("page_up"))
        draw(chat, session)

        finish_message(chat, "late")
        draw(chat, session)
        assert_equal 28, chat.scroll_offset,
          "the detached view stays put while output streams"
        refute_includes transcript_view(session, chat), "late"

        chat.on_event(TUI.key_event("page_down"))
        draw(chat, session)
        refute_includes transcript_view(session, chat), "late", "a paged view pans one page, not to the end"
        chat.on_event(TUI.key_event("page_down"))
        draw(chat, session)
        assert_equal " late", transcript_view(session, chat).last,
          "landing at the end re-follows the new output"
      end
    end

    def test_page_scrolling_is_the_lists_prisoner_and_needs_no_overflow
      with_chat(width: 20, screen_height: 12) do |chat, session|
        chat.on_agent_event({type: :agent_start})
        "ar".each_char { |char| chat.on_event(TUI.key_event(char)) } # no slash: no list, page keys free
        chat.on_event(TUI.key_event("page_up"))
        assert_equal 0, chat.scroll_offset, "paging with nothing to scroll is a no-op"
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
        chat.on_event(TUI.key_event("page_up"))
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

    # Mark sites (AC2): the user-scroll seams (pi scrollTo/scrollBy/
    # scrollToStart/scrollToEnd analogs — page keys and the wheel) mark
    # activity; the render-time follow-end adjustment never does (pi
    # updateLayout :180-192), and a clamped no-op scroll marks nothing
    # (pi scrollBy: moved === 0).
    def test_user_scroll_marks_scrollbar_activity_follow_end_does_not
      with_chat(width: 20, screen_height: 12) do |chat, session, kernel|
        20.times { |i| finish_message(chat, "line#{i}") }
        chat.scrollbar_hide_delay_ms = 10_000 # fresh for the duration of the test — no real sleeps

        finish_message(chat, "late") # new output lands while following
        draw(chat, session)
        assert_equal " ", session.cell_symbol(19, 5),
          "the follow-end adjustment never marks activity (pi updateLayout)"

        chat.on_event(TUI.key_event("page_up"))
        draw(chat, session)
        assert_equal "┃", session.cell_symbol(19, 4), "the page-key seam marks"
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

        chat.on_event(TUI.key_event("page_up"))
        draw(chat, session)
        rows = TUI.widget_lines(chat.renderer.call)
        assert_equal "│", rows[0][-1], "the track paints the last column while visible"
        assert_equal " line14", rows[1][0, 7], "the row's content survives under the overlay (clipped at width−1, padded, then the glyph)"
      end
    end

    # --- mouse: wheel scroll + transcript selection (I14 items 6/10,
    # driven through the synthetic-seam event shapes) ---

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
    # a bell terminator, buffer "c").
    def copied_text(stdout)
      stdout[/\e\]52;c;(.*?)\a/, 1].unpack1("m")
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
        assert_includes transcript_lines(session, chat), "✻ compacted (manual, 100 tokens)",
          "the post-hoc compaction line renders unchanged"

        chat.on_agent_event({type: :compaction_start, reason: :threshold})
        chat.on_agent_event({type: :agent_end})
        draw(chat, session)
        refute_includes editor_area(session, chat), "Auto-compacting...", "cleared by the run end"
      end
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
    def with_headless_chat(autocomplete: nil, width: 40)
      TUI.run(headless: true, viewport: :fullscreen, width:, screen_height: 12) do |session|
        yield Render::Chat.new(session:, kernel: IdleKernel.new, autocomplete:, motd: false), session
      end
    end

    # Render-only tests: the real headless fullscreen test terminal (buffer
    # readback). Width 9 makes wrapping observable ("aaaa bbbb" is exactly 9
    # cells). motd: false — the MOTD block is pinned by its own tests.
    def with_chat(width: 9, screen_height: 12, footer_data: nil, branch_reader: nil, motd: false)
      TUI.run(headless: true, viewport: :fullscreen, width:, screen_height:) do |session|
        kernel = IdleKernel.new
        chat = Render::Chat.new(session:, kernel:,
          footer_data:, branch_reader: branch_reader || ->(_cwd) { nil }, motd:)
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

    def tool_start(chat, name)
      chat.on_agent_event({type: :tool_execution_start, tool_call: ToolCallDouble.new(name)})
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
  end
end
