# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "shellwords"
# The app-side mock LLM server (top-level MockLLMServer, minitest-free).
# Dev-only cross-tree require: from gems/tui-split-rig/lib/tui_split_rig, four
# levels up is the tart repo root — test/support. Never ships.
require_relative "../../../../test/support/mock_llm_server"

module TuiSplitRig
  # The oracle resolution seam (I67 R1): the pinned repos/pi clone @ v1.1.0
  # is the rig's ONLY oracle — the system pi on PATH is never consulted.
  # Resolution order, frozen: the --pi-bin flag (kept verbatim) → the
  # TUI_SPLIT_RIG_PI_BIN env escape hatch → the pinned clone default
  # <pi-root>/packages/coding-agent/dist/bundle/cli.js (the clone's built
  # entry — package.json "bin": {"pi": "dist/bundle/cli.js"}).
  # pi_root is the sibling `pi` of the tart repo root; the default-root
  # case alone falls back to the CANONICAL checkout (git rev-parse
  # --git-common-dir, dirname'd — the worktree case) when the direct
  # sibling is missing. An explicit tart_root gets NO git fallback (the
  # pure testability contract). Unresolvable → Error naming the expected
  # clone path. Direct oracle execs must strip PI_PACKAGE_DIR — pi's
  # getPackageDir prefers the env over the __dirname walk
  # (coding-agent config.ts:393-405); the rig's pane env scrub
  # (env_flags) already covers the in-pane class.
  def self.resolve_pi_bin(flag: nil, env: ENV, tart_root: nil)
    return flag unless flag.nil? || flag.to_s.empty?

    from_env = env["TUI_SPLIT_RIG_PI_BIN"]
    return from_env unless from_env.nil? || from_env.to_s.empty?

    cli = File.join(pi_root_for(tart_root), "packages", "coding-agent", "dist", "bundle", "cli.js")
    return File.expand_path(cli) if File.executable?(cli)

    raise Error, "pinned pi clone not found: expected #{cli} " \
                 "(repos/pi on tag v1.1.0 with a built dist/bundle/cli.js)"
  end

  # The pi clone root: the sibling `pi` of the tart repo root. Explicit
  # tart_root → sibling, no fallback. Default root → the rig's own repo
  # root, and when the direct sibling clone is missing there, the
  # canonical checkout via git rev-parse --git-common-dir (a worktree's
  # git-common-dir points at the canonical .git — dirname is the
  # canonical checkout; git failure degrades to the direct sibling, whose
  # missing cli.js raises with the named path).
  def self.pi_root_for(tart_root)
    repo = tart_root ? File.expand_path(tart_root) : File.expand_path("../../../..", __dir__)
    sibling = File.expand_path("../pi", repo)
    return sibling if tart_root
    return sibling if File.executable?(File.join(sibling, "packages", "coding-agent", "dist", "bundle", "cli.js"))

    git_dir = Open3.capture2("git", "-C", repo, "rev-parse", "--git-common-dir")[0].to_s.strip
    return sibling if git_dir.empty?

    canonical = File.expand_path("..", File.expand_path(git_dir, repo))
    File.expand_path("../pi", canonical)
  end

  # Drives one scenario: for each run, boots ONE mock LLM server, stages
  # isolated environments under the out dir, runs pi and tart side by side
  # in 120x40 tmux panes against the same byte-identical response script,
  # captures the settled screen of each, tears everything down hard, then
  # diffs the capture pair through the registry.
  #
  # Teardown discipline (I01 finding): tmux kill-session does NOT reliably
  # kill the apps — tart survives SIGHUP spinning at 100% CPU. Every pane
  # command is exec-wrapped (verified live: pane_pid IS the app process —
  # the exec chain replaces the pane's default fish shell), so teardown
  # kills -9 the pane pid and all descendants, waits for exit, kills the
  # session, and asserts no survivor and no leftover session OF ITS OWN
  # (I27: sessions carry a per-Runner token, and the leftover check greps
  # only that token — concurrent rig processes on the shared tmux server
  # must not flake each other's end-of-run check or kill each other's panes).
  class Runner
    GEOMETRY = %w[-x 120 -y 40].freeze
    POLL_INTERVAL = 0.25
    QUIET_POLLS = 3 # 3 consecutive identical polls ≈ 750 ms quiescence
    HARD_CAP = 30.0 # seconds per settle wait
    KILL_WAIT = 5.0 # seconds to wait for killed pids to disappear
    # The tmux format string for the pane pid, as a literal (single-quoted:
    # no Ruby interpolation).
    PANE_PID_FORMAT = '#{pane_pid}'

    Result = Struct.new(:exit_code, :summary, :out_dir, keyword_init: true)

    def initialize(scenario:, runs: 1, app: "both", out: nil, tart_dir: default_tart_dir,
                   pi_bin: default_pi_bin, registry: default_registry)
      @scenario = scenario
      @runs = runs
      @app = app
      @tart_dir = File.expand_path(tart_dir || default_tart_dir)
      @pi_bin = File.expand_path(pi_bin || default_pi_bin)
      @registry_path = File.expand_path(registry)
      @out_dir = File.expand_path(out || default_out_dir)
      @failure = nil
      @bundle_bin = resolve_bundle_bin
      # Concurrent-run scoping (I27): every session this runner creates is
      # named tui-split-rig-<token>-…, and the leftover check greps only
      # that token — another process's live sessions are invisible to it.
      @token = format("%04x%04x", rand(65_536), rand(65_536))
    end

    attr_reader :out_dir, :token

    def run!
      FileUtils.mkdir_p(@out_dir)
      registry = Registry.load(@registry_path)
      run_results = (1..@runs).map { |n| run_once(n, registry) }
      summary = build_summary(run_results)
      Report.write(@out_dir, @scenario, summary)
      Result.new(exit_code: summary.fetch("exit_code"), summary: summary, out_dir: @out_dir)
    end

    # The per-app boot primitives the probe reuses (bin/tool-pending-probe
    # drives a mid-flight capture through the same staging the runner uses
    # — the probe needs the panes DURING the turn, not at settle).
    def boot_session(app, mock, n, stage)
      home = File.join(stage, "home", app)
      sandbox = File.join(stage, "sandbox", app)
      [home, sandbox].each { |dir| FileUtils.mkdir_p(dir) }
      agent_dir = app == "pi" ? stage_pi_agent(stage, mock.port) : nil
      stage_tart_home(home, mock.port) if app == "tart"
      # BEFORE the boot (the apps scan resources at startup — a staged file
      # landing after the scan is a race): the scenario's loaded-resource
      # set, byte-identical per app (the s9 instrument).
      stage_project_resources(home:, sandbox:, agent_dir:) if @scenario.stage_project_resources
      # Same boot-race discipline for the memory set (the s11 instrument):
      # pi scans its agent dir's extensions/ at startup.
      stage_memory(app, home:, sandbox:, agent_dir:) if @scenario.stage_memory

      session = session_name(app, n)
      command = app == "pi" ? pi_command(home, agent_dir) : tart_command(sandbox, home, mock.port)
      tmux("kill-session", "-t", session) if session_exists?(session)
      tmux("new-session", "-d", *GEOMETRY, "-c", sandbox, "-s", session, command)
      {session:, home:, sandbox:, agent_dir:}
    end

    # The token-scoped tmux session name (I27): unique per runner, app,
    # scenario and run; the leftover check greps for exactly this shape.
    def session_name(app, n)
      "tui-split-rig-#{@token}-#{app}-#{@scenario.name}-r#{n}-#{format('%04x', rand(65_536))}"
    end

    private

    def run_once(n, registry)
      stage = File.join(@out_dir, "run-#{n}")
      mock = MockLLMServer.new.script(@scenario.responses)
      mock.suppress_usage! if @scenario.suppress_usage
      mock.start
      apps = {}
      begin
        (@app == "both" ? %w[pi tart] : [@app]).each do |app|
          mock.rearm!
          apps[app] = run_app(app, mock, n, stage)
        end
      ensure
        mock.stop
      end
      assert_clean_sessions!
      run_result(n, stage, apps, registry)
    end

    def run_app(app, mock, n, stage)
      staged = boot_session(app, mock, n, stage)
      session = staged[:session]

      boot = settle(session, "boot")
      alive = session_exists?(session)
      # The scenario's resize knob (the s16 instrument, I56): after the boot
      # settle, BEFORE the paste/prompt block — resize-window moves a
      # manual-size session (resize-PANE does not, Grounds §1), then a
      # re-settle. The no-knob path stays byte-frozen (every pre-I56
      # scenario's flow identical).
      if alive && @scenario.resize
        width, height = @scenario.resize
        tmux("resize-window", "-t", session, "-x", width.to_s, "-y", height.to_s)
        settle(session, "resize")
      end
      if alive && @scenario.paste
        # The paste knob (I55, s14/s15): the text rides a token-scoped tmux
        # buffer; paste-buffer -p wraps it in the bracketed-paste pair the
        # apps enable (live-calibrated — Grounds §4.1), so the app sees ONE
        # Paste event, exactly like a terminal paste. Then the prompt only
        # when non-empty; Enter only when submit (paste-only display flows
        # never submit).
        paste_path = File.join(stage, "#{app}-paste.txt")
        File.write(paste_path, @scenario.paste)
        buffer = "tui-split-rig-#{@token}-paste"
        tmux("load-buffer", "-b", buffer, paste_path)
        tmux("paste-buffer", "-b", buffer, "-p", "-t", session)
        tmux("delete-buffer", "-b", buffer)
        tmux("send-keys", "-t", session, @scenario.prompt) unless @scenario.prompt.empty?
        tmux("send-keys", "-t", session, "Enter") if @scenario.submit
      elsif alive
        # The no-knob path is byte-frozen (I55 Spec D6): today's ONE call,
        # unsplit and unreordered — the s1–s10 battery is its regression net.
        tmux("send-keys", "-t", session, @scenario.prompt, "Enter")
      end
      # The scenario's mid-run keys (the s12/s13 instrument, I54): after
      # the prompt, poll the mock's NON-DRAINING request_count until the
      # after_request-th request has been SERVED (HARD_CAP-bounded — a dead
      # pane or a timeout fails the app's completed), then send the tokens
      # verbatim. The existing reply settle continues (default: today's
      # behavior, byte-identical — the knob is nil for every pre-I54
      # scenario).
      alive &&= send_mid_run_keys(session, mock) if alive && @scenario.mid_run_keys
      reply = alive ? settle(session, "reply") : {ms: nil, timed_out: true}
      # The scenario's post-settle keys (the s9 instrument): each token
      # sent after the reply settles, then a re-settle, so the capture
      # shows the flow's SETTLED screen. A dead pane sends nothing.
      @scenario.post_settle_keys.each do |key|
        next unless session_exists?(session)

        tmux("send-keys", "-t", session, key)
        reply = settle(session, "post-settle #{key}")
      end

      # A dead session still gets a capture file (empty) — the rig reports
      # the failure, it never crashes on a missing artifact.
      capture_path = File.join(stage, "#{app}.capture")
      File.write(capture_path, session_exists?(session) ? capture(session) : "")
      styled_path = File.join(stage, "#{app}.capture.styled")
      File.write(styled_path, session_exists?(session) ? capture_styled(session) : "")

      requests = mock.captured_request_logs
      request_log = File.join(stage, "#{app}-requests.jsonl")
      File.write(request_log, requests.map { |r| JSON.generate(r) }.join("\n") << "\n")

      # `completed` is computed BEFORE the replay leg (I57): the re-boot
      # expects no requests and must not move the counts.
      completed = alive && !reply[:timed_out] && requests.size == @scenario.expected_requests

      result = {
        "app" => app, "session" => session, "completed" => completed,
        "requests" => requests.size, "expected_requests" => @scenario.expected_requests,
        "capture" => capture_path, "styled_capture" => styled_path, "request_log" => request_log,
        "boot_settle_ms" => boot[:ms], "boot_timed_out" => boot[:timed_out],
        "reply_settle_ms" => reply[:ms], "reply_timed_out" => reply[:timed_out],
      }
      teardown(session)
      capture_replay(app, staged, n, stage, mock, result) if @scenario.replay
      result
    end

    # The replay knob's leg (I57, s17): AFTER the completed computation
    # and the primary teardown, re-boot the app on its RECORDED session —
    # pi `--continue` (no picker, the most recent session for the cwd);
    # tart the `-r` flag APPENDED AFTER the workdir positional
    # (OptionParser's optional [ID] placeholder greedily eats a following
    # token — `bin/tart -r <workdir>` mis-parses, probed live in the I57
    # calibration). Same staged home/sandbox, a fresh token-scoped
    # session name, a settle, the replay captures, teardown. NO prompt is
    # sent; no requests are expected; `completed` is untouched.
    def capture_replay(app, staged, n, stage, mock, result)
      session = session_name(app, n)
      command = if app == "pi"
        "#{pi_command(staged[:home], staged[:agent_dir])} --continue"
      else
        "#{tart_command(staged[:sandbox], staged[:home], mock.port)} -r"
      end
      tmux("kill-session", "-t", session) if session_exists?(session)
      tmux("new-session", "-d", *GEOMETRY, "-c", staged[:sandbox], "-s", session, command)
      settle(session, "replay")
      File.write(File.join(stage, "#{app}.replay.capture"), session_exists?(session) ? capture(session) : "")
      File.write(File.join(stage, "#{app}.replay.capture.styled"), session_exists?(session) ? capture_styled(session) : "")
      teardown(session)
      result["replay_capture"] = File.join(stage, "#{app}.replay.capture")
      result["replay_styled_capture"] = File.join(stage, "#{app}.replay.capture.styled")
    end

    # Stages the pi agent dir with the mock provider (I01-verified shape);
    # PI_CODING_AGENT_DIR at this path also suppresses first-time setup,
    # and sessions land under it.
    def stage_pi_agent(stage, port)
      # pi's real layout: the agent dir lives under HOME (~/.pi/agent,
      # config.ts:610) — the staged tree mirrors that, so the resource
      # paths under it ~-contract exactly like the port's settings-root
      # paths (the s9 [Skills] rows).
      agent_dir = File.join(stage, "home", "pi", ".pi", "agent")
      FileUtils.mkdir_p(agent_dir)
      window = @scenario.context_window || 32_768
      config = {
        providers: {
          mock: {
            baseUrl: "http://127.0.0.1:#{port}/v1",
            apiKey: "mock-key",
            api: "openai-completions",
            models: [
              {id: "mock-1", name: "Mock 1", reasoning: false, contextWindow: window, maxTokens: 512},
            ],
          },
        },
      }
      File.write(File.join(agent_dir, "models.json"), JSON.pretty_generate(config))
      # The parity TARGET is the owner's daily-driver pi (~/.pi/agent/
      # settings.json: "theme": "dark") — a fresh staged HOME otherwise
      # boots the SYSTEM theme (theme.ts:683 `themeName ?? SYSTEM_THEME_NAME`),
      # and under tmux (no OSC palette report) that degenerates to the
      # indexed-16 fallback: accent 38;5;5, neutrals as the [2m dim
      # attribute. Every style measured against that config was an
      # artifact — dark renders truecolor 38;2;r;g;b tokens instead.
      #
      # A scenario context_window shrinks BOTH compaction knobs to zero
      # (settings-manager.ts:822 — the same keys the port's settings.json
      # compaction block reads): with the window at a few tokens the
      # threshold trigger fires after the first completed turn in either
      # app — the s7 compaction scenario's lever. Unset (s1–s6), nothing
      # changes: pi's defaults (settings-defaults.ts:9-13) hold.
      settings = {theme: "dark"}
      settings[:compaction] = {enabled: true, reserveTokens: 0, keepRecentTokens: 0} if @scenario.context_window
      File.write(File.join(agent_dir, "settings.json"), JSON.pretty_generate(settings))
      agent_dir
    end

    # The tart-side mirror of the pi compaction staging: the staged HOME's
    # global settings (settings.rb global root — HOME/.tart/settings.json)
    # carrying the same zeroed compaction knobs. The context window itself
    # rides the identity-namespaced CONTEXT_WINDOW env in tart_command.
    #
    # The model-menu staging (I27): HOME/.tart/models.json — pi's staged
    # models.json shape (providers → {baseUrl, apiKey, api, models}) with
    # TWO mock models, so the /model menu has something to select. Inert
    # for tart at the pre-model-lane base (no reader); the model lane's
    # reader contract must match this shape. I36 staging symmetry: mock-2
    # (reasoning:true) also carries the owner's full-string
    # thinkingLevelMap — the same catalog shape both sides' thinking
    # resolution reads; mock-1 (reasoning:false) stays map-less. Inert for
    # the pinned scenarios (mock-2 never boots; the menu renders id/name
    # only) — no new scenario, no registry change.
    def stage_tart_home(home, port)
      dir = File.join(home, ".tart")
      FileUtils.mkdir_p(dir)
      models = {
        providers: {
          mock: {
            baseUrl: "http://127.0.0.1:#{port}/v1",
            apiKey: "mock-key",
            api: "openai-completions",
            models: [
              {id: "mock-1", name: "Mock 1", reasoning: false, contextWindow: (@scenario.context_window || 32_768), maxTokens: 512},
              {id: "mock-2", name: "Mock 2", reasoning: true, contextWindow: (@scenario.context_window || 32_768), maxTokens: 512,
               thinkingLevelMap: {"off" => "low", "minimal" => "low", "low" => "low", "medium" => "medium",
                                  "high" => "high", "xhigh" => "xhigh", "max" => "max"}},
            ],
          },
        },
      }
      File.write(File.join(dir, "models.json"), JSON.pretty_generate(models))
      # I67 R2: the tart-pane docs pin — stage bin/pi as a SYMLINK to the
      # resolved @pi_bin (the same pinned clone the pi pane runs) and
      # prepend that bin dir to the staged PATH (see tart_command):
      # tart's SystemPrompt.pi_package_dir realpath walk (system_prompt.rb
      # :173-191) then realpaths into the pinned clone, making both
      # panes' <docs> segments byte-identical (the s8 cure).
      bin_dir = File.join(home, "bin")
      FileUtils.mkdir_p(bin_dir)
      FileUtils.ln_sf(@pi_bin, File.join(bin_dir, "pi"))
      return unless @scenario.context_window

      File.write(File.join(dir, "settings.json"), JSON.pretty_generate(
        "compaction" => {"enabled" => true, "reserveTokens" => 0, "keepRecentTokens" => 0}
      ))
    end

    # The loaded-resource set the [Context]/[Skills]/[Prompts] sections
    # list (the s9 instrument, stage_project_resources): AGENTS.md at the
    # cwd, one project skill + one project prompt template under each
    # app's config dir (pi resource-loader.ts:991-998 — agentDir + the
    # cwd CONFIG_DIR; tart's mirror: skills.rb/prompts.rb load roots),
    # one user skill in the staged agent dir (pi: agentDir/skills; tart:
    # the staged settings root's skills/). Byte-identical per app; valid
    # frontmatter (a missing description blocks the port's load).
    def stage_project_resources(home:, sandbox:, agent_dir:)
      File.write(File.join(sandbox, "AGENTS.md"), AGENTS_MD)
      # Pre-seed pi's project-trust store (the dialog's own "Trust"
      # outcome — trust-manager.ts:214: <agentDir>/trust.json, keyed by
      # the canonicalized cwd): the staged .pi dir would otherwise pop
      # the trust dialog at boot, racing the prompt typing (the base s9
      # run swallowed the prompt once).
      # Pre-seed pi's project-trust store (the dialog's own "Trust"
      # outcome — trust-manager.ts:214: <agentDir>/trust.json, keyed by
      # the canonicalized cwd): the staged .pi dir would otherwise pop
      # the trust dialog at boot, racing the prompt typing (the base s9
      # run swallowed the prompt once).
      if agent_dir
        FileUtils.mkdir_p(agent_dir)
        File.write(File.join(agent_dir, "trust.json"), JSON.generate({File.realpath(sandbox) => true}))
      end
      {"pi" => ".pi", "tart" => ".tart"}.each do |app, config_dir|
        root = File.join(sandbox, config_dir)
        FileUtils.mkdir_p(File.join(root, "skills"))
        FileUtils.mkdir_p(File.join(root, "prompts"))
        File.write(File.join(root, "skills", "demo.md"), DEMO_SKILL_MD)
        File.write(File.join(root, "prompts", "demo.md"), DEMO_PROMPT_MD)
      end
      # A DISTINCT user-skill name: the same name in both scopes fires
      # both apps' collision diagnostics (pi's [Skill conflicts] section
      # — a cut section the base s9 run surfaced).
      user_skills = {"pi" => agent_dir && File.join(agent_dir, "skills"), "tart" => File.join(home, ".tart", "skills")}
      user_skills.compact.each do |_app, dir|
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, "demo-user.md"), DEMO_USER_SKILL_MD)
      end
    end

    AGENTS_MD = <<~MD.freeze
      # Demo project

      Staged context file for the s9 startup-help scenario.
    MD
    DEMO_SKILL_MD = <<~MD.freeze
      ---
      name: demo
      description: Staged demo skill for the s9 startup-help scenario.
      ---
      Staged demo skill body.
    MD
    DEMO_USER_SKILL_MD = <<~MD.freeze
      ---
      name: demo-user
      description: Staged demo user skill for the s9 startup-help scenario.
      ---
      Staged demo user skill body.
    MD
    DEMO_PROMPT_MD = <<~MD.freeze
      ---
      description: Staged demo prompt template for the s9 startup-help scenario.
      ---
      Staged demo prompt body.
    MD

    # The memory-recall staging (the s11 instrument, I47 Grounds §6): BOTH
    # apps run with the owner's memory behavior ACTIVE. pi loads the owner's
    # memory.ts VERBATIM — the rig fixture copied into the staged agent
    # dir's extensions/; user-dir extensions auto-load with NO settings row
    # (package-manager.ts:2446-2453; verified live: the "[Extensions]\n
    # memory.ts" header row renders) — and reads its index under the agent
    # dir (PI_MEMORY_HOME unset → ~/.pi/agent/memory, memory.ts:13). tart
    # gets the SAME behavior from the core lane's native module, gated by
    # the settings row {"memory" => true} deep-merged into the staged
    # settings.json — never clobbering the compaction rows the
    # context_window lever writes (the s7/s8 family coexist) — with its
    # store under .tart/memory/<project-key>/. The project key is
    # memory.ts's own rule (memory_project_key) — NOT the hard-coded
    # "pi"/"tart" the frozen letter assumed: the sandboxes carry no .git
    # but the walk ascends PAST them, and rig out dirs live inside the tart
    # checkout (PHASE 0, verified live — with a hard-coded key the recall
    # no-ops and the block never renders). The index bytes are the frozen
    # Grounds §6 oracle content — both sides render them as the recall
    # block; the bytes are the gate, not a registry class.
    def stage_memory(app, home:, sandbox:, agent_dir: nil)
      key = memory_project_key(sandbox)
      if app == "pi"
        extensions = File.join(agent_dir, "extensions")
        FileUtils.mkdir_p(extensions)
        FileUtils.cp(MEMORY_FIXTURE, File.join(extensions, "memory.ts"))
        dir = File.join(agent_dir, "memory", key)
      else
        settings_path = File.join(home, ".tart", "settings.json")
        FileUtils.mkdir_p(File.dirname(settings_path))
        settings = File.exist?(settings_path) ? JSON.parse(File.read(settings_path)) : {}
        File.write(settings_path, JSON.pretty_generate(deep_merge(settings, "memory" => true)))
        dir = File.join(home, ".tart", "memory", key)
      end
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "MEMORY.md"), MEMORY_INDEX_MD)
    end

    # memory.ts's project-key rule, mirrored so the staged index lands
    # under the key the extension ACTUALLY reads (memory.ts:29-44): walk up
    # from the app's sandbox cwd for a .git entry (file or dir — worktrees
    # use a file) and take its basename; outside any repo fall back to the
    # sandbox basename. Both apps' sandboxes are siblings, so the walked
    # key is the same per run — the parity holds in any checkout location.
    def memory_project_key(sandbox)
      start = File.expand_path(sandbox)
      dir = start
      loop do
        return File.basename(dir) if File.exist?(File.join(dir, ".git"))

        parent = File.dirname(dir)
        return File.basename(start) if parent == dir

        dir = parent
      end
    end

    # Recursive right-biased hash merge (the staged-settings helper):
    # nested mappings merge key-by-key, scalars replace.
    def deep_merge(base, extra)
      base.merge(extra) do |_key, old, new|
        old.is_a?(Hash) && new.is_a?(Hash) ? deep_merge(old, new) : new
      end
    end

    # The owner's memory.ts, byte-verbatim (gems/tui-split-rig/lib/
    # tui_split_rig → the rig fixtures/ dir is two levels up).
    MEMORY_FIXTURE = File.expand_path("../../fixtures/memory.ts", __dir__)
    # The frozen Grounds §6 index bytes — the s11 scenario content, rendered
    # by both sides as the recall block's markdown rows.
    MEMORY_INDEX_MD = <<~MD.freeze
      - [deploy](deploy.md): deploys via herdr pipeline, stage first
      - [api-notes](api-notes.md): gateway streams SSE, no websockets
    MD

    # Pane commands are exec-wrapped so the pane's default shell (fish)
    # replaces itself: pane_pid resolves to the app process, no fish
    # survives teardown, and no real HOME dotfile is ever touched (staged
    # HOME on every pane, pi included).
    def pi_command(home, agent_dir)
      staged = staged_env("pi",
        "HOME" => home,
        "PATH" => "#{File.dirname(@pi_bin)}:#{ENV.fetch('PATH', '')}",
        "PI_CODING_AGENT_DIR" => agent_dir,
        "PI_OFFLINE" => "1"
      )
      "exec env #{env_flags(staged)} #{Shellwords.escape(@pi_bin)} --model mock/mock-1"
    end

    def tart_command(sandbox, home, port)
      # No BUNDLE_PATH: gems resolve from the mise ruby's Gem Home (same as
      # `bundle exec rake test`); staging HOME + BUNDLE_FROZEN guarantees
      # bundler never writes .bundle/ or touches Gemfile.lock (verified:
      # `bundle check` clean under a staged HOME, no .bundle/ created). An
      # empty BUNDLE_PATH HIDES those gems (bundler exits before boot),
      # which is why I01 shipped a pre-populated bundle dir.
      #
      # The scenario's staged identity decides the env namespace (I32
      # AC4): the parity scenarios run tart in pi mode → PI_*; s1_tart
      # stages TART_IDENTITY=tart → TART_*. TART_IDENTITY itself stays the
      # launcher-owned bootstrap knob, always spelled literally.
      #
      # I69 R3: the runner OWNS the explicit staging — the fetch default
      # stays "pi" (no scenario path ever rides the app default, which the
      # I69 flip turned into tart), and an override staging a BLANK or NIL
      # identity is REFUSED LOUDLY: a blank would compose through as
      # TART_IDENTITY='' with a blank _MODEL namespace and abort the boot
      # (measured via the rig-identity-assert probe). Parity scenarios
      # always carry an explicit non-empty identity.
      tart_env = @scenario.env.fetch("tart", {})
      if tart_env.key?("TART_IDENTITY") && (tart_env["TART_IDENTITY"].nil? || tart_env["TART_IDENTITY"].to_s.strip.empty?)
        raise TuiSplitRig::Error,
          "scenario env tart.TART_IDENTITY must stage an explicit non-empty identity " \
          "(pi for the parity face, tart for the tart face) — got #{tart_env["TART_IDENTITY"].inspect}; " \
          "a blank or nil identity must never compose into the pane command"
      end
      identity = tart_env["TART_IDENTITY"] || "pi"
      prefix = "#{identity.upcase}_"
      staged = staged_env("tart",
        "HOME" => home,
        # I67 R2: the staged bin/pi symlink FIRST — tart's pi_package_dir
        # walk resolves the pinned clone, not the system install.
        "PATH" => "#{File.join(home, 'bin')}:#{File.dirname(@bundle_bin)}:#{ENV.fetch('PATH', '')}",
        "BUNDLE_FROZEN" => "true",
        "TART_IDENTITY" => identity,
        "#{prefix}MODEL" => "mock-1",
        "#{prefix}PROVIDER" => "openai",
        "#{prefix}API_KEY" => "mock-key",
        "#{prefix}API_BASE" => "http://127.0.0.1:#{port}",
        "#{prefix}CONTEXT_WINDOW" => (@scenario.context_window || 32_768).to_s
      )
      "cd #{Shellwords.escape(@tart_dir)} && exec env #{env_flags(staged)} #{Shellwords.escape(@bundle_bin)} exec bin/tart #{Shellwords.escape(sandbox)}"
    end

    # The -u flags scrubbing the parent environment's PI_*/TART_* keys —
    # the operator's real PI_API_KEY must not leak into a staged run —
    # followed by the staged assignments. Staged keys are never scrubbed:
    # they always win.
    def env_flags(staged)
      scrub = ENV.keys.grep(/\A(?:PI|TART)_/) - staged.keys
      [*scrub.flat_map { |key| ["-u", key] }, *env_list(staged)].join(" ")
    end

    # The scenario's per-app env overrides (Scenario#env — the
    # branding/staging seam) layered over the runner's staged env;
    # overrides win.
    def staged_env(app, env)
      env.merge(@scenario.env.fetch(app, {}))
    end

    def env_list(env)
      env.map { |key, value| "#{key}=#{Shellwords.escape(value)}" }.join(" ")
    end

    # -- settle --

    # The mid_run_keys knob's arm (I54): poll mock.request_count every
    # POLL_INTERVAL until >= after_request (HARD_CAP-bounded; captured_
    # request_logs semantics untouched — the drain stays at capture time),
    # then send each key token. Returns false when the pane died or the
    # wait timed out (the caller fails the app's completed); true when the
    # keys were sent.
    def send_mid_run_keys(session, mock)
      cfg = @scenario.mid_run_keys
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      until mock.request_count >= cfg[:after_request]
        return false unless session_exists?(session)
        return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) - started >= HARD_CAP

        sleep POLL_INTERVAL
      end
      cfg[:keys].each { |key| tmux("send-keys", "-t", session, key) }
      true
    end

    def capture(session)
      # A dead pane/session is a legitimate mid-run state (we surface it in
      # the summary); keep its tmux stderr out of the rig's own output.
      Open3.capture2("tmux", "capture-pane", "-p", "-t", session, err: IO::NULL)[0].to_s
    end

    # The STYLED capture (-e): the SGR sequences ride the output — the
    # color/attribute dimension the plain capture strips (tmux
    # normalizes both apps' escapes through its own writer, so a
    # difference is the APP's, not the terminal's).
    def capture_styled(session)
      Open3.capture2("tmux", "capture-pane", "-e", "-p", "-t", session, err: IO::NULL)[0].to_s
    end

    def settle(session, label)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      last = nil
      same = 0
      loop do
        current = capture(session)
        same = current == last ? same + 1 : 0
        last = current
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        return {label:, ms: (elapsed * 1000).round, timed_out: false} if same >= QUIET_POLLS
        return {label:, ms: (elapsed * 1000).round, timed_out: true} if elapsed >= HARD_CAP

        sleep POLL_INTERVAL
      end
    end

    # -- teardown ---------------------------------------------------------

    # kill -9 the pane pid (exec-wrapped: the app itself) and all
    # descendants (bundle exec may spawn a ruby child), wait for exit,
    # then drop the session.
    def teardown(session)
      pids = pane_pid_tree(session)
      pids.each { |pid| Process.kill("KILL", pid) }
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + KILL_WAIT
      gone = false
      loop do
        gone = pids.none? { |pid| process_exists?(pid) }
        break if gone || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep 0.1
      end
      @failure = "teardown: pids #{pids.inspect} survived kill -9" unless gone
    rescue Errno::ESRCH
      nil # pane already gone
    ensure
      tmux("kill-session", "-t", session) if session_exists?(session)
    end

    # The probe drives the pane lifecycle directly (bin/tool-pending-probe
    # captures DURING the turn — settle here would wait it out); the staging
    # methods are public for the same reason (the load pin asserts their
    # staged files and env).
    public :capture, :capture_styled, :settle, :teardown, :boot_session,
      :stage_pi_agent, :stage_tart_home, :stage_project_resources, :stage_memory, :session_name, :pi_command, :tart_command

    def pane_pid_tree(session)
      out = Open3.capture2("tmux", "list-panes", "-t", session, "-F", PANE_PID_FORMAT)[0].to_s
      roots = out.lines.map(&:strip).reject(&:empty?).map(&:to_i)
      roots.flat_map { |root| [root, *descendants(root)] }
    end

    def descendants(root)
      rows = Open3.capture2("ps", "-eo", "pid=,ppid=")[0].to_s.lines.filter_map do |line|
        pid, ppid = line.strip.split(/\s+/).map(&:to_i)
        [pid, ppid]
      end
      children = rows.group_by { |_, ppid| ppid }.transform_values { |entries| entries.map(&:first) }
      tree = []
      frontier = [root]
      until frontier.empty?
        kids = children.fetch(frontier.pop, [])
        tree.concat(kids)
        frontier.concat(kids)
      end
      tree
    end

    def process_exists?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end

    def session_exists?(session)
      system("tmux", "has-session", "-t", session, err: IO::NULL)
    end

    def tmux(*args)
      system("tmux", *args) or raise Error, "tmux #{args.join(' ')} failed"
    end

    # Scoped to THIS runner's token (I27): a concurrent rig process's live
    # sessions share the server but not the token, so parallel lanes don't
    # flake each other's end-of-run leftover check.
    def assert_clean_sessions!
      left = Open3.capture2("tmux", "ls", err: IO::NULL)[0].to_s.lines.grep(/tui-split-rig-#{@token}-/)
      @failure = "leftover tui-split-rig-#{@token}-* tmux sessions: #{left.join(', ')}" unless left.empty?
    end

    # -- assembly ---------------------------------------------------------

    def run_result(n, stage, apps, registry)
      pi = apps["pi"]
      tart = apps["tart"]
      diff = pi && tart ? Differ.diff(File.read(pi["capture"]), File.read(tart["capture"]), registry) : nil
      styles = diff && pi && tart ? style_result(diff, pi, tart, registry) : nil
      {
        "run" => n,
        "stage" => stage,
        "apps" => apps,
        "diff" => diff && {
          "classes" => diff.per_class,
          "candidates" => diff.candidates.map { |c| tagged_line(c) },
          "unified" => diff.unified,
          "attribution" => diff.classifications.map { |c| "#{tagged_line(c)} -> #{c.klass || 'unknown-candidate'}" },
        }.merge(styles || {}),
      }
    end

    # The style pass over the -e captures: the SGR runs on the lines the
    # structural diff called :same must be byte-identical; a mismatch is
    # a style candidate, classified by the registry against the stripped
    # line. Unknown style candidates block exit 0 like text ones.
    def style_result(diff, pi, tart, registry)
      pairs = diff.style_candidates(File.read(pi["styled_capture"]).lines(chomp: true),
                                    File.read(tart["styled_capture"]).lines(chomp: true), registry)
      unknown = pairs.reject { |(_candidate, klass)| klass }
      {
        "style_candidates" => pairs.map { |candidate, klass| style_line(candidate, klass) },
        "style_unknown" => unknown.map { |candidate, _klass| "[style]#{style_line(candidate, nil)}" },
      }
    end

    def style_line(candidate, klass)
      "~ #{candidate.line.inspect} pi=#{candidate.pi_styles} tart=#{candidate.tart_styles} -> #{klass || 'unknown-candidate'}"
    end

    def tagged_line(classified)
      "#{classified.op.kind == :del ? '-' : '+'}#{classified.op.line}"
    end

    def build_summary(run_results)
      @failure ||= "not all apps completed" if run_results.any? { |r| r["apps"].values.any? { |a| !a["completed"] } }
      @failure ||= "request counts did not match expected" if run_results.any? do |r|
        r["apps"].values.any? { |a| a["requests"] != a["expected_requests"] }
      end

      candidates = run_results.flat_map { |r| r["diff"] ? r["diff"]["candidates"] : [] }
      style_unknown = run_results.flat_map { |r| r["diff"] ? r["diff"]["style_unknown"] : [] }
      code = @failure ? 2 : (candidates.empty? && style_unknown.empty? ? 0 : 1)
      {
        "scenario" => @scenario.name,
        "runs" => run_results,
        "candidates" => candidates,
        "style_candidates" => style_unknown,
        "rig_failure" => @failure,
        "exit_code" => code,
      }
    end

    def default_tart_dir
      repo_root
    end

    def default_pi_bin
      # I67 R1: the pinned repos/pi clone @ v1.1.0 — `command -v pi` is
      # GONE (the system pi on PATH, 1.2.0+, is never the oracle again).
      TuiSplitRig.resolve_pi_bin(env: ENV)
    end

    def resolve_bundle_bin
      bundle = Open3.capture2("sh", "-c", "command -v bundle")[0].to_s.strip
      raise Error, "bundle binary not found on PATH" if bundle.empty?

      bundle
    end

    def default_registry
      File.join(repo_root, "gems", "tui-split-rig", "registry.yml")
    end

    def default_out_dir
      File.join(repo_root, "tmp", "parity", Time.now.utc.strftime("%Y%m%d-%H%M%S"))
    end

    def repo_root
      # gems/tui-split-rig/lib/tui_split_rig → tart repo root (four levels up)
      @repo_root ||= File.expand_path("../../../..", __dir__)
    end
  end
end
