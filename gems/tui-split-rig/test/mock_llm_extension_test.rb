# frozen_string_literal: true

require_relative "../../../test/test_helper"
require_relative "../lib/tui_split_rig"
require_relative "../../../test/support/mock_llm_server"
require "net/http"
require "socket"

module TuiSplitRig
  # The parity-rig extensions of MockLLMServer (I02): per-request wire
  # logging and the re-armable script — over a real TCP socket, no doubles.
  class MockLLMExtensionTest < Tart::Test
    def test_request_logs_capture_method_path_headers_and_parsed_body
      with_server([{type: :message, content: "hi"}]) do |server|
        post(server, "/v1/chat/completions", {model: "mock-1", stream: false}.to_json,
          "authorization" => "Bearer mock-key")

        entry = server.captured_request_logs.first
        assert_equal "POST", entry[:method]
        assert_equal "/v1/chat/completions", entry[:path]
        assert_equal "Bearer mock-key", entry[:headers]["authorization"]
        assert_equal "mock-1", entry[:body]["model"]
      end
    end

    def test_captured_requests_still_yields_parsed_bodies
      with_server([{type: :message, content: "hi"}]) do |server|
        post(server, "/v1/chat/completions", {model: "mock-1", stream: false}.to_json, {})
        assert_equal ["mock-1"], server.captured_requests.map { |body| body["model"] }
      end
    end

    def test_rearm_serves_the_same_script_to_a_fresh_app
      with_server([{type: :message, content: "one"}, {type: :message, content: "two"}]) do |server|
        assert_equal "one", fetch_content(server)
        assert_equal "two", fetch_content(server)
        server.rearm!
        assert_equal "one", fetch_content(server)
        assert_equal "two", fetch_content(server)
      end
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

    def post(server, path, body, headers)
      uri = URI("http://127.0.0.1:#{server.port}#{path}")
      request = Net::HTTP::Post.new(uri, headers.merge("content-type" => "application/json"))
      request.body = body
      Net::HTTP.start(uri.host, uri.port) { |http| http.request(request) }
    end

    def fetch_content(server)
      response = post(server, "/v1/chat/completions", {model: "m", stream: false}.to_json, {})
      JSON.parse(response.body).fetch("choices")[0].fetch("message").fetch("content")
    end
  end
end
