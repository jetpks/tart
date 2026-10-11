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

    # The launcher's wired footer hash (the frozen cross-lane contract): the
    # surface lane renders footer_data[:thinking_level] as "model • <level>"
    # (nil → model alone); the data side sources it from the thinkingLevel
    # setting. bin/tart cannot be required (it launches on load) — the same
    # eval-minus-run-line seam as launcher_filter reaches the module.
    def test_footer_data_carries_the_settings_resolved_thinking_level
      launcher_filter
      home = Dir.mktmpdir("tart-footer-home-")
      settings = Settings.load(cwd: home, root: home).settings
      chat = RubyLLM.context do |config|
        config.openai_api_key = "k"
        config.openai_api_base = "http://localhost:1/v1"
      end.chat(model: "accounts/fireworks/models/glm-5p3-flash", provider: "openai",
               protocol: :chat_completions, assume_model_exists: true)

      data = Executable.footer_data("/somewhere", settings, chat: chat)
      assert_equal "/somewhere", data[:cwd]
      assert_equal "medium", data[:thinking_level]
      assert data.key?(:model) && data.key?(:context_window) && data.key?(:auto_compact)

      data = Executable.footer_data("/somewhere", settings.merge("thinkingLevel" => "off"), chat: chat)
      assert_equal "off", data[:thinking_level]
    ensure
      FileUtils.rm_rf(home)
    end

    # bin/tart launches the agent on load, so it cannot be required — eval
    # its source minus the final run line to reach the module (the
    # launcher boot itself is covered by the child-process smoke above).
    def launcher
      src = File.read(File.join(REPO_ROOT, "bin", "tart"))
        .sub(/^Tart::Executable\.run\(ARGV\)\n\z/, "")
      # Anchor the filename so bin/tart's require_relative resolves (it is
      # already loaded in-process and no-ops).
      eval(src, TOPLEVEL_BINDING, File.join(REPO_ROOT, "bin", "tart")) # rubocop:disable Security/Eval
      Executable
    end

    def launcher_filter
      launcher
      Executable::QuietIOBufferWarning
    end

    # The exit resume hint (item 1/AC1, pi formatResumeCommand
    # interactive-mode.ts:339-355 + the :4324 print): exact shape (dim
    # label, plain command) when the session was persisted; nothing when
    # not (pi's isPersisted gate; the isTTY gate is itemized — the port's
    # interactive exit only ever runs on a terminal).
    def test_resume_hint_shape_and_not_persisted_branch
      launcher
      recorder = Object.new.tap do |r|
        r.define_singleton_method(:persisted?) { true }
        r.define_singleton_method(:id) { "abc123" }
      end
      assert_equal "\e[2mTo resume this session:\e[0m tart --resume abc123", Executable.resume_hint(recorder)

      unpersisted = Object.new.tap do |r|
        r.define_singleton_method(:persisted?) { false }
        r.define_singleton_method(:id) { "abc123" }
      end
      assert_nil Executable.resume_hint(unpersisted), "nothing when the session was never persisted"
      assert_nil Executable.resume_hint(nil), "no recorder (boot failure) — nothing"
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
