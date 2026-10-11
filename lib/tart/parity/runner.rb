# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "shellwords"
# The app-side mock LLM server (top-level MockLLMServer, minitest-free).
# Four levels up from lib/tart/parity: repo root/test/support.
require_relative "../../../test/support/mock_llm_server"

module Tart
  module Parity
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
    # session, and asserts no survivor and no leftover pty-tester-* session.
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
      end

      attr_reader :out_dir

      def run!
        FileUtils.mkdir_p(@out_dir)
        registry = Registry.load(@registry_path)
        run_results = (1..@runs).map { |n| run_once(n, registry) }
        summary = build_summary(run_results)
        Report.write(@out_dir, @scenario, summary)
        Result.new(exit_code: summary.fetch("exit_code"), summary: summary, out_dir: @out_dir)
      end

      private

      def run_once(n, registry)
        stage = File.join(@out_dir, "run-#{n}")
        mock = MockLLMServer.new.script(@scenario.responses).start
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
        home = File.join(stage, "home", app)
        sandbox = File.join(stage, "sandbox", app)
        [home, sandbox].each { |dir| FileUtils.mkdir_p(dir) }
        agent_dir = app == "pi" ? stage_pi_agent(stage, mock.port) : nil

        session = "pty-tester-#{app}-#{@scenario.name}-r#{n}-#{format('%04x', rand(65_536))}"
        command = app == "pi" ? pi_command(home, agent_dir) : tart_command(sandbox, home, mock.port)
        tmux("kill-session", "-t", session) if session_exists?(session)
        tmux("new-session", "-d", *GEOMETRY, "-c", sandbox, "-s", session, command)

        boot = settle(session, "boot")
        alive = session_exists?(session)
        tmux("send-keys", "-t", session, @scenario.prompt, "Enter") if alive
        reply = alive ? settle(session, "reply") : {ms: nil, timed_out: true}

        # A dead session still gets a capture file (empty) — the rig reports
        # the failure, it never crashes on a missing artifact.
        capture_path = File.join(stage, "#{app}.capture")
        File.write(capture_path, session_exists?(session) ? capture(session) : "")
        styled_path = File.join(stage, "#{app}.capture.styled")
        File.write(styled_path, session_exists?(session) ? capture_styled(session) : "")

        requests = mock.captured_request_logs
        request_log = File.join(stage, "#{app}-requests.jsonl")
        File.write(request_log, requests.map { |r| JSON.generate(r) }.join("\n") << "\n")

        completed = alive && !reply[:timed_out] && requests.size == @scenario.expected_requests

        result = {
          "app" => app, "session" => session, "completed" => completed,
          "requests" => requests.size, "expected_requests" => @scenario.expected_requests,
          "capture" => capture_path, "styled_capture" => styled_path, "request_log" => request_log,
          "boot_settle_ms" => boot[:ms], "boot_timed_out" => boot[:timed_out],
          "reply_settle_ms" => reply[:ms], "reply_timed_out" => reply[:timed_out],
        }
        teardown(session)
        result
      end

      # Stages the pi agent dir with the mock provider (I01-verified shape);
      # PI_CODING_AGENT_DIR at this path also suppresses first-time setup,
      # and sessions land under it.
      def stage_pi_agent(stage, port)
        agent_dir = File.join(stage, "agent", "pi")
        FileUtils.mkdir_p(agent_dir)
        config = {
          providers: {
            mock: {
              baseUrl: "http://127.0.0.1:#{port}/v1",
              apiKey: "mock-key",
              api: "openai-completions",
              models: [
                {id: "mock-1", name: "Mock 1", reasoning: false, contextWindow: 32_768, maxTokens: 512},
              ],
            },
          },
        }
        File.write(File.join(agent_dir, "models.json"), JSON.pretty_generate(config))
        agent_dir
      end

      # Pane commands are exec-wrapped so the pane's default shell (fish)
      # replaces itself: pane_pid resolves to the app process, no fish
      # survives teardown, and no real HOME dotfile is ever touched (staged
      # HOME on every pane, pi included).
      def pi_command(home, agent_dir)
        "exec env #{env_list(staged_env("pi",
          "HOME" => home,
          "PATH" => "#{File.dirname(@pi_bin)}:#{ENV.fetch('PATH', '')}",
          "PI_CODING_AGENT_DIR" => agent_dir,
          "PI_OFFLINE" => "1"
        ))} #{Shellwords.escape(@pi_bin)} --model mock/mock-1"
      end

      def tart_command(sandbox, home, port)
        # No BUNDLE_PATH: gems resolve from the mise ruby's Gem Home (same as
        # `bundle exec rake test`); staging HOME + BUNDLE_FROZEN guarantees
        # bundler never writes .bundle/ or touches Gemfile.lock (verified:
        # `bundle check` clean under a staged HOME, no .bundle/ created). An
        # empty BUNDLE_PATH HIDES those gems (bundler exits before boot),
        # which is why I01 shipped a pre-populated bundle dir.
        "cd #{Shellwords.escape(@tart_dir)} && exec env #{env_list(staged_env("tart",
          "HOME" => home,
          "PATH" => "#{File.dirname(@bundle_bin)}:#{ENV.fetch('PATH', '')}",
          "BUNDLE_FROZEN" => "true",
          "TART_MODEL" => "mock-1",
          "TART_PROVIDER" => "openai",
          "TART_API_KEY" => "mock-key",
          "TART_API_BASE" => "http://127.0.0.1:#{port}",
          "TART_CONTEXT_WINDOW" => "32768"
        ))} #{Shellwords.escape(@bundle_bin)} exec bin/tart #{Shellwords.escape(sandbox)}"
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

      # -- settle -----------------------------------------------------------

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

      def assert_clean_sessions!
        left = Open3.capture2("tmux", "ls", err: IO::NULL)[0].to_s.lines.grep(/pty-tester-/)
        @failure = "leftover pty-tester-* tmux sessions: #{left.join(', ')}" unless left.empty?
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
        pi = Open3.capture2("sh", "-c", "command -v pi")[0].to_s.strip
        raise Error, "pi binary not found on PATH" if pi.empty?

        pi
      end

      def resolve_bundle_bin
        bundle = Open3.capture2("sh", "-c", "command -v bundle")[0].to_s.strip
        raise Error, "bundle binary not found on PATH" if bundle.empty?

        bundle
      end

      def default_registry
        File.join(repo_root, "parity", "registry.yml")
      end

      def default_out_dir
        File.join(repo_root, "tmp", "parity", Time.now.utc.strftime("%Y%m%d-%H%M%S"))
      end

      def repo_root
        # lib/tart/parity → repo root
        @repo_root ||= File.expand_path("../../..", __dir__)
      end
    end
  end
end
