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

    # The async-reactor IO::Buffer experimental warning never fires in print
    # mode (no in-reactor IO — the LLM work bridges to a worker thread and
    # print mode records no session), so its filter is unit-proven here:
    # exactly the IO::Buffer message dies, every other warning passes
    # through.
    def test_io_buffer_experimental_warning_is_filtered_others_pass_through
      sink = Class.new do
        attr_reader :seen

        def initialize = @seen = []

        def warn(message, **)
          @seen << message
        end
      end.new.extend(launcher_filter)

      # The realistic shape: ruby decorates the message with a file:line:
      # prefix and category :experimental (probed live on 4.0.7).
      sink.warn("somewhere.rb:10: warning: IO::Buffer is experimental and both " \
        "the Ruby and C interface may change in the future!\n", category: :experimental)
      sink.warn("some unrelated warning\n", category: nil)

      assert_equal ["some unrelated warning\n"], sink.seen
    end

    # bin/tart launches the agent on load, so it cannot be required — eval
    # its source minus the final run line to reach the filter module (the
    # launcher boot itself is covered by the child-process smoke above).
    def launcher_filter
      src = File.read(File.join(REPO_ROOT, "bin", "tart"))
        .sub(/^Tart::Executable\.run\(ARGV\)\n\z/, "")
      # Anchor the filename so bin/tart's require_relative resolves (it is
      # already loaded in-process and no-ops).
      eval(src, TOPLEVEL_BINDING, File.join(REPO_ROOT, "bin", "tart")) # rubocop:disable Security/Eval
      Executable::QuietIOBufferWarning
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
