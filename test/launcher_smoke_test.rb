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
      # Pin the boot pair: legacy shape resolves it from env > models.json >
      # settings, so the clamp outcome otherwise rides whatever model the
      # HOST resolves (a dev box with PI_MODEL set clamps; a clean runner
      # resolves the catalogue default, which carries a full xhigh map and
      # does not).
      boot = Shapes::ModelRef.new(provider: "openai", id: "assumed-mapless-reasoner")

      data = Executable.footer_data("/somewhere", settings, boot:, chat:, identity: "pi")
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

    # The I71 R5 launcher threading (the I27 live-defect lesson): the
    # build_surface endpoint: parameter threads the boot endpoint facts
    # into the surface — a staged catalog + a mock listing server through
    # build_surface, and the menu merges the listed rows.
    def test_build_surface_threads_the_listing_endpoint
      # I107 (OQ5): the scenario rides a Sync-wrapped host reactor —
      # the migrated workers are reactor tasks. Same name, same assertions.
      Sync do
        server = MockLLMServer.new.start
        server.script([{type: :models, ids: ["mock-3"]}])
        launcher
        home = Dir.mktmpdir("tart-surface-home-")
        FileUtils.mkdir_p(File.join(home, ".tart"))
        File.write(File.join(home, ".tart", "models.json"), JSON.generate({"default" => "mock/mock-1",
          "providers" => {"mock" => {"baseUrl" => server.url, "apiKey" => "k",
            "models" => [{"id" => "mock-1"}]}}}))
        models = Models.load(root: File.join(home, ".tart"))

        TUI.run(headless: true, viewport: :fullscreen, width: 40, screen_height: 24) do |session|
          resolved = Shapes::ResolvedSettings.from_load(Settings.load(cwd: home), identity: Identity::DEFAULT)
          boot = Models.resolve_boot_model(models, {}, identity: Identity::DEFAULT)
          surface = Executable.build_surface(session:, kernel: idle_kernel,
            skills: [], prompts: [], mcp_servers: {}, resume: nil,
            identity: Identity::DEFAULT, models: models,
            endpoint: Executable.endpoint_facts(models, boot, identity: Identity::DEFAULT, resolved:))
          # The launcher threads the footer facts right after construction
          # (the boot pair drives the menu's ✓ marker AND the listing's
          # provider resolution) — the build_surface seam under test is the
          # endpoint tier.
          surface.footer_data = {cwd: home, model: boot.id, default_provider: boot.provider}

          surface.open_model_menu
          # The fetch fires on the listing thread — await the arrival (B:
          # the MockLLMServer request gate; was the 5 s wall #1).
          await(server, "the listing fetch to arrive") { server.request_count == 1 }
          # The merge lands on the listing thread — await the merge event
          # (A: the L1 broadcast at merge_listing; was the 5 s wall #2 —
          # the F1 load-flake's race dies with the wall).
          await(surface, "the listing merge into the menu") do
            menu = surface.instance_variable_get(:@menu)
            menu && menu.instance_variable_get(:@filtered).map { |item| item[:id] }.include?("mock-3")
          end

          menu = surface.instance_variable_get(:@menu)
          ids = menu.instance_variable_get(:@filtered).map { |item| item[:id] }
          assert_includes ids, "mock-1", "the staged catalog entry renders immediately"
          assert_includes ids, "mock-3", "the listed id merged in — the endpoint threaded through build_surface"
          assert_equal 1, server.request_count, "ONE fetch per menu open"
        end
      ensure
        server.stop
        FileUtils.rm_rf(home)
      end
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
      pi_bin = stage_pi_install(home)
      stdout, stderr, status = Open3.capture3(smoke_env(home, server).merge("PATH" => "#{pi_bin}:#{ENV.fetch('PATH', '')}"),
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

    # I69 new pin (owner ruling 2026-10-17): the DEFAULT-mode real boot —
    # no TART_IDENTITY staged, TART_* env only — resolves tart and reaches
    # the wire with the tart preamble and the TART_* namespace bullet.
    def test_default_mode_boot_speaks_the_tart_preamble_and_tart_namespace
      server = MockLLMServer.new.start
      server.script([{type: :message, content: "ok"}])
      home = Dir.mktmpdir("tart-default-boot-")
      # The staged env carries ONLY the default-mode keys: TART_API_KEY /
      # TART_API_BASE name the mock (the resolved tart identity's
      # namespace); every identity-ish env tier is nil-scrubbed so nothing
      # rides the parent (a herdr pane's TART_IDENTITY must not leak in).
      stdout, stderr, status = Open3.capture3(
        {"PATH" => ENV.fetch("PATH", nil), "HOME" => home,
         "TART_MCP_CONFIG" => File.join(home, "absent-mcp.json"),
         "TART_API_KEY" => "default-key", "TART_API_BASE" => server.url,
         "TART_IDENTITY" => nil, "TART_MODEL" => nil, "TART_PROVIDER" => nil,
         "TART_CONTEXT_WINDOW" => nil, "TART_MODEL_REASONING" => nil,
         "PI_MODEL" => nil, "PI_PROVIDER" => nil, "PI_API_KEY" => nil,
         "PI_API_BASE" => nil, "PI_CONTEXT_WINDOW" => nil, "PI_MODEL_REASONING" => nil},
        RbConfig.ruby, File.join(REPO_ROOT, "bin", "tart"), "-p", "hello",
        chdir: REPO_ROOT)

      assert_equal 0, status.exitstatus, "the default-mode boot runs (stderr: #{stderr})"
      system_message = server.captured_request_logs.first.fetch(:body)
        .fetch("messages").first.fetch("content")
      assert_includes system_message, "operating inside tart, a coding agent harness",
        "the default identity's preamble"
      assert_includes system_message, "You can inspect TART_* environment variables",
        "the env namespace follows the resolved default"
      refute_includes system_message, "You can inspect PI_* environment variables",
        "no pi namespace leaks into the default boot"
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

    # A self-contained pi install for the <docs> walk (pi_docs_paths:
    # realpath the pi on PATH, up to the package.json carrying the pi
    # package name). Real runners have no pi installed — the prompt would
    # omit <docs> and the test would be host-coupled.
    def stage_pi_install(home)
      install = File.join(home, "pi-install")
      FileUtils.mkpath(File.join(install, "bin"))
      FileUtils.mkpath(File.join(install, "docs"))
      FileUtils.mkpath(File.join(install, "examples"))
      File.write(File.join(install, "bin", "pi"), "#!/bin/sh\nexit 0\n")
      File.chmod(0o755, File.join(install, "bin", "pi"))
      File.write(File.join(install, "package.json"),
        JSON.generate("name" => Agent::SystemPrompt::PI_PACKAGE))
      File.write(File.join(install, "README.md"), "staged pi readme\n")
      File.join(install, "bin")
    end

    # --- I120 provider-swap: build_chat through the registry + the /new
    # --- carryover chain ---

    # The BOOT arm is byte-held: the env tier wins first, the client lands
    # in the per-provider registry cache (the switch-back reuse seat), and
    # the Chat carries the resolved key + boot facts.
    def test_provider_swap_build_chat_boot_arm_seeds_the_registry
      launcher
      Tart::Endpoints.clear_cache
      home = Dir.mktmpdir("tart-i120-boot-")
      models = stage_two_provider_catalog(home, "http://a.test/v1", "http://b.test/v1")
      resolved = Shapes::ResolvedSettings.from_load({}, identity: "pi", env: {})
      boot = Shapes::ModelRef.new(provider: "alpha", id: "a-1")
      chat = Executable.build_chat(models, boot, identity: "pi", resolved:,
        env: {"PI_API_KEY" => "launcher-pin"})

      assert_equal "launcher-pin", chat.endpoint[:api_key], "the env tier wins at boot"
      assert_equal "alpha", chat.endpoint[:provider], "the boot facts name the provider"
      cached = Tart::Endpoints.provide("alpha", models: models, env: {"PI_API_KEY" => "launcher-pin"})
      assert_same cached.fetch(:client), chat.client, "the boot client IS the registry's cached entry"
    ensure
      Tart::Endpoints.clear_cache
      FileUtils.rm_rf(home)
    end

    # The CARRY arm (a /new that carries a DIFFERENT provider's pair):
    # build_chat resolves the carried provider through the MID-SESSION
    # chain — never the identity env tier (the launcher pin governs its
    # own provider only) — and the chat posts to the CARRIED provider with
    # ITS key.
    def test_provider_swap_build_chat_carry_arm_resolves_the_carried_provider
      launcher
      Tart::Endpoints.clear_cache
      home = Dir.mktmpdir("tart-i120-carry-")
      models = stage_two_provider_catalog(home, "http://a.test/v1", "http://b.test/v1")
      resolved = Shapes::ResolvedSettings.from_load({}, identity: "pi", env: {})
      carried = Shapes::ModelRef.new(provider: "beta", id: "b-1")
      chat = Executable.build_chat(models, carried, identity: "pi", resolved:,
        settings: {"apiKey" => nil}, boot_provider: "alpha",
        env: {"PI_API_KEY" => "launcher-pin", "PI_API_BASE" => "http://a.test/v1"})

      assert_equal "beta-key", chat.endpoint[:api_key], "BETA's block key — never the launcher pin"
      assert_equal "http://b.test/v1", chat.endpoint[:api_base], "BETA's own base — never the pin base"
      assert_equal "beta", chat.endpoint[:provider]
      assert_nil chat.instance_variable_get(:@request_error)
    ensure
      Tart::Endpoints.clear_cache
      FileUtils.rm_rf(home)
    end

    # The carry arm's never-raise discipline (I119 at the /new seat): a
    # carried provider whose key does not resolve boots KEYLESS with the
    # named error carried — /new never crashes the session.
    def test_provider_swap_build_chat_carry_arm_never_raises
      launcher
      Tart::Endpoints.clear_cache
      home = Dir.mktmpdir("tart-i120-carrynr-")
      FileUtils.mkdir_p(File.join(home, ".tart"))
      File.write(File.join(home, ".tart", "models.json"), JSON.generate(
        "providers" => {"alpha" => {"baseUrl" => "http://a.test/v1", "apiKey" => "alpha-key",
          "models" => [{"id" => "a-1"}]},
          "gamma" => {"baseUrl" => "http://g.test/v1", "apiKey" => "$GAMMA_KEY",
            "models" => [{"id" => "g-1"}]}}))
      models = Models.load(root: File.join(home, ".tart"))
      resolved = Shapes::ResolvedSettings.from_load({}, identity: "pi", env: {})
      carried = Shapes::ModelRef.new(provider: "gamma", id: "g-1")
      chat = Executable.build_chat(models, carried, identity: "pi", resolved:,
        settings: {"apiKey" => nil}, boot_provider: "alpha", env: {})

      assert_nil chat.endpoint[:api_key], "the unresolvable carried key boots keyless"
      assert_instance_of ConfigValue::UnresolvedError, chat.instance_variable_get(:@request_error),
        "the named failure is CARRIED for the first request (never a raise)"
    ensure
      Tart::Endpoints.clear_cache
      FileUtils.rm_rf(home)
    end

    # The /new boot-ref helper: the surface's CURRENT model ref rides as
    # the boot override when one answers (a /model switch's pair survives
    # /new); no surface (or a surface with no ref) falls to today's boot
    # tiers.
    def test_provider_swap_new_session_boot_ref_threads_the_current_pair
      launcher
      home = Dir.mktmpdir("tart-i120-newref-")
      models = stage_two_provider_catalog(home, "http://a.test/v1", "http://b.test/v1")
      surface = Object.new
      surface.define_singleton_method(:runtime_model_ref) do
        Struct.new(:provider, :id).new("beta", "b-1")
      end
      carried = Executable.new_session_boot_ref(surface, models, {}, identity: "pi")
      assert_equal "beta", carried.provider, "the surface's current ref rode"
      assert_equal "b-1", carried.id

      no_switch = Object.new
      no_switch.define_singleton_method(:runtime_model_ref) { nil }
      unswitched = Executable.new_session_boot_ref(no_switch, models, {}, identity: "pi")
      assert_equal "alpha", unswitched.provider, "a surface with NO runtime switch falls to the boot tiers"
      assert_equal "a-1", unswitched.id

      fresh = Executable.new_session_boot_ref(nil, models, {"defaultProvider" => "alpha",
        "defaultModel" => "a-1"}, identity: "pi")
      assert_equal "alpha", fresh.provider, "no surface → today's boot tiers"
      assert_equal "a-1", fresh.id
    ensure
      FileUtils.rm_rf(home)
    end

    # A staged TWO-provider catalog (the registry's cross-provider arms):
    # alpha + beta, each with its own base and literal key.
    def stage_two_provider_catalog(home, alpha_base, beta_base)
      FileUtils.mkdir_p(File.join(home, ".tart"))
      File.write(File.join(home, ".tart", "models.json"), JSON.generate(
        "default" => "alpha/a-1",
        "providers" => {
          "alpha" => {"baseUrl" => alpha_base, "apiKey" => "alpha-key", "models" => [{"id" => "a-1"}]},
          "beta" => {"baseUrl" => beta_base, "apiKey" => "beta-key", "models" => [{"id" => "b-1"}]}
        }))
      Models.load(root: File.join(home, ".tart"))
    end

    # --- I119 env-templates: `endpoint_facts` resolves the provider block's
    # apiKey at the USE seam (never at load), on an injected env ---

    # The in-process seam: a pi-copied catalog (`"$FIREWORKS_API_KEY"`) with
    # the variable in the injected env resolves; the boot's three threadings
    # (build_chat, the surface, the subagents Manager) all read this hash.
    def test_env_template_endpoint_facts_resolves_a_templated_api_key_from_the_injected_env
      launcher
      home = Dir.mktmpdir("tart-i119-facts-")
      models = stage_templated_catalog(home, "$FIREWORKS_API_KEY")
      resolved = Shapes::ResolvedSettings.from_load({}, identity: "pi", env: {})
      boot = Models.resolve_boot_model(models, {}, identity: "pi", env: {})
      facts = Executable.endpoint_facts(models, boot, identity: "pi", resolved:,
        env: {"FIREWORKS_API_KEY" => "resolved-secret"})

      assert_equal "resolved-secret", facts[:api_key]
      assert_nil facts[:api_key_error]
      assert_equal "http://mock.test/v1", facts[:api_base]
    ensure
      FileUtils.rm_rf(home)
    end

    # An unset OR empty-string variable (pi :89) is the NAMED failure carried
    # for the first request — api_key nil, the error's message is pi's exact
    # string — and the settings view's apiKey (staged) never fills in.
    def test_env_template_endpoint_facts_carries_the_named_failure_for_an_unresolvable_template
      launcher
      home = Dir.mktmpdir("tart-i119-unres-")
      models = stage_templated_catalog(home, "$FIREWORKS_API_KEY")
      resolved = Shapes::ResolvedSettings.from_load({"apiKey" => "settings-key-must-not-fill-in"}, identity: "pi", env: {})
      boot = Models.resolve_boot_model(models, {}, identity: "pi", env: {})

      facts = Executable.endpoint_facts(models, boot, identity: "pi", resolved:, env: {})
      assert_nil facts[:api_key], "no key reaches the client"
      assert_kind_of ConfigValue::UnresolvedError, facts[:api_key_error]
      assert_equal 'Failed to resolve API key for provider "mock" from environment variable: FIREWORKS_API_KEY',
        facts[:api_key_error].message

      facts = Executable.endpoint_facts(models, boot, identity: "pi", resolved:, env: {"FIREWORKS_API_KEY" => ""})
      assert_nil facts[:api_key], "an empty-string variable counts as unset"
      assert_equal 'Failed to resolve API key for provider "mock" from environment variable: FIREWORKS_API_KEY',
        facts[:api_key_error].message
    ensure
      FileUtils.rm_rf(home)
    end

    # The `!command` cut: a leading-`!` apiKey is neither executed nor sent —
    # the carried error is tart's named message and the canary stays uncreated.
    def test_env_template_endpoint_facts_carries_the_command_cut_error
      launcher
      home = Dir.mktmpdir("tart-i119-cmd-")
      canary = File.join(home, "canary")
      models = stage_templated_catalog(home, "!touch #{canary}")
      resolved = Shapes::ResolvedSettings.from_load({}, identity: "pi", env: {})
      boot = Models.resolve_boot_model(models, {}, identity: "pi", env: {})
      facts = Executable.endpoint_facts(models, boot, identity: "pi", resolved:, env: {"PATH" => ENV["PATH"]})

      assert_nil facts[:api_key]
      assert_kind_of ConfigValue::CommandConfigValueError, facts[:api_key_error]
      assert_equal 'Failed to resolve API key for provider "mock": "!command" values are not supported — ' \
        'use a "$VAR" or "${VAR}" reference or the <IDENTITY>_API_KEY environment override',
        facts[:api_key_error].message
      refute File.exist?(canary), "the command never ran"
    ensure
      FileUtils.rm_rf(home)
    end

    # Precedence unchanged otherwise (1): the <IDENTITY>_API_KEY env tier wins
    # BEFORE the provider's key is consulted — a template naming an unset
    # variable is never even looked at when the env tier is set.
    def test_env_template_precedence_env_tier_wins_before_the_template
      launcher
      home = Dir.mktmpdir("tart-i119-prec1-")
      models = stage_templated_catalog(home, "$FIREWORKS_API_KEY")
      resolved = Shapes::ResolvedSettings.from_load({}, identity: "pi", env: {})
      boot = Models.resolve_boot_model(models, {}, identity: "pi", env: {})
      facts = Executable.endpoint_facts(models, boot, identity: "pi", resolved:, env: {"PI_API_KEY" => "env-tier-key"})

      assert_equal "env-tier-key", facts[:api_key]
      assert_nil facts[:api_key_error], "the unresolvable template was never consulted"
    ensure
      FileUtils.rm_rf(home)
    end

    # Precedence unchanged otherwise (2): a literal key rides verbatim (an
    # escaped `$$` included); baseUrl never expands; the settings view's
    # apiKey is reached ONLY when the block declares none, and is itself
    # never expanded.
    def test_env_template_precedence_literal_key_settings_fallback_and_base_url_stay_verbatim
      launcher
      home = Dir.mktmpdir("tart-i119-prec2-")
      env = {"BASE" => "http://expanded.test/v1", "SETTINGS_KEY" => "expanded-settings"}
      literal = stage_templated_catalog(home, "sk-$$literal")
      resolved = Shapes::ResolvedSettings.from_load({}, identity: "pi", env: {})
      boot = Models.resolve_boot_model(literal, {}, identity: "pi", env: {})
      facts = Executable.endpoint_facts(literal, boot, identity: "pi", resolved:, env:)
      assert_equal "sk-$literal", facts[:api_key], "a literal rides verbatim (the escape is pi's)"
      assert_nil facts[:api_key_error]

      # The block declares NO apiKey and a templated baseUrl: today's chain
      # falls to the settings view — literal — and baseUrl never expands.
      blockless = Models.load(root: stage_blockless_catalog(home))
      boot2 = Models.resolve_boot_model(blockless, {}, identity: "pi", env: {})
      resolved2 = Shapes::ResolvedSettings.from_load({"apiKey" => "$SETTINGS_KEY"},
        identity: "pi", env: {})
      facts = Executable.endpoint_facts(blockless, boot2, identity: "pi", resolved: resolved2, env:)
      assert_equal "$SETTINGS_KEY", facts[:api_key], "settings.json is out of scope — never expanded"
      assert_nil facts[:api_key_error]
      assert_equal "$BASE", facts[:api_base], "baseUrl never expands (the env has BASE set)"
    ensure
      FileUtils.rm_rf(home)
    end

    # The REAL launcher (print boot, staged HOME, explicit subprocess env):
    # the hermetic mock receives `Authorization: Bearer <resolved>` — the
    # owner's pi-copied catalog works (I46 OQ-3 closed).
    def test_env_template_print_boot_sends_the_resolved_key_on_the_wire
      server = MockLLMServer.new.start
      server.script([{type: :message, content: "templated answer"}])
      home = Dir.mktmpdir("tart-i119-wire-")
      stage_templated_catalog(home, "$FIREWORKS_API_KEY", base_url: server.url)
      stdout, stderr, status = Open3.capture3(templated_env(home).merge("FIREWORKS_API_KEY" => "resolved-secret"),
        RbConfig.ruby, File.join(REPO_ROOT, "bin", "tart"), "-p", "say the magic word", chdir: REPO_ROOT)

      assert_equal 0, status.exitstatus, "the templated boot runs (stderr: #{stderr})"
      assert_equal "templated answer\n", stdout
      assert_equal "Bearer resolved-secret", server.captured_request_logs.first.fetch(:headers)["authorization"],
        "the mock receives the RESOLVED key, never the literal template"
    ensure
      server&.stop
      FileUtils.rm_rf(home)
    end

    # The named failure on print's existing bad-key surface: the FIRST request
    # fails — exit 1, pi's exact line on stderr, nothing on stdout, NO request
    # reaches the mock, no fall-through to settings' apiKey (staged).
    def test_env_template_print_boot_fails_the_first_request_named_without_a_request
      server = MockLLMServer.new.start
      home = Dir.mktmpdir("tart-i119-named-")
      stage_templated_catalog(home, "$FIREWORKS_API_KEY")
      File.write(File.join(home, ".tart", "settings.json"), JSON.generate("apiKey" => "settings-key-must-not-fall-through"))
      stdout, stderr, status = Open3.capture3(templated_env(home),
        RbConfig.ruby, File.join(REPO_ROOT, "bin", "tart"), "-p", "say the magic word", chdir: REPO_ROOT)

      assert_equal 1, status.exitstatus
      assert_empty stdout
      assert_equal "Failed to resolve API key for provider \"mock\" from environment variable: FIREWORKS_API_KEY\n", stderr
      assert_equal 0, server.request_count, "the literal template never reaches the wire"
    ensure
      server&.stop
      FileUtils.rm_rf(home)
    end

    # A pi-copied catalog under a staged HOME (provider mock, declared default,
    # the given apiKey) — the only key source in these legs (no env tier).
    def stage_templated_catalog(home, api_key, base_url: "http://mock.test/v1")
      FileUtils.mkdir_p(File.join(home, ".tart"))
      File.write(File.join(home, ".tart", "models.json"), JSON.generate(
        "default" => "mock/mock-1",
        "providers" => {"mock" => {"baseUrl" => base_url, "apiKey" => api_key,
          "models" => [{"id" => "mock-1"}]}}))
      Models.load(root: File.join(home, ".tart"))
    end

    def stage_blockless_catalog(home)
      root = File.join(home, "blockless")
      FileUtils.mkdir_p(root)
      File.write(File.join(root, "models.json"), JSON.generate(
        "default" => "mock/mock-1",
        "providers" => {"mock" => {"baseUrl" => "$BASE", "models" => [{"id" => "mock-1"}]}}))
      root
    end

    # The print-boot subprocess env for the templated legs: staged HOME, the
    # pi identity, NO <IDENTITY>_API_KEY, the model tiers nil-scrubbed so the
    # catalog's default decides, MCP absent.
    def templated_env(home)
      {"PATH" => ENV.fetch("PATH", nil), "HOME" => home, "TART_IDENTITY" => "pi",
       "TART_MCP_CONFIG" => File.join(home, "absent-mcp.json"),
       "PI_MODEL" => nil, "PI_PROVIDER" => nil, "TART_MODEL" => nil, "TART_PROVIDER" => nil,
       "PI_CONTEXT_WINDOW" => nil, "TART_CONTEXT_WINDOW" => nil}
    end

    def smoke_env(home, server)
      {
        "PATH" => ENV.fetch("PATH", nil),
        "HOME" => home,
        # I69 move: the real-boot pins test the PI_-parity opt-in — stage
        # the identity EXPLICITLY so the (now tart) default never rides.
        "TART_IDENTITY" => "pi",
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
      # prefix; restored in ensure. I69 move: the scrub gains the TART_*
      # model-shaping keys (the RESOLVED DEFAULT identity reads TART_* —
      # the frozen gate's prefix carries both families).
      pi_keys = %w[PI_MODEL PI_PROVIDER PI_CONTEXT_WINDOW PI_MODEL_REASONING PI_API_KEY PI_API_BASE
        TART_MODEL TART_PROVIDER TART_CONTEXT_WINDOW TART_MODEL_REASONING TART_API_KEY TART_API_BASE]
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

      # I69 move: the env tier rides the RESOLVED DEFAULT identity's key
      # (tart → TART_CONTEXT_WINDOW; pre-flip the default was pi).
      ENV["TART_CONTEXT_WINDOW"] = "999"
      data = Executable.footer_data(home, settings, boot:, chat:, identity: Identity::DEFAULT,
                                    models:, resolved:)
      assert_equal 999, data[:context_window], "the env tier still wins over the entry"
    ensure
      saved_env&.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
      FileUtils.rm_rf(home)
    end
  end
end
