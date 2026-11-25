# frozen_string_literal: true

require_relative "test_helper"
require "async"
require "fileutils"
require "json"
require "open3"
require "tmpdir"

module Tart
  # The MCP Streamable HTTP lane (I122): the transport against the
  # pure-Ruby fixture HTTP echo server on loopback (hermetic — never a
  # real gateway), the config schema's http arm with pi's exact strings,
  # the header env-value resolution (the I119 law composed), and the
  # never-raising boot loader (the models.json law) with the fail-fast
  # Config.load contract re-frozen beside it.
  class McpHttpTest < Test
    ECHO_SERVER = File.expand_path("support/mcp_http_echo_server.rb", __dir__)
    RUBY = RbConfig.ruby

    def setup
      @dir = Dir.mktmpdir("tart-mcp-http-")
      @mcp_tools = []
      @fixture_pids = []
      @log_path = File.join(@dir, "requests.jsonl")
    end

    def teardown
      @mcp_tools.each(&:close)
      @fixture_pids.each do |pid|
        Process.kill("TERM", pid)
        Process.detach(pid)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end
      FileUtils.rm_rf(@dir)
    end

    # -- the transport round trip (AC1) --------------------------------------

    def test_mcp_streamable_http_connect_lists_and_calls
      server = start_echo_server
      Sync do
        tools = Mcp.tools_for("gw" => {url: server_url(server)})
        @mcp_tools.concat(tools.values)
        assert_equal %w[mcp__gw__echo mcp__gw__sleep], tools.keys.sort,
                     "the streamable HTTP server's tools must merge into the loadout"

        assert_equal "echo: hello", tools.fetch("mcp__gw__echo").execute("message" => "hello")
        assert_equal "slept 0ms", tools.fetch("mcp__gw__sleep").execute("ms" => 0)
      end
    end

    def test_mcp_streamable_http_sse_response_arm_parses_every_event_until_the_answer
      server = start_echo_server("MCP_HTTP_ECHO_SSE" => "1")
      Sync do
        client = Mcp::Client.new
        result = client.connect(Mcp::Http.new(url: server_url(server)))
        assert result.success?, "connect over JSON must succeed: #{result.failure&.message}"

        called = client.call_tool("echo", {"message" => "via-sse"})
        assert called.success?, "the SSE reply must arrive: #{called.failure&.message}"
        assert_equal "echo: via-sse", called.value!["content"].first["text"]
        client.close
      end
    end

    def test_mcp_streamable_http_session_and_protocol_headers_ride_every_request
      server = start_echo_server
      Sync do
        tools = Mcp.tools_for("gw" => {url: server_url(server)})
        @mcp_tools.concat(tools.values)
        tools.fetch("mcp__gw__echo").execute("message" => "hdrs")

        posts = request_log.select { |entry| entry["method"] == "POST" }
        assert posts.length >= 3, "initialize + tools/list + tools/call must each POST"
        # The initialize POST OPENS the session (no id to carry yet); every
        # POST after it rides the captured session id + the negotiated
        # protocol version (pi's buildHeaders).
        assert(posts.drop(1).all? { |entry| entry["headers"]["mcp-session-id"] },
               "every POST after initialize carries the session id")
        assert(posts.drop(1).all? { |entry| entry["headers"]["mcp-protocol-version"] == "2025-06-18" },
               "every POST after initialize carries the negotiated protocol version")
      end
    end

    def test_mcp_streamable_http_unreachable_server_is_a_named_connect_failure
      config = {url: "http://127.0.0.1:9/mcp"}
      out, stderr = capture_io do
        tools = nil
        Sync { tools = Mcp.tools_for("gw" => config) }
        assert_empty tools
      end
      assert_empty out
      assert_match(/\Atart: mcp server "gw" failed to connect: .+\n\z/, stderr,
                   "an unreachable HTTP server warns and skips, byte-shape like stdio")
    end

    def test_mcp_streamable_http_named_error_taxonomy
      server = start_echo_server("MCP_HTTP_ECHO_STATUS" => "401")
      Sync do
        client = Mcp::Client.new
        result = client.connect(Mcp::Http.new(url: server_url(server)))
        assert_instance_of Mcp::Http::AuthRequiredError, result.failure
        assert_equal "MCP server requires authentication", result.failure.message
      end

      server = start_echo_server("MCP_HTTP_ECHO_LATE_404" => "1")
      Sync do
        client = Mcp::Client.new
        result = client.connect(Mcp::Http.new(url: server_url(server)))
        assert result.success?, "the first POST (initialize) succeeds"
        called = client.call_tool("echo", {"message" => "x"})
        assert_instance_of Mcp::Http::SessionExpiredError, called.failure
        assert_equal "MCP session expired", called.failure.message
        client.close
      end
    end

    def test_mcp_streamable_http_headers_resolve_env_values_at_connect
      server = start_echo_server
      Sync do
        result = Mcp.server_tools("gw", {url: server_url(server), headers: {"X-Token" => "$I122_TOKEN"}},
                                  used: {}, env: {"I122_TOKEN" => "tok-42"})
        assert result.success?, result.failure&.message
        @mcp_tools.concat(result.value!.values)
        result.value!.values.first.execute("message" => "x")

        assert(request_log.any? { |entry| entry.dig("headers", "x-token") == "tok-42" },
               "the resolved header VALUE rides the request")
      end

      Sync do
        failure = Mcp.server_tools("gw", {url: server_url(server), headers: {"X-Token" => "$I122_MISSING"}},
                                   used: {}, env: {})
        assert failure.failure?, "an unresolvable header VALUE is this server's connect failure"
        assert_match(/Failed to resolve MCP server "gw" header "X-Token" from environment variable: I122_MISSING/,
                     failure.failure.message)
      end
    end

    def test_mcp_streamable_http_unresolvable_header_warns_and_skips_via_tools_for
      server = start_echo_server
      out, stderr = capture_io do
        tools = nil
        Sync do
          tools = Mcp.tools_for("gw" => {url: server_url(server), headers: {"X-Token" => "$I122_GONE"}})
        end
        assert_empty tools
      end
      assert_empty out
      assert_match(
        /\Atart: mcp server "gw" failed to connect: Failed to resolve MCP server "gw" header "X-Token" from environment variable: I122_GONE\n\z/,
        stderr)
    end

    def test_mcp_streamable_http_get_stream_carries_server_requests
      server = start_echo_server("MCP_HTTP_ECHO_GET_STREAM" => "1")
      Sync do
        client = Mcp::Client.new
        result = client.connect(Mcp::Http.new(url: server_url(server)))
        assert result.success?
        # The fixture sends one server->client `ping` REQUEST over the GET
        # stream; the client's built-in handler answers it by POST.
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
        answered = false
        until answered || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          sleep 0.1
          answered = request_log.any? do |entry|
            entry["method"] == "POST" && entry["body"].to_s.include?("srv-1")
          end
        end
        assert answered, "the ping request from the GET stream must be answered over POST"
        client.close
      end
    end

    def test_mcp_streamable_http_close_sends_the_delete_and_off_reactor_is_the_named_seat_error
      server = start_echo_server
      transport = Mcp::Http.new(url: server_url(server))
      error = assert_raises(ArgumentError) { transport.start }
      assert_equal "MCP HTTP start runs on the host reactor (Sync-wrapped scenario or tool task)",
                   error.message

      Sync do
        client = Mcp::Client.new
        client.connect(transport)
        client.close
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
        deleted = false
        until deleted || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          sleep 0.1
          deleted = request_log.any? { |entry| entry["method"] == "DELETE" }
        end
        assert deleted, "close sends the best-effort session DELETE"
      end
    end

    # -- the bounded wire (no unbounded network wait on any path) ----------

    def test_mcp_streamable_http_stalled_get_stream_fails_within_the_request_timeout
      server = start_echo_server("MCP_HTTP_ECHO_GET_STALL" => "1")
      Sync do
        errors = []
        client = Mcp::Client.new(on_error: ->(error) { errors << error })
        result = client.connect(Mcp::Http.new(url: server_url(server), request_timeout_ms: 500))
        assert result.success?, result.failure&.message

        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
        until errors.any? || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          sleep 0.05
        end
        assert errors.any?, "a stalled GET stream must fail its reader within the request timeout, never hang"
        client.close
      end
    end

    def test_mcp_streamable_http_slow_sse_reply_fails_within_the_request_timeout
      server = start_echo_server("MCP_HTTP_ECHO_SSE" => "1", "MCP_HTTP_ECHO_SLOW_SSE" => "1")
      Sync do
        client = Mcp::Client.new
        result = client.connect(Mcp::Http.new(url: server_url(server), request_timeout_ms: 500))
        assert result.success?, result.failure&.message

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        called = client.call_tool("echo", {"message" => "slow"})
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        assert called.failure?, "an SSE reply that outlives the request timeout fails the request"
        assert_operator elapsed, :<, 3, "the failure lands within a bounded wait, not the fixture's 2s drip"
        client.close
      end
    end

    # -- the config schema's http arm (AC4, pi's exact strings) ------------

    def test_mcp_streamable_schema_accepts_the_http_arm_and_keeps_pi_strings
      table = {
        {"type" => "http", "url" => "http://127.0.0.1:9/mcp"} =>
          {url: "http://127.0.0.1:9/mcp", headers: nil},
        {"type" => "streamable-http", "url" => "https://example.com/mcp"} =>
          {url: "https://example.com/mcp", headers: nil},
        {"url" => "https://example.com/mcp", "headers" => {"X-A" => "b"}} =>
          {url: "https://example.com/mcp", headers: {"X-A" => "b"}}
      }
      table.each do |raw, want|
        assert_equal want, Mcp::Config.validate_server!("gw", raw), raw.inspect
      end

      string_table = {
        {"type" => "http", "url" => "ftp://example.com/mcp"} =>
          %(server "gw": url must be an http or https URL),
        {"type" => "http", "url" => "http://127.0.0.1:9/mcp", "headers" => {"X-A" => 1}} =>
          %(server "gw": headers must map names to strings),
        {"type" => "sse", "url" => "http://127.0.0.1:9/mcp"} =>
          %(server "gw": legacy SSE transport is not supported; use the streamable HTTP URL),
        {"type" => "weird", "command" => "c"} =>
          %(server "gw" needs either "command" (stdio) or "url" (streamable HTTP)),
        {"url" => 3} =>
          %(server "gw" needs either "command" (stdio) or "url" (streamable HTTP)),
        {"command" => "c", "url" => "http://127.0.0.1:9/mcp", "type" => "stdio"} =>
          {command: "c", args: [], env: nil, cwd: nil}
      }
      string_table.each do |raw, want|
        if want.is_a?(String)
          error = assert_raises(Mcp::Config::ConfigError) { Mcp::Config.validate_server!("gw", raw) }
          assert_equal want, error.message, raw.inspect
        else
          assert_equal want, Mcp::Config.validate_server!("gw", raw), raw.inspect
        end
      end
    end

    def test_mcp_streamable_stdio_arm_strings_are_byte_held
      # The stdio arm's checks and strings are unchanged (AC3): rows from
      # the existing load table still raise exactly (the full table lives
      # in test/mcp_test.rb and runs in the suite).
      path = write_config("mcpServers" => {"x" => {"command" => "c", "args" => "nope"}})
      error = assert_raises(Mcp::Config::ConfigError) { Mcp::Config.load(path) }
      assert_equal %(#{path}: server "x": args must be an array of strings), error.message

      path = write_config("mcpServers" => {"z" => "nope", "a" => {"cwd" => 3}})
      error = assert_raises(Mcp::Config::ConfigError) { Mcp::Config.load(path) }
      assert_equal %(#{path}: server "z" must be an object), error.message
    end

    # -- the never-raising boot loader (AC2, the models.json law) -----------

    def test_mcp_streamable_boot_loader_never_raises_and_skips_only_the_bad_servers
      good = {"command" => RUBY, "args" => [File.expand_path("support/mcp_echo_server.rb", __dir__)]}
      http = {"type" => "http", "url" => "http://127.0.0.1:9/mcp"}
      path = write_config("mcpServers" => {"bad" => {"args" => []}, "http" => http, "good" => good})

      result = Mcp::Config.load_with_diagnostics(path)
      assert_equal %w[good http], result.servers.keys.sort, "the good stdio AND http servers load"
      assert_equal 1, result.diagnostics.length, "the bad server is one named diagnostic"
      assert_equal %(#{path}: server "bad" needs either "command" (stdio) or "url" (streamable HTTP)),
                   result.diagnostics.first

      # Every failure class becomes diagnostics, never a raise:
      File.write(path = File.join(@dir, "m.json"), "{not json")
      result = Mcp::Config.load_with_diagnostics(path)
      assert result.servers.empty?
      assert_match(%r{\A#{Regexp.escape(path)}: }, result.diagnostics.first)

      File.write(path, JSON.generate([1, 2]))
      result = Mcp::Config.load_with_diagnostics(path)
      assert_equal ["#{path}: expected an object with an \"mcpServers\" object"], result.diagnostics

      # A missing file is no servers, no diagnostics (byte-held).
      absent = File.join(@dir, "absent.json")
      result = Mcp::Config.load_with_diagnostics(absent)
      assert_empty result.servers
      assert_empty result.diagnostics

      # An unreadable file is a diagnostic (today it is an Errno crash).
      unreadable = File.join(@dir, "unreadable.json")
      File.write(unreadable, "{}")
      File.chmod(0o000, unreadable)
      result = Mcp::Config.load_with_diagnostics(unreadable)
      assert_empty result.servers
      refute_empty result.diagnostics
    ensure
      File.chmod(0o644, unreadable) if defined?(unreadable) && File.exist?(unreadable)
    end

    def test_mcp_streamable_boot_loader_first_diagnostic_matches_the_fail_fast_raise
      path = write_config("mcpServers" => {"a" => {"cwd" => 3}, "z" => "nope"})
      raised = assert_raises(Mcp::Config::ConfigError) { Mcp::Config.load(path) }
      result = Mcp::Config.load_with_diagnostics(path)
      assert_equal raised.message, result.diagnostics.first,
                   "the lenient walk's FIRST diagnostic is byte-equal to the fail-fast raise"
      assert_equal 2, result.diagnostics.length, "every bad server names itself, not just the first"
    end

    private

    def write_config(body)
      path = File.join(@dir, "mcp-#{object_id}.json")
      File.write(path, body.is_a?(String) ? body : JSON.generate(body))
      path
    end

    def server_url(server)
      "http://127.0.0.1:#{server[:port]}/mcp"
    end

    def start_echo_server(extra_env = {})
      File.delete(@log_path) if File.exist?(@log_path)
      env = {"MCP_HTTP_ECHO_LOG" => @log_path}.merge(extra_env)
      stdin, stdout, _stderr, wait_thr = Open3.popen3(env, RUBY, ECHO_SERVER)
      line = stdout.gets
      raise "fixture server did not boot: #{line.inspect}" unless line&.start_with?("PORT=")

      ready = stdout.gets
      raise "fixture server not ready: #{ready.inspect}" unless ready&.strip == "READY"

      @fixture_pids << wait_thr.pid
      {port: line.delete_prefix("PORT=").strip.to_i, stdin:, stdout:}
    end

    def request_log
      return [] unless File.exist?(@log_path)

      File.readlines(@log_path).map { |line| JSON.parse(line) }
    end
  end
end
