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

  end
end
