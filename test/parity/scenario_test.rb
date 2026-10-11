# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/tart/parity"

module Tart
  # Scenario loading: the shipped data files and the failure path.
  class ParityScenarioTest < Test
    REPO_ROOT = File.expand_path("#{__dir__}/../..")

    def test_loads_the_shipped_s1_text_turn_scenario
      scenario = Parity::Scenario.load(File.join(REPO_ROOT, "parity/scenarios/s1_text_turn.yml"))
      assert_equal "s1_text_turn", scenario.name
      assert_equal "hello", scenario.prompt
      assert_equal 1, scenario.expected_requests
      assert_equal [{type: :stream, content: "The mock reply is fixed and short for the spike."}], scenario.responses
    end

    def test_loads_the_shipped_s2_tool_turn_scenario
      scenario = Parity::Scenario.load(File.join(REPO_ROOT, "parity/scenarios/s2_tool_turn.yml"))
      assert_equal "s2_tool_turn", scenario.name
      assert_equal "run the echo", scenario.prompt
      assert_equal 2, scenario.expected_requests
      assert_equal 2, scenario.responses.size
      assert_equal "bash", scenario.responses[0][:tool_calls][0][:name]
      assert_equal({command: "echo pty-tester"}, scenario.responses[0][:tool_calls][0][:arguments])
    end

    def test_missing_required_field_raises_a_rig_error
      path = File.join(Dir.mktmpdir("pty-tester-scenario-"), "broken.yml")
      File.write(path, "name: broken\nexpected_requests: 1\nresponses:\n  - type: stream\n    content: x\n")
      error = assert_raises(Parity::Error) { Parity::Scenario.load(path) }
      assert_match(/missing required field 'prompt'/, error.message)
    end

    def test_absent_scenario_file_raises_a_rig_error
      assert_raises(Parity::Error) { Parity::Scenario.load("/nonexistent/scenario.yml") }
    end
  end
end
