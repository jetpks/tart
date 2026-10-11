# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/tart/parity"
require "net/http"
require "socket"

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
      assert_equal({"tart" => {"TART_MODEL_PROVIDER" => "mock"}}, scenario.env,
        "the footer staging rides the per-app env seam (I16)")
    end

    def test_loads_the_shipped_s1_tart_scenario_with_the_identity_staged
      scenario = Parity::Scenario.load(File.join(REPO_ROOT, "parity/scenarios/s1_tart.yml"))
      assert_equal "s1_tart", scenario.name
      assert_equal "tart", scenario.env.fetch("tart").fetch("TART_IDENTITY"),
        "tart-mode stages TART_IDENTITY=tart (I16 AC3)"
    end

    def test_env_is_optional_and_defaults_to_empty
      path = File.join(Dir.mktmpdir("pty-tester-scenario-"), "s.yml")
      File.write(path, "name: s\nprompt: p\nexpected_requests: 1\nresponses:\n  - type: stream\n    content: x\n")
      assert_empty Parity::Scenario.load(path).env
    end

    def test_unknown_env_app_is_a_rig_error
      path = File.join(Dir.mktmpdir("pty-tester-scenario-"), "s.yml")
      File.write(path, "name: s\nprompt: p\nexpected_requests: 1\nresponses:\n  - type: stream\n    content: x\nenv:\n  mockapp:\n    FOO: 1\n")
      error = assert_raises(Parity::Error) { Parity::Scenario.load(path) }
      assert_match(/unknown env app 'mockapp'/, error.message)
    end

    def test_non_mapping_env_is_a_rig_error
      path = File.join(Dir.mktmpdir("pty-tester-scenario-"), "s.yml")
      File.write(path, "name: s\nprompt: p\nexpected_requests: 1\nresponses:\n  - type: stream\n    content: x\nenv: nope\n")
      error = assert_raises(Parity::Error) { Parity::Scenario.load(path) }
      assert_match(/env must be a mapping/, error.message)
    end

    def test_env_values_stringify
      path = File.join(Dir.mktmpdir("pty-tester-scenario-"), "s.yml")
      File.write(path, "name: s\nprompt: p\nexpected_requests: 1\nresponses:\n  - type: stream\n    content: x\nenv:\n  tart:\n    COUNT: 3\n")
      assert_equal({"tart" => {"COUNT" => "3"}}, Parity::Scenario.load(path).env)
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

    def test_s2_stages_the_footer_provider_env
      scenario = Parity::Scenario.load(File.join(REPO_ROOT, "parity/scenarios/s2_tool_turn.yml"))
      assert_equal({"tart" => {"TART_MODEL_PROVIDER" => "mock"}}, scenario.env,
        "the footer staging rides the per-app env seam (I16)")
    end

    def test_loads_the_shipped_s3_tool_turn_files_scenario
      scenario = Parity::Scenario.load(File.join(REPO_ROOT, "parity/scenarios/s3_tool_turn_files.yml"))
      assert_equal "s3_tool_turn_files", scenario.name
      assert_equal "write then read the file", scenario.prompt
      assert_equal 3, scenario.expected_requests
      assert_equal "write", scenario.responses[0][:tool_calls][0][:name]
      assert_equal({path: "s3-tool-turn-note.txt", content: "parity s3 sandbox note"},
        scenario.responses[0][:tool_calls][0][:arguments])
      assert_equal "read", scenario.responses[1][:tool_calls][0][:name]
      assert_equal({path: "s3-tool-turn-note.txt"}, scenario.responses[1][:tool_calls][0][:arguments])
      assert_equal "The file tools ran; fixed final reply for the spike.", scenario.responses[2][:content]
      assert_equal({"tart" => {"TART_MODEL_PROVIDER" => "mock"}}, scenario.env,
        "the footer staging rides the per-app env seam (I16)")
    end

    def test_loads_the_shipped_s4_bash_variants_scenario
      scenario = Parity::Scenario.load(File.join(REPO_ROOT, "parity/scenarios/s4_bash_variants.yml"))
      assert_equal "s4_bash_variants", scenario.name
      assert_equal "run the two bash commands", scenario.prompt
      assert_equal 3, scenario.expected_requests
      assert_equal "bash", scenario.responses[0][:tool_calls][0][:name]
      assert_equal({command: "seq 1 12"}, scenario.responses[0][:tool_calls][0][:arguments])
      assert_equal "bash", scenario.responses[1][:tool_calls][0][:name]
      assert_equal({command: "ls /definitely-not-here-s4"}, scenario.responses[1][:tool_calls][0][:arguments])
      assert_equal "The bash tools ran; fixed final reply for the spike.", scenario.responses[2][:content]
      assert_equal({"tart" => {"TART_MODEL_PROVIDER" => "mock"}}, scenario.env,
        "the footer staging rides the per-app env seam (I16)")
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

    # AC4 (I18 rig robustness): a connection that sends no request line
    # consumes no scripted response — no @script shift, no request-log
    # entry, no response — so the next real request gets the next spec.
    def test_an_empty_tcp_connection_consumes_no_scripted_response
      with_server([{type: :message, content: "one"}, {type: :message, content: "two"}]) do |server|
        TCPSocket.new("127.0.0.1", server.port).close

        assert_equal "one", fetch_content(server)
        assert_equal "two", fetch_content(server)
        logs = server.captured_request_logs
        assert_equal 2, logs.size
        assert logs.all? { |entry| entry[:method] == "POST" && entry[:path] == "/v1/chat/completions" }
      end
    end

    private

    def with_server(specs)
      server = MockLLMServer.new.script(specs).start
      yield server
    ensure
      server&.stop
    end

    def fetch_content(server)
      uri = URI("http://127.0.0.1:#{server.port}/v1/chat/completions")
      response = Net::HTTP.post(uri, {model: "m", stream: false}.to_json, "content-type" => "application/json")
      JSON.parse(response.body).fetch("choices")[0].fetch("message").fetch("content")
    end
  end
end
