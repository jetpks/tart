# frozen_string_literal: true

require_relative "../../../test/test_helper"
require_relative "../lib/tui_split_rig"

module TuiSplitRig
  # Scenario loading: the shipped data files and the failure path.
  class ScenarioTest < Tart::Test
    RIG_ROOT = File.expand_path("#{__dir__}/..")

    def test_loads_the_shipped_s1_text_turn_scenario
      scenario = Scenario.load(File.join(RIG_ROOT, "scenarios/s1_text_turn.yml"))
      assert_equal "s1_text_turn", scenario.name
      assert_equal "hello", scenario.prompt
      assert_equal 1, scenario.expected_requests
      assert_equal [{type: :stream, content: "The mock reply is fixed and short for the spike."}], scenario.responses
    end

    def test_loads_the_shipped_s1_tart_scenario_with_the_identity_staged
      scenario = Scenario.load(File.join(RIG_ROOT, "scenarios/s1_tart.yml"))
      assert_equal "s1_tart", scenario.name
      assert_equal "tart", scenario.env.fetch("tart").fetch("TART_IDENTITY"),
        "tart-mode stages TART_IDENTITY=tart (I16 AC3)"
    end

    def test_env_is_optional_and_defaults_to_empty
      path = File.join(Dir.mktmpdir("tui-split-rig-scenario-"), "s.yml")
      File.write(path, "name: s\nprompt: p\nexpected_requests: 1\nresponses:\n  - type: stream\n    content: x\n")
      assert_empty Scenario.load(path).env
    end

    def test_unknown_env_app_is_a_rig_error
      path = File.join(Dir.mktmpdir("tui-split-rig-scenario-"), "s.yml")
      File.write(path, "name: s\nprompt: p\nexpected_requests: 1\nresponses:\n  - type: stream\n    content: x\nenv:\n  mockapp:\n    FOO: 1\n")
      error = assert_raises(Error) { Scenario.load(path) }
      assert_match(/unknown env app 'mockapp'/, error.message)
    end

    def test_non_mapping_env_is_a_rig_error
      path = File.join(Dir.mktmpdir("tui-split-rig-scenario-"), "s.yml")
      File.write(path, "name: s\nprompt: p\nexpected_requests: 1\nresponses:\n  - type: stream\n    content: x\nenv: nope\n")
      error = assert_raises(Error) { Scenario.load(path) }
      assert_match(/env must be a mapping/, error.message)
    end

    def test_env_values_stringify
      path = File.join(Dir.mktmpdir("tui-split-rig-scenario-"), "s.yml")
      File.write(path, "name: s\nprompt: p\nexpected_requests: 1\nresponses:\n  - type: stream\n    content: x\nenv:\n  tart:\n    COUNT: 3\n")
      assert_equal({"tart" => {"COUNT" => "3"}}, Scenario.load(path).env)
    end

    def test_loads_the_shipped_s2_tool_turn_scenario
      scenario = Scenario.load(File.join(RIG_ROOT, "scenarios/s2_tool_turn.yml"))
      assert_equal "s2_tool_turn", scenario.name
      assert_equal "run the echo", scenario.prompt
      assert_equal 2, scenario.expected_requests
      assert_equal 2, scenario.responses.size
      assert_equal "bash", scenario.responses[0][:tool_calls][0][:name]
      assert_equal({command: "echo pty-tester"}, scenario.responses[0][:tool_calls][0][:arguments])
    end

    def test_loads_the_shipped_s3_tool_turn_files_scenario
      scenario = Scenario.load(File.join(RIG_ROOT, "scenarios/s3_tool_turn_files.yml"))
      assert_equal "s3_tool_turn_files", scenario.name
      assert_equal "write then read the file", scenario.prompt
      assert_equal 3, scenario.expected_requests
      assert_equal "write", scenario.responses[0][:tool_calls][0][:name]
      assert_equal({path: "s3-tool-turn-note.txt", content: "parity s3 sandbox note"},
        scenario.responses[0][:tool_calls][0][:arguments])
      assert_equal "read", scenario.responses[1][:tool_calls][0][:name]
      assert_equal({path: "s3-tool-turn-note.txt"}, scenario.responses[1][:tool_calls][0][:arguments])
      assert_equal "The file tools ran; fixed final reply for the spike.", scenario.responses[2][:content]
    end

    def test_loads_the_shipped_s4_bash_variants_scenario
      scenario = Scenario.load(File.join(RIG_ROOT, "scenarios/s4_bash_variants.yml"))
      assert_equal "s4_bash_variants", scenario.name
      assert_equal "run the two bash commands", scenario.prompt
      assert_equal 3, scenario.expected_requests
      assert_equal "bash", scenario.responses[0][:tool_calls][0][:name]
      assert_equal({command: "seq 1 12"}, scenario.responses[0][:tool_calls][0][:arguments])
      assert_equal "bash", scenario.responses[1][:tool_calls][0][:name]
      assert_equal({command: "ls /definitely-not-here-s4"}, scenario.responses[1][:tool_calls][0][:arguments])
      assert_equal "The bash tools ran; fixed final reply for the spike.", scenario.responses[2][:content]
    end

    def test_loads_the_shipped_s5_bash_truncation_scenario
      scenario = Scenario.load(File.join(RIG_ROOT, "scenarios/s5_bash_truncation.yml"))
      assert_equal "s5_bash_truncation", scenario.name
      assert_equal "run the long seq", scenario.prompt
      assert_equal 2, scenario.expected_requests
      assert_equal 2, scenario.responses.size
      assert_equal "bash", scenario.responses[0][:tool_calls][0][:name]
      assert_equal({command: "seq 1 2100"}, scenario.responses[0][:tool_calls][0][:arguments],
        "2100 lines crosses the 2000-line model-facing tail cap")
      assert_equal "The truncated bash output was captured; fixed final reply for the spike.",
        scenario.responses[1][:content]
    end

    def test_loads_the_shipped_s6_long_calls_scenario
      scenario = Scenario.load(File.join(RIG_ROOT, "scenarios/s6_long_calls.yml"))
      assert_equal "s6_long_calls", scenario.name
      assert_equal "run the long command and write the long-named file", scenario.prompt
      assert_equal 3, scenario.expected_requests
      assert_equal 3, scenario.responses.size
      assert_equal "bash", scenario.responses[0][:tool_calls][0][:name]
      assert scenario.responses[0][:tool_calls][0][:arguments][:command].length > 120,
        "the bash call row crosses the 120-col viewport"
      assert_equal "write", scenario.responses[1][:tool_calls][0][:name]
      write_args = scenario.responses[1][:tool_calls][0][:arguments]
      assert write_args[:path].length > 100, "the write call row's staged path crosses 100 chars"
      assert_equal "parity s6 note", write_args[:content]
      assert_equal "The long tool calls ran; fixed final reply for the spike.", scenario.responses[2][:content]
    end

    def test_loads_the_shipped_s7_compaction_scenario
      scenario = Scenario.load(File.join(RIG_ROOT, "scenarios/s7_compaction.yml"))
      assert_equal "s7_compaction", scenario.name
      assert_equal "hello compact", scenario.prompt
      assert_equal 2, scenario.expected_requests
      assert_equal 2, scenario.responses.size
      assert_equal 10, scenario.context_window,
        "the threshold-trigger lever: both apps' context windows shrink to 10 (I26)"
    end

    def test_loads_the_shipped_probe_tool_pending_scenario
      scenario = Scenario.load(File.join(RIG_ROOT, "scenarios/probe_tool_pending.yml"))
      assert_equal "probe_tool_pending", scenario.name
      assert_equal "run the sleeper", scenario.prompt
      assert_equal 2, scenario.expected_requests
      assert_equal({command: "sleep 6"}, scenario.responses[0][:tool_calls][0][:arguments],
        "the slow bash call gives the probe its mid-flight window")
      assert_nil scenario.context_window, "the probe needs no window shrink"
    end

    # The I38 user-bash streaming probe's driver (Grounds 7): the
    # !-command emits a line per second for ~3 s (pre-settle frames carry
    # the loader + output rows against the 0.5 s cadence); the inert
    # scripted reply is never requested (a user bash runs no model turn —
    # the loader constraints make one ride along).
    def test_loads_the_shipped_probe_user_bash_scenario
      scenario = Scenario.load(File.join(RIG_ROOT, "scenarios/probe_user_bash.yml"))
      assert_equal "probe_user_bash", scenario.name
      assert_equal '!for i in 1 2 3; do echo "probe line $i"; sleep 1; done', scenario.prompt
      assert_equal 1, scenario.expected_requests
      assert_equal 1, scenario.responses.size
      assert_match(/probe line/, scenario.prompt, "the probe's output rows echo the header's loop body")
      assert_nil scenario.context_window, "the probe needs no window shrink"
    end

    def test_context_window_is_optional_and_defaults_to_nil
      path = File.join(Dir.mktmpdir("tui-split-rig-scenario-"), "s.yml")
      File.write(path, "name: s\nprompt: p\nexpected_requests: 1\nresponses:\n  - type: stream\n    content: x\n")
      assert_nil Scenario.load(path).context_window
    end

    def test_non_positive_context_window_is_a_rig_error
      path = File.join(Dir.mktmpdir("tui-split-rig-scenario-"), "s.yml")
      File.write(path, "name: s\nprompt: p\nexpected_requests: 1\ncontext_window: 0\nresponses:\n  - type: stream\n    content: x\n")
      error = assert_raises(Error) { Scenario.load(path) }
      assert_match(/context_window must be a positive integer/, error.message)
    end

    def test_missing_required_field_raises_a_rig_error
      path = File.join(Dir.mktmpdir("tui-split-rig-scenario-"), "broken.yml")
      File.write(path, "name: broken\nexpected_requests: 1\nresponses:\n  - type: stream\n    content: x\n")
      error = assert_raises(Error) { Scenario.load(path) }
      assert_match(/missing required field 'prompt'/, error.message)
    end

    # The resize knob (I56, s16): a positive-integer pair or absent → nil;
    # everything else is a rig error at load.
    def test_resize_knob_parses_a_positive_pair_and_defaults_to_nil
      path = File.join(Dir.mktmpdir("tui-split-rig-scenario-"), "s.yml")
      File.write(path, "name: s\nprompt: p\nexpected_requests: 1\nresize: [80, 40]\nresponses:\n  - type: stream\n    content: x\n")
      assert_equal [80, 40], Scenario.load(path).resize

      plain = File.join(Dir.mktmpdir("tui-split-rig-scenario-"), "s.yml")
      File.write(plain, "name: s\nprompt: p\nexpected_requests: 1\nresponses:\n  - type: stream\n    content: x\n")
      assert_nil Scenario.load(plain).resize, "absent by default — the no-knob path is byte-frozen"
    end

    def test_resize_knob_rejects_non_positive_and_non_pair_shapes
      bad_shapes = [
        "resize: 80\n",                    # not a pair
        "resize: [80]\n",                  # one element
        "resize: [80, 40, 20]\n",          # three elements
        "resize: [0, 40]\n",               # non-positive width
        "resize: [80, -1]\n",              # non-positive height
        "resize: [\"80\", 40]\n",          # non-integer width
        "resize: [80, 40.5]\n",            # non-integer height
      ]
      bad_shapes.each do |resize_line|
        path = File.join(Dir.mktmpdir("tui-split-rig-scenario-"), "s.yml")
        File.write(path, "name: s\nprompt: p\nexpected_requests: 1\n#{resize_line}responses:\n  - type: stream\n    content: x\n")
        error = assert_raises(Error) { Scenario.load(path) }
        assert_match(/resize must be a \[width, height\] pair of positive integers/, error.message)
      end
    end

    # The shipped s16 instrument: the 120→80 mid-run resize with the s1
    # reply — the scenario the SIGWINCH parity rides.
    def test_resize_knob_loads_the_shipped_s16_resize_wrap_scenario
      scenario = Scenario.load(File.join(RIG_ROOT, "scenarios/s16_resize_wrap.yml"))
      assert_equal "s16_resize_wrap", scenario.name
      assert_equal [80, 40], scenario.resize
      assert_equal 1, scenario.expected_requests
      assert_equal [{type: :stream, content: "The mock reply is fixed and short for the spike."}], scenario.responses
    end

    def test_absent_scenario_file_raises_a_rig_error
      assert_raises(Error) { Scenario.load("/nonexistent/scenario.yml") }
    end

    # The context-window lever shrinks BOTH apps consistently: pi's staged
    # models.json + zeroed compaction knobs, tart's TART_CONTEXT_WINDOW env
    # + the same zeroed knobs in the staged HOME's settings.json (I26).
    def test_context_window_stages_both_apps_compaction_knobs
      scenario = Scenario.load(File.join(RIG_ROOT, "scenarios/s7_compaction.yml"))
      runner = Runner.new(scenario:, out: File.join(Dir.mktmpdir("tui-split-rig-runner-")))
      stage = File.join(runner.out_dir, "run-1")
      agent_dir = runner.stage_pi_agent(stage, 4711)
      models = JSON.parse(File.read(File.join(agent_dir, "models.json")))
      assert_equal 10, models.dig("providers", "mock", "models", 0, "contextWindow")
      settings = JSON.parse(File.read(File.join(agent_dir, "settings.json")))
      assert_equal({"enabled" => true, "reserveTokens" => 0, "keepRecentTokens" => 0},
        settings.fetch("compaction"), "pi's compaction knobs zeroed (settings-manager.ts:822)")

      home = File.join(stage, "home", "tart")
      FileUtils.mkdir_p(home)
      runner.stage_tart_home(home, 4711)
      tart_settings = JSON.parse(File.read(File.join(home, ".tart", "settings.json")))
      assert_equal({"enabled" => true, "reserveTokens" => 0, "keepRecentTokens" => 0},
        tart_settings.fetch("compaction"), "tart's knobs zeroed too (settings.rb compaction_kwargs)")
    end

    # I27: sessions carry the per-Runner token and the leftover check greps
    # only it — concurrent rig processes don't flake each other's cleanup.
    def test_session_names_and_leftover_check_are_token_scoped
      scenario = Scenario.load(File.join(RIG_ROOT, "scenarios/s1_text_turn.yml"))
      a = Runner.new(scenario:, out: File.join(Dir.mktmpdir("tui-split-rig-runner-")))
      b = Runner.new(scenario:, out: File.join(Dir.mktmpdir("tui-split-rig-runner-")))
      refute_equal a.token, b.token, "each runner gets its own token"

      name = a.session_name("pi", 1)
      assert_match(/^tui-split-rig-#{a.token}-pi-s1_text_turn-r1-/, name)
      refute_match(/#{b.token}/, name)
    end

    # I27: the tart menu staging mirrors pi's models.json shape with ≥2 mock
    # models so the /model menu has something to select; staged unconditionally
    # (the menu probe needs it without a context_window), settings.json stays
    # context_window-gated.
    def test_tart_home_stages_two_mock_models
      scenario = Scenario.load(File.join(RIG_ROOT, "scenarios/s1_text_turn.yml"))
      runner = Runner.new(scenario:, out: File.join(Dir.mktmpdir("tui-split-rig-runner-")))
      home = File.join(Dir.mktmpdir("tui-split-rig-home-"))
      runner.stage_tart_home(home, 4711)

      models = JSON.parse(File.read(File.join(home, ".tart", "models.json")))
      provider = models.dig("providers", "mock")
      assert_equal "http://127.0.0.1:4711/v1", provider.fetch("baseUrl")
      assert_operator provider.fetch("models").size, :>=, 2, "the menu needs ≥2 mock models"
      assert_equal %w[mock-1 mock-2], provider.fetch("models").map { |m| m.fetch("id") }
      refute File.exist?(File.join(home, ".tart", "settings.json")),
        "settings.json stays context_window-gated (s1–s6 don't stage it)"
    end

    # The usage-suppression knob (I29, the Case-3 instrument): a boolean
    # scenario field, false when absent, a rig error when mistyped.
    def test_suppress_usage_defaults_to_false_and_loads_from_the_shipped_s8
      path = File.join(Dir.mktmpdir("tui-split-rig-scenario-"), "s.yml")
      File.write(path, "name: s\nprompt: p\nexpected_requests: 1\nresponses:\n  - type: stream\n    content: x\n")
      refute Scenario.load(path).suppress_usage

      scenario = Scenario.load(File.join(RIG_ROOT, "scenarios/s8_zero_usage_compaction.yml"))
      assert scenario.suppress_usage
      assert_equal 10, scenario.context_window
    end

    def test_non_boolean_suppress_usage_is_a_rig_error
      path = File.join(Dir.mktmpdir("tui-split-rig-scenario-"), "s.yml")
      File.write(path, "name: s\nprompt: p\nexpected_requests: 1\nsuppress_usage: yes-please\n" \
        "responses:\n  - type: stream\n    content: x\n")
      error = assert_raises(Error) { Scenario.load(path) }
      assert_match(/suppress_usage must be a boolean/, error.message)
    end

    # --- the post-settle keys + the resource staging (I33, s9) ---

    def test_post_settle_keys_default_to_empty_and_load_from_the_shipped_s9
      path = File.join(Dir.mktmpdir("tui-split-rig-scenario-"), "s.yml")
      File.write(path, "name: s\nprompt: p\nexpected_requests: 1\nresponses:\n  - type: stream\n    content: x\n")
      assert_empty Scenario.load(path).post_settle_keys

      scenario = Scenario.load(File.join(RIG_ROOT, "scenarios/s9_startup_help.yml"))
      assert_equal ["C-o"], scenario.post_settle_keys
      assert scenario.stage_project_resources, "s9 stages the loaded-resource set"
    end

    def test_post_settle_keys_must_be_a_list_of_strings
      path = File.join(Dir.mktmpdir("tui-split-rig-scenario-"), "s.yml")
      File.write(path, "name: s\nprompt: p\nexpected_requests: 1\npost_settle_keys: C-o\n" \
        "responses:\n  - type: stream\n    content: x\n")
      error = assert_raises(Error) { Scenario.load(path) }
      assert_match(/post_settle_keys must be a list of key strings/, error.message)

      File.write(path, "name: s\nprompt: p\nexpected_requests: 1\npost_settle_keys: [1, 2]\n" \
        "responses:\n  - type: stream\n    content: x\n")
      error = assert_raises(Error) { Scenario.load(path) }
      assert_match(/post_settle_keys must be a list of key strings/, error.message)
    end

    def test_non_boolean_stage_project_resources_is_a_rig_error
      path = File.join(Dir.mktmpdir("tui-split-rig-scenario-"), "s.yml")
      File.write(path, "name: s\nprompt: p\nexpected_requests: 1\nstage_project_resources: sure\n" \
        "responses:\n  - type: stream\n    content: x\n")
      error = assert_raises(Error) { Scenario.load(path) }
      assert_match(/stage_project_resources must be a boolean/, error.message)
    end

    # The staging writes BOTH apps' resource sets byte-identical: AGENTS.md
    # at the cwd, a project skill + prompt under each config dir, a user
    # skill in the staged agent dir (pi) / settings root (tart) — with a
    # DISTINCT user-skill name (the base s9 run: same-name skills fire
    # both apps' collision diagnostics).
    def test_stage_project_resources_writes_both_apps_resource_sets
      scenario = Scenario.load(File.join(RIG_ROOT, "scenarios/s9_startup_help.yml"))
      runner = Runner.new(scenario:, out: File.join(Dir.mktmpdir("tui-split-rig-runner-")))
      home = File.join(Dir.mktmpdir("tui-split-rig-home-"), "tart")
      sandbox = File.join(Dir.mktmpdir("tui-split-rig-sandbox-"))
      agent_dir = File.join(Dir.mktmpdir("tui-split-rig-agent-"), "pi")
      FileUtils.mkdir_p(home)

      runner.stage_project_resources(home:, sandbox:, agent_dir:)

      assert File.file?(File.join(sandbox, "AGENTS.md"))
      assert_equal File.read(File.join(sandbox, ".pi", "skills", "demo.md")),
        File.read(File.join(sandbox, ".tart", "skills", "demo.md")), "the project skills are byte-identical"
      assert_equal File.read(File.join(sandbox, ".pi", "prompts", "demo.md")),
        File.read(File.join(sandbox, ".tart", "prompts", "demo.md")), "the prompt templates are byte-identical"
      refute_equal File.read(File.join(sandbox, ".pi", "skills", "demo.md")),
        File.read(File.join(agent_dir, "skills", "demo-user.md")), "the user skill carries its own name"
      assert_equal File.read(File.join(agent_dir, "skills", "demo-user.md")),
        File.read(File.join(home, ".tart", "skills", "demo-user.md")), "the user skills are byte-identical"
      [File.join(sandbox, ".pi", "skills", "demo.md"), File.join(agent_dir, "skills", "demo-user.md")].each do |path|
        assert_match(/\A---\nname: /, File.read(path), "valid frontmatter (a missing description blocks the port's load)")
      end
    end

    # --- the prefix-aware env staging (I32 AC4) ---(

    def runner_for(name)
      Runner.new(scenario: Scenario.load(File.join(RIG_ROOT, "scenarios/#{name}.yml")),
                 out: File.join(Dir.mktmpdir("tui-split-rig-runner-")))
    end

    # The parity scenarios run tart in pi mode (no TART_IDENTITY staged):
    # the boot env speaks PI_*, and TART_IDENTITY stages the literal
    # bootstrap value pi.
    def test_parity_scenarios_stage_pi_prefix_env_for_tart
      command = runner_for("s1_text_turn").tart_command("/sandbox", "/home", 4711)
      assert_includes command, "TART_IDENTITY=pi"
      assert_includes command, "PI_MODEL=mock-1"
      assert_includes command, "PI_PROVIDER=openai"
      assert_includes command, "PI_API_KEY=mock-key"
      assert_includes command, "PI_API_BASE=http://127.0.0.1:4711"
      assert_includes command, "PI_CONTEXT_WINDOW=32768"
      refute_includes command, "TART_MODEL="
      refute_includes command, "TART_API_KEY="
    end

    # s1_tart (tart mode) stages TART_* unchanged.
    def test_s1_tart_stages_the_tart_namespace
      command = runner_for("s1_tart").tart_command("/sandbox", "/home", 4711)
      assert_includes command, "TART_IDENTITY=tart"
      assert_includes command, "TART_MODEL=mock-1"
      assert_includes command, "TART_API_KEY=mock-key"
      assert_includes command, "TART_CONTEXT_WINDOW=32768"
      refute_includes command, "PI_MODEL="
    end

    # The parent environment's PI_*/TART_* keys are scrubbed (-u) — the
    # operator's real PI_API_KEY must not leak into a staged run — while
    # the staged keys themselves always win (never scrubbed).
    def test_staging_scrubs_parent_pi_and_tart_env
      ENV["PI_SESSION_ID"] = "operator-session"
      ENV["PI_API_KEY"] = "operator-key"
      ENV["TART_MODEL"] = "operator-model"
      ENV["TART_CONTEXT_WINDOW"] = "1"
      command = runner_for("s1_text_turn").tart_command("/sandbox", "/home", 4711)
      assert_includes command, "-u PI_SESSION_ID"
      assert_includes command, "-u TART_MODEL"
      assert_includes command, "-u TART_CONTEXT_WINDOW"
      assert_includes command, "PI_API_KEY=mock-key", "staged values still stage"
      # pi's pane scrubs too, but never its own staged keys.
      pi_command = runner_for("s1_text_turn").pi_command("/home", "/agent")
      assert_includes pi_command, "-u PI_API_KEY"
      assert_includes pi_command, "-u TART_MODEL"
      assert_includes pi_command, "PI_OFFLINE=1"
      refute_includes pi_command, "-u PI_OFFLINE"
    ensure
      ENV.delete("PI_SESSION_ID")
      ENV.delete("PI_API_KEY")
      ENV.delete("TART_MODEL")
      ENV.delete("TART_CONTEXT_WINDOW")
    end

    # --- the memory-recall staging (I47, s11) ---

    # The stage_memory knob (the s11 instrument): a boolean scenario field,
    # false when absent, a rig error when mistyped.
    def test_stage_memory_defaults_to_false_and_loads_from_the_shipped_s11
      path = File.join(Dir.mktmpdir("tui-split-rig-scenario-"), "s.yml")
      File.write(path, "name: s\nprompt: p\nexpected_requests: 1\nresponses:\n  - type: stream\n    content: x\n")
      refute Scenario.load(path).stage_memory

      scenario = Scenario.load(File.join(RIG_ROOT, "scenarios/s11_memory_recall.yml"))
      assert scenario.stage_memory, "s11 stages the memory-recall set"
      assert_equal "hello", scenario.prompt
      assert_equal 1, scenario.expected_requests
      assert_equal [{type: :stream, content: "Memory recall staged; fixed reply for the scenario."}], scenario.responses
    end

    def test_non_boolean_stage_memory_is_a_rig_error
      path = File.join(Dir.mktmpdir("tui-split-rig-scenario-"), "s.yml")
      File.write(path, "name: s\nprompt: p\nexpected_requests: 1\nstage_memory: definitely\n" \
        "responses:\n  - type: stream\n    content: x\n")
      error = assert_raises(Error) { Scenario.load(path) }
      assert_match(/stage_memory must be a boolean/, error.message)
    end

    # The staging writes BOTH apps' memory set: pi — the owner's memory.ts
    # VERBATIM (byte-identical to the rig fixture) in the staged agent
    # dir's extensions/ + the frozen index under <agentDir>/memory/<key>;
    # tart — the "memory": true settings row + the same index under
    # .tart/memory/<key>. The temp sandboxes sit under the macOS temp root
    # (no .git anywhere above), so the walk falls back to the sandbox
    # basename — the keys here are literally "pi" and "tart", the frozen
    # letter's paths.
    def test_stage_memory_writes_both_apps_memory_set
      scenario = Scenario.load(File.join(RIG_ROOT, "scenarios/s11_memory_recall.yml"))
      runner = Runner.new(scenario:, out: File.join(Dir.mktmpdir("tui-split-rig-runner-")))
      fixture = File.read(File.join(RIG_ROOT, "fixtures/memory.ts"))
      index = "- [deploy](deploy.md): deploys via herdr pipeline, stage first\n" \
              "- [api-notes](api-notes.md): gateway streams SSE, no websockets\n"

      pi_home = File.join(Dir.mktmpdir("tui-split-rig-home-"), "pi")
      agent_dir = File.join(pi_home, ".pi", "agent")
      FileUtils.mkdir_p(agent_dir)
      runner.stage_memory("pi", home: pi_home, sandbox: File.join(Dir.mktmpdir("tui-split-rig-sandbox-"), "pi"), agent_dir:)
      assert_equal fixture, File.read(File.join(agent_dir, "extensions", "memory.ts")),
        "the staged extension is the fixture VERBATIM"
      assert_equal index, File.read(File.join(agent_dir, "memory", "pi", "MEMORY.md"))

      tart_home = File.join(Dir.mktmpdir("tui-split-rig-home-"), "tart")
      runner.stage_memory("tart", home: tart_home, sandbox: File.join(Dir.mktmpdir("tui-split-rig-sandbox-"), "tart"))
      assert_equal index, File.read(File.join(tart_home, ".tart", "memory", "tart", "MEMORY.md")),
        "the index bytes are identical per app"
      settings = JSON.parse(File.read(File.join(tart_home, ".tart", "settings.json")))
      assert_equal true, settings.fetch("memory"), "the core lane's gate row"
    end

    # The project key is memory.ts's OWN rule, mirrored (memory.ts:29-44):
    # a .git entry (file or dir — worktrees use a file) anywhere ABOVE the
    # sandbox renames the key to that root's basename — the rig's out dirs
    # live inside the tart checkout, so the fallback key never survives a
    # real run (PHASE 0: with a hard-coded key the recall no-ops live).
    def test_stage_memory_walks_up_for_a_git_root_like_memory_ts
      scenario = Scenario.load(File.join(RIG_ROOT, "scenarios/s11_memory_recall.yml"))
      runner = Runner.new(scenario:, out: File.join(Dir.mktmpdir("tui-split-rig-runner-")))
      index = "- [deploy](deploy.md): deploys via herdr pipeline, stage first\n" \
              "- [api-notes](api-notes.md): gateway streams SSE, no websockets\n"

      repo = File.join(Dir.mktmpdir("tui-split-rig-repo-"), "myrepo")
      FileUtils.mkdir_p(repo)
      FileUtils.mkdir_p(File.join(repo, "nested"))
      File.write(File.join(repo, ".git"), "gitdir: elsewhere\n")
      home = File.join(Dir.mktmpdir("tui-split-rig-home-"), "pi")
      agent_dir = File.join(home, ".pi", "agent")
      FileUtils.mkdir_p(agent_dir)

      runner.stage_memory("pi", home:, sandbox: File.join(repo, "nested", "sandbox"), agent_dir:)
      assert_equal index, File.read(File.join(agent_dir, "memory", "myrepo", "MEMORY.md")),
        "the key is the walked git root's basename (memory.ts:44)"
    end

    # The tart merge must not clobber the compaction rows the
    # context_window lever writes (the s7/s8 family) — deep-merge, existing
    # rows survive, memory just joins them.
    def test_stage_memory_merges_into_existing_tart_settings
      scenario = Scenario.load(File.join(RIG_ROOT, "scenarios/s11_memory_recall.yml"))
      runner = Runner.new(scenario:, out: File.join(Dir.mktmpdir("tui-split-rig-runner-")))
      home = File.join(Dir.mktmpdir("tui-split-rig-home-"), "tart")
      settings_path = File.join(home, ".tart", "settings.json")
      FileUtils.mkdir_p(File.dirname(settings_path))
      File.write(settings_path, JSON.pretty_generate(
        "compaction" => {"enabled" => true, "reserveTokens" => 0, "keepRecentTokens" => 0}
      ))

      runner.stage_memory("tart", home:, sandbox: File.join(Dir.mktmpdir("tui-split-rig-sandbox-"), "tart"))

      settings = JSON.parse(File.read(settings_path))
      assert_equal true, settings.fetch("memory")
      assert_equal({"enabled" => true, "reserveTokens" => 0, "keepRecentTokens" => 0},
        settings.fetch("compaction"), "the compaction rows survive the merge")
    end

    # --- the paste/submit knobs (I55, s14/s15) ---

    # The canonical calibration block (Grounds §4): 12 short ASCII lines,
    # no trailing newline — the byte-exact s14/s15 content.
    PASTE_BLOCK = (<<~BLOCK).chomp.freeze
      line alpha one
      line bravo two
      line charlie three
      line delta four
      line echo five
      line foxtrot six
      line golf seven
      line hotel eight
      line india nine
      line juliet ten
      line kilo eleven
      line lima twelve
    BLOCK

    def test_paste_knob_defaults_to_nil_and_loads_from_the_shipped_s14
      path = File.join(Dir.mktmpdir("tui-split-rig-scenario-"), "s.yml")
      File.write(path, "name: s\nprompt: p\nexpected_requests: 0\nresponses:\n  - type: stream\n    content: x\n")
      assert_nil Scenario.load(path).paste, "no paste knob — today's behavior"

      scenario = Scenario.load(File.join(RIG_ROOT, "scenarios/s14_paste_marker_display.yml"))
      assert_equal PASTE_BLOCK, scenario.paste, "the byte-exact calibrated block"
      assert_equal "", scenario.prompt
      refute scenario.submit, "s14 is paste-only: no Enter"
      assert_equal 0, scenario.expected_requests, "the display flow makes no requests"
    end

    def test_paste_knob_non_string_is_a_rig_error
      path = File.join(Dir.mktmpdir("tui-split-rig-scenario-"), "s.yml")
      File.write(path, "name: s\nprompt: p\npaste: [not, a, string]\nexpected_requests: 0\n" \
        "responses:\n  - type: stream\n    content: x\n")
      error = assert_raises(Error) { Scenario.load(path) }
      assert_match(/paste must be a string/, error.message)
    end

    def test_submit_knob_defaults_to_true_and_loads_from_the_shipped_s15
      path = File.join(Dir.mktmpdir("tui-split-rig-scenario-"), "s.yml")
      File.write(path, "name: s\nprompt: p\nexpected_requests: 1\nresponses:\n  - type: stream\n    content: x\n")
      assert Scenario.load(path).submit, "submit defaults TRUE — today's behavior"

      scenario = Scenario.load(File.join(RIG_ROOT, "scenarios/s15_paste_marker_submit.yml"))
      assert_equal PASTE_BLOCK, scenario.paste
      assert scenario.submit, "s15 submits (the default — no submit key in the file)"
      assert_equal 1, scenario.expected_requests
      assert_equal [{type: :stream, content: "copy that, twelve lines"}], scenario.responses
    end

    def test_submit_knob_non_boolean_is_a_rig_error
      path = File.join(Dir.mktmpdir("tui-split-rig-scenario-"), "s.yml")
      File.write(path, "name: s\nprompt: p\nexpected_requests: 1\nsubmit: maybe\n" \
        "responses:\n  - type: stream\n    content: x\n")
      error = assert_raises(Error) { Scenario.load(path) }
      assert_match(/submit must be a boolean/, error.message)
    end

    def test_expected_requests_zero_is_accepted_and_negative_rejected
      path = File.join(Dir.mktmpdir("tui-split-rig-scenario-"), "s.yml")
      File.write(path, "name: s\nprompt: p\nexpected_requests: 0\nresponses:\n  - type: stream\n    content: x\n")
      scenario = Scenario.load(path)
      assert_equal 0, scenario.expected_requests, "paste-only flows make zero requests (I55)"

      File.write(path, "name: s\nprompt: p\nexpected_requests: -1\nresponses:\n  - type: stream\n    content: x\n")
      error = assert_raises(Error) { Scenario.load(path) }
      assert_match(/expected_requests must be a non-negative integer/, error.message)
    end

  end
end
