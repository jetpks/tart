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
    # mode (print mode records no session and its LLM turns run on the same
    # fiber-scheduler-cooperative :net_http path as every mode — I50 de-bridge:
    # no worker-thread hop, no in-reactor buffer IO on this surface), so its
    # filter is unit-proven here: exactly the IO::Buffer message dies, every
    # other warning passes through.
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
      # The model metadata (pi footer.ts:226-258): the provider prefix is
      # pi's >1-available-provider gate — the port never renders it, so
      # footer_data carries no provider at all. The assumed glm resolves
      # reasoning-capable through the known-models table (the owner's
      # daily driver — pi's footer shows its level).
      refute data.key?(:provider), "no provider label — pi's single-provider fallthrough"
      assert data[:reasoning], "the assumed glm is reasoning-capable (the known-models table)"

      data = Executable.footer_data("/somewhere", settings.merge("thinkingLevel" => "off"), chat: chat)
      assert_equal "off", data[:thinking_level]
    ensure
      FileUtils.rm_rf(home)
    end

    # I40 AC2, the boot clamp (pi createSdk sdk.ts:271-279 — createSdk
    # clamps the boot level through the boot model for EVERY mode): the
    # session level fact (:thinking_level — the surface reader's fallback
    # AND the interactive loop ctor's level) is the settings value
    # CLAMPED through the boot model's composed facts, while the ·
    # default badge source (:default_thinking_level) stays UNCLAMPED (pi
    # badges getDefaultThinkingLevel() ?? DEFAULT raw —
    # thinking-selector.ts:71-72; an out-of-set default marks NO row).
    # Staged xhigh + a map-less reasoning boot model: the map-less rule
    # tops out at high (models.ts:1224-1231).
    def test_footer_data_clamps_the_boot_level_but_keeps_the_badge_source_raw
      launcher
      home = Dir.mktmpdir("tart-footer-home-")
      FileUtils.mkpath(home)
      File.write(File.join(home, "settings.json"), JSON.generate("thinkingLevel" => "xhigh"))
      settings = Settings.load(cwd: home, root: home).settings.merge("modelReasoning" => true)
      chat = RubyLLM.context do |config|
        config.openai_api_key = "k"
        config.openai_api_base = "http://localhost:1/v1"
      end.chat(model: "assumed-mapless-reasoner", provider: "openai",
               protocol: :chat_completions, assume_model_exists: true)

      data = Executable.footer_data("/somewhere", settings, chat: chat)
      assert_equal "high", data[:thinking_level],
        "the boot level clamps through the map-less rule (no known map for the id)"
      assert_equal "xhigh", data[:default_thinking_level], "the badge source stays unclamped"
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
    # interactive exit only ever runs on a terminal). The command word
    # follows the identity (I16).
    def test_resume_hint_shape_and_not_persisted_branch
      launcher
      recorder = Object.new.tap do |r|
        r.define_singleton_method(:persisted?) { true }
        r.define_singleton_method(:id) { "abc123" }
      end
      assert_equal "\e[2mTo resume this session:\e[0m tart --resume abc123",
        Executable.resume_hint(recorder, "tart")
      assert_equal "\e[2mTo resume this session:\e[0m pi --resume abc123",
        Executable.resume_hint(recorder, "pi"), "pi-mode's hint reads pi --resume"

      unpersisted = Object.new.tap do |r|
        r.define_singleton_method(:persisted?) { false }
        r.define_singleton_method(:id) { "abc123" }
      end
      assert_nil Executable.resume_hint(unpersisted, "tart"), "nothing when the session was never persisted"
      assert_nil Executable.resume_hint(nil, "tart"), "no recorder (boot failure) — nothing"
    end

    # The surface construction seam (I27): the launcher wires the loaded
    # models.json catalog into the chat surface — build_surface's catalog
    # is REQUIRED, so a launcher that forgets it fails loud at construction
    # instead of silently degenerating the /model menu to the boot model
    # (the defect the post-integration probe caught: the catalog was
    # threaded into build_chat/the handler/footer_data but not the
    # surface; the class-level tests inject models: directly and never
    # see the seam).
    def test_build_surface_threads_the_catalog_into_the_model_menu
      launcher
      home = Dir.mktmpdir("tart-surface-home-")
      FileUtils.mkdir_p(File.join(home, ".tart"))
      File.write(File.join(home, ".tart", "models.json"), <<~JSON)
        {"providers": {"mock": {"models": [{"id": "mock-1"}, {"id": "mock-2"}]}}}
      JSON
      models = Models.load(root: File.join(home, ".tart"))

      TUI.run(headless: true, viewport: :fullscreen, width: 40, screen_height: 24) do |session|
        surface = Executable.build_surface(session:, kernel: idle_kernel,
          skills: [], prompts: [], mcp_servers: {}, resume: nil,
          identity: Identity::DEFAULT, models: models)
        surface.open_model_menu

        assert surface.menu_open?, "the menu opens"
        assert_equal "mock-1", surface.menu_selection&.fetch(:id),
          "the menu lists the catalog (not the degenerate boot model)"
        surface.on_event(TUI.key_event("down"))
        assert_equal "mock-2", surface.menu_selection&.fetch(:id),
          "the second catalog entry is reachable — both staged models are in the menu"
      end
    ensure
      FileUtils.rm_rf(home)
    end

    # A render-idle kernel double (the menu assertions read state; the
    # render loop never runs) — chat_test's IdleKernel shape.
    def idle_kernel
      Object.new.tap do |k|
        k.define_singleton_method(:animate) { |**| nil }
        k.define_singleton_method(:request_draw) { nil }
      end
    end

    # AC2, the wiring proof: the real launcher composes the full harness
    # prompt onto the request — the I04-era terse string is gone from the
    # print path (the interactive path shares the seam; the s-rig runs
    # both). The system message carries every section: preamble, rules,
    # docs (pi's install paths), cwd.
    def test_print_boot_wires_the_composed_harness_prompt
      server = MockLLMServer.new.start
      server.script([{type: :message, content: "wired"}])
      home = Dir.mktmpdir("tart-prompt-home-")
      stdout, stderr, status = Open3.capture3(smoke_env(home, server),
        RbConfig.ruby, File.join(REPO_ROOT, "bin", "tart"), "-p", "hello",
        chdir: REPO_ROOT)

      assert_equal 0, status.exitstatus, "boot + run exit 0 (stderr: #{stderr})"
      system_message = server.captured_request_logs.first.fetch(:body)
        .fetch("messages").first.fetch("content")
      refute_includes system_message, "You are a coding assistant working in",
        "the terse prompt is gone"
      assert_includes system_message, "You are an expert coding assistant operating inside pi"
      assert_includes system_message, "<rules>"
      assert_includes system_message, "<docs>"
      assert_includes system_message, "<cwd>"
      refute_includes system_message, "<project_context>",
        "no context files in the staged home → no section (AC3, pi parity)"
    ensure
      server.stop
      FileUtils.rm_rf(home)
    end

    # AC1's foo smoke, end to end: the free-form identity boots print mode
    # through its OWN namespace (FOO_API_KEY/FOO_API_BASE) and the request
    # carries the foo-named preamble and the FOO_* env-rule bullet.
    def test_foo_identity_boots_through_its_own_env_namespace
      server = MockLLMServer.new.start
      server.script([{type: :message, content: "foo answer"}])
      home = Dir.mktmpdir("tart-foo-home-")
      stdout, stderr, status = Open3.capture3(
        {"PATH" => ENV.fetch("PATH", nil), "HOME" => home,
         "FOO_API_KEY" => "foo-key", "FOO_API_BASE" => server.url,
         "TART_MCP_CONFIG" => File.join(home, "absent-mcp.json")},
        RbConfig.ruby, File.join(REPO_ROOT, "bin", "tart"), "--identity", "foo",
        "-p", "hello", chdir: REPO_ROOT)

      assert_equal 0, status.exitstatus, "foo boots (stderr: #{stderr})"
      assert_includes stdout, "foo answer"
      system_message = server.captured_request_logs.first.fetch(:body)
        .fetch("messages").first.fetch("content")
      assert_includes system_message, "operating inside foo, a coding agent harness"
      assert_includes system_message, "You can inspect FOO_* environment variables"
    ensure
      server.stop
      FileUtils.rm_rf(home)
    end

    def smoke_env(home, server)
      {
        "PATH" => ENV.fetch("PATH", nil),
        "HOME" => home,
        "PI_API_KEY" => "smoke-key",
        "PI_API_BASE" => server.url,
        "TART_MCP_CONFIG" => File.join(home, "absent-mcp.json")
      }
    end
  end
end
