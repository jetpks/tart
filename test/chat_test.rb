# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/mock_llm_server"
require "tmpdir"
require "fileutils"

module Tart
  # The interactive chat surface (AC1/AC2): streaming render on the inline
  # viewport, scrollback insertion on completion, input line, key-driven
  # approval gates — hermetic via the headless inline test terminal (render,
  # buffer readback) and ScriptedSession + MockLLMServer (kernel-driven
  # input/approval/interrupt; the real test terminal cannot feed the poller
  # without a tty — I01 finding).
  class ChatTest < Test
    def setup
      @dir = Dir.mktmpdir("tart-chat-")
    end

    def teardown
      FileUtils.rm_rf(@dir)
      @server&.stop
    end

    # --- render model (headless inline test terminal, buffer readback) ---

    def test_streaming_deltas_grow_the_live_region
      with_inline_chat do |chat, session|
        stream(chat, "hel")
        draw(chat, session)
        assert_includes live_region(session), "hel"

        stream(chat, "lo", start: false)
        draw(chat, session)
        assert_includes live_region(session), "hello",
          "the live region must grow with the deltas"
      end
    end

    def test_completed_message_lands_above_the_live_region_wrapped
      with_inline_chat do |chat, session|
        stream(chat, "aaaa bbbb cccc dddd")
        finish_message(chat, "aaaa bbbb cccc dddd")
        draw(chat, session)

        # The viewport is the last 4 rows; the wrapped message is above it.
        assert_equal ["aaaa bbbb", "cccc dddd"], inserted_lines(session),
          "the completed text lands above the live region, wrapped to width"
        assert_includes live_region(session), "❯", "the input line stays in the live region"
      end
    end

    def test_tool_call_lifecycle_is_rendered
      with_inline_chat(width: 40) do |chat, session|
        chat.on_agent_event({type: :agent_start})
        tool_start(chat, "bash")
        draw(chat, session)
        assert_includes live_region(session), "tool: bash"

        tool_end(chat, "bash", "done\nmore")
        draw(chat, session)
        assert_includes live_region(session), "❯", "input line visible after tool end"
        # inserted_lines strips per-row whitespace (buffer rows are padded).
        assert_equal ["⎿ bash: done", "more"], inserted_lines(session),
          "the tool result lifecycle renders into scrollback as a multi-line excerpt"
      end
    end

    def test_tool_result_preview_is_bounded_multiline
      with_inline_chat(width: 40) do |chat, session|
        tool_start(chat, "bash")
        tool_end(chat, "bash", "one\ntwo\nthree\nfour\nfive")
        draw(chat, session)
        assert_equal ["⎿ bash: one", "two", "three", "…"], inserted_lines(session),
          "the preview shows a bounded multi-line excerpt, then an ellipsis"
      end
    end

    # The style vocabulary (AC4): line kinds are distinguished by fg color,
    # proven by cell readback on the headless terminal (not presence-greps).
    def test_user_assistant_tool_and_status_lines_read_back_distinct_fg_colors
      with_inline_chat(width: 40, height: 10) do |chat, session|
        chat.on_agent_event({type: :agent_start})
        stream(chat, "streaming")
        draw(chat, session)
        assert lead_cells(session).any? { |symbol, fg| Render::Chat::SPINNER.include?(symbol) && fg == Render::Chat::FG[:status] },
          "the status line is dim (#{Render::Chat::FG[:status].inspect})"

        finish_message(chat, "assistant answer") # scrollback: assistant, terminal default
        tool_end(chat, "bash", "tool output")    # scrollback: tool, muted
        chat.on_agent_event({type: :agent_end})
        "hi".each_char { |char| chat.on_event(TUI.key_event(char)) }
        chat.on_event(TUI.key_event("enter"))    # scrollback: user echo
        draw(chat, session)

        leads = lead_cells(session)
        assert_includes leads, ["a", nil],
          "assistant text carries the terminal default fg (pi: userMessageText/text)"
        assert_includes leads, ["⎿", Render::Chat::FG[:tool]],
          "tool output is muted (pi: toolOutput)"
        assert_includes leads, ["❯", Render::Chat::FG[:user]],
          "the user echo carries the blue distinction (pi: userMessageBg)"
        assert_includes leads, ["❯", nil],
          "the input line keeps the terminal default — visually apart from the colored echo"
      end
    end

    def test_pending_approval_stays_fully_visible_over_a_full_live_region
      with_inline_chat(width: 40, height: 10) do |chat, session|
        chat.on_agent_event({type: :agent_start})
        stream(chat, "word " * 40, start: false)
        decision = Thread.new { chat.approval(ToolCallDouble.new("bash")) }
        wait_until { chat.pending_approval }
        draw(chat, session)

        region = live_region(session)
        assert_includes region, "approve bash?"
        assert_includes region, "y = yes, n = no", "the full approval prompt stays in the viewport"

        chat.on_event(TUI.key_event("y"))
        assert decision.value == true, "the prompt remains answerable"
      end
    end

    def test_chat_runs_inside_the_seam_lifecycle_and_restores
      TUI.run(headless: true, viewport: :inline, height: 4) do |session|
        chat = Render::Chat.new(session:, kernel: IdleKernel.new)
        stream(chat, "hi")
        draw(chat, session)
        assert_includes live_region(session), "hi"
      end
      refute TUI::Session.active?, "terminal restored after the chat surface exits"
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
      assert_equal ["❯ hi"], scrollback_lines(session),
        "the submitted prompt is echoed into scrollback"
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

    def test_approval_yes_executes_the_tool
      @server = MockLLMServer.new.start
      @server.script([
        {type: :stream, tool_calls: [{id: "call_1", name: "bash", arguments: {command: "echo approved-out"}}]},
        {type: :message, content: "done"},
      ])
      kernel, chat, session = chat_with_server(tools: Tools::Registry.build(selected: %w[bash], cwd: @dir))

      scenario = Thread.new do
        type(session, "run it")
        wait_until { chat.pending_approval }
        wait_until { drawn_text(session).include?("approve bash?") }
        session.push_event(TUI.key_event("y"))
        wait_until { chat.pending_approval.nil? && !chat.busy? }
        kernel.stop!
      end
      kernel.run
      scenario.join

      tool_message = captured.last["messages"].find { |m| m["role"] == "tool" }
      assert_includes tool_message["content"], "approved-out", "approve -> the tool executes"
      assert chat.pending_approval.nil?, "prompt state torn down on resolution"
    end

    def test_approval_no_denies_and_the_model_continues
      @server = MockLLMServer.new.start
      @server.script([
        {type: :stream, tool_calls: [{id: "call_1", name: "bash", arguments: {command: "echo denied-out"}}]},
        {type: :message, content: "understood"},
      ])
      kernel, chat, session = chat_with_server(tools: Tools::Registry.build(selected: %w[bash], cwd: @dir))

      scenario = Thread.new do
        type(session, "run it")
        wait_until { chat.pending_approval }
        session.push_event(TUI.key_event("n"))
        wait_until { !chat.busy? }
        kernel.stop!
      end
      kernel.run
      scenario.join

      tool_message = captured.last["messages"].find { |m| m["role"] == "tool" }
      assert_includes tool_message["content"], "The user denied the bash tool call."
      refute tool_message["content"].include?("denied-out"), "a denied call never executes"
    end

    def test_keys_during_approval_do_not_leak_into_the_input_line
      @server = MockLLMServer.new.start
      @server.script([
        {type: :stream, tool_calls: [{id: "call_1", name: "bash", arguments: {command: "echo x"}}]},
        {type: :message, content: "ok"},
      ])
      kernel, chat, session = chat_with_server(tools: Tools::Registry.build(selected: %w[bash], cwd: @dir))

      scenario = Thread.new do
        type(session, "run it")
        wait_until { chat.pending_approval }
        session.push_event(TUI.key_event("z"))
        session.push_event(TUI.key_event("q"))
        assert_equal "", chat.input, "input during approval must not leak into the chat input"
        session.push_event(TUI.key_event("y"))
        wait_until { !chat.busy? }
        kernel.stop!
      end
      kernel.run
      scenario.join

      assert chat.pending_approval.nil?
    end

    def test_kernel_interrupt_during_approval_cancels_and_tears_down_the_prompt
      @server = MockLLMServer.new.start
      @server.script([
        {type: :stream, tool_calls: [{id: "call_1", name: "bash", arguments: {command: "sleep 30"}}]},
        {type: :message, content: "never reached"},
      ])
      kernel, chat, session = chat_with_server(tools: Tools::Registry.build(selected: %w[bash], cwd: @dir))

      scenario = Thread.new do
        type(session, "run it")
        wait_until { chat.pending_approval }
        session.push_event(TUI.key_event("c", modifiers: ["ctrl"]))
        wait_until { chat.pending_approval.nil? && chat.agent.interrupted? }
        kernel.stop!
      end
      kernel.run
      scenario.join

      assert chat.pending_approval.nil?, "prompt state fully torn down on interrupt"
      assert kernel.interrupted?
      refute kernel.poller&.thread&.alive?
    end

    def test_kernel_interrupt_during_streaming_cancels_and_leaves_render_coherent
      @server = MockLLMServer.new.start
      @server.script([{type: :slow_stream, content: "x" * 40}])
      kernel, chat, session = chat_with_server

      scenario = Thread.new do
        type(session, "long stream")
        wait_until { chat.busy? }
        session.push_event(TUI.key_event("c", modifiers: ["ctrl"]))
        wait_until { !chat.busy? }
        wait_until { scrollback_lines(session).join.include?("interrupted") }
        kernel.stop!
      end
      kernel.run
      scenario.join

      assert kernel.interrupted?
      assert chat.agent.interrupted?
      refute kernel.poller&.thread&.alive?, "no orphan poller"
      assert_includes scrollback_lines(session).join, "interrupted",
        "the interrupted turn renders coherently"
    end

    # --- markdown seam (AC5): assistant completions render through the
    # converter into scrollback — styled cells proven by readback; the live
    # region stays verbatim streaming text. ---

    def test_assistant_completion_renders_markdown_styled_in_scrollback
      with_inline_chat(width: 40, height: 6) do |chat, session|
        finish_message(chat, "# Heading\n\nplain **bold** text")
        draw(chat, session)

        cells = scrollback_cells(session) # [x, y, symbol, fg, modifiers]
        heading = cells.find { |cell| cell[2] == "H" }
        assert_equal :yellow, heading[3], "the markdown heading renders yellow (mdHeading)"
        assert_equal %i[bold underlined], heading[4], "h1 is bold+underlined (markdown.ts:481-483)"
        bold = cells.find { |cell| cell[2] == "b" }
        assert_equal [:bold], bold[4], "strong renders the bold modifier (markdown.ts:683-687)"
        plain = cells.find { |cell| cell[2] == "p" }
        assert_equal [nil, []], plain[3, 2], "plain prose keeps the terminal default"
        assert_equal 3, session.viewport_area.y,
          "the heading, its spacing row, and the paragraph occupy three scrollback rows"
      end
    end

    def test_live_region_streams_markdown_source_verbatim
      with_inline_chat do |chat, session|
        stream(chat, "**bo")
        draw(chat, session)
        assert_includes live_region(session), "**bo",
          "the live region carries the raw markdown source while streaming"
      end
    end

    def test_assistant_markdown_renders_through_the_kernel_loop
      @server = MockLLMServer.new.start
      @server.script([{type: :message, content: "# Title\n\nplain body"}])
      kernel, chat, session = chat_with_server

      scenario = Thread.new do
        type(session, "hi")
        wait_until { scrollback_lines(session).join.include?("Title") }
        kernel.stop!
      end
      kernel.run
      scenario.join

      assert_equal ["❯ hi", "Title", "", "plain body"], scrollback_lines(session),
        "the assistant reply renders as markdown rows in scrollback (with the spacing row between blocks)"
    end

    def test_wrap_row_wraps_styled_rows_preserving_spans
      bold = Render::Markdown::Span.new(text: "bold", modifiers: [:bold])
      row = [Render::Markdown::Span.new(text: "plain "), bold]
      rows = Render::Chat.wrap_row(row, 9) # "plain bold" is 10 cells

      assert_equal ["plain", "bold"], rows.map { |r| r.map(&:text).join },
        "the break consumes the separator space, as {wrap} does"
      assert_equal [:bold], rows[1].first.modifiers, "styling survives the wrap"
      assert_equal [row], Render::Chat.wrap_row(row, 10), "a fitting row passes through unchanged"
      assert_equal [[]], Render::Chat.wrap_row([], 10), "a blank row stays blank"
    end

    # --- wrapping ---

    def test_wrap_breaks_words_and_hard_splits_long_words
      assert_equal ["aaaa", "bbbb"], Render::Chat.wrap("aaaa bbbb", 5)
      assert_equal ["aaaa bbbb"], Render::Chat.wrap("aaaa bbbb", 9)
      assert_equal ["", "aaaa"], Render::Chat.wrap(" aaaa", 4)
      assert_equal ["aaaa bbbb", "cccc dddd"], Render::Chat.wrap("aaaa bbbb cccc dddd", 9)
      assert_equal ["aaaaa", "bbbbb"], Render::Chat.wrap("aaaaabbbbb", 5), "over-long words hard-split"
      assert_equal [""], Render::Chat.wrap("", 5)
    end

    # --- input line (minimal: chars, backspace, enter, paste) ---

    def test_input_line_edits_and_submits
      chat_idle_kernel = IdleKernel.new
      TUI.run(headless: true, viewport: :inline, height: 4, screen_height: 24) do |session|
        chat = Render::Chat.new(session:, kernel: chat_idle_kernel)
        "hi".each_char { |char| chat.on_event(TUI.key_event(char)) }
        chat.on_event(TUI.paste_event(" there"))
        chat.on_event(TUI.key_event("backspace"))
        assert_equal "hi ther", chat.input, "backspace removes the last character"
        chat.on_event(TUI.key_event("e", modifiers: ["ctrl"]))
        assert_equal "hi ther", chat.input, "ctrl+e moves to line end without editing"
        chat.on_event(TUI.key_event("enter"))
        assert_equal "", chat.input, "enter submits and clears the input line"
        draw(chat, session) # the frame loop's flush inserts the echo
        assert_equal ["❯ hi ther"], inserted_lines(session),
          "the submitted prompt is echoed into scrollback"
        assert_equal 1, chat_idle_kernel.submitted.size, "an idle submit starts an agent run"
      end
    end

    # --- cursor (AC2): the insertion point is cell-readback-visible at all
    # times — pi's fake cursor: the grapheme under it renders inverse-video,
    # at end-of-input a highlighted trailing space (tui.ts renderFakeCursor
    # via editor.ts:583-597); the port carries the reversed modifier. ---

    def test_cursor_reads_back_at_end_of_input
      with_inline_chat(width: 40) do |chat, session|
        "hi".each_char { |char| chat.on_event(TUI.key_event(char)) }
        draw(chat, session)
        row = input_row(session)
        assert_equal [" ", [:reversed]], cursor_cell(session, 4, row),
          "end-of-input cursor: highlighted trailing space after 'hi'"
        assert session.cell_modifiers(3, row).empty?, "the grapheme left of the cursor is unhighlighted"
      end
    end

    def test_cursor_reads_back_mid_input_and_tracks_left_right
      with_inline_chat(width: 40) do |chat, session|
        "hi".each_char { |char| chat.on_event(TUI.key_event(char)) }
        chat.on_event(TUI.key_event("left"))
        draw(chat, session)
        row = input_row(session)
        assert_equal ["i", [:reversed]], cursor_cell(session, 3, row),
          "after cursor-left the insertion point sits on the 'i'"
        assert session.cell_modifiers(4, row).empty?, "the trailing space is no longer highlighted"

        chat.on_event(TUI.key_event("right"))
        draw(chat, session)
        assert_equal [" ", [:reversed]], cursor_cell(session, 4, row),
          "cursor-right returns the insertion point to end-of-input"
      end
    end

    def test_cursor_hides_while_an_approval_prompt_holds_the_input_row
      with_inline_chat(width: 40) do |chat, session|
        "hi".each_char { |char| chat.on_event(TUI.key_event(char)) }
        thread = Thread.new { chat.approval(ToolCallDouble.new("bash")) }
        wait_until { chat.pending_approval }
        draw(chat, session)
        refute live_region(session).include?("❯"), "input row displaced by the approval prompt"
        chat.on_event(TUI.key_event("n"))
        assert_equal false, thread.value
      end
    end

    # --- mid-line editing (AC2) ---

    def test_printable_characters_insert_at_the_cursor
      with_headless_chat do |chat|
        "hi".each_char { |char| chat.on_event(TUI.key_event(char)) }
        chat.on_event(TUI.key_event("left"))
        chat.on_event(TUI.key_event("X"))
        assert_equal "hXi", chat.input, "a printable character inserts at the cursor"
        chat.on_event(TUI.key_event("left"))
        chat.on_event(TUI.key_event("left"))
        chat.on_event(TUI.key_event("!"))
        assert_equal "!hXi", chat.input, "inserting at the start of the line"
      end
    end

    def test_backspace_deletes_before_and_forward_delete_after_the_cursor
      with_headless_chat do |chat|
        "hi".each_char { |char| chat.on_event(TUI.key_event(char)) }
        chat.on_event(TUI.key_event("left"))
        chat.on_event(TUI.key_event("backspace"))
        assert_equal "i", chat.input, "backspace deletes before the cursor"
        chat.on_event(TUI.key_event("delete"))
        assert_equal "", chat.input, "forward-delete removes the character after the cursor"
        chat.on_event(TUI.key_event("delete"))
        assert_equal "", chat.input, "forward-delete at end-of-input is a no-op"
        "ab".each_char { |char| chat.on_event(TUI.key_event(char)) }
        chat.on_event(TUI.key_event("home"))
        chat.on_event(TUI.key_event("delete"))
        assert_equal "b", chat.input, "forward-delete at line start removes the first character"
      end
    end

    def test_home_end_and_ctrl_b_f_move_the_cursor
      with_headless_chat do |chat|
        "abcd".each_char { |char| chat.on_event(TUI.key_event(char)) }
        chat.on_event(TUI.key_event("home"))
        chat.on_event(TUI.key_event("X"))
        assert_equal "Xabcd", chat.input, "home jumps to line start"
        chat.on_event(TUI.key_event("f", modifiers: ["ctrl"])) # over 'a'
        chat.on_event(TUI.key_event("f", modifiers: ["ctrl"])) # over 'b'
        chat.on_event(TUI.key_event("Y"))
        assert_equal "XabYcd", chat.input, "ctrl+f steps right one character"
        chat.on_event(TUI.key_event("b", modifiers: ["ctrl"]))
        chat.on_event(TUI.key_event("Z"))
        assert_equal "XabZYcd", chat.input, "ctrl+b steps left one character"
        chat.on_event(TUI.key_event("e", modifiers: ["ctrl"]))
        chat.on_event(TUI.key_event("!"))
        assert_equal "XabZYcd!", chat.input, "ctrl+e jumps to line end"
      end
    end

    # --- history (AC3): pi's editor.ts addToHistory/navigateHistory —
    # most recent first, draft restored, recalled entries editable. ---

    def test_history_recalls_entries_in_order
      with_headless_chat do |chat|
        send_message(chat, "A")
        send_message(chat, "B")
        chat.on_event(TUI.key_event("up"))
        assert_equal "B", chat.input, "up recalls the most recent entry"
        chat.on_event(TUI.key_event("up"))
        assert_equal "A", chat.input, "up again walks to older entries"
        chat.on_event(TUI.key_event("down"))
        assert_equal "B", chat.input, "down returns toward the draft"
        chat.on_event(TUI.key_event("down"))
        assert_equal "", chat.input, "down past the newest entry restores the live draft"
      end
    end

    def test_recalled_history_entry_is_editable_and_sends_as_edited
      chat_idle_kernel = IdleKernel.new
      TUI.run(headless: true, viewport: :inline, height: 4, screen_height: 24) do |session|
        chat = Render::Chat.new(session:, kernel: chat_idle_kernel)
        send_message(chat, "A")
        send_message(chat, "B")
        chat.on_event(TUI.key_event("up"))
        chat.on_event(TUI.key_event("up")) # "A", cursor at line start (pi: cursorPlacement start)
        chat.on_event(TUI.key_event("!"))
        assert_equal "!A", chat.input, "a recalled entry is editable at the cursor"
        chat.on_event(TUI.key_event("enter"))
        draw(chat, session) # the frame loop's flush inserts the echo
        assert_equal ["❯ A", "❯ B", "❯ !A"], inserted_lines(session),
          "the edited recall sends as edited (after the two original echoes)"
      end
    end

    def test_history_skips_consecutive_duplicates
      with_headless_chat do |chat|
        send_message(chat, "A")
        send_message(chat, "A")
        chat.on_event(TUI.key_event("up"))
        assert_equal "A", chat.input, "a duplicate submission enters history once"
        chat.on_event(TUI.key_event("down"))
        assert_equal "", chat.input, "down past the newest entry restores the empty draft"
        chat.on_event(TUI.key_event("up"))
        chat.on_event(TUI.key_event("up"))
        assert_equal "A", chat.input, "history holds a single entry — walking past it is a no-op"
      end
    end

    # --- word-wise operations (AC3): pi's word-navigation.ts boundary
    # semantics — skip trailing whitespace, then one word/punctuation run. ---

    def test_find_word_backward_boundaries
      assert_equal 6, Render::Chat.find_word_backward("hello world", 11),
        "deletes 'world' but keeps the separator space (pi segment semantics)"
      assert_equal 0, Render::Chat.find_word_backward("hello ", 6), "trailing whitespace goes with the word"
      assert_equal 4, Render::Chat.find_word_backward("foo.bar", 7), "ASCII punctuation stays a boundary"
      assert_equal 3, Render::Chat.find_word_backward("foo.", 4), "a punctuation run goes as one unit"
      assert_equal 0, Render::Chat.find_word_backward("hi", 0)
      assert_equal 0, Render::Chat.find_word_backward("", 0)
    end

    def test_find_word_forward_boundaries
      assert_equal 5, Render::Chat.find_word_forward("hello world", 0)
      assert_equal 11, Render::Chat.find_word_forward("hello world", 5), "whitespace skipped to the next word"
      assert_equal 2, Render::Chat.find_word_forward("hi.", 0), "a word stops at the punctuation"
      assert_equal 3, Render::Chat.find_word_forward("hi.", 2), "a punctuation run is one unit"
      assert_equal 2, Render::Chat.find_word_forward("hi", 3), "at end-of-line the cursor stays put"
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

    def test_alt_b_alt_f_jump_words
      with_headless_chat do |chat|
        "hello world".each_char { |char| chat.on_event(TUI.key_event(char)) }
        chat.on_event(TUI.key_event("b", modifiers: ["alt"]))
        chat.on_event(TUI.key_event("X"))
        assert_equal "hello Xworld", chat.input, "alt+b jumps one word backward"
        chat.on_event(TUI.key_event("b", modifiers: ["alt"]))
        chat.on_event(TUI.key_event("Y"))
        assert_equal "hello YXworld", chat.input, "alt+b from the last word jumps to its start"
        chat.on_event(TUI.key_event("f", modifiers: ["alt"]))
        chat.on_event(TUI.key_event("Z"))
        assert_equal "hello YXworldZ", chat.input, "alt+f jumps one word forward"
      end
    end

    private

    # A chat surface on the headless test terminal for key-surface tests
    # (draw/readback assertions use with_inline_chat; these only need the
    # editor's key path, which never draws).
    def with_headless_chat
      TUI.run(headless: true, viewport: :inline, height: 4, screen_height: 24) do |session|
        yield Render::Chat.new(session:, kernel: IdleKernel.new)
      end
    end

    # Types +text+ into the input line and presses Enter (direct key events
    # — the render-level editor path, no kernel).
    def send_message(chat, text)
      text.chars.each { |char| chat.on_event(TUI.key_event(char)) }
      chat.on_event(TUI.key_event("enter"))
    end

    # The input line's row: the chat's live region puts it at the top of the
    # viewport (status/live/approval rows absent in these tests).
    def input_row(session)
      session.viewport_area.y
    end

    def cursor_cell(session, x, row)
      [session.cell_symbol(x, row), session.cell_modifiers(x, row)]
    end

    # Render-only tests: the real headless inline test terminal (buffer
    # readback) without the kernel. Width 9 makes wrapping observable
    # ("aaaa bbbb" is exactly 9 cells).
    def with_inline_chat(width: 9, height: 4, &)
      TUI.run(headless: true, viewport: :inline, height:, width:, screen_height: 24) do |session|
        chat = Render::Chat.new(session:, kernel: IdleKernel.new)
        yield chat, session
      end
    end

    # Kernel-driven tests: ScriptedSession feeds the real poller/frame loop.
    def chat_with_server(tools: {})
      session = ScriptedSession.new
      kernel = Core::Loop.new(session:)
      chat = Render::Chat.new(session:, kernel:)
      chat.agent = Agent::Loop.new(
        chat: TestChat.build(@server, tools: tools.values, system_prompt: "test"),
        tools:, on_event: ->(event) { chat.on_agent_event(event) },
        approval: ->(tool_call) { chat.approval(tool_call) }
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

    def tool_start(chat, name)
      chat.on_agent_event({type: :tool_execution_start, tool_call: ToolCallDouble.new(name)})
    end

    def tool_end(chat, name, result)
      chat.on_agent_event({type: :tool_execution_end, tool_call: ToolCallDouble.new(name), result:})
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

    # The test terminal's inline viewport starts at the TOP of the screen
    # (y=0) and shifts down as scrollback is inserted (verified gem source:
    # ext .../init.rs Viewport::Inline starts at the origin) — so the live
    # region and the inserted scrollback are located via the viewport Rect,
    # not hardcoded rows.
    def live_region(session)
      area = session.viewport_area
      session.buffer_content[area.y, area.height].join
    end

    # Lines the chat inserted above the viewport (rows 0...viewport.y).
    def inserted_lines(session)
      area = session.viewport_area
      session.buffer_content[0, area.y].map(&:strip).reject(&:empty?)
    end

    # [x, y, symbol, fg, modifiers] of every non-blank cell in the rows the
    # chat inserted above the viewport — the markdown-seam style readback.
    def scrollback_cells(session)
      area = session.viewport_area
      (0...area.y).flat_map do |y|
        (0...area.width).filter_map do |x|
          symbol = session.cell_symbol(x, y)
          next if symbol == " "

          [x, y, symbol, session.cell_fg(x, y), session.cell_modifiers(x, y)]
        end
      end
    end

    # [symbol, fg] of the first non-blank cell of every non-blank screen row
    # — the style readback for line-kind assertions (lead glyphs ❯ / ⎿ /
    # spinner make the row kind identifiable).
    def lead_cells(session)
      area = session.viewport_area
      (0...session.buffer_content.size).filter_map do |row|
        col = (0...area.width).find { |x| session.cell_symbol(x, row) != " " }
        next unless col

        [session.cell_symbol(col, row), session.cell_fg(col, row)]
      end
    end

    def drawn_text(session)
      widget = session.drawn.last
      widget ? widget_lines(widget).join("\n") : ""
    end

    # Widget texts recorded by ScriptedSession#insert_before, in order.
    def scrollback_lines(session)
      session.scrollback.flat_map { |(_height, widget)| widget_lines(widget) }
    end

    # A Paragraph's text is a String or an array of styled Lines (the chat
    # surface's style vocabulary); both normalize to display strings.
    def widget_lines(widget)
      text = widget.text
      text.is_a?(String) ? text.lines(chomp: true) : text.map { |line| line.spans.map(&:content).join }
    end

    # Accumulating view of the mock server's captured request bodies.
    # captured_requests DRAINS the server's queue, so polling it directly
    # inside wait_until loses earlier requests — accumulate instead.
    def captured
      @captured ||= []
      @captured.concat(@server.captured_requests)
    end

    ChunkDouble = Struct.new(:content)
    MessageDouble = Struct.new(:role, :content)
    ToolCallDouble = Struct.new(:name) do
      def arguments = {}
    end

    # A kernel double for render-only tests (chat opens animation windows and
    # submits runs through the real one in kernel-driven tests).
    class IdleKernel
      attr_reader :submitted

      def initialize
        @submitted = []
      end

      def animate(duration:) = nil

      # Records the submitted agent-run block (a real kernel spawns it as a
      # reactor task).
      def async(&block)
        @submitted << block
      end
    end
  end
end
