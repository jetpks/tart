# frozen_string_literal: true

require_relative "../test_helper"
require_relative "mock_llm_server"
require "net/http"
require "json"

# The I87 Law-2 pins for MockLLMServer's content-addressable scripting
# (+match:+): the deterministic-order cure for the subagents-e2e drain legs.
# Over a real TCP socket, no doubles — the same hermetic discipline as the
# parity rig's mock_llm_extension_test. These pins are the file's whole
# reason to exist: the suite's run count grows by exactly THESE five.
module Tart
  class MockLLMMatchTest < Test
    # A non-streaming scripted round trip: POST one chat completion, return
    # the assistant content the server served.
    def served_content(server, messages)
      uri = URI("#{server.url}/chat/completions")
      res = Net::HTTP.post(uri, {model: "mock-1", messages:}.to_json,
        "content-type" => "application/json")
      JSON.parse(res.body).dig("choices", 0, "message", "content")
    end

    # The cure property: responses route by REQUEST CONTENT regardless of
    # arrival order — the child's first request (task text) gets the slow
    # script even when it arrives BEFORE the parent's tool-result turn
    # (the class-(f) flip; the parent's own two turns are sequential, so
    # their relative order is fixed).
    def test_match_routes_by_content_regardless_of_arrival_order
      with_server do |server|
        server.script([
          {type: :message, content: "parent-opening",
           match: ->(req) { req["messages"].to_a.any? { |m| m["role"] == "user" && m["content"] == "delegate" } }},
          {type: :message, content: "parent-tool-turn",
           match: ->(req) { req["messages"].to_a.any? { |m| m["role"] == "tool" } }},
          {type: :message, content: "child-slow",
           match: ->(req) { req["messages"].to_a.any? { |m| m["role"] == "user" && m["content"] == "child task" } }}
        ])
        # The FLIPPED order (the class-(f) firing shape): the child's
        # request arrives FIRST — before the parent's tool-result turn.
        assert_equal "child-slow", served_content(server, [{role: "user", content: "child task"}])
        assert_equal "parent-opening", served_content(server, [{role: "user", content: "delegate"}])
        assert_equal "parent-tool-turn", served_content(server, [{role: "user", content: "delegate"}, {role: "assistant", content: nil, tool_calls: []}, {role: "tool", tool_call_id: "c1", content: "Async: worker"}])
      end
    end

    # Strictly additive: a script with NO match: entries keeps the blind
    # arrival-order shift, in order (every pre-I87 caller's contract).
    def test_entries_without_match_keep_the_blind_arrival_order_shift
      with_server do |server|
        server.script([{type: :message, content: "one"}, {type: :message, content: "two"}])
        any = ->(_req) { true }
        assert_equal "one", served_content(server, [{role: "user", content: "x"}])
        assert_equal "two", served_content(server, [{role: "user", content: "y"}])
        # Mixed: a match: entry parked behind a legacy entry is skipped by
        # the blind shift — the legacy entry serves the non-matching
        # request; the match: entry stays available for its request.
        server.rearm!
        server.script([{type: :message, content: "parked", match: ->(req) { req.dig("messages", 0, "content") == "special" }},
                       {type: :message, content: "legacy"}])
        assert_equal "legacy", served_content(server, [{role: "user", content: "ordinary"}])
        assert_equal "parked", served_content(server, [{role: "user", content: "special"}])
        assert any # the documented first-match-wins shape needs a callable
      end
    end

    # A non-matching request never consumes a parked match: entry; once
    # every entry is consumed (or nothing matches), the exhausted fallback
    # is the unchanged {type: :message, content: ""}.
    def test_unmatched_requests_park_match_entries_and_fallback_is_unchanged
      with_server do |server|
        server.script([{type: :message, content: "special",
                        match: ->(req) { req.dig("messages", 0, "content") == "special" }}])
        fallback = served_content(server, [{role: "user", content: "ordinary"}])
        assert_equal "", fallback, "the exhausted fallback serves an empty message"
        assert_equal "special", served_content(server, [{role: "user", content: "special"}]),
          "the parked entry survived the non-matching request"
      end
    end

    # rearm! restores match: entries byte-identically — ONE server instance
    # can re-serve the same content-routed script to a fresh app.
    def test_rearm_restores_match_entries
      with_server do |server|
        server.script([{type: :message, content: "routed",
                        match: ->(req) { req.dig("messages", 0, "content") == "ask" }}])
        assert_equal "routed", served_content(server, [{role: "user", content: "ask"}])
        assert_equal "", served_content(server, [{role: "user", content: "ask"}]), "exhausted after one serve"
        server.rearm!
        assert_equal "routed", served_content(server, [{role: "user", content: "ask"}])
      end
    end

    # Overlapping predicates: the FIRST matching entry wins (documented
    # scan order), and each entry is served EXACTLY once per script pass.
    def test_first_match_wins_and_each_entry_serves_once
      with_server do |server|
        server.script([
          {type: :message, content: "first", match: ->(_req) { true }},
          {type: :message, content: "second", match: ->(_req) { true }}
        ])
        assert_equal "first", served_content(server, [{role: "user", content: "x"}])
        assert_equal "second", served_content(server, [{role: "user", content: "x"}])
        assert_equal "", served_content(server, [{role: "user", content: "x"}]), "both consumed, fallback"
      end
    end

    # Routing works for the STREAMING arm too (the drain legs' slow_stream
    # child response rides match: routing; non-streaming pins above pin the
    # selector, this one pins the wire shape end-to-end).
    def test_match_routing_serves_the_streaming_arm
      with_server do |server|
        server.script([{type: :stream, content: "streamed-child",
                        match: ->(req) { req.dig("messages", 0, "content") == "child task" }}])
        uri = URI("#{server.url}/chat/completions")
        socket = Net::HTTP.new(uri.host, uri.port)
        body = +""
        socket.post(uri.path, {model: "mock-1", messages: [{role: "user", content: "child task"}], stream: true}.to_json,
          "content-type" => "application/json", "accept" => "text/event-stream") { |chunk| body << chunk }
        answer = +""
        body.scan(/data: (.*)/).each do |(line)|
          next if line.strip == "[DONE]"
          delta = JSON.parse(line)
          answer << delta.dig("choices", 0, "delta", "content").to_s
        end
        assert_includes answer, "streamed-child", "the matched stream reached the matching request: #{body.inspect}"
      end
    end

    private

    def with_server
      server = MockLLMServer.new.start
      begin
        yield server
      ensure
        server.stop
      end
    end
  end
end
