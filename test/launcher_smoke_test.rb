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
      chat = Agent::Chat.new(
        client: Fast::Completions::Client.new(base_url: "http://localhost:1/v1", api_key: "k"),
        model_id: "accounts/fireworks/models/glm-5p3-flash", provider_key: "openai")

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
      chat = Agent::Chat.new(
        client: Fast::Completions::Client.new(base_url: "http://localhost:1/v1", api_key: "k"),
        model_id: "assumed-mapless-reasoner", provider_key: "openai")

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

    # --- I59 zai_max_tokens: the Face-2 regression bar at the REAL boot
    # (P3 — real `bin/tart -p` subprocess, staged HOME, MockLLMServer) ---

    # The scrubbed boot env: the model-shaping env tiers are UNSET so the
    # leg decides the boot model (Process.spawn merges the parent env — a
    # CI/agent parent carrying PI_MODEL/PI_PROVIDER must not leak in).
    def wire_env(home, server)
      smoke_env(home, server).merge(
        "PI_MODEL" => nil, "PI_PROVIDER" => nil,
        "TART_MODEL" => nil, "TART_PROVIDER" => nil,
        "PI_CONTEXT_WINDOW" => nil, "TART_CONTEXT_WINDOW" => nil)
    end

    # P3(i) — the catalog leg: a staged ~/.tart/models.json (provider mock
    # pointing at the mock server, glm-5.3 window 131_072 cap 131_072,
    # declared default) and NO context-window env — the boot threads the
    # entry's pair and the request sends min(cap, window − est − 4096):
    # an Integer in (120_000, 131_072] — never 1. The harness prompt's
    # estimate is checkout-depth-sensitive, so the RANGE is the
    # path-robust exact bar (Face 2 sends exactly 1 — five orders of
    # magnitude of discrimination).
    def test_zai_max_tokens_staged_catalog_boot_sends_the_capped_max
      server = MockLLMServer.new.start
      server.script([{type: :message, content: "capped"}])
      home = Dir.mktmpdir("tart-maxtok-home-")
      FileUtils.mkdir_p(File.join(home, ".tart"))
      File.write(File.join(home, ".tart", "models.json"), JSON.generate(
        "default" => "mock/glm-5.3",
        "providers" => {
          "mock" => {"name" => "Mock", "baseUrl" => server.url, "apiKey" => "k",
                     "models" => [{"id" => "glm-5.3", "contextWindow" => 131_072,
                                   "maxTokens" => 131_072}]}
        }))
      stdout, stderr, status = Open3.capture3(wire_env(home, server),
        RbConfig.ruby, File.join(REPO_ROOT, "bin", "tart"), "-p", "hello",
        chdir: REPO_ROOT)

      assert_equal 0, status.exitstatus, "the staged-catalog boot runs (stderr: #{stderr})"
      max = server.captured_request_logs.first.fetch(:body).fetch("max_completion_tokens")
      assert_kind_of Integer, max
      assert_operator max, :>, 120_000, "the clamp's safety margin is the only deduction"
      assert_operator max, :<=, 131_072, "the catalog cap bounds the send"
      refute_equal 1, max, "Face 2 (the one-token boot) is cured on the real boot"
    ensure
      server&.stop
      FileUtils.rm_rf(home)
    end

    # P3(ii) — the no-entry leg: no models.json, an env-tier boot model in
    # no known table, no context-window env — today's chain lands wire 0/0
    # and the request sends max_tokens 1 (the DECLARED fallback, pinned at
    # the real boot; Grounds §4-b).
    def test_zai_max_tokens_no_entry_boot_still_sends_one
      server = MockLLMServer.new.start
      server.script([{type: :message, content: "fallback"}])
      home = Dir.mktmpdir("tart-maxtok-none-")
      stdout, stderr, status = Open3.capture3(
        wire_env(home, server).merge("PI_MODEL" => "custom-x", "PI_PROVIDER" => "openai"),
        RbConfig.ruby, File.join(REPO_ROOT, "bin", "tart"), "-p", "hello",
        chdir: REPO_ROOT)

      assert_equal 0, status.exitstatus, "the entry-less boot runs (stderr: #{stderr})"
      assert_equal 1, server.captured_request_logs.first.fetch(:body).fetch("max_completion_tokens"),
        "the no-entry chain keeps today's exact fallback shape"
    ensure
      server&.stop
      FileUtils.rm_rf(home)
    end

    # I65 D3 (the footer context window `?` — the I59 D4 asymmetry):
    # footer_data's context_window carries the SAME fallback the loop
    # kwarg (bin/tart :475) and the print boot (:325) already carry —
    # Settings.resolve_context_window(...) || Models.entry_context_window(entry).
    # A staged zai/glm-5.3 catalog entry declaring contextWindow 1_000_000
    # resolves from the FIRST frame (the boot snapshots footer_data before
    # Agent::Loop exists — chat.model is the placeholder ModelFacts with a
    # nil window, and the segment renders "?" on nil), identical in value
    # to the loop kwarg's expression; the env tier (PI_CONTEXT_WINDOW,
    # identity-namespaced) still wins over the entry; the models-nil legacy
    # shape keeps window nil.
    def test_footer_data_carries_the_boot_entry_context_window_and_env_still_wins
      launcher
      # The boot's env tier outranks the staged catalog (PI_MODEL/PI_PROVIDER
      # name a boot pair without an entry) — neutralize the boot-relevant
      # PI_* tiers exactly like the frozen footer-window gate's env-strip
      # prefix; restored in ensure.
      pi_keys = %w[PI_MODEL PI_PROVIDER PI_CONTEXT_WINDOW PI_MODEL_REASONING PI_API_KEY PI_API_BASE]
      saved_env = pi_keys.to_h { |key| [key, ENV[key]] }
      home = nil
      pi_keys.each { |key| ENV.delete(key) }
      home = Dir.mktmpdir("tart-footer-window-")
      FileUtils.mkdir_p(File.join(home, ".tart"))
      File.write(File.join(home, ".tart", "models.json"), JSON.generate(
        "default" => "zai/glm-5.3",
        "providers" => {"zai" => {"name" => "ZAI", "baseUrl" => "http://localhost:1/v1", "apiKey" => "k",
                                  "models" => [{"id" => "glm-5.3", "contextWindow" => 1_000_000,
                                                "maxTokens" => 65_536}]}}))
      settings = Settings.load(cwd: home, root: home).settings
      models = Models.load(root: File.join(home, ".tart"))
      resolved = Shapes::ResolvedSettings.from_load(settings, identity: Identity::DEFAULT)
      boot = Models.resolve_boot_model(models, settings, identity: Identity::DEFAULT)
      chat = Agent::Chat.new(
        client: Fast::Completions::Client.new(base_url: "http://localhost:1/v1", api_key: "k"),
        model_id: boot.id, provider_key: boot.provider)

      data = Executable.footer_data(home, settings, boot:, chat:, identity: Identity::DEFAULT,
                                    models:, resolved:)
      loop_window = Settings.resolve_context_window(settings:, model: chat.model,
        identity: Identity::DEFAULT) || Models.entry_context_window(Executable.resolve_boot_entry(models, boot))
      assert_equal 1_000_000, data[:context_window], "the entry window resolves from the first frame (no ?)"
      assert_equal loop_window, data[:context_window],
        "identical in value to the loop kwarg's expression (one asymmetry measurement)"

      # The models-nil legacy call sites keep today's behavior: no catalog,
      # no entry, and a nil Settings ladder — the window stays nil (Footer
      # #context_segment renders ?).
      legacy = Executable.footer_data("/somewhere", settings, chat: chat)
      assert_nil legacy[:context_window], "entry nil without a catalog — the legacy shape"

      ENV["PI_CONTEXT_WINDOW"] = "999"
      data = Executable.footer_data(home, settings, boot:, chat:, identity: Identity::DEFAULT,
                                    models:, resolved:)
      assert_equal 999, data[:context_window], "the env tier still wins over the entry"
    ensure
      saved_env&.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
      FileUtils.rm_rf(home)
    end
  end
end
