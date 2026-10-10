# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/mock_llm_server"
require "tmpdir"
require "fileutils"

module Tart
  # The interactive chat surface (AC1/AC2/AC3/AC4): the fullscreen
  # three-area composition — transcript buffer tail, bordered editor with
  # the status line in its top border, footer — with streaming render,
  # buffer-backed scrollback, input line, and key-driven approval gates —
  # hermetic via the headless fullscreen test terminal (render, buffer
  # readback) and ScriptedSession + MockLLMServer (kernel-driven
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
      with_chat do |chat, session|
        stream(chat, "aaaa bbbb cccc dddd")
        finish_message(chat, "aaaa bbbb cccc dddd")
        draw(chat, session)

        # The completed message is in the buffer; the editor's input line
        # sits in the docked editor area below it.
        assert_equal ["aaaa bbbb", "cccc dddd"], transcript_lines(session, chat),
          "the completed text lands above the live region, wrapped to width"
        assert_includes editor_area(session, chat), "❯", "the input line stays in the live region (the editor area)"
      end
    end

    def test_tool_call_lifecycle_is_rendered
      with_chat(width: 40) do |chat, session|
        chat.on_agent_event({type: :agent_start})
        tool_start(chat, "bash")
        draw(chat, session)
        assert_includes editor_area(session, chat), "tool: bash",
          "the tool name renders in the editor's status border while it runs"

        tool_end(chat, "bash", "done\nmore")
        draw(chat, session)
        assert_includes editor_area(session, chat), "❯", "input line visible after tool end"
        # transcript_lines strips per-row whitespace (buffer rows are padded).
        assert_equal ["⎿ bash: done", "more"], transcript_lines(session, chat),
          "the tool result lifecycle renders into the transcript as a multi-line excerpt"
      end
    end

    def test_tool_result_preview_is_bounded_multiline
      with_chat(width: 40) do |chat, session|
        tool_start(chat, "bash")
        tool_end(chat, "bash", "one\ntwo\nthree\nfour\nfive")
        draw(chat, session)
        assert_equal ["⎿ bash: one", "two", "three", "…"], transcript_lines(session, chat),
          "the preview shows a bounded multi-line excerpt, then an ellipsis"
      end
    end

    # The style vocabulary (AC3): line kinds are distinguished by fg color
    # through the theme, proven by cell readback on the headless terminal
    # (not presence-greps).
    def test_user_assistant_tool_and_status_lines_read_back_distinct_fg_colors
      with_chat(width: 40, screen_height: 14) do |chat, session|
        chat.on_agent_event({type: :agent_start})
        stream(chat, "streaming")
        draw(chat, session)
        # The status renders in the editor's top border (after the corner
        # glyph) — scan cells, not lead cells.
        assert all_cells(session).any? { |symbol, fg| Render::Chat::SPINNER.include?(symbol) && fg == Theme[:dim] },
          "the status line is dim (#{Theme[:dim].inspect})"

        finish_message(chat, "assistant answer") # transcript: assistant, terminal default
        tool_end(chat, "bash", "tool output")    # transcript: tool, muted
        chat.on_agent_event({type: :agent_end})
        "hi".each_char { |char| chat.on_event(TUI.key_event(char)) }
        chat.on_event(TUI.key_event("enter"))    # transcript: user echo
        draw(chat, session)

        leads = lead_cells(session)
        assert_includes leads, ["a", nil],
          "assistant text carries the terminal default fg (pi: userMessageText/text)"
        assert_includes leads, ["⎿", Theme[:tool_output]],
          "tool output is muted (pi: toolOutput)"
        assert_includes leads, ["❯", Theme[:user_message_text]],
          "the user echo carries the blue distinction (pi: userMessageBg)"
        # The input row sits inside the editor borders — its lead cell is
        # the border glyph; read the prompt glyph's cell directly.
        assert_nil session.cell_fg(1, input_row(session)),
          "the input line keeps the terminal default — visually apart from the colored echo"
      end
    end

    def test_pending_approval_stays_fully_visible_over_a_full_live_region
      with_chat(width: 40, screen_height: 14) do |chat, session|
        chat.on_agent_event({type: :agent_start})
        stream(chat, "word " * 40, start: false)
        decision = Thread.new { chat.approval(ToolCallDouble.new("bash")) }
        wait_until { chat.pending_approval }
        draw(chat, session)

        region = editor_area(session, chat)
        assert_includes region, "approve bash?"
        assert_includes region, "y = yes, n = no", "the full approval prompt stays in the editor area"

        chat.on_event(TUI.key_event("y"))
        assert decision.value == true, "the prompt remains answerable"
      end
    end

    def test_chat_runs_inside_the_seam_lifecycle_and_restores
      TUI.run(headless: true, viewport: :fullscreen, width: 40, screen_height: 12) do |session|
        chat = Render::Chat.new(session:, kernel: IdleKernel.new)
        stream(chat, "hi")
        draw(chat, session)
        assert_includes live_region(session, chat), "hi"
      end
      refute TUI::Session.active?, "terminal restored after the chat surface exits"
    end

    # --- the fullscreen composition (AC1): transcript above, bordered
    # editor (status in its top border), footer at the bottom. ---

    def test_fullscreen_composition_draws_transcript_editor_and_footer
      with_chat(width: 40, screen_height: 12, footer_data: {cwd: Dir.home, model: "test-model", context_window: 1000, auto_compact: true}, branch_reader: ->(_cwd) { "main" }) do |chat, session|
        send_message(chat, "hello")
        finish_message(chat, "answer")
        draw(chat, session)

        buffer = session.buffer_content
        assert_includes buffer[0, transcript_height(session, chat)].join, "❯ hello", "transcript on top"
        assert_includes buffer[transcript_height(session, chat), 3].join, "┌", "a bordered editor area below it"
        assert_equal "└", buffer[transcript_height(session, chat) + 2][0], "the editor's bottom border"
        footer = buffer[-2, 2].join
        assert_includes footer, "~ (main)", "the footer carries the ~-contracted cwd and branch"
        assert_includes footer, "?/1.0k (auto)", "the footer carries context usage vs the resolved window"
        assert_includes footer, "test-model", "the footer carries the model id"
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
        assert_includes buffer[0, transcript_height(session, chat)].join, "❯ hello",
          "the transcript survives the resize"
        assert_includes buffer[transcript_height(session, chat), 3].join, "┌",
          "the editor area recomposes at the new geometry"
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
      assert_equal ["❯ hi"], chat.transcript_lines,
        "the submitted prompt is echoed into the transcript"
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
        wait_until { chat.transcript_lines.join.include?("interrupted") }
        kernel.stop!
      end
      kernel.run
      scenario.join

      assert kernel.interrupted?
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
      skills = Skills.load(cwd: @dir, root: @dir).skills
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
    def drain_runs(chat)
      kernel_runs(chat).slice!(0..).each(&:call)
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
        assert_equal :yellow, heading[3], "the markdown heading renders yellow (mdHeading)"
        assert_equal %i[bold underlined], heading[4], "h1 is bold+underlined (markdown.ts:481-483)"
        bold = cells.find { |cell| cell[2] == "b" }
        assert_equal [:bold], bold[4], "strong renders the bold modifier (markdown.ts:683-687)"
        plain = cells.find { |cell| cell[2] == "p" }
        assert_equal [nil, []], plain[3, 2], "plain prose keeps the terminal default"
        assert_equal 3, chat.transcript_lines.size,
          "the heading, its spacing row, and the paragraph occupy three transcript rows"
      end
    end

    def test_live_region_streams_markdown_source_verbatim
      with_chat do |chat, session|
        stream(chat, "**bo")
        draw(chat, session)
        assert_includes live_region(session, chat), "**bo",
          "the live region carries the raw markdown source while streaming"
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

      assert_equal ["❯ hi", "Title", "", "plain body"], chat.transcript_lines,
        "the assistant reply renders as markdown rows in the transcript (with the spacing row between blocks)"
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

    # --- footer formatting (AC4, pi footer.ts) ---

    def test_format_tokens_compacts_counts_like_pi
      assert_equal "999", Render::Chat.format_tokens(999)
      assert_equal "1.0k", Render::Chat.format_tokens(1000)
      assert_equal "12k", Render::Chat.format_tokens(12_345)
      assert_equal "1.2M", Render::Chat.format_tokens(1_234_567)
      assert_equal "12M", Render::Chat.format_tokens(12_345_678)
      assert_equal "1235M", Render::Chat.format_tokens(1_234_567_890)
    end

    def test_format_cwd_contracts_the_home_prefix
      home = Dir.home
      assert_equal "~", Render::Chat.format_cwd(home, home)
      assert_equal "~/sub/dir", Render::Chat.format_cwd(File.join(home, "sub", "dir"), home)
      assert_equal "/elsewhere", Render::Chat.format_cwd("/elsewhere", home), "outside home renders absolute"
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
        assert_includes footer_text(session), "?/1.0k", "no usage yet: the context segment is '?'"

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
        chat = Render::Chat.new(session:, kernel: chat_idle_kernel)
        "hi".each_char { |char| chat.on_event(TUI.key_event(char)) }
        chat.on_event(TUI.paste_event(" there"))
        chat.on_event(TUI.key_event("backspace"))
        assert_equal "hi ther", chat.input, "backspace removes the last character"
        chat.on_event(TUI.key_event("e", modifiers: ["ctrl"]))
        assert_equal "hi ther", chat.input, "ctrl+e moves to line end without editing"
        chat.on_event(TUI.key_event("enter"))
        assert_equal "", chat.input, "enter submits and clears the input line"
        draw(chat, session) # the frame's flush moves the echo into the buffer
        assert_equal ["❯ hi ther"], chat.transcript_lines,
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
        assert_equal [" ", [:reversed]], cursor_cell(session, 5, row),
          "end-of-input cursor: highlighted trailing space after 'hi'"
        assert session.cell_modifiers(4, row).empty?, "the grapheme left of the cursor is unhighlighted"
      end
    end

    def test_cursor_reads_back_mid_input_and_tracks_left_right
      with_chat(width: 40) do |chat, session|
        "hi".each_char { |char| chat.on_event(TUI.key_event(char)) }
        chat.on_event(TUI.key_event("left"))
        draw(chat, session)
        row = input_row(session)
        assert_equal ["i", [:reversed]], cursor_cell(session, 4, row),
          "after cursor-left the insertion point sits on the 'i'"
        assert session.cell_modifiers(5, row).empty?, "the trailing space is no longer highlighted"

        chat.on_event(TUI.key_event("right"))
        draw(chat, session)
        assert_equal [" ", [:reversed]], cursor_cell(session, 5, row),
          "cursor-right returns the insertion point to end-of-input"
      end
    end

    def test_cursor_hides_while_an_approval_prompt_holds_the_input_row
      with_chat(width: 40, screen_height: 14) do |chat, session|
        "hi".each_char { |char| chat.on_event(TUI.key_event(char)) }
        thread = Thread.new { chat.approval(ToolCallDouble.new("bash")) }
        wait_until { chat.pending_approval }
        draw(chat, session)
        refute editor_area(session, chat).include?("❯"), "input row displaced by the approval prompt"
        assert_includes editor_area(session, chat), "approve bash?", "the prompt holds the editor area"
        chat.on_event(TUI.key_event("n"))
        assert_equal false, thread.value
      end
    end

    # --- mid-line editing (I06/AC2) ---

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

    # --- history (I06/AC3): pi's editor.ts addToHistory/navigateHistory —
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
      TUI.run(headless: true, viewport: :fullscreen, width: 40, screen_height: 12) do |session|
        chat = Render::Chat.new(session:, kernel: chat_idle_kernel)
        send_message(chat, "A")
        send_message(chat, "B")
        chat.on_event(TUI.key_event("up"))
        chat.on_event(TUI.key_event("up")) # "A", cursor at line start (pi: cursorPlacement start)
        chat.on_event(TUI.key_event("!"))
        assert_equal "!A", chat.input, "a recalled entry is editable at the cursor"
        chat.on_event(TUI.key_event("enter"))
        draw(chat, session) # the frame's flush moves the echo into the buffer
        assert_equal ["❯ A", "❯ B", "❯ !A"], chat.transcript_lines,
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

    # --- word-wise operations (I06/AC3): pi's word-navigation.ts boundary
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

    # --- autocomplete (AC1, I12): the /-triggered fuzzy suggestion list,
    # with pi's key precedence (the list owns up/down/escape/enter while
    # active — history and interrupt yield). ---

    def test_fuzzy_match_scores_like_pi
      assert_equal 0, Render::Chat.fuzzy_match("", "new"), "an empty query matches everything"
      assert Render::Chat.fuzzy_match("ar", "architect"), "a subsequence matches"
      assert_nil Render::Chat.fuzzy_match("zx", "architect"), "no subsequence = no match"
      assert Render::Chat.fuzzy_match("new", "new") <= -100, "an exact match scores best (pi's -100 bonus)"
      assert Render::Chat.fuzzy_match("ab12", "12abc"), "the swapped alnum query retries (+5)"
    end

    def test_fuzzy_filter_ranks_word_boundary_matches_first
      items = %w[skills compact].map { |value| {value:} }
      ranked = Render::Chat.fuzzy_filter(items, "c") { |item| item[:value] }
      assert_equal "compact", ranked.first[:value], "a word-boundary match outranks a mid-word one"
    end

    def test_slash_source_lists_builtin_commands_and_skills
      skill = Skills::Skill.new(name: "greet", description: "Says hi", file_path: "/tmp/x",
        base_dir: "/tmp", disable_model_invocation: false)
      source = Render::Chat::SlashSource.new(commands: {"new" => {description: "Start a new session"}}, skills: [skill])
      assert_equal [
        {value: "new", label: "new", description: "Start a new session"},
        {value: "skill:greet", label: "skill:greet", description: "Says hi"}
      ], source.items
    end

    def test_typing_slash_opens_the_fuzzy_list_below_the_input
      with_headless_chat(autocomplete: slash_source("new", "compact", "architect"), width: 50) do |chat, session|
        chat.on_event(TUI.key_event("/"))
        draw(chat, session)
        input_y, rows = editor_rows(session)
        assert_includes session.buffer_content[input_y - 1], "┌", "the list renders inside the bordered editor area"
        assert_equal 3, chat.suggestions.size
        assert_match(/\A→ new\s+new description\z/, rows[0], "the selection marker on the first item")
        assert_match(/\A  compact\s+compact description\z/, rows[1], "descriptions render beside the labels")
        assert_equal :light_magenta, session.cell_fg(1, input_y + 1), "the selected row is accent (pi theme.ts:1063-1064)"
        assert_equal :gray, session.cell_fg(15, input_y + 2), "the description column is muted (pi theme.ts:1065)"
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
        assert_equal [:reversed], session.cell_modifiers(14, input_y), "the cursor lands after the applied value"
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
        assert_equal ["❯ /architect"], transcript_lines(session, chat),
          "enter applies AND submits (pi editor.ts:790-816 — a /-prefix completion falls through to submit, trimmed)"
      end
    end

    def test_escape_cancels_the_list_without_interrupting_the_run
      with_headless_chat(autocomplete: slash_source("architect")) do |chat|
        chat.on_agent_event({type: :agent_start})
        "/ar".each_char { |char| chat.on_event(TUI.key_event(char)) }
        chat.on_event(TUI.key_event("escape"))
        assert_nil chat.suggestions, "escape cancels the list"
        assert_equal "/ar", chat.input, "the input is untouched"
        assert chat.busy?, "the run is NOT interrupted (pi custom-editor.ts:103-111)"
      end
    end

    def test_escape_with_no_list_leaves_the_run_alone_and_is_a_noop
      with_headless_chat do |chat|
        chat.on_event(TUI.key_event("escape"))
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
        assert_equal "line19", transcript_view(session, chat).last, "following: the tail is visible"

        chat.on_event(TUI.key_event("page_up"))
        draw(chat, session)
        visible = transcript_view(session, chat)
        refute_includes visible, "line19", "a page up detaches from the end"
        assert_equal "line12", visible.last, "one page = the transcript viewport rows (7 here)"

        chat.on_event(TUI.key_event("page_down"))
        draw(chat, session)
        assert_equal "line19", transcript_view(session, chat).last,
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
        assert_equal "line12", transcript_view(session, chat).last,
          "the detached view stays put while output streams"

        chat.on_event(TUI.key_event("page_down"))
        draw(chat, session)
        refute_includes transcript_view(session, chat), "late", "a paged view pans one page, not to the end"
        chat.on_event(TUI.key_event("page_down"))
        draw(chat, session)
        assert_equal "late", transcript_view(session, chat).last,
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

    def test_scrollbar_renders_only_when_content_overflows
      with_chat(width: 20, screen_height: 12) do |chat, session|
        2.times { |i| finish_message(chat, "line#{i}") }
        draw(chat, session)
        assert_equal " ", session.cell_symbol(19, 0), "no gutter glyphs when the view fits (pi 'auto')"

        20.times { |i| finish_message(chat, "line#{i}") }
        draw(chat, session)
        assert_equal "┃", session.cell_symbol(19, 5), "the thumb pins to the track bottom while following"
        assert_equal :gray, session.cell_fg(19, 5), "the thumb routes through the theme (muted analog)"
        assert_equal "│", session.cell_symbol(19, 0), "the track fills above the thumb"
        assert_equal :dark_gray, session.cell_fg(19, 0)

        chat.on_event(TUI.key_event("page_up"))
        draw(chat, session)
        assert_equal "┃", session.cell_symbol(19, 3), "the thumb moves with the scroll offset"
        assert_equal "│", session.cell_symbol(19, 5)
      end
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
        session.push_event(TUI.key_event("escape"))
        wait_until { chat.suggestions.nil? }
        wait_until { chat.transcript_lines.join.include?("answer") }
        kernel.stop!
      end
      kernel.run
      scenario.join

      assert_includes chat.transcript_lines.join, "answer",
        "the turn completed — escape with an active list never interrupts the run"
    end

    private

    # A chat surface on the headless fullscreen test terminal for key-surface
    # tests (draw/readback assertions use with_chat; these only need the
    # editor's key path, which never draws).
    def with_headless_chat(autocomplete: nil, width: 40)
      TUI.run(headless: true, viewport: :fullscreen, width:, screen_height: 12) do |session|
        yield Render::Chat.new(session:, kernel: IdleKernel.new, autocomplete:), session
      end
    end

    # Render-only tests: the real headless fullscreen test terminal (buffer
    # readback). Width 9 makes wrapping observable ("aaaa bbbb" is exactly 9
    # cells).
    def with_chat(width: 9, screen_height: 12, footer_data: nil, branch_reader: nil)
      TUI.run(headless: true, viewport: :fullscreen, width:, screen_height:) do |session|
        chat = Render::Chat.new(session:, kernel: IdleKernel.new,
          footer_data:, branch_reader: branch_reader || ->(_cwd) { nil })
        yield chat, session
      end
    end

    # Kernel-driven tests: ScriptedSession feeds the real poller/frame loop.
    def chat_with_server(tools: {}, autocomplete: nil)
      session = ScriptedSession.new(width: 80, height: 24)
      kernel = Core::Loop.new(session:)
      chat = Render::Chat.new(session:, kernel:, branch_reader: nil, autocomplete:)
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

    def assistant_done(chat, tokens)
      chat.on_agent_event({type: :message_end, message: MessageDouble.new(:assistant, "done", tokens)})
    end

    def tool_start(chat, name)
      chat.on_agent_event({type: :tool_execution_start, tool_call: ToolCallDouble.new(name)})
    end

    def tool_end(chat, name, result)
      chat.on_agent_event({type: :tool_execution_end, tool_call: ToolCallDouble.new(name), result:})
    end

    # Types +text+ into the input line and presses Enter (direct key events
    # — the render-level editor path, no kernel).
    def send_message(chat, text)
      text.chars.each { |char| chat.on_event(TUI.key_event(char)) }
      chat.on_event(TUI.key_event("enter"))
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
    # mirrored from Render::Chat::FOOTER_ROWS/MIN_EDITOR_ROWS): transcript
    # rows on top, then the 3-row editor block (5 with an approval pending —
    # three prompt rows inside the borders), then the 2-row footer.
    def transcript_height(session, chat)
      session.buffer_content.size - 5 - (chat.pending_approval ? 2 : 0)
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

    # One editor-block inner row (the side borders shaved).
    def inner_row(session, y)
      row = session.buffer_content[y]
      row.length >= 2 ? row[1..-2] : row
    end

    # The editor block's input row and the suggestion-list rows below it:
    # from the "❯" row down to (excluding) the block's bottom border.
    def editor_rows(session)
      h = session.buffer_content.size
      input = h.times.find { |y| session.buffer_content[y].include?("❯") }
      bottom = h.times.find { |y| session.buffer_content[y].include?("└") }
      [input, ((input + 1)...bottom).map { |y| inner_row(session, y).rstrip }]
    end

    # The buffer's transcript rows, stripped and non-empty.
    def transcript_lines(session, chat)
      session.buffer_content[0, transcript_height(session, chat)].map(&:strip).reject(&:empty?)
    end

    # The editor area rows (block borders + inner content).
    def editor_area(session, chat)
      h = session.buffer_content.size
      session.buffer_content[(h - 5 - (chat.pending_approval ? 2 : 0))..(h - 3)].join
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

    # The input line's row: the editor block's single inner row (3-row
    # block: borders at h-5 and h-3).
    def input_row(session)
      session.buffer_content.size - 4
    end

    def cursor_cell(session, x, row)
      [session.cell_symbol(x, row), session.cell_modifiers(x, row)]
    end

    # A SlashSource over bare builtin names (description = "<name>
    # description") — the synthetic catalog for the editor's key paths.
    def slash_source(*names)
      Render::Chat::SlashSource.new(
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

    ChunkDouble = Struct.new(:content)
    MessageDouble = Struct.new(:role, :content, :tokens)
    ToolCallDouble = Struct.new(:name) do
      def arguments = {}
    end
    TokensDouble = Struct.new(:input, :output, :cache_read, :cache_write)

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
