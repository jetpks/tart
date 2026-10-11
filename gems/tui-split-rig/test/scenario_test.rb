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

    def test_missing_required_field_raises_a_rig_error
      path = File.join(Dir.mktmpdir("tui-split-rig-scenario-"), "broken.yml")
      File.write(path, "name: broken\nexpected_requests: 1\nresponses:\n  - type: stream\n    content: x\n")
      error = assert_raises(Error) { Scenario.load(path) }
      assert_match(/missing required field 'prompt'/, error.message)
    end

    def test_absent_scenario_file_raises_a_rig_error
      assert_raises(Error) { Scenario.load("/nonexistent/scenario.yml") }
    end

  end
end
