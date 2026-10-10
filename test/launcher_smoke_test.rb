# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/mock_llm_server"
require "open3"
require "tmpdir"
require "fileutils"

module Tart
  # The launcher boot smoke test (AC5): the real `bin/tart -p` boots
  # end-to-end against the MockLLMServer through the env seam
  # (TART_API_KEY/TART_API_BASE) and writes the final response to stdout.
  # The pin for the first-live-boot defect class — I10 shipped all gates
  # green while the first real boot crashed (a Settings::Result unwrap,
  # fixed in 53a08db); no test booted the launcher itself. Hermetic: HOME
  # points at a tmpdir so ~/.tart is never touched, and TART_MCP_CONFIG
  # points at an absent path so no real MCP config loads.
  class LauncherSmokeTest < Test
    REPO_ROOT = File.expand_path("#{__dir__}/..")

    def test_print_boots_the_real_launcher_end_to_end
      server = MockLLMServer.new.start
      server.script([{type: :message, content: "smoke answer"}])

      home = Dir.mktmpdir("tart-smoke-home-")
      stdout, stderr, status = Open3.capture3(smoke_env(home, server),
        RbConfig.ruby, File.join(REPO_ROOT, "bin", "tart"), "-p", "say the magic word",
        chdir: REPO_ROOT)

      assert_equal 0, status.exitstatus, "boot + run exit 0 (stderr: #{stderr})"
      assert_includes stdout, "smoke answer", "the final response lands on stdout"
    ensure
      server.stop
      FileUtils.rm_rf(home)
    end

    def smoke_env(home, server)
      {
        "PATH" => ENV.fetch("PATH", nil),
        "HOME" => home,
        "TART_API_KEY" => "smoke-key",
        "TART_API_BASE" => server.url,
        "TART_MCP_CONFIG" => File.join(home, "absent-mcp.json")
      }
    end
  end
end
