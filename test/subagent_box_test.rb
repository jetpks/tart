# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"
require "json"
require "stringio"

module Tart
  # The I79 subagent status box pins (the `subagent-box-units` gate, AC1-AC3):
  # the row law per state against the FROZEN oracle fixture bytes
  # (gems/tui-split-rig/fixtures/subagent-box/ — the spec session's tmux
  # captures of the pinned pi 1.1.0 + pi-subagents 0.79.1, plain AND the
  # styled SGR runs), form selection + the +N more overflow, the retention
  # and absent-box laws, the cadence laws (1s glyph tick / ≤5s sweep / no
  # new thread), the additive model/context status fields with the
  # nil/legacy tolerance, the attention mapping from a staged supervisor
  # ask, the display-layer state map (pi's childState law), the render-key
  # cache, and the Manager's box snapshot seam. Hermetic: staged homes,
  # staged disk states, the MockLLMServer for the owned-run leg.
  class SubagentBoxTest < Test
    FIXTURES = File.expand_path("../gems/tui-split-rig/fixtures/subagent-box", __dir__)

    # The staged epoch (the oracle captures' BOOT_T analog): every staged
    # fact anchors here so the rendered elapsed deltas are fixed.
    BOOT = 1_700_000_000_000

    # The frozen normalization classes (tmp/i79-spec/oracle/extract.rb,
    # verbatim): the ten spinner frames + the static glyph, every
    # elapsed/age token (incl. the word "now"), the output row's path.
    SPIN = /[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏●]/

    def setup
      @home = Dir.mktmpdir("i79-box-home-")
      @cwd = Dir.mktmpdir("i79-box-cwd-")
      @hooks = Hooks.new
      @managers = []
      @pids = []
      @home_home = ENV["HOME"]
      Subagents.current_manager = nil
    end

    def teardown
      Subagents.current_manager = nil
      @managers.each(&:shutdown)
      FileUtils.rm_rf(@home)
      FileUtils.rm_rf(@cwd)
    end

    # --- Law 1: the frozen oracle bytes (plain) ---

    def test_box_renders_the_frozen_multi_running_bytes
      assert_box_fixture("01-running-two", two_running_rows)
    end

    def test_box_renders_the_frozen_attention_bytes
      rows = two_running_rows
      rows[0][:attention] = true
      assert_box_fixture("02-attention", rows)
    end

    def test_box_renders_the_frozen_completed_with_output_bytes
      # worker flipped terminal at BOOT+29.4s (the capture's derive), the
      # 10s retention keeps it visible beside the still-running reviewer.
      rows = [terminal_row("r1", "worker", "completed"), running_row("r2", "reviewer")]
      assert_box_fixture("03-completed-with-output", rows)
    end

    def test_box_renders_the_frozen_single_running_bytes
      assert_box_fixture("04-running-one", [running_row("r2", "reviewer")])
    end

    def test_box_renders_the_frozen_single_failed_bytes
      assert_box_fixture("05-failed", [terminal_row("r2", "reviewer", "failed",
                                                     error: "staged failure: the wire died")])
    end

    def test_box_renders_the_frozen_single_stopped_bytes
      # The escalation arm: the run stopped (■), the failed child renders
      # the step state (pi's childState law) + the error row.
      assert_box_fixture("11-single-stopped", [terminal_row("r1", "worker", "stopped",
                                                            error: "staged stop: the ladder fired")])
    end

    def test_box_renders_the_frozen_single_completed_bytes
      assert_box_fixture("08-single-completed", [terminal_row("r1", "worker", "completed")])
    end

    def test_box_is_absent_without_visible_runs
      assert_equal [], Render::SubagentBox.render(rows: [], now: BOOT, frame: 0, width: 120, main_level: "off")
    end

    # --- Law 1: the frozen styled SGR runs ---

    def test_box_renders_the_frozen_styled_runs_for_every_state
      # The styled law at the parsed-run level (the tmux capture-pane -e
      # model: attribute state carries across newlines, resets land at
      # default-attr cell boundaries — the raw byte placement of the reset
      # is the terminal's scan artifact, the cell attributes are the app's
      # law). Each state's runs must equal the frozen fixture's.
      {
        "01-running-two" => two_running_rows,
        "02-attention" => two_running_rows.tap { |rows| rows[0][:attention] = true },
        "03-completed-with-output" => [terminal_row("r1", "worker", "completed"), running_row("r2", "reviewer")],
        "04-running-one" => [running_row("r2", "reviewer")],
        "05-failed" => [terminal_row("r2", "reviewer", "failed", error: "staged failure: the wire died")],
        "08-single-completed" => [terminal_row("r1", "worker", "completed")],
        "11-single-stopped" => [terminal_row("r1", "worker", "stopped", error: "staged stop: the ladder fired")]
      }.each do |state, rows|
        got = parse_styled(serialize_styled(Render::SubagentBox.render(
          rows: rows, now: BOOT + 31_000, frame: 3, width: 120, main_level: "off")))
        want = parse_styled(File.readlines(File.join(FIXTURES, "#{state}-styled-norm.txt"), chomp: true))
        assert_equal want, got, "#{state}: the styled runs moved"
      end
    end

    def test_box_theme_tokens_carry_the_frozen_truecolor_codes
      # The Grounds' styled law: dim #7e888e = 126;136;142, accent
      # #a798d7 = 167;152;215, success (dark.json's green var, the port's
      # md_code_block token) #68b78d = 104;183;141, error #ea7f81 =
      # 234;127;129, warning #cd9a22 = 205;154;34, toolTitle #dee0e1 =
      # 222;224;225, thinking_off #6c767b = 108;118;123.
      sgr = ->(token) do
        hex = Theme::TOKENS.fetch(token)
        hex.delete_prefix("#").scan(/../).map { |pair| pair.to_i(16) }.join(";")
      end
      assert_equal "126;136;142", sgr.call(:dim)
      assert_equal "167;152;215", sgr.call(:accent)
      assert_equal "104;183;141", sgr.call(:md_code_block)
      assert_equal "234;127;129", sgr.call(:error)
      assert_equal "205;154;34", sgr.call(:warning)
      assert_equal "222;224;225", sgr.call(:toolTitle)
      assert_equal "108;118;123", sgr.call(:thinking_off)
    end

    # --- form selection + the overflow law ---

    def test_multi_form_with_running_first_and_terminal_last_within_class
      rows = [terminal_row("r1", "worker", "completed"), running_row("r2", "reviewer")]
      text = box_text(rows).join("\n")
      assert_includes text, "Async agents · background"
      reviewer_i = text.index("reviewer")
      worker_i = text.index("worker")
      assert reviewer_i < worker_i, "running renders before the finished tail"
      assert_includes text, "├─", "the non-last branch is ├─"
      assert_includes text, "└─", "the last branch is └─"
      assert_includes text, "✓", "the terminal row carries the ✓ glyph"
    end

    def test_overflow_beyond_four_runs_collapses_to_the_plus_n_more_row
      rows = 4.times.map { |i| running_row("r#{i}", "agent#{i}") }
      rows += 2.times.map { |i| terminal_row("t#{i}", "done#{i}", "completed") }
      text = box_text(rows)
      assert_equal 4, text.count { |line| line.match?(/├─|└─/) && !line.include?("more") },
                   "exactly MAX_WIDGET_JOBS item rows render"
      overflow = text.find { |line| line.include?("more") }
      assert overflow, "the overflow row renders"
      assert_includes overflow, "+2 more (2 finished)"
      assert text.index(overflow) > text.index { |line| line.include?("agent3") },
             "the overflow item renders after the visible tail"
    end

    def test_single_form_with_one_visible_run
      text = box_text([running_row("r2", "reviewer")]).join("\n")
      assert_includes text, "async subagent · background"
      refute_includes text, "Async agents", "one run never renders the multi header"
    end

    # --- Law 2: retention + the absent box ---

    def test_terminal_rows_drop_after_the_ten_second_retention_window
      row = terminal_row("r1", "worker", "completed")
      now = row[:ended_at]
      assert_equal 1, Render::SubagentBox.visible([row], now + 9_999).size
      assert_equal [], Render::SubagentBox.visible([row], now + 10_001), "the row drops at the 10s boundary"
      assert_equal [], Render::SubagentBox.render(rows: [row], now: now + 10_001, frame: 0, width: 120,
                                                  main_level: "off"), "the box disappears with the last row"
    end

    def test_the_absent_path_allocates_nothing
      # the renderer's empty contract…
      assert_equal [], Render::SubagentBox.render(rows: [], now: BOOT, frame: 0, width: 120, main_level: "off")
      # …and the chat's absent path: no Manager → the SAME shared frozen
      # rows and widget object every frame — identity is the zero-
      # allocation guarantee (no per-frame rows/lines/spans/widgets).
      with_chat_surface do |chat, session, _kernel|
        draw(chat, session)
        seen = 3.times.map { chat.send(:subagent_box_rows) }
        assert_same Render::Chat::NO_BOX_ROWS, seen[0], "the frozen rows are shared"
        assert seen[0].equal?(seen[1]) && seen[1].equal?(seen[2]), "every absent frame reuses the frozen rows"
        assert Render::Chat::NO_BOX_ROWS.frozen?
      end
    end

    def test_box_persists_across_frames_through_the_render_key_cache
      with_box_chat do |chat, _session, _kernel|
        first = chat.send(:subagent_box_rows)
        assert first.any?, "the staged run renders"
        second = chat.send(:subagent_box_rows)
        assert_same first, second, "no rebuild without an observable change"
      end
    end

    def test_render_key_rebuilds_on_observable_change_only
      rows = [running_row("r1", "worker")]
      key = Render::SubagentBox.render_key(rows, BOOT)
      assert_equal key, Render::SubagentBox.render_key(dup_rows(rows), BOOT), "equal facts → equal key"
      refute_equal key, Render::SubagentBox.render_key(dup_rows(rows), BOOT + 1500),
                   "the 1s glyph frame bucket rides the key while a row runs"
      assert_equal Render::SubagentBox.render_key(rows, BOOT + 500),
                   Render::SubagentBox.render_key(dup_rows(rows), BOOT + 900),
                   "sub-second clock drift never rebuilds"
      terminal = [terminal_row("r1", "worker", "completed")]
      tkey = Render::SubagentBox.render_key(terminal, BOOT)
      assert_nil tkey[1], "no glyph bucket without a running row"
      refute_equal tkey, Render::SubagentBox.render_key(terminal, BOOT + 40_000), "retention expiry rebuilds"
      attention = dup_rows(rows)
      attention[0][:attention] = true
      refute_equal Render::SubagentBox.stable_key(rows), Render::SubagentBox.stable_key(attention),
                   "the attention fact is observable"
      assert_equal Render::SubagentBox.stable_key(rows), Render::SubagentBox.stable_key(rows.reverse),
                   "the fact key is order-independent"
    end

    def test_box_widget_renders_between_pending_and_editor_and_survives_pick_panes
      with_box_chat do |chat, session, _kernel|
        draw(chat, session)
        content = session.buffer_content
        box_i = content.index { |row| row.include?("async subagent · background") }
        assert box_i, "the box renders on the frame"
        editor_i = content.index { |row| row.match?("─{3,}") }
        assert editor_i, "the editor border renders"
        assert editor_i > box_i, "the box sits above the editor"
        # mounted-picker frame: the box's rows must not drop or duplicate
        chat.instance_variable_set(:@picker, PickerDouble.new)
        draw(chat, session)
        content2 = session.buffer_content
        assert_equal 1, content2.count { |row| row.include?("async subagent · background") },
                     "the box neither drops nor duplicates under a mounted picker"
      end
    end

    # --- Law 2: the cadences ---

    def test_box_ticks_arm_at_the_frozen_cadences_and_cancel_with_the_last_row
      with_box_chat do |chat, session, kernel|
        draw(chat, session)
        assert_includes kernel.ticks, 1.0, "the 1s glyph tick arms while a visible row runs"
        assert kernel.submitted.any?, "the ≤5s sweep task arms with the Manager present"
        # the glyph tick cancels with the last running row (I58 — the armed
        # state paints frame 0 itself; the tick only paces the paints)
        handle = kernel.tick_handles.first
        chat.instance_variable_set(:@box_running, false)
        chat.send(:arm_box_ticks)
        assert handle.stopped, "the glyph tick cancels when no visible row runs"
        # no NEW thread anywhere in the box's files (the threads-budget
        # law): the Manager's two Thread.new sites (the watcher + the
        # deadline supervisor) are the frozen I48/I78 baseline.
        assert_equal 2, File.read(File.expand_path("../lib/tart/subagents/manager.rb", __dir__)).scan("Thread.new").size
        ["lib/tart/render/subagent_box.rb", "lib/tart/subagents.rb"].each do |rel|
          refute File.read(File.expand_path("../#{rel}", __dir__)).include?("Thread.new"),
                 "#{rel} adds no thread"
        end
      end
    end

    def test_box_ticks_never_arm_without_a_manager
      with_chat_surface do |chat, session, kernel|
        draw(chat, session)
        assert_empty kernel.ticks, "no box, no tick"
        assert_empty kernel.submitted, "no box, no sweep task"
      end
    end

    def test_terminal_flip_requests_one_draw_through_the_kernel_bridge
      manager = new_manager
      bridge = Subagents::KernelBridge.new(->(block) { (@pushed ||= []) << block })
      manager.supervisor_channel = nil
      manager.instance_variable_set(:@kernel, bridge)
      dir = File.join(manager.home, "01adopted-0000")
      FileUtils.mkdir_p(dir)
      write_status(dir, "running", pid: live_pid, model: "mock/mock-1", context: "fresh")
      manager.status(id: nil) # the sweep adopts
      result = {"output" => "done", "success" => true, "timedOut" => false}
      File.write(File.join(dir, "result.json"), JSON.generate(result))
      manager.box_sweep # the reaper's result-derive leg flips the run
      row = manager.box_snapshot[:rows].find { |r| r[:id] == "01adopted-0000" }
      assert_equal "completed", row[:state], "the reaper derived the terminal state"
      assert (@pushed ||= []).any?, "the flip requested a draw through the bridge"
    end

    # --- Law 3: the data seams ---

    def test_base_status_gains_exactly_the_additive_model_and_context_fields
      manager = new_manager
      run = manager.spawn_run(agent: "worker", task: "additive facts", async: false)
      status = JSON.parse(File.read(File.join(run[:dir], "status.json")))
      assert_equal "mock/mock-1", status["model"], "the inherited pair records as provider/id"
      assert_equal "fresh", status["context"]
      # every existing key byte-unchanged
      %w[id agent task taskChars mode state pid cwd asyncDir sessionRoot startedAt lastUpdate
         toolCallId].each do |key|
        assert status.key?(key), "existing key #{key} survives"
      end
      assert_equal nil, status["task"], "the task text is NEVER recorded"
    end

    def test_fork_spawn_records_the_fork_context
      manager = new_manager
      parent = File.join(@home, "parent-session.jsonl")
      File.write(parent, "{}\n")
      run = manager.spawn_run(agent: "oracle", task: "fork facts", async: false, parent_session: parent)
      status = JSON.parse(File.read(File.join(run[:dir], "status.json")))
      assert_equal "fork", status["context"], "the fork badge law (resumes the parent session)"
    end

    def test_legacy_dirs_without_the_fields_render_no_badge_and_never_raise
      manager = new_manager
      dir = File.join(manager.home, "02legacy-0000")
      FileUtils.mkdir_p(dir)
      write_status(dir, "running", pid: live_pid, legacy: true)
      manager.status(id: nil)
      rows = manager.box_snapshot[:rows]
      row = rows.find { |r| r[:id] == "02legacy-0000" }
      assert row, "the legacy dir adopts"
      assert_nil row[:model]
      assert_nil row[:context]
      lines = Render::SubagentBox.render(rows: [row], now: row[:started_at] + 31_000, frame: 0,
                                         width: 120, main_level: "off")
      text = lines.map { |l| l.spans.map(&:content).join }
      assert text.any? { |l| l.include?("worker") }, "the legacy row renders"
      refute text.any? { |l| l.include?("[fresh]") || l.include?("[fork]") || l.include?("(mock") },
             "no badge and no model segment without the fields"
    end

    def test_attention_maps_from_a_staged_supervisor_ask_file
      manager = new_manager(with_channel: true)
      dir = File.join(manager.home, "03attention-000")
      FileUtils.mkdir_p(File.join(dir, "control", "supervisor-requests"))
      write_status(dir, "running", pid: live_pid, model: "mock/mock-1", context: "fresh")
      manager.status(id: nil) # the sweep adopts the staged dir
      File.write(File.join(dir, "control", "supervisor-requests", "ask-1.json"),
                 JSON.generate({"type" => "subagent.supervisor.request", "id" => "ask-1",
                                "runId" => "03attention-000", "agent" => "worker",
                                "reason" => "need_decision", "message" => "which way?",
                                "expectsReply" => true,
                                "createdAt" => (Time.now.to_f * 1000).to_i}))
      channel = manager.supervisor_channel
      wait_until { channel.pending.any? } # the 250ms poll's scan
      row = manager.box_snapshot[:rows].find { |r| r[:id] == "03attention-000" }
      assert row[:attention], "a pending ask names the run id"
      lines = Render::SubagentBox.render(rows: [row], now: row[:last_update], frame: 0,
                                         width: 120, main_level: "off")
      assert lines.map { |l| l.spans.map(&:content).join }.any? { |l| l.include?("no activity for") },
             "the attention label renders"
      channel.stop
    end

    def test_box_snapshot_is_a_thread_safe_bounded_copy
      manager = new_manager
      run = manager.spawn_run(agent: "worker", task: "snapshot copy", async: false)
      rows = manager.box_snapshot[:rows]
      row = rows.find { |r| r[:id] == run[:id] }
      row[:agent] = "mutated"
      assert_equal "worker", manager.runs.first[:agent], "the rows are copies, not the records"
      assert row.key?(:agent) && row.key?(:id) && row.key?(:state), "bounded shape"
      assert_nil row[:task], "no task text ever rides the snapshot (the redaction law)"
    end

    def test_display_layer_state_map_keeps_the_disk_vocabulary
      # The box renders pi's words; the disk schema stays the frozen I48
      # vocabulary — settle writes "completed", never "complete".
      manager = new_manager
      run = manager.spawn_run(agent: "worker", task: "map check", async: false)
      disk = JSON.parse(File.read(File.join(run[:dir], "status.json")))
      assert_includes %w[completed failed stopped], disk["state"],
                      "the disk vocabulary stays the frozen I48 schema"
      refute disk.values.include?("complete"), "the display word never lands on disk"
      rows = [{id: "x", agent: "w", state: "completed", started_at: BOOT, ended_at: BOOT + 29_400,
               last_update: BOOT + 29_400, model: "m/1", context: "fresh", dir: nil, error: nil, attention: false}]
      text = box_text(rows).join("\n")
      assert_includes text, "complete (m/1)", "completed renders complete"
      refute_includes text, "completed", "the disk word never leaks into the box"
      stopped = [{id: "y", agent: "w", state: "stopped", started_at: BOOT, ended_at: BOOT + 29_400,
                  last_update: BOOT + 29_400, model: "m/1", context: "fresh", dir: nil,
                  error: "stop", attention: false}]
      text = box_text(stopped).join("\n")
      assert_includes text, "■", "stopped renders the warning glyph"
      assert_includes text, "failed (m/1)", "the stopped run's failed child renders failed"
    end

    # --- Law 1 details ---

    def test_format_duration_is_pi_verbatim
      f = ->(ms) { Render::SubagentBox.format_duration(ms) }
      assert_equal "999ms", f.call(999)
      assert_equal "1.0s", f.call(1_000)
      assert_equal "30.0s", f.call(30_000)
      assert_equal "59.9s", f.call(59_900)
      assert_equal "1m0s", f.call(60_000)
      assert_equal "1m30s", f.call(90_000)
      assert_equal "2m1s", f.call(121_000)
    end

    def test_format_activity_label_is_pi_verbatim
      f = ->(last, state, now) { Render::SubagentBox.format_activity_label(last, state, now) }
      assert_equal "now", Render::SubagentBox.format_activity_age(999)
      assert_equal "30s", Render::SubagentBox.format_activity_age(30_000)
      assert_equal "2m", Render::SubagentBox.format_activity_age(120_000)
      assert_equal "active now", f.call(BOOT, nil, BOOT)
      assert_equal "active 30s ago", f.call(BOOT, nil, BOOT + 30_000)
      assert_equal "no activity for 15s", f.call(BOOT + 15_000, "needs_attention", BOOT + 30_000)
      assert_equal "needs attention", f.call(nil, "needs_attention", BOOT)
      assert_nil f.call(nil, nil, BOOT)
    end

    def test_shorten_path_contracts_the_home_prefix
      Dir.mktmpdir do |dir|
        ENV["HOME"] = dir
        assert_equal "~/x/runner.stdout.log", Render::SubagentBox.shorten_path(File.join(dir, "x/runner.stdout.log"))
        assert_equal "/elsewhere/log", Render::SubagentBox.shorten_path("/elsewhere/log")
      end
    ensure
      ENV["HOME"] = @home_home
    end

    # --- harness ---

    def dup_rows(rows)
      rows.map(&:dup)
    end

    def two_running_rows
      [running_row("r1", "worker"), running_row("r2", "reviewer")]
    end

    def running_row(id, agent)
      {id: id, agent: agent, state: "running", started_at: BOOT, last_update: BOOT + 30_000,
       ended_at: nil, model: "mock/mock-1", context: "fresh",
       dir: File.join(@home, id), error: nil, attention: false}
    end

    def terminal_row(id, agent, state, error: nil)
      {id: id, agent: agent, state: state, started_at: BOOT, last_update: BOOT + 29_400,
       ended_at: BOOT + 29_400, model: "mock/mock-1", context: "fresh", dir: File.join(@home, id),
       error: error, attention: false}
    end

    def assert_box_fixture(state, rows)
      lines = Render::SubagentBox.render(rows: rows, now: BOOT + 31_000, frame: 3, width: 120,
                                         main_level: "off")
      got = if lines.empty?
              "(box absent)\n"
            else
              lines.map { |line| line.spans.map(&:content).join }.map { |line| normalize.call(line) }
                   .join("\n") + "\n"
            end
      want = File.read(File.join(FIXTURES, "#{state}-norm.txt"))
      assert_equal want, got, "#{state}: the box bytes moved off the frozen oracle"
    end

    def normalize
      @normalize ||= lambda do |line|
        out = line.gsub(SPIN, "◖SPIN◗")
        out = out.gsub(/output: \S.*\z/, "output: ◖PATH◗")
        out = out.gsub(/(\d+)m(\d+)s\b/, "◖DUR◗")
        out = out.gsub(/(\d+(?:\.\d+)?)s\b/, "◖DUR◗")
        out = out.gsub(/(\d+)ms\b/, "◖DUR◗")
        out = out.gsub(/\bnow\b/, "◖DUR◗")
        out
      end
    end

    def box_text(rows)
      Render::SubagentBox.render(rows: rows, now: BOOT + 31_000, frame: 3, width: 120,
                                 main_level: "off").map { |line| line.spans.map(&:content).join }
    end

    # Serializes composed lines the way a terminal pane carries them (SGR
    # emitted only on state change), then parses both sides back to runs —
    # the styled comparison's instrument.
    def serialize_styled(lines)
      fg = nil
      bold = false
      lines.map do |line|
        s = +""
        line.spans.each do |span|
          want_fg = nil
          want_bold = false
          style = span.style
          if style
            want_bold = style.modifiers.to_a.include?(:bold)
            f = style.fg
            if f.is_a?(String) && f.start_with?("#")
              r, g, b = f.delete_prefix("#").scan(/../).map { |pair| pair.to_i(16) }
              want_fg = "38;2;#{r};#{g};#{b}"
            end
          end
          if want_fg != fg || want_bold != bold
            codes = []
            codes << "0" if !want_bold && (bold || want_fg.nil?)
            codes << "1" if want_bold
            codes << want_fg if want_fg
            codes << "39" if !want_bold && want_fg.nil? && bold
            s << "\e[#{codes.join(';')}m"
            fg = want_fg
            bold = want_bold
          end
          s << span.content
        end
        s
      end
    end

    # The stateful SGR parser (tmux capture-pane -e's model): attribute
    # state carries across newlines; 0/empty reset everything, 39 resets
    # fg, 1 bolds, 38;2;r;g;b sets fg. Runs are [text, {fg:, bold:}].
    def parse_styled(lines)
      fg = nil
      bold = false
      lines.map do |line|
        runs = []
        buf = +""
        pos = 0
        while (match = /\e\[([0-9;]*)m/.match(line, pos))
          buf << line[pos...match.begin(0)]
          runs << [normalize.call(buf), {fg: fg, bold: bold}] unless buf.empty?
          buf = +""
          codes = match[1].split(";", -1)
          i = 0
          while i < codes.size
            case codes[i]
            when "", "0"
              fg = nil
              bold = false
            when "39"
              fg = nil
            when "1"
              bold = true
            when "38"
              if codes[i + 1] == "2"
                fg = "38;2;#{codes[i + 2]};#{codes[i + 3]};#{codes[i + 4]}"
                i += 4
              end
            end
            i += 1
          end
          pos = match.end(0)
        end
        buf << line[pos..] if pos < line.length
        runs << [normalize.call(buf), {fg: fg, bold: bold}] unless buf.empty?
        runs
      end
    end

    # --- the Manager / chat harnesses ---

    def new_manager(with_channel: false)
      manager = Subagents::Manager.new(cwd: @cwd, home: File.join(@home, "subagents"),
                                       env: {"PATH" => ENV["PATH"], "HOME" => @home,
                                             "PI_API_KEY" => "k", "PI_API_BASE" => "http://127.0.0.1:9/v1",
                                             "PI_PROVIDER" => "mock", "PI_MODEL" => "mock-1"},
                                       identity: "pi", hooks: @hooks, arm_deadline_supervisor: false,
                                       root: @cwd)
      if with_channel
        channel = Subagents::SupervisorChannel.new(home: manager.home, hooks: @hooks)
        channel.start
        manager.supervisor_channel = channel
      end
      @managers << manager
      manager
    end

    def write_status(dir, state, pid:, model: nil, context: nil, legacy: false)
      payload = {"id" => File.basename(dir), "agent" => "worker", "task" => nil, "taskChars" => nil,
                 "mode" => "single", "state" => state, "pid" => pid, "cwd" => @cwd,
                 "asyncDir" => dir, "sessionRoot" => File.join(dir, "sessions"),
                 "startedAt" => BOOT, "lastUpdate" => BOOT + 30_000, "toolCallId" => nil}
      payload["model"] = model if model
      payload["context"] = context if context
      if legacy
        payload["startedAt"] = BOOT
        payload.delete("lastUpdate")
      end
      File.write(File.join(dir, "status.json"), JSON.generate(payload))
    end

    def live_pid
      pid = Process.spawn("sleep", "30")
      Process.detach(pid)
      @pids ||= []
      @pids << pid
      pid
    end

    # The chat surface with a Manager carrying one adopted staged run —
    # the box's chat-level laws (cache, ticks, composition).
    def with_box_chat
      manager = new_manager
      dir = File.join(manager.home, "04chat-00000")
      FileUtils.mkdir_p(dir)
      write_status(dir, "running", pid: live_pid, model: "mock/mock-1", context: "fresh")
      manager.status(id: nil)
      Subagents.current_manager = manager
      with_chat_surface do |chat, session, kernel|
        yield chat, session, kernel
      end
    end

    def with_chat_surface
      TUI.run(headless: true, viewport: :fullscreen, width: 60, screen_height: 16) do |session|
        kernel = IdleKernel.new
        chat = Render::Chat.new(session:, kernel:, motd: false,
                                branch_reader: ->(_cwd) { nil })
        yield chat, session, kernel
      end
    end

    def draw(chat, session)
      session.draw(chat.render_frame)
    end

    # The picker double (a mounted selector in the editor slot — the
    # editor_area_rows/widget contract).
    PickerDouble = Class.new do
      def widget_rows
        3
      end

      def widget(_width)
        TUI.paragraph(text: [TUI.line("PICKER")], wrap: false)
      end
    end

    # The tick-recording kernel double (chat_test's IdleKernel shape,
    # restated here so this file runs self-contained under -n).
    class IdleKernel
      attr_reader :ticks, :tick_handles, :submitted

      def initialize
        @ticks = []
        @tick_handles = []
        @submitted = []
      end

      def request_draw = nil

      def animate(duration:) = nil

      def tick(interval)
        @ticks << interval
        TickHandle.new.tap { |handle| @tick_handles << handle }
      end

      def async(&block)
        @submitted << block
        self
      end
    end

    class TickHandle
      def initialize
        @stopped = false
      end

      def stop
        @stopped = true
        nil
      end

      attr_reader :stopped
    end
  end
end