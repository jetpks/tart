# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/mock_llm_server"
require "tmpdir"
require "fileutils"
require "json"
require "securerandom"
require "rbconfig"

module Tart
  # The I95 architect-loop battery (A-Laws 1-12): the gate, the pure
  # config/render/plan/guard functions, the two tool surfaces, the /loop
  # command, the compaction customInstructions carry (the seam + the
  # pending-manual drain), and the builder guard through the Registry
  # gate — then the /live/ family (A-Law 11): a REAL driver session
  # (in-process Agent::Loop carrying the module's tools + the real
  # subagent tool + a real Manager + SupervisorChannel + the W3/W4
  # wake-kernel harness) over a toy scratch SPACE with real `bin/tart -p`
  # children performing the full arc, ONE staged escalation round trip,
  # and the architect_compact carry observed in the captured summarization
  # request. Hermetic: staged HOME/space, MockLLMServer, the
  # intercom/e2e/wake-wiring idioms with SELF-CONTAINED helpers (the I90
  # precedent). ZERO new skips; the only threads are the sanctioned
  # harness reactor threads (the intercom/wake-wiring precedents).
  class ArchitectLoopTest < Test
    ROLES = %w[spec builder judge narrator].freeze

    LIVE_SPEC_TASK = "TOY-SPEC-TASK ground the toy iteration and freeze it"
    LIVE_BUILDER_TASK = "TOY-BUILDER-TASK read the lane prompt and implement"
    LIVE_JUDGE_TASK = "TOY-JUDGE-TASK judge the toy iteration cold"
    LIVE_SPEC_ANSWER = "toy spec complete: digest written"
    LIVE_BUILDER_ANSWER = "toy builder complete: lane implemented"
    LIVE_JUDGE_ANSWER = "toy judge verdict: CONTINUE"
    LIVE_ESCALATION_QUESTION = "THE-ESCALATION-QUESTION: may the builder touch the frozen schema?"
    SPEC_PROFILE_MARKER = "You are architect-spec."
    BUILDER_PROFILE_MARKER = "You are architect-builder:"
    JUDGE_PROFILE_MARKER = "You are architect-judge."

    def setup
      @server = MockLLMServer.new.start
      @dirs = []
      @managers = []
      @channels = []
      @kernel = nil
      @kernel_thread = nil
      @run_thread = nil
      @captures = []
    end

    def teardown
      @run_thread&.join(1) rescue nil
      @channels.each { |channel| channel.stop rescue nil }
      @managers.each(&:shutdown)
      stop_kernel
      @server.stop
      # The module state is process-global: never leak a playbook between
      # tests (session_start resets it in real boots).
      ArchitectLoop.instance_variable_set(:@driver_playbook_text, nil)
      @dirs.each { |dir| FileUtils.rm_rf(dir) if dir && File.directory?(dir) }
    end

    def tmpdir!(prefix)
      dir = Dir.mktmpdir(prefix)
      @dirs << dir
      dir
    end

    # The flow-test idiom: loop seams run on a real reactor fiber.
    def on_reactor
      Core::Loop.new(session: Test::ScriptedSession.new).run { yield }
    end

    # --- A-Law 1: the gate (default off; settings row + env tier) ---

    def test_gate_is_default_off_with_settings_and_env_tiers
      assert_equal false, ArchitectLoop.enabled?({}, identity: "pi", env: {}),
        "no settings row and no env tier = OFF (the default-off law)"
      assert_equal true, ArchitectLoop.enabled?({"architect_loop" => true}, identity: "pi", env: {})
      assert_equal true, ArchitectLoop.enabled?({"architect_loop" => "true"}, identity: "pi", env: {})
      assert_equal true, ArchitectLoop.enabled?({"architect_loop" => "1"}, identity: "pi", env: {})
      assert_equal false, ArchitectLoop.enabled?({"architect_loop" => false}, identity: "pi", env: {}),
        "an explicit false row stays off"
      assert_equal true, ArchitectLoop.enabled?({}, identity: "pi", env: {"PI_ARCHITECT_LOOP" => "1"})
      assert_equal true, ArchitectLoop.enabled?({}, identity: "pi", env: {"PI_ARCHITECT_LOOP" => "true"})
      assert_equal true, ArchitectLoop.enabled?({}, identity: "tart", env: {"TART_ARCHITECT_LOOP" => "1"}),
        "the env tier rides the identity's namespace"
      assert_equal false, ArchitectLoop.enabled?({}, identity: "tart", env: {"PI_ARCHITECT_LOOP" => "1"}),
        "a foreign identity's tier never reads"
      assert_equal false, ArchitectLoop.enabled?({"architect_loop" => "on"}, identity: "pi", env: {}),
        "the on spellings are exactly true/\"true\"/\"1\""
    end

    # --- A-Law 2: split/compose ---

    def test_split_and_compose_model_spec_ride_the_settings_ladder
      assert_equal({model: "zai/glm-5.3", thinking: "high"}, ArchitectLoop.split_model_spec("zai/glm-5.3:high"))
      assert_equal({model: "zai/glm-5.3"}, ArchitectLoop.split_model_spec("zai/glm-5.3"))
      # A suffix counts only when it names a THINKING_LEVELS entry — a model
      # id that merely contains a colon keeps working.
      assert_equal({model: "openrouter/a:model:x"}, ArchitectLoop.split_model_spec("openrouter/a:model:x"))
      assert_equal Settings::THINKING_LEVELS, ArchitectLoop::THINKING_LEVELS, "the identical ladder"
      # The suffix beats the thinking key.
      assert_equal "zai/glm-5.3:high", ArchitectLoop.compose_model_spec({model: "zai/glm-5.3:high", thinking: "low"})
      assert_equal "zai/glm-5.3:low", ArchitectLoop.compose_model_spec({model: "zai/glm-5.3", thinking: "low"})
      assert_equal "zai/glm-5.3", ArchitectLoop.compose_model_spec({model: "zai/glm-5.3"})
    end

    # --- A-Law 2: find_space_root / parse / resolve ---

    def test_find_space_root_walks_up_and_ignores_a_stray_architect_yaml
      dir = tmpdir!("i95-cfg-")
      space = File.join(dir, "deep", "space")
      FileUtils.mkdir_p(File.join(space, "lanes", "wt"))
      File.write(File.join(space, "space.yaml"), "name: toy\n")
      File.write(File.join(space, "architect.yaml"), "version: 1\nroles: {}\n")
      # A stray architect.yaml WITHOUT space.yaml is never a config.
      File.write(File.join(dir, "architect.yaml"), "version: 1\nroles: {}\n")

      assert_equal space, ArchitectLoop.find_space_root(File.join(space, "lanes", "wt"))
      assert_equal space, ArchitectLoop.find_space_root(space)
      assert_nil ArchitectLoop.find_space_root(dir), "an architect.yaml without space.yaml is ignored"
    end

    def test_parse_failures_name_the_file_the_key_and_the_expectation
      file = File.join(tmpdir!("i95-parse-"), "architect.yaml")
      [
        ["", "document"],
        ["version: 2\nroles: {}\n", "version"],
        ["version: 1\n", "roles"],
        ["version: 1\nroles:\n  spec: {}\n", "roles.spec.model"],
        ["version: 1\nroles:\n  spec: {model: a/b, mode: fast}\n", "roles.spec.mode"],
        ["version: 1\nroles:\n  spec: {model: \"  \"}\n", "roles.spec.model"],
        ["version: 1\nroles:\n  spec: {model: a/b, thinking: loudest}\n", "roles.spec.thinking"],
        ["version: 1\nroles:\n  spec: {model: a/b, thinking: \"\"}\n", "roles.spec.thinking"],
        ["version: 1\nroles:\n  spec: not-a-map\n", "roles.spec"]
      ].each do |text, key|
        error = assert_raises(ArchitectLoop::Error) { ArchitectLoop.parse_architect_yaml(text, file) }
        assert_includes error.message, "architect.yaml (#{file})", "every failure names the file: #{error.message}"
        assert_includes error.message, key, "every failure names the key: #{error.message}"
        assert_includes error.message, "expected", "every failure names the expectation: #{error.message}"
      end
    end

    def test_parse_tolerates_and_collects_unknown_roles_first_seen
      parsed = ArchitectLoop.parse_architect_yaml(
        "version: 1\nroles:\n  coordinator: {model: old/one}\n  spec: {model: a/b}\n  tyypo: {model: x/y}\n",
        "f.yaml")
      assert_equal ["coordinator", "tyypo"], parsed[:unknown_roles], "first-seen order, tolerated, ignored whole"
      assert_equal ["spec"], parsed[:roles].keys, "the unknown entries never reach the role table"
      assert_equal({model: "a/b"}, parsed[:roles]["spec"])
      trimmed = ArchitectLoop.parse_architect_yaml("version: 1\nroles:\n  spec: {model: \" a/b \", thinking: \" high \"}\n", "f.yaml")
      assert_equal({model: "a/b", thinking: "high"}, trimmed[:roles]["spec"], "membership checked after trim")
    end

    def toy_config(dir)
      space = File.join(dir, "space")
      FileUtils.mkdir_p(space)
      File.write(File.join(space, "space.yaml"), "name: toy\n")
      File.write(File.join(space, "architect.yaml"), <<~YAML)
        version: 1
        roles:
          spec: {model: mock/toy-spec:high}
          builder: {model: mock/toy-builder}
          judge: {model: mock/toy-judge}
          narrator: {model: mock/toy-narrator}
      YAML
      [space, ArchitectLoop.resolve_config(space, global_file: File.join(dir, "absent.yaml"), env: {})]
    end

    def test_resolve_config_layers_global_base_space_override_and_demands_every_agent_role
      dir = tmpdir!("i95-layer-")
      space = File.join(dir, "space")
      FileUtils.mkdir_p(space)
      File.write(File.join(space, "space.yaml"), "name: toy\n")
      global = File.join(dir, "global.yaml")
      File.write(global, <<~YAML)
        version: 1
        roles:
          spec: {model: global/spec}
          builder: {model: global/builder}
          judge: {model: global/judge}
          narrator: {model: global/narrator}
          coordinator: {model: global/old}
      YAML
      local = File.join(space, "architect.yaml")
      File.write(local, <<~YAML)
        version: 1
        roles:
          builder: {model: local/builder:high}
      YAML

      config = ArchitectLoop.resolve_config(space, global_file: global, env: {})
      assert_equal [global, local], config[:files], "honored layers in order (global first)"
      assert_equal space, config[:space_root]
      assert_equal({model: "global/spec"}, config[:roles]["spec"], "the global layer is the base")
      assert_equal({model: "local/builder:high"}, config[:roles]["builder"], "the space-local overrides per role (whole entry; compose splits the suffix)")
      assert_equal ["coordinator"], config[:unknown_roles], "unknown keys merge across layers, first seen"

      # The env tier overrides the global file (pi's SPACE_ARCHITECT_GLOBAL_CONFIG).
      staged = File.join(dir, "staged-global.yaml")
      File.write(staged, "version: 1\nroles:\n  spec: {model: env/spec}\n  builder: {model: env/b}\n  judge: {model: env/j}\n  narrator: {model: env/n}\n")
      config = ArchitectLoop.resolve_config(space, env: {"SPACE_ARCHITECT_GLOBAL_CONFIG" => staged})
      assert_equal [staged, local], config[:files], "the env tier names the global file"

      # A missing agent role fails LOUD naming the layered files.
      File.write(staged, "version: 1\nroles:\n  spec: {model: env/spec}\n")
      error = assert_raises(ArchitectLoop::Error) { ArchitectLoop.resolve_config(space, env: {"SPACE_ARCHITECT_GLOBAL_CONFIG" => staged}) }
      assert_includes error.message, "roles.judge", "the first missing role in role order is named"
      assert_includes error.message, "every loop role (architect-spec, architect-builder, architect-judge, architect-narrator) routed"

      # NEITHER file exists = the quiet no-op nil (a configless dir).
      assert_nil ArchitectLoop.resolve_config(File.join(dir, "configless"), global_file: File.join(dir, "absent.yaml"), env: {})
      # A global-only config resolves (generation is space-scoped, not resolution).
      config = ArchitectLoop.resolve_config(File.join(dir, "no-space"), global_file: global, env: {})
      assert_nil config[:space_root], "a global-only config has no space root"
      assert config[:roles]["spec"], "resolution still carries the roles"
    end

    # --- A-Law 9: spawn-contract validation ---

    def staged_catalog(models)
      # The REAL load path over a staged models.json (the I27 catalog, the
      # same seat the live legs use).
      dir = tmpdir!("i95-catalog-")
      File.write(File.join(dir, "models.json"), JSON.generate(
        "providers" => {"mock" => {"name" => "mock", "baseUrl" => "http://127.0.0.1:9",
                                   "models" => models.map { |id| {"id" => id, "name" => id} }}}))
      Models.load(root: dir)
    end

    def test_validate_model_ref_laws
      catalog = staged_catalog(%w[toy-spec toy-builder])
      # Hits pass silently.
      ArchitectLoop.validate_model_ref("spec", "mock/toy-spec", catalog)
      assert ArchitectLoop.validate_model_ref("spec", "mock/toy-spec:high", catalog).nil?, "a :level suffix strips first"
      # Malformed refs are loud, naming the role and the raw ref.
      ["noslash", "/leading", "trailing/"].each do |ref|
        error = assert_raises(ArchitectLoop::Error) { ArchitectLoop.validate_model_ref("spec", ref, catalog) }
        assert_includes error.message, "roles.spec.model", error.message
        assert_includes error.message, ref.inspect, error.message
        assert_includes error.message, "expected provider/model-id[:thinking]", error.message
      end
      # A registry miss is loud, naming the parsed pair and EVERY valid choice.
      error = assert_raises(ArchitectLoop::Error) { ArchitectLoop.validate_model_ref("builder", "mock/toy-judge", catalog) }
      assert_includes error.message, "roles.builder.model 'mock/toy-judge'", error.message
      assert_includes error.message, "(provider 'mock', id 'toy-judge')", error.message
      assert_includes error.message, "Valid choices: mock/toy-spec, mock/toy-builder", error.message
      # The I78 never-validate laws: catalog nil = parse-only; an errored or
      # empty catalog NEVER validates (a corrupt models.json must not break
      # the loop's launches).
      ArchitectLoop.validate_model_ref("spec", "totally/bogus", nil)
      ArchitectLoop.validate_model_ref("spec", "totally/bogus", Models::Config.new(providers: {}, default: nil, error: "boom"))
      ArchitectLoop.validate_model_ref("spec", "totally/bogus", Models::Config.new(providers: {}, default: nil, error: nil))
    end

    # --- A-Law 3: render + write (.tart/agents ONLY) ---

    def test_render_agent_file_frontmatter_is_the_tart_contract_only
      _, config = toy_config(tmpdir!("i95-render-"))
      file = ArchitectLoop.render_agent_file("spec", config)
      frontmatter, body = Skills.parse_frontmatter(file)
      assert_equal "architect-spec", frontmatter["name"]
      assert_equal ArchitectLoop::ROLE_DESCRIPTIONS["spec"], frontmatter["description"]
      assert_equal "read, grep, find, ls, bash, edit, write", frontmatter["tools"], "the comma string"
      assert_equal "mock/toy-spec", frontmatter["model"], "the composed model carries the split id"
      assert_equal "high", frontmatter["thinking"], "the composed thinking rides its own field"
      assert_equal "fresh", frontmatter["context"]
      assert_nil frontmatter["systemPromptMode"], "the pi-only fields are NOT emitted (ruling 3)"
      assert_nil frontmatter["inheritProjectContext"], "the pi-only fields are NOT emitted (ruling 3)"
      assert_equal ArchitectLoop::ROLE_PLAYBOOKS["spec"], body, "the body IS the carried playbook"
      # The builder re-expression carries tart's web tools; the narrator
      # carries no bash and no edits.
      assert_includes ArchitectLoop.render_agent_file("builder", config),
        "tools: read, grep, find, ls, bash, edit, write, web_search, web_fetch"
      assert_includes ArchitectLoop.render_agent_file("narrator", config), "tools: read, grep, find, ls, write"
      refute_includes ArchitectLoop.render_agent_file("narrator", config), "bash"
      # Every scalar on one line (the lineWidth: 0 discipline) — no folded
      # continuation lines in the frontmatter.
      frontmatter_text = file.split("---\n")[1]
      frontmatter_text.each_line do |line|
        assert_includes line, ": ", "every frontmatter line is a complete scalar: #{line.inspect}"
      end
    end

    def test_write_agent_files_writes_if_changed_and_self_cleans_the_coordinator
      dir = tmpdir!("i95-write-")
      space, config = toy_config(dir)
      result = ArchitectLoop.write_agent_files(space, config)
      agents_dir = File.join(space, ".tart", "agents")
      assert_equal ROLES.map { |role| File.join(agents_dir, "architect-#{role}.md") }, result[:written]
      # Byte-identical files are left untouched (mtime unchanged).
      before = result[:written].to_h { |path| [path, File.mtime(path)] }
      result = ArchitectLoop.write_agent_files(space, config)
      assert_empty result[:written]
      assert_equal ROLES.size, result[:unchanged].size
      result[:unchanged].each { |path| assert_equal before[path], File.mtime(path), "byte-identical files stay untouched" }
      # A stale pre-collapse coordinator self-cleans.
      File.write(File.join(agents_dir, "architect-coordinator.md"), "stale")
      result = ArchitectLoop.write_agent_files(space, config)
      assert_equal [File.join(agents_dir, "architect-coordinator.md")], result[:removed]
      refute File.exist?(File.join(agents_dir, "architect-coordinator.md"))
      # The generated file RESOLVES through the I49 project tier (the owner's
      # ruling-3 slot) with the routed model + tools + body.
      spec = Subagents::Profiles.resolve("architect-spec", cwd: space, root: File.join(dir, "no-root"), env: {})
      assert_equal "mock/toy-spec", spec[:model]
      assert_equal ArchitectLoop::ROLE_TOOLS["spec"], spec[:tools]
      assert_includes spec[:system_prompt], "You are architect-spec."
    end

    # --- A-Law 4: the /loop arg parser ---

    def test_extract_plan_carries_pi_errors_byte_exact
      dir = tmpdir!("i95-plan-")
      plan = File.join(dir, "plan.md")
      File.write(plan, "  ENTRY 1: the toy plan.  \n")
      assert_equal "ENTRY 1: the toy plan.", ArchitectLoop.extract_plan("--from #{plan}"), "reads + trims"
      assert_equal "inline text", ArchitectLoop.extract_plan("inline text")
      error = assert_raises(ArchitectLoop::Error) { ArchitectLoop.extract_plan("--from   ") }
      assert_equal "/loop --from needs a file path: /loop --from <plan file>", error.message
      error = assert_raises(ArchitectLoop::Error) { ArchitectLoop.extract_plan("--from #{File.join(dir, 'absent.md')}") }
      assert_match(%r{\A/loop --from .*absent\.md: cannot read plan file \(}, error.message)
      empty = File.join(dir, "empty.md")
      File.write(empty, "   \n")
      error = assert_raises(ArchitectLoop::Error) { ArchitectLoop.extract_plan("--from #{empty}") }
      assert_equal "/loop --from #{empty} is empty — expected the plan text", error.message
      error = assert_raises(ArchitectLoop::Error) { ArchitectLoop.extract_plan("   ") }
      assert_equal "Usage: /loop <plan text> — or /loop --from <plan file>", error.message
    end

    # --- A-Law 6: the playbook element list ---

    def test_driver_playbook_carries_every_element
      _, config = toy_config(tmpdir!("i95-book-"))
      plan_path = "/tmp/never/i95-plan.md"
      book = ArchitectLoop.driver_playbook(config, plan_path)
      # (a) the role sentence
      assert_includes book, "You are the architect session driving one space-architect plan to completion by " \
        "spawning role subagents and tending them. You never do lane work yourself."
      # (b) the mid-turn install + the never-idle law, VERBATIM
      assert_includes book, "You are installed mid-turn: begin driving NOW, in this same turn — ground from disk and " \
        "proceed to the first child spawn. Never end your turn before the first child of this session is in flight; " \
        "an idle driver with no child in flight has no wake source, and the loop stalls."
      # (c) ground-from-disk
      assert_includes book, "Ground from disk at every wake — space.yaml, the plan under notes/plan-, and `architect looplog`"
      assert_includes book, "re-derive where the plan stands from those records and continue"
      # (d) the per-iteration procedure, re-expressed spawn spelling + the pings
      assert_includes book, "1. Spawn architect-spec via the subagent tool (agent \"architect-spec\", async, task = the iteration's plan entry, verbatim)."
      assert_includes book, "bash `architect ping <iteration-id> spec-launched`"
      assert_includes book, "2. Run `architect provision` via bash"
      assert_includes book, "3. The spec report names each lane's scratch prompt path. Copy each to build/<iteration-id>-<lane>/prompt.md (bash cp is fine)."
      assert_includes book, "4. Spawn one architect-builder per lane via the subagent tool"
      assert_includes book, "bash `architect ping <iteration-id> builders-settled`"
      assert_includes book, "5. Spawn architect-judge via the subagent tool (agent \"architect-judge\", async, task = judge this iteration by id)."
      assert_includes book, "bash `architect ping <iteration-id> judge-running`"
      # (e) the phase-ping best-effort law
      assert_includes book, "Phase pings are best-effort: a ping that fails (unconfigured, dead server, bad exit) is one line in the completion report — never an exception, never a gate, never retried in a loop."
      # (f) the spawn contract: timeouts + the composed pins + the override + the tart cwd law
      assert_includes book, "spec 3600000, builder 7200000, judge 7200000, narrator 300000"
      assert_includes book, "architect-spec mock/toy-spec:high, architect-builder mock/toy-builder, " \
        "architect-judge mock/toy-judge, architect-narrator mock/toy-narrator"
      assert_includes book, "pass that pin in the spawn's model field as provider/id[:thinking]"
      assert_includes book, "(tart cwd law: role children always run in THIS session's cwd"
      # (g) the compaction law + the ONE sanctioned no-abort port note
      assert_includes book, "call the architect_compact tool after every child launch"
      assert_includes book, "NEVER compact before this session's first child launch, and never once every child has settled"
      assert_includes book, "(Port note: the tart port never aborts the turn — architect_compact schedules the compaction at the post-run point"
      # (h) the tending law
      assert_includes book, "rely on native async completion wakes. Never sleep and never poll-loop."
      assert_includes book, "relaunch it ONCE"
      assert_includes book, "launch exactly one replacement in the same cwd with a larger explicit timeout_ms, and make auditing the inherited uncommitted diff its first task"
      # (i) the narration law
      assert_includes book, "exactly ONE narration lands — the more-final kind absorbs the earlier event's facts"
      assert_includes book, "timeout_ms 300000, the standing model pin, best-effort"
      # (j) the escalation one-hop law, tart reply-action spelling
      assert_includes book, "subagent({ action: \"reply\", reply_to: \"<requestId>\", message: \"...\" })"
      assert_includes book, "notes/escalation-<UTC timestamp>.md"
      # (k) the exception law
      assert_includes book, "notes/exception-<UTC timestamp>.md"
      assert_includes book, "Do not improvise repairs."
      # (l) the closing laws
      assert_includes book, "You never edit files except your own notes/ reports"
      assert_includes book, "notes/report-<UTC timestamp>.md"
      assert_includes book, "build/ stays ephemeral per-run scratch."
      # The file-plan line law
      assert_includes book, "#{plan_path} — read it from disk at every wake, never from a remembered copy"
      refute_includes book, "it lives nowhere on disk", "a file launch carries no inline marker line"

      inline = ArchitectLoop.driver_playbook(config, ArchitectLoop::INLINE_PLAN_REF, "ENTRY 1: the toy plan.")
      assert_includes inline, "inline plan text — it lives nowhere on disk, so it is embedded verbatim below and rides in this playbook (the compaction keep-essentials)."
      assert_includes inline, "\n\nENTRY 1: the toy plan.", "the plan rides verbatim"
      refute_includes inline, "read it from disk at every wake", "the inline arm carries its own law"
    end

    # --- A-Law 8: the builder guard ---

    def test_is_lane_worktree_matches_the_pi_shape
      assert ArchitectLoop.is_lane_worktree?("/space/build/i95-lane-x/wt")
      refute ArchitectLoop.is_lane_worktree?("/space/build/i95-lane-x/other")
      refute ArchitectLoop.is_lane_worktree?("/space/repo/wt")
      refute ArchitectLoop.is_lane_worktree?("/space/build/wt")
      refute ArchitectLoop.is_lane_worktree?("")
      refute ArchitectLoop.is_lane_worktree?(nil)
    end

    def test_guard_denial_carries_the_ported_git_write_law
      denial = ArchitectLoop.guard_denial("git commit -m x")
      assert_equal "git commit writes repository state — the architect CLI owns all commits and git mutations; " \
        "leave repository state alone and report what you would have run", denial
      # Value flags locate the subcommand; segments split at the separators;
      # reads and non-git commands pass; never substring-match.
      assert_equal denial, ArchitectLoop.guard_denial("git -C /repo commit -m x")
      assert_equal "git push writes repository state — the architect CLI owns all commits and git mutations; " \
        "leave repository state alone and report what you would have run",
        ArchitectLoop.guard_denial("git -c x=y push origin")
      assert_equal "git push writes repository state — the architect CLI owns all commits and git mutations; " \
        "leave repository state alone and report what you would have run", ArchitectLoop.guard_denial("echo hi && git push --force")
      assert_equal "git reset writes repository state — the architect CLI owns all commits and git mutations; " \
        "leave repository state alone and report what you would have run",
        ArchitectLoop.guard_denial("git status\ngit reset --hard HEAD")
      assert_equal "git clean writes repository state — the architect CLI owns all commits and git mutations; " \
        "leave repository state alone and report what you would have run",
        ArchitectLoop.guard_denial("ls | git clean -fd")
      assert_equal "git rm writes repository state — the architect CLI owns all commits and git mutations; " \
        "leave repository state alone and report what you would have run",
        ArchitectLoop.guard_denial("git rm -f x; git mv a b")
      assert_nil ArchitectLoop.guard_denial("git log --grep=commit"), "never substring-match"
      assert_nil ArchitectLoop.guard_denial("git status && git diff")
      assert_nil ArchitectLoop.guard_denial("git log --oneline | wc -l")
      assert_nil ArchitectLoop.guard_denial("echo git commit"), "a payload mentioning the verb is not a git invocation"
    end

    def test_the_guard_blocks_through_the_registry_gate_inside_a_lane_worktree
      space = tmpdir!("i95-guard-")
      lane_wt = File.join(space, "build", "i95-toy-lane", "wt")
      FileUtils.mkdir_p(lane_wt)
      hooks = Hooks.new
      notices = []
      env = {"SPACE_ARCHITECT_GLOBAL_CONFIG" => File.join(space, "absent.yaml")}
      catalog = -> { staged_catalog(%w[toy-spec toy-builder toy-judge toy-narrator]) }
      ArchitectLoop.register(hooks:, cwd: lane_wt, identity: "pi", agent: -> { nil },
                             output: ->(text) { notices << text }, env:, catalog:)

      tools = Tools::Registry.build(selected: %w[bash read], cwd: lane_wt, hooks:)
      blocked = tools["bash"].call(command: "git commit -m 'nope'")
      assert_equal "architect builder guard: git commit writes repository state — the architect CLI owns all commits " \
        "and git mutations; leave repository state alone and report what you would have run", blocked
      # git reads pass through to the REAL bash tool (scratch repo staged;
      # no lane write anywhere — `git init` stages the throwaway repo).
      result = tools["bash"].call(command: "git init -q . && git status --short")
      refute_includes result.to_s, "builder guard", "git reads pass"
      refute_equal blocked, result
      read_result = tools["read"].call(path: File.join(lane_wt, "absent.txt"))
      assert read_result.is_a?(Hash) && read_result[:error], "non-bash tools are untouched by the guard"

      # Outside a lane worktree nothing blocks (the same command runs).
      plain = tmpdir!("i95-guard-plain-")
      hooks2 = Hooks.new
      ArchitectLoop.register(hooks: hooks2, cwd: plain, identity: "pi", agent: -> { nil },
                             output: ->(text) { notices << text }, env:, catalog:)
      tools2 = Tools::Registry.build(selected: %w[bash], cwd: plain, hooks: hooks2)
      assert_includes tools2["bash"].call(command: "git commit -m nope 2>&1; echo done").to_s, "done",
        "outside a lane worktree nothing blocks"
    end

    # --- A-Law 4/5: the surfaces ---

    def new_module_hooks(cwd, catalog_models: %w[toy-spec toy-builder toy-judge toy-narrator])
      hooks = Hooks.new
      notices = []
      env = {"SPACE_ARCHITECT_GLOBAL_CONFIG" => File.join(File.dirname(cwd), "absent-global.yaml")}
      catalog = -> { staged_catalog(catalog_models) }
      [hooks, notices, env, catalog]
    end

    def test_loop_command_success_notice_error_rescue_and_registration_shape
      dir = tmpdir!("i95-cmd-")
      space, config = toy_config(dir)
      hooks, notices, env, catalog = new_module_hooks(space)
      plan = File.join(space, "notes", "plan.md")
      FileUtils.mkdir_p(File.dirname(plan))
      File.write(plan, "ENTRY 1: the toy plan.\n")

      ArchitectLoop.register(hooks:, cwd: space, identity: "pi", agent: -> { nil },
                             output: ->(text) { notices << text }, env:, catalog:)
      row = hooks.registered_commands.find { |command| command[:name] == "loop" }
      assert row, "/loop registers on the seam"
      assert_equal ArchitectLoop::LOOP_COMMAND_DESCRIPTION, row[:description], "the description carried verbatim"
      assert_equal true, row[:args], "/loop is args-taking"

      # The failing arms first (the state must be nil at their ends).
      notices.clear
      hooks.command_handler("loop").call("")
      assert_equal ["Usage: /loop <plan text> — or /loop --from <plan file>"], notices
      notices.clear
      hooks.command_handler("loop").call("--from #{File.join(space, 'absent.md')}")
      assert_match(/\A\/loop --from .*absent\.md: cannot read plan file/, notices.first)
      plain = File.join(dir, "no-space-here")
      FileUtils.mkdir_p(plain)
      hooks2, notices2, env2, catalog2 = new_module_hooks(plain)
      ArchitectLoop.register(hooks: hooks2, cwd: plain, identity: "pi", agent: -> { nil },
                             output: ->(text) { notices2 << text }, env: env2, catalog: catalog2)
      hooks2.command_handler("loop").call("plan text")
      assert_equal [ArchitectLoop.no_config_message(plain, env: env2)], notices2
      assert_nil ArchitectLoop.driver_playbook_text, "a failed install leaves the session not driving"

      # The success arm: pi's notice carried verbatim; the state installed.
      notices.clear
      hooks.command_handler("loop").call("--from #{plan}")
      assert_equal ["architect loop: driver mode engaged — this session now drives the plan (#{plan}); " \
                    "driving starts this turn, first architect_compact after the first child launch."], notices
      assert_equal ArchitectLoop.driver_playbook(config, plan, nil), ArchitectLoop.driver_playbook_text,
        "the installed playbook is the composed one"
    ensure
      ArchitectLoop.instance_variable_set(:@driver_playbook_text, nil)
    end

    def test_architect_loop_tool_exactly_one_of_and_error_shapes
      dir = tmpdir!("i95-tool-")
      space, = toy_config(dir)
      hooks, notices, env, catalog = new_module_hooks(space)
      tool = Tools::ArchitectLoop.new(cwd: space, output: ->(text) { notices << text }, env:, catalog:)
      assert_equal "architect_loop", tool.name
      assert_includes tool.description, "the detached coordinator is retired"
      assert_includes tool.description, "call architect_compact only after a child launch, never before the first"
      assert_includes tool.description, "Requires the cwd to be inside a space (space.yaml + architect.yaml)."

      assert_equal "architect_loop: pass exactly one of `from` (path to the plan file, preferred) or `plan` (the plan text)",
                   tool.execute
      assert_equal "architect_loop: pass exactly one of `from` (path to the plan file, preferred) or `plan` (the plan text)",
                   tool.execute(from: "a", plan: "b")
      # An empty string is JS-falsy: absent.
      assert_equal "architect_loop: pass exactly one of `from` (path to the plan file, preferred) or `plan` (the plan text)",
                   tool.execute(from: "", plan: "")

      assert_match(/\Aarchitect_loop: \/loop --from .*absent\.md: cannot read plan file/,
                   tool.execute(from: File.join(space, "absent.md")))
      assert_empty notices, "a failing tool install prints no inform"

      no_config = Tools::ArchitectLoop.new(cwd: File.join(dir, "no-space"), output: ->(text) { notices << text },
                                           env:, catalog:)
      assert_equal "architect_loop: #{ArchitectLoop.no_config_message(File.join(dir, 'no-space'), env: env)}",
                   no_config.execute(plan: "text")

      bad_catalog = -> { staged_catalog(%w[unrelated-thing]) }
      bad = Tools::ArchitectLoop.new(cwd: space, output: ->(text) { notices << text }, env:, catalog: bad_catalog)
      result = bad.execute(plan: "text")
      assert_match(/\Aarchitect_loop: architect\.yaml: roles\.spec\.model 'mock\/toy-spec:high' does not resolve/, result)
      assert_match(/Valid choices: mock\/unrelated-thing\z/, result)
      refute File.exist?(File.join(space, ".tart", "agents", "architect-spec.md")),
        "a bad pin rejects BEFORE any file write"
    end

    def test_architect_loop_tool_success_installs_and_returns_the_playbook
      dir = tmpdir!("i95-tool-ok-")
      space, config = toy_config(dir)
      hooks, notices, env, catalog = new_module_hooks(space)
      plan = File.join(space, "notes", "plan.md")
      FileUtils.mkdir_p(File.dirname(plan))
      File.write(plan, "ENTRY 1: the toy plan.\n")
      tool = Tools::ArchitectLoop.new(cwd: space, output: ->(text) { notices << text }, env:, catalog:)

      result = tool.execute(from: plan)
      assert_equal ArchitectLoop.driver_playbook(config, plan, nil), result, "the RESULT TEXT is the playbook"
      assert_equal result, ArchitectLoop.driver_playbook_text, "the module state carries it"
      assert_equal ["architect loop: driver mode engaged — this session now drives the plan (#{plan}); " \
                    "driving starts this turn, first architect_compact after the first child launch."], notices
      ROLES.each do |role|
        assert_equal ArchitectLoop.render_agent_file(role, config),
                     File.read(File.join(space, ".tart", "agents", "architect-#{role}.md")),
                       "the role file bytes match the composer"
      end
      refute Dir.exist?(File.join(space, ".pi")), "ZERO .pi reads or writes (ruling 3)"
      # An unknown role informs ONCE per surface invocation, through output.
      File.write(File.join(space, "architect.yaml"), File.read(File.join(space, "architect.yaml")) + "  coordinator: {model: old/one}\n")
      notices.clear
      tool.execute(from: plan)
      assert_equal ["architect-loop: unknown role key(s) in architect.yaml — ignored: coordinator. " \
                    "Known roles: architect, spec, builder, judge, narrator.",
                    "architect loop: driver mode engaged — this session now drives the plan (#{plan}); " \
                    "driving starts this turn, first architect_compact after the first child launch."], notices
    ensure
      ArchitectLoop.instance_variable_set(:@driver_playbook_text, nil)
    end

    def test_architect_compact_tool_texts_and_states
      driving_playbook = "THE PLAYBOOK"
      fake_loop = Object.new
      requests = []
      fake_loop.define_singleton_method(:request_manual_compaction) do |**kwargs|
        requests << kwargs
        nil
      end
      driver_module = Object.new
      driver_module.define_singleton_method(:driver_playbook_text) { @text }
      driver_module.instance_variable_set(:@text, nil)

      tool = Tools::ArchitectCompact.new(driver: driver_module, agent: -> { fake_loop })
      assert_equal "architect_compact", tool.name
      assert_includes tool.description, "never before this session's first child launch and never once every child has settled"
      assert_includes tool.description, "No parameters."

      # Not driving: a plain compaction, pi's carried text.
      assert_equal "Session compaction scheduled — no driver playbook in this session, compacted plainly.", tool.execute
      assert_equal [{}], requests, "a plain compaction schedules with no custom instructions"

      # Driving: the playbook rides as custom instructions.
      driver_module.instance_variable_set(:@text, driving_playbook)
      assert_equal "Session compaction scheduled with the driver playbook as customInstructions — the keep-essentials " \
        "(plan reference, routing pins, per-iteration procedure) survive; ground everything else from disk.", tool.execute
      assert_equal [{custom_instructions: driving_playbook}], requests.drop(1)

      # A loop without the seam: pi's guard text carried verbatim.
      seamless = Tools::ArchitectCompact.new(driver: driver_module, agent: -> { Object.new })
      assert_equal({error: "architect_compact: this pi build exposes no ctx.compact — nothing scheduled"}, seamless.execute)

      # A raising loop: pi's failure shape carried.
      raising = Object.new
      raising.define_singleton_method(:request_manual_compaction) { |**| raise StandardError, "boom" }
      failing = Tools::ArchitectCompact.new(driver: driver_module, agent: -> { raising })
      assert_equal({error: "architect_compact: compaction failed — boom"}, failing.execute)
    end

    def test_session_start_handler_resets_regenerates_and_quietly_no_ops
      dir = tmpdir!("i95-ss-")
      space, config = toy_config(dir)
      hooks, notices, env, catalog = new_module_hooks(space)
      ArchitectLoop.register(hooks:, cwd: space, identity: "pi", agent: -> { nil },
                             output: ->(text) { notices << text }, env:, catalog:)

      # Install, then a session_start resets (driver mode is never inherited)
      # AND regenerates (a mid-session architect.yaml edit lands).
      hooks.emit({"type" => "session_start", "reason" => "startup"}, context: {cwd: space, mode: "tui", identity: "pi"})
      ArchitectLoop.install_driver_mode(config, ArchitectLoop::INLINE_PLAN_REF, "plan", output: ->(_) {})
      refute_nil ArchitectLoop.driver_playbook_text
      File.delete(File.join(space, ".tart", "agents", "architect-spec.md"))
      hooks.emit({"type" => "session_start", "reason" => "new"}, context: {cwd: space, mode: "tui", identity: "pi"})
      assert_nil ArchitectLoop.driver_playbook_text, "the reset runs on every session_start"
      assert File.exist?(File.join(space, ".tart", "agents", "architect-spec.md")), "the regeneration ran"
      assert_empty notices, "a clean config informs nothing"

      # No config anywhere = quiet no-op.
      plain = File.join(dir, "plain")
      FileUtils.mkdir_p(plain)
      hooks.emit({"type" => "session_start", "reason" => "resume"}, context: {cwd: plain, mode: "tui", identity: "pi"})
      assert_empty notices

      # The context's cwd wins over the register cwd (the memory idiom) —
      # a config at a DIFFERENT cwd regenerates THERE.
      other = File.join(dir, "other-space")
      FileUtils.mkdir_p(other)
      File.write(File.join(other, "space.yaml"), "name: other\n")
      File.write(File.join(other, "architect.yaml"), File.read(File.join(space, "architect.yaml")))
      hooks.emit({"type" => "session_start", "reason" => "resume"}, context: {cwd: other, mode: "tui", identity: "pi"})
      assert File.exist?(File.join(other, ".tart", "agents", "architect-spec.md")), "the context cwd drove the pass"
    ensure
      ArchitectLoop.instance_variable_set(:@driver_playbook_text, nil)
    end

    # --- A-Law 7: the compaction carry + the pending-manual drain ---

    def test_summarization_prompt_carry_and_nil_bytes
      messages = [Agent::Message.user("hi")]
      nil_prompt = Compaction.summarization_prompt(messages)
      assert_equal "<conversation>\n[User]: hi\n</conversation>\n\n#{Compaction::SUMMARIZATION_PROMPT}", nil_prompt
      assert_equal nil_prompt, Compaction.summarization_prompt(messages, custom_instructions: nil),
        "nil leaves today's bytes byte-identical"
      assert_equal nil_prompt, Compaction.summarization_prompt(messages, custom_instructions: ""),
        "empty stays today's bytes (pi's truthiness guard)"
      carried = Compaction.summarization_prompt(messages, custom_instructions: "KEEP THE PLAYBOOK")
      assert_equal "#{nil_prompt}\n\nAdditional focus: KEEP THE PLAYBOOK", carried, "pi's EXACT bytes appended"
      update_nil = Compaction.summarization_prompt(messages, previous_summary: "earlier")
      carried_update = Compaction.summarization_prompt(messages, previous_summary: "earlier", custom_instructions: "FOCUS")
      assert_equal "#{update_nil}\n\nAdditional focus: FOCUS", carried_update
    end

    def small_compaction_loop(system_prompt)
      # Returns [loop, chat] — a conversation-bearing history is seeded
      # (prepare nils on an empty one); the Loop exposes no chat reader.
      chat = Test::TestChat.build(@server, system_prompt:)
      loop = Agent::Loop.new(chat:, tools: {}, system_prompt:,
                             compaction: {keep_recent_tokens: 1, reserve_tokens: 16_384, enabled: true})
      chat.add_message(Agent::Message.user("hello driver"))
      chat.add_message(Agent::Message.user("second seed turn"))
      [loop, chat]
    end

    def test_compact_threads_custom_instructions_through_the_seam
      # keep_recent_tokens: 1 makes prepare non-nil for ANY history; the
      # threshold trigger stays disabled (no resolvable window on the
      # TestChat model), so ONLY the manual seam fires.
      loop, chat = small_compaction_loop("carry harness")
      @server.script([
        {type: :stream, content: "THE SUMMARY"}
      ])
      happened = on_reactor { loop.compact(custom_instructions: "KEEP THE PLAYBOOK") }
      assert happened, "the inline compact ran"

      requests = @server.captured_requests
      assert_equal 1, requests.size, "just the summarization call"
      summary_request = requests.last
      refute summary_request.key?("tools"), "the standalone summarization call carries no tools"
      prompt = summary_request["messages"].last["content"].to_s
      assert_includes prompt, "Additional focus: KEEP THE PLAYBOOK"
      assert prompt.end_with?("\n\nAdditional focus: KEEP THE PLAYBOOK"), "pi's exact carry bytes"
      summary_message = chat.messages.find { |m| m.content.to_s.include?(Compaction::COMPACTION_SUMMARY_PREFIX) }
      refute_nil summary_message, "the compaction landed"
      assert_includes summary_message.content.to_s, "THE SUMMARY"
    end

    def test_pending_manual_compaction_replaces_and_drains_first_at_the_post_run_point
      loop, chat = small_compaction_loop("drain harness")
      @server.script([
        {type: :stream, content: "turn done"},
        {type: :stream, content: "THE DRAIN SUMMARY"}
      ])
      # Single slot: a second request replaces the first.
      loop.request_manual_compaction(custom_instructions: "FIRST FOCUS")
      loop.request_manual_compaction(custom_instructions: "SECOND FOCUS")
      on_reactor { loop.run("drive it") }

      requests = @server.captured_requests
      assert_equal 2, requests.size
      prompt = requests.last["messages"].last["content"].to_s
      assert_includes prompt, "Additional focus: SECOND FOCUS", "the last request wins the slot"
      refute_includes prompt, "FIRST FOCUS"
      summary_message = chat.messages.find { |m| m.content.to_s.include?(Compaction::COMPACTION_SUMMARY_PREFIX) }
      refute_nil summary_message, "the compaction landed at post-run"
      assert_includes summary_message.content.to_s, "THE DRAIN SUMMARY"
      # The slot cleared: a second run schedules nothing (just the turn).
      before = @server.request_count
      on_reactor { loop.run("again") }
      assert_equal before + 1, @server.request_count, "no summarization request after the slot cleared"
    end

    # --- A-Law 10: the env audit's hermetic pin ---

    def test_env_audit_hermetic_pin_bash_child_env_flows_post_scrub
      # The I73 explicit-copy arm measured: a staged parent env
      # (SSH_AUTH_SOCK + a mise-shaped PATH head) flows through the bash
      # tool's composed child env VERBATIM post-scrub — a REAL bash-tool
      # child (unsetenv_others over ChildEnv.scrub(ENV.to_h)) prints the
      # staged values back. ENV is staged for the composition's read window
      # only, restored in ensure (the serial suite's process-wide read).
      dir = tmpdir!("i95-env-")
      shim = File.join(dir, "mise-shims")
      FileUtils.mkdir_p(shim)
      tool = Tools::Bash.new(cwd: dir, identity: "pi")
      staged_sock = "/tmp/fake-agent.sock"
      original_path = ENV["PATH"]
      original_sock = ENV["SSH_AUTH_SOCK"]
      original_env_recorded_path = ENV["BUNDLER_ORIG_PATH"]
      begin
        ENV["SSH_AUTH_SOCK"] = staged_sock
        ENV["PATH"] = "#{shim}#{File::PATH_SEPARATOR}#{original_path}"
        # Under a bundle-exec'd parent the scrub's ORIG restore wins (the
        # I73 record law) — stage the RECORD too, so the staged PATH is
        # what the law's precedence hands the child.
        ENV["BUNDLER_ORIG_PATH"] = ENV["PATH"]
        result = tool.execute(command: "printenv SSH_AUTH_SOCK; printenv PATH | cut -d: -f1; command -v mise rbenv || true")
      ensure
        ENV["SSH_AUTH_SOCK"] = original_sock
        ENV["PATH"] = original_path
        ENV["BUNDLER_ORIG_PATH"] = original_env_recorded_path
      end
      lines = result.to_s.split("\n")
      assert_equal staged_sock, lines[0], "the staged SSH_AUTH_SOCK rides the child env verbatim"
      assert_equal shim, lines[1], "the mise-shaped PATH head rides the child env verbatim"
      assert_equal original_path, ENV["PATH"], "the staging restored"
    end

    # --- the /live/ family (A-Law 11) ---

    def stage_live_space
      space = tmpdir!("i95-live-space-")
      File.write(File.join(space, "space.yaml"), "name: toy-loop\n")
      FileUtils.mkdir_p([File.join(space, "architecture"), File.join(space, "notes")])
      File.write(File.join(space, "architect.yaml"), <<~YAML)
        version: 1
        roles:
          spec: {model: mock/toy-spec}
          builder: {model: mock/toy-builder}
          judge: {model: mock/toy-judge}
          narrator: {model: mock/toy-narrator}
      YAML
      File.write(File.join(space, "notes", "plan-toy.md"),
        "ENTRY 1 of 1, this toy iteration, ONE lane: prove the loop parity mechanics.\n")
      space
    end

    def stage_live_home
      home = tmpdir!("i95-live-home-")
      FileUtils.mkdir_p(File.join(home, ".tart"))
      # The I70 explicit-staging law: the child print boot never rides the
      # app default (the e2e i49 staging idiom).
      File.write(File.join(home, ".tart", "settings.json"), JSON.generate("subagents" => false))
      File.write(File.join(home, ".tart", "models.json"), JSON.generate(
        "providers" => {"mock" => {"name" => "mock", "baseUrl" => "http://127.0.0.1:9", "models" => [
          {"id" => "toy-spec", "name" => "Toy Spec"},
          {"id" => "toy-builder", "name" => "Toy Builder"},
          {"id" => "toy-judge", "name" => "Toy Judge"},
          {"id" => "toy-narrator", "name" => "Toy Narrator"}
        ]}}))
      @subagents_home = File.join(home, "subagents")
      FileUtils.mkdir_p(@subagents_home)
      @home = home
    end

    def live_child_env
      {
        "PATH" => ENV["PATH"],
        "HOME" => @home,
        "TART_IDENTITY" => "pi",
        "PI_API_KEY" => "live-key",
        "PI_API_BASE" => @server.url,
        # The escalation leg's bounded ask: a missed reply fails the child
        # loud at the 60s bound instead of hanging at the 600s default.
        "PI_INTERCOM_ASK_TIMEOUT_MS" => "60000"
      }
    end

    # The live harness: real Manager + SupervisorChannel + wake kernel over
    # a ScriptedSession, the module registered through the FULL boot path,
    # the driver loop carrying the module's tools + the real subagent tool.
    def build_live_harness(space)
      stage_live_home
      @hooks = Hooks.new
      @session = Test::ScriptedSession.new
      @kernel, @kernel_thread, @rail_else = wake_kernel(@session)
      @notices = []
      @manager = Subagents::Manager.new(cwd: space, home: @subagents_home, env: live_child_env,
                                        identity: "pi", hooks: @hooks, kernel: Subagents.wake_bridge(@session),
                                        agent: -> { @driver }, root: File.join(@home, ".tart"))
      @managers << @manager
      @channel = Subagents::SupervisorChannel.new(home: @subagents_home, hooks: @hooks,
                                                  kernel: Subagents.wake_bridge(@session), agent: -> { @driver })
      @channel.start
      @channels << @channel
      @manager.supervisor_channel = @channel
      ArchitectLoop.register(hooks: @hooks, cwd: space, identity: "pi", agent: -> { @driver },
                             output: ->(text) { @notices << text },
                             env: {"SPACE_ARCHITECT_GLOBAL_CONFIG" => File.join(@home, "absent-global.yaml")},
                             catalog: -> { Models.load(root: File.join(@home, ".tart")) })
      @space = space
      tools = {}
      @hooks.registered_tools.each { |tool| tools[tool.name.to_s] = tool }
      tools["subagent"] = Tools::Subagent.new(manager: @manager)
      chat = Test::TestChat.build(@server, system_prompt: "driver harness prompt")
      @driver = Agent::Loop.new(chat:, tools:, system_prompt: "driver harness prompt", hooks: @hooks,
                                compaction: {keep_recent_tokens: 1, reserve_tokens: 16_384, enabled: true})
      # The boot's session_start emission (the register precedes it in the
      # real boot): reset + regenerate + validate through the staged catalog.
      @hooks.emit({"type" => "session_start", "reason" => "startup"},
                  context: {cwd: space, mode: "tui", identity: "pi"})
    end

    def drain_captures
      @captures.concat(@server.captured_requests)
    end

    def wait_until_bounded(timeout, what)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        value = yield
        return value if value
        raise "timed out after #{timeout}s waiting for #{what}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep 0.05
      end
    end

    def system_role_content(body)
      message = body["messages"].to_a.find { |m| %w[system developer].include?(m["role"]) }
      message && message["content"].to_s
    end

    def driver_request?(body)
      system_role_content(body) == "driver harness prompt"
    end

    def child_request?(body, marker)
      system_role_content(body).to_s.include?(marker)
    end

    def summarization_request?(body)
      body["messages"].to_a.any? do |m|
        m["role"] == "user" && m["content"].to_s.include?("<conversation>") &&
          m["content"].to_s.include?("Additional focus: ")
      end
    end

    def user_texts(body)
      body["messages"].to_a.select { |m| m["role"] == "user" }.map { |m| m["content"].to_s }
    end

    def tool_calls(body)
      body["messages"].to_a.select { |m| m["role"] == "assistant" }
                          .flat_map { |m| m["tool_calls"].to_a }
                          .map do |call|
        # The wire shape: {id, type, function: {name, arguments: JSON string}}
        # — normalized to {id, name, arguments-hash} for the matchers.
        raw_arguments = call.dig("function", "arguments") || call["arguments"]
        arguments = raw_arguments.is_a?(String) ? (JSON.parse(raw_arguments) rescue {}) : (raw_arguments || {})
        {"id" => call["id"], "name" => call.dig("function", "name") || call["name"], "arguments" => arguments}
      end
    end

    def run_by_agent(agent)
      @manager.runs.find { |record| record[:agent] == agent }
    end

    def wait_terminal(manager, id, timeout = 40)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      record = nil
      while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        record = manager.runs.find { |r| r[:id] == id }
        break if record && record[:state] != :running

        sleep 0.1
      end
      flunk "run #{id} never settled: #{record && record[:state]}" unless record && record[:state] != :running
      debug_run(record)
      record[:state]
    end

    def assert_ps_clean(pid)
      wait_until_bounded(5, "pid #{pid} to be reaped (no zombie)") do
        `ps -p #{Integer(pid)} -o pid=`.strip.empty?
      end
    end

    def debug_run(record)
      return unless ENV["I95_DEBUG"]

      err = File.join(record[:dir], "runner.stderr.log")
      out = File.join(record[:dir], "runner.stdout.log")
      puts "[i95-debug] run #{record[:id]} (#{record[:agent]}) state=#{record[:state]}"
      puts "[i95-debug] status: #{File.read(File.join(record[:dir], 'status.json'))}"
      puts "[i95-debug] stderr tail: #{File.exist?(err) ? File.readlines(err).last(30).join : '(none)'}"
      puts "[i95-debug] stdout tail: #{File.exist?(out) ? File.readlines(out).last(10).join : '(none)'}"
      result_path = File.join(record[:dir], 'result.json')
      puts "[i95-debug] result: #{File.exist?(result_path) ? File.read(result_path) : '(none)'}"
    end

    def assert_run_terminal(record)
      # Re-read through the manager: runs() hands out dup'd snapshot hashes,
      # and a snapshot taken before the settle carries the stale :running.
      fresh = @manager.runs.find { |r| r[:id] == record[:id] } || record
      debug_run(fresh) if fresh[:state] != :completed
      assert_equal :completed, fresh[:state], "the child settled completed"
      status = JSON.parse(File.read(File.join(fresh[:dir], "status.json")))
      assert_equal "completed", status["state"]
      assert_equal true, JSON.parse(File.read(File.join(fresh[:dir], "result.json")))["success"]
      assert_ps_clean(fresh[:pid])
    end

    # The W3/W4 wake harness: the REAL core loop in event-only mode on a
    # background thread, draining the session's synthetic channel, with the
    # frozen on_event rail contract transcribed from bin/tart.
    def wake_kernel(session)
      kernel = Core::Loop.new(session:)
      rail_else = []
      kernel.on_event = lambda do |event, source|
        if event.is_a?(Proc) && source == :synthetic
          kernel.async(&event)
        else
          rail_else << [event, source]
        end
      end
      thread = Thread.new do
        Thread.current.report_on_exception = false
        kernel.run
      end
      [kernel, thread, rail_else]
    end

    def stop_kernel
      return unless @kernel_thread

      @kernel&.stop!
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
      until !@kernel_thread.alive? || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep 0.02
      end
      flunk "the wake kernel never stopped" if @kernel_thread.alive?
      @kernel_thread.join
      @kernel_thread = nil
    end

    # The I48 agent-loop pattern: the run on a background-thread reactor.
    def run_in_background(agent, prompt)
      @run_thread = Thread.new do
        Thread.current.report_on_exception = false
        begin
          Async do |root|
            root.async { agent.run(prompt) }.wait
          end
        rescue Async::Cancel
          nil
        end
      end
    end

    def join_run(timeout = 60)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      until !@run_thread.alive? || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep 0.05
      end
      flunk "the parent run never finished" if @run_thread.alive?
      @run_thread.join
    end

    def kill_stray_children
      @managers.each do |manager|
        manager.runs.each do |record|
          next unless record[:pid]
          Process.kill("TERM", -record[:pid]) rescue nil
        end
      end
    end

    # (1)-(4): the tool installs the playbook, the role files land, a real
    # spec child runs and wakes, and the driver chains builder then judge —
    # every child a real bin/tart -p boot over the project-tier profiles,
    # every wake the REAL notify path (the I94 W3 idiom, zero keypress).
    def test_live_arc_installs_the_playbook_and_three_role_children_run_and_wake
      space = stage_live_space
      build_live_harness(space)
      @server.script([
        # The driver's install turn (the only first driver request).
        {type: :stream, match: ->(body) { driver_request?(body) && tool_calls(body).empty? && user_texts(body) == ["Drive the toy plan"] },
         tool_calls: [{id: "d1", name: "architect_loop", arguments: {from: File.join(space, "notes", "plan-toy.md")}}]},
        # The spawn turn (d1's result rode back).
        {type: :stream, match: ->(body) { driver_request?(body) && tool_calls(body).map { |c| c["id"] } == %w[d1] },
         tool_calls: [{id: "d2", name: "subagent",
                       arguments: {agent: "architect-spec", task: LIVE_SPEC_TASK, async: true,
                                   timeout_ms: 3_600_000, model: "mock/toy-spec:high"}}]},
        # The spec child: its system prompt IS the generated project-tier profile.
        {type: :stream, match: ->(body) { child_request?(body, SPEC_PROFILE_MARKER) }, content: LIVE_SPEC_ANSWER},
        # The spec completion wake turn: spawn the builder (the async spawn
        # turns end on the server's empty-script fallback — the loop
        # continues through the REAL wake path only).
        {type: :stream, match: ->(body) { driver_request?(body) && user_texts(body).any? { |text| text.include?("Background task completed: **architect-spec**") } },
         tool_calls: [{id: "d4", name: "subagent",
                       arguments: {agent: "architect-builder", task: LIVE_BUILDER_TASK, async: true,
                                   timeout_ms: 7_200_000, model: "mock/toy-builder"}}]},
        {type: :stream, match: ->(body) { child_request?(body, BUILDER_PROFILE_MARKER) }, content: LIVE_BUILDER_ANSWER},
        # The builder completion wake turn: spawn the judge.
        {type: :stream, match: ->(body) { driver_request?(body) && user_texts(body).any? { |text| text.include?("Background task completed: **architect-builder**") } },
         tool_calls: [{id: "d5", name: "subagent",
                       arguments: {agent: "architect-judge", task: LIVE_JUDGE_TASK, async: true,
                                   timeout_ms: 7_200_000, model: "mock/toy-judge"}}]},
        {type: :stream, match: ->(body) { child_request?(body, JUDGE_PROFILE_MARKER) }, content: LIVE_JUDGE_ANSWER},
        # The judge completion wake turn: the driver closes.
        {type: :stream, match: ->(body) { driver_request?(body) && user_texts(body).any? { |text| text.include?("Background task completed: **architect-judge**") } },
         content: "TOY ARC DONE"}
      ])

      run_in_background(@driver, "Drive the toy plan")
      join_run # run 1: install + the spec spawn
      spec_run = wait_until_bounded(30, "the spec run to register") { run_by_agent("architect-spec") }
      assert_equal :completed, wait_terminal(@manager, spec_run[:id])
      builder_run = wait_until_bounded(30, "the builder run to register") { run_by_agent("architect-builder") }
      assert_equal :completed, wait_terminal(@manager, builder_run[:id])
      judge_run = wait_until_bounded(30, "the judge run to register") { run_by_agent("architect-judge") }
      assert_equal :completed, wait_terminal(@manager, judge_run[:id])
      # The final wake turn closed the arc.
      wait_until_bounded(30, "the judge-completion wake turn") do
        drain_captures
        @captures.any? do |body|
          driver_request?(body) && user_texts(body).any? { |text| text.include?("Background task completed: **architect-judge**") }
        end
      end
      drain_captures

      agents = @manager.runs.map { |record| record[:agent] }.sort
      assert_equal %w[architect-builder architect-judge architect-spec], agents,
        "the driver chained spec → builder → judge through the real subagent tool"
      @manager.runs.each { |record| assert_run_terminal(record) }

      # (1) The tool's RESULT text is the playbook (first + last lines pinned).
      install_request = @captures.find { |body| tool_calls(body).map { |c| c["name"] }.include?("architect_loop") }
      assert install_request, "the driver called architect_loop"
      result_request = @captures.find do |body|
        body["messages"].to_a.any? { |m| m["role"] == "tool" && m["tool_call_id"] == "d1" }
      end
      playbook_result = result_request["messages"].find { |m| m["role"] == "tool" && m["tool_call_id"] == "d1" }["content"].to_s
      expected = live_expected_playbook(space)
      assert_equal expected, playbook_result, "the wire tool result IS the composed playbook"
      assert_equal "You are the architect session driving one space-architect plan to completion by spawning role " \
        "subagents and tending them. You never do lane work yourself.", playbook_result.lines.first.chomp
      assert playbook_result.lines.last.chomp.end_with?("build/ stays ephemeral per-run scratch."),
        "the playbook's closing law closes its last line: #{playbook_result.lines.last[0, 60].inspect}"
      assert_includes @notices, "architect loop: driver mode engaged — this session now drives the plan " \
        "(#{File.join(space, 'notes', 'plan-toy.md')}); driving starts this turn, first architect_compact after the first child launch."

      # (1) The four role files exist with the routed model — byte-asserted
      # against the composer; NO .pi/ dir anywhere.
      config = live_expected_config(space)
      ROLES.each do |role|
        file = File.join(space, ".tart", "agents", "architect-#{role}.md")
        assert File.exist?(file), "the role file exists: #{role}"
        assert_equal ArchitectLoop.render_agent_file(role, config), File.read(file)
        frontmatter, = Skills.parse_frontmatter(File.read(file))
        assert_equal "mock/toy-#{role}", frontmatter["model"]
      end
      refute Dir.glob(File.join(space, "**", ".pi")).any?, "NO .pi/ dir anywhere under the scratch space"

      # (2) The spec child booted the PROJECT-TIER profile: its system prompt
      # is the spec playbook (+ the bridge), its wire tools the role file's.
      spec_request = @captures.find { |body| child_request?(body, SPEC_PROFILE_MARKER) }
      refute_nil spec_request, "the spec child made a real wire request"
      assert_equal "toy-spec", spec_request["model"], "the routing model pin rode the child's wire"
      spec_tools = spec_request["tools"].to_a.map { |t| t.dig("function", "name") }.compact
      assert_equal %w[read grep find ls bash edit write contact_supervisor], spec_tools,
        "the role file's tool list + the bridge tool LAST"
      assert_equal 3_600_000, JSON.parse(File.read(File.join(spec_run[:dir], "status.json")))["timeoutMs"],
        "the spawn contract's explicit spec timeout (never the 30-minute default)"
      spec_prompt = File.read(File.join(spec_run[:dir], "system-prompt.md"))
      assert_includes spec_prompt, ArchitectLoop::ROLE_PLAYBOOKS["spec"]
      assert_includes spec_prompt, Subagents::Supervisor::BRIDGE_INSTRUCTION
      assert_includes spec_request["messages"].last["content"].to_s, LIVE_SPEC_TASK
      assert_equal 7_200_000, JSON.parse(File.read(File.join(builder_run[:dir], "status.json")))["timeoutMs"]
      assert_equal "toy-builder", @captures.find { |body| child_request?(body, BUILDER_PROFILE_MARKER) }["model"]

      # (3) The completion notify + wake landed the driver's NEXT request
      # with the notify content and the prior turn's history (the I94 W3/W4
      # idiom — bounded waits, ZERO keypress).
      wake_request = @captures.find do |body|
        driver_request?(body) && user_texts(body).any? { |text| text.include?("Background task completed: **architect-spec**") }
      end
      refute_nil wake_request, "the completion notify opened a driver turn"
      notify_text = user_texts(wake_request).find { |text| text.include?("Background task completed: **architect-spec**") }
      assert_includes notify_text, LIVE_SPEC_ANSWER, "the child's output preview rides the notify"
      assert_includes JSON.generate(wake_request["messages"]), "Drive the toy plan",
        "the wake request carries the prior turn's history"
      assert_empty @rail_else, "the rail's non-wake arm never fired (ZERO native events)"
      assert_equal LIVE_JUDGE_ANSWER, JSON.parse(File.read(File.join(judge_run[:dir], "result.json")))["output"].to_s.strip
    ensure
      kill_stray_children
    end

    # (5): the staged escalation round trip — a real child asks, the ask
    # surfaces in the driver's next request with the byte-pinned strings,
    # the driver replies via the subagent tool's reply action ON THE LEAF
    # REQUEST ID, the child unblocks and completes.
    def test_live_escalation_round_trip_replies_on_the_leaf_request_id
      space = stage_live_space
      build_live_harness(space)
      judge_run_holder = []
      # The reply's reply_to IS the leaf child's request id — read from the
      # child's control dir AT MATCH TIME (the ask file precedes any wake:
      # the channel surfaces only from the file), so the id is learned the
      # way the driver learns it, with no timing bet.
      reply_entry = {
        type: :stream,
        match: lambda do |body|
          begin
            next false unless driver_request?(body) &&
                              user_texts(body).any? { |text| text.include?(LIVE_ESCALATION_QUESTION) }
            run = judge_run_holder.first
            files = run ? Dir.glob(File.join(run[:dir], "control", "supervisor-requests", "*.json")) : []
            next false if files.empty?

            payload = JSON.parse(File.read(files.first))
            reply_entry[:tool_calls] = [{id: "dR", name: "subagent",
                                         arguments: {action: "reply", reply_to: payload["id"], message: "THE RULING: yes"}}]
            true
          rescue StandardError
            false
          end
        end
      }
      @server.script([
        {type: :stream, match: ->(body) { driver_request?(body) && tool_calls(body).empty? && user_texts(body) == ["Escalate the toy plan"] },
         tool_calls: [{id: "e1", name: "architect_loop", arguments: {from: File.join(space, "notes", "plan-toy.md")}}]},
        {type: :stream, match: ->(body) { driver_request?(body) && tool_calls(body).map { |c| c["id"] } == %w[e1] },
         tool_calls: [{id: "e2", name: "subagent",
                       arguments: {agent: "architect-judge", task: LIVE_JUDGE_TASK, async: true,
                                   timeout_ms: 7_200_000, model: "mock/toy-judge"}}]},
        # The judge child asks (the intercom bridge arms every role child).
        {type: :stream, match: ->(body) { child_request?(body, JUDGE_PROFILE_MARKER) },
         tool_calls: [{id: "j1", name: "contact_supervisor",
                       arguments: {reason: "need_decision", message: LIVE_ESCALATION_QUESTION}}]},
        reply_entry,
        # The unblocked judge completes.
        {type: :stream, match: ->(body) { child_request?(body, JUDGE_PROFILE_MARKER) }, content: LIVE_JUDGE_ANSWER},
        # The judge completion wake turn: the driver closes.
        {type: :stream, match: ->(body) { driver_request?(body) && user_texts(body).any? { |text| text.include?("Background task completed: **architect-judge**") } },
         content: "ESCALATION ARC DONE"}
      ])

      run_in_background(@driver, "Escalate the toy plan")
      judge_run = wait_until_bounded(30, "the judge run to register") { run_by_agent("architect-judge") }
      judge_run_holder << judge_run
      assert_equal :completed, wait_terminal(@manager, judge_run[:id], 40), "the child unblocked and completed"
      join_run

      drain_captures
      # The surfaced ask rode the driver's wake request as USER-role wire
      # text with the §4.4 byte-pinned strings.
      ask_request = @captures.find do |body|
        driver_request?(body) && user_texts(body).any? { |text| text.include?(LIVE_ESCALATION_QUESTION) }
      end
      refute_nil ask_request, "the child's own ask surfaced in the driver's next request"
      assert_includes JSON.generate(ask_request["messages"]), "Escalate the toy plan",
        "the wake request carries the prior turn's history"
      ask_message = user_texts(ask_request).find { |text| text.include?(LIVE_ESCALATION_QUESTION) }
      assert_includes ask_message, "Subagent needs a supervisor decision."
      assert_includes ask_message, "Run: #{judge_run[:id]}"
      assert_includes ask_message, "Agent: architect-judge"
      assert_includes ask_message, 'Reply with: subagent({ action: "reply", reply_to: "'
      assert_includes ask_message, "(Reply to the pending request first.)"

      # The reply rode the LEAF request id (the driver's reply action), and
      # the child's NEXT request carried the answer as the tool result.
      reply_call = @captures.flat_map { |body| tool_calls(body) }
                            .find { |call| call.is_a?(Hash) && call.dig("arguments", "action") == "reply" }
      refute_nil reply_call, "the driver replied via the subagent tool's reply action"
      assert_equal "subagent", reply_call["name"]
      assert_match(/\A[0-9a-f-]{36}\z/, reply_call.dig("arguments", "reply_to").to_s, "ON the leaf request id")
      judge_requests = @captures.select { |body| child_request?(body, JUDGE_PROFILE_MARKER) }
      assert judge_requests.size >= 2, "the judge made a post-reply request"
      assert judge_requests.any? do |body|
        body["messages"].to_a.any? do |m|
          m["role"] == "tool" && m["content"].to_s.include?("**Reply from supervisor:**\nTHE RULING: yes")
        end
      end
      files = Dir.glob(File.join(judge_run[:dir], "control", "supervisor-requests", "*.json"))
      assert_empty files, "the child's request file was swept (the reply consumed it)"
      assert_equal LIVE_JUDGE_ANSWER, JSON.parse(File.read(File.join(judge_run[:dir], "result.json")))["output"].to_s.strip
      assert_run_terminal(judge_run)
    ensure
      kill_stray_children
    end

    # (6): after a child launch the driver calls architect_compact — the
    # pending compaction runs at the post-run point with the playbook as
    # custom instructions, observed in the captured summarization request.
    def test_live_compaction_after_first_child_launch_carries_the_playbook
      space = stage_live_space
      build_live_harness(space)
      @server.script([
        {type: :stream, match: ->(body) { driver_request?(body) && tool_calls(body).empty? && user_texts(body) == ["Compact the toy drive"] },
         tool_calls: [{id: "k1", name: "architect_loop", arguments: {from: File.join(space, "notes", "plan-toy.md")}}]},
        {type: :stream, match: ->(body) { driver_request?(body) && tool_calls(body).map { |c| c["id"] } == %w[k1] },
         tool_calls: [{id: "k2", name: "subagent",
                       arguments: {agent: "architect-spec", task: LIVE_SPEC_TASK, async: true,
                                   timeout_ms: 3_600_000, model: "mock/toy-spec"}}]},
        {type: :stream, match: ->(body) { driver_request?(body) && tool_calls(body).map { |c| c["id"] } == %w[k1 k2] },
         tool_calls: [{id: "k3", name: "architect_compact", arguments: {}}]},
        {type: :stream, match: ->(body) { driver_request?(body) && tool_calls(body).map { |c| c["id"] } == %w[k1 k2 k3] &&
          user_texts(body).none? { |text| text.include?("Background task completed") } },
         content: "driving on — compaction scheduled"},
        # The scheduled-manual summarization request (the post-run point).
        {type: :stream, match: ->(body) { summarization_request?(body) }, content: "TOY COMPACT SUMMARY"},
        {type: :stream, match: ->(body) { child_request?(body, SPEC_PROFILE_MARKER) }, content: LIVE_SPEC_ANSWER},
        {type: :stream, match: ->(body) { driver_request?(body) && user_texts(body).any? { |text| text.include?("Background task completed: **architect-spec**") } },
         content: "COMPACT DRIVE DONE"}
      ])

      run_in_background(@driver, "Compact the toy drive")
      join_run # run 1 ends after the compaction landed (the post-run drain)
      spec_run = wait_until_bounded(30, "the spec run to register") { run_by_agent("architect-spec") }
      assert_equal :completed, wait_terminal(@manager, spec_run[:id])
      drain_captures

      if ENV["I95_DEBUG"]
        @captures.each_with_index do |body, index|
          marks = user_texts(body).map { |t| t[0, 40].inspect } + [system_role_content(body)[0, 40].inspect]
          puts "[i95-debug] capture #{index}: users=#{marks.uniq.inspect}"
        end
      end
      summary_request = @captures.find { |body| summarization_request?(body) }
      refute_nil summary_request, "the pending manual compaction ran at the post-run point"
      prompt = summary_request["messages"].last["content"].to_s
      expected_playbook = live_expected_playbook(space)
      assert prompt.end_with?("\n\nAdditional focus: #{expected_playbook}"),
        "the summarization request carries pi's exact carry bytes + the playbook text"
      assert_equal expected_playbook, ArchitectLoop.driver_playbook_text, "the driver state held the carried playbook"

      # The compaction LANDED before the wake: the wake request's history
      # carries the summary marker and the original prompt is gone (bounded
      # wait — the notify's kick fires right after the child settles).
      wake_request = wait_until_bounded(15, "the completion wake turn") do
        drain_captures
        @captures.find do |body|
          driver_request?(body) && user_texts(body).any? { |text| text.include?("Background task completed: **architect-spec**") }
        end
      end
      summary_message = wake_request["messages"].to_a.find do |m|
        m["role"] == "user" && m["content"].to_s.include?(Compaction::COMPACTION_SUMMARY_PREFIX)
      end
      refute_nil summary_message, "the post-compaction summary rides the history"
      assert_includes summary_message["content"].to_s, "TOY COMPACT SUMMARY"
      refute_includes JSON.generate(wake_request["messages"]), "Compact the toy drive",
        "the pre-compaction prompt was summarized away"
      # The tool's own result text rode the wire (pi's byte-carried string).
      compact_result_request = @captures.find do |body|
        body["messages"].to_a.any? { |m| m["role"] == "tool" && m["tool_call_id"] == "k3" }
      end
      compact_result = compact_result_request["messages"].find { |m| m["role"] == "tool" && m["tool_call_id"] == "k3" }["content"].to_s
      assert_equal "Session compaction scheduled with the driver playbook as customInstructions — the keep-essentials " \
        "(plan reference, routing pins, per-iteration procedure) survive; ground everything else from disk.", compact_result
      assert_run_terminal(spec_run)
    ensure
      kill_stray_children
    end

    def live_expected_config(space)
      ArchitectLoop.resolve_config(space, env: {"SPACE_ARCHITECT_GLOBAL_CONFIG" => File.join(@home, "absent-global.yaml")})
    end

    def live_expected_playbook(space)
      ArchitectLoop.driver_playbook(live_expected_config(space), File.join(space, "notes", "plan-toy.md"), nil)
    end
  end
end
