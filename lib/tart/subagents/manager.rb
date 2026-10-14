# frozen_string_literal: true

require "fast/uuid"
require "fileutils"
require "json"
require "rbconfig"
require "time"

require_relative "../agent/session"
require_relative "../identity"

module Tart
  module Subagents
    # The run registry (I48 §2): thread-safe — called from tool workers,
    # the watcher thread, the deadline supervisors, and tests.
    #
    # On-disk lifecycle (T3 discipline): every run owns
    # `<home>/<uuidv7>/{status.json, result.json, runner.stdout.log,
    # runner.stderr.log, system-prompt.md, control/{steer-requests/,
    # stop-requests/, steer-log.jsonl}, sessions/}`. status.json is
    # written atomically (temp+rename — pi control-channel's idiom) at
    # spawn and at every transition; result.json is written BEFORE the
    # terminal status flip; the task text is NEVER recorded (taskChars
    # only — pi's redaction). Process.detach owns every child reap (no
    # waitpid anywhere here — no early reap, no zombie); a run settles
    # only on observed exit (EOF on the child-held sentinel fd, or ESRCH
    # on both pid and pgid), and status reads reconcile from disk so a
    # run found terminal is reported terminal even when the watcher never
    # saw it live. The registry never deletes run dirs.
    #
    # The child harness is ONE path for both modes (Grounds §4's
    # decision): a `bin/tart -p` subprocess (§4's exact argv/env, built by
    # the public {spawn_argv_and_env}) — foreground = the spawning tool
    # worker blocks on the child's sentinel pipe; async = the watcher
    # (a plain thread — PHASE 0: kernel.async is reactor-context-only)
    # polls at POLL_INTERVAL (pi POLL_INTERVAL_MS 250) and on terminal
    # delivers the I47 notification + the interactive wake.
    class Manager
      # pi's 30-minute single-run default (DEFAULT_ASYNC_TIMEOUT_MS);
      # 0/nil = unbounded (T2's first kind, settable per call).
      DEFAULT_TIMEOUT_MS = 1_800_000

      # pi's inbox bounds (control-channel.js): the 128KB steer message
      # cap, the 250ms poll, the graceful-stop ladder (§2.4: file → 5s →
      # TERM → 2s → KILL).
      STEER_MESSAGE_CAP_BYTES = 128 * 1024
      POLL_INTERVAL = 0.25
      STOP_GRACE_SECONDS = 5.0
      TERM_GRACE_SECONDS = 2.0

      DEFAULT_ACK_MS = 3_000

      # pi notify.js:17 — the completion preview bound + marker.
      PREVIEW_MAX_BYTES = 2_000
      PREVIEW_TRUNCATION_MARKER = "...[preview truncated]"

      TERMINAL_STATES = %w[completed failed stopped].freeze

      # pi fleet-view.js:391, byte-exact — the empty-fleet status line.
      FLEET_EMPTY_LINE = "No active subagent fleet. Background runs that already finished are available " \
                         "through completion notifications or subagent({ action: \"status\", id: \"...\" }).".freeze

      attr_reader :cwd, :home, :identity, :root
      # The parent-side supervisor channel (I49): register() constructs and
      # arms it; #shutdown stops it; the `subagent` tool's reply/pending
      # actions read it (a bare Manager — tests — carries nil, and the
      # tool answers the empty-state texts).
      attr_accessor :supervisor_channel

      # @param cwd [String] the children's working directory (the parent's).
      # @param home [String] the runs root ({Subagents.home}).
      # @param env [Hash] the parent's environment (the child env's source).
      # @param identity [String] the resolved face (the env namespace).
      # @param hooks [Tart::Hooks] the I47 seam (the notification channel).
      # @param kernel [Object, nil] the interactive wake bridge (a duck
      #   #async; {Subagents::KernelBridge} from the boot wiring). nil in
      #   print boots and tests.
      # @param agent [Proc, Agent::Loop, nil] the current parent loop (or a
      #   callable returning it) — the wake target and the :fork seeding
      #   source. nil in print boots (the drain path) and tests.
      # @param arm_deadline_supervisor [Boolean] the parent-side deadline
      #   backstop thread (default true). Tests disarm it to prove the
      #   child self-deadline alone enforces (T2 both-sides; PHASE 0: an
      #   additive defaulted kwarg beside the frozen §2.7 surface).
      # @param root [String] the agent root for the I49 profile tier's
      #   user scan (`<root>/agents/**/*.md`; Profiles). Additive defaulted
      #   kwarg — default {Agent::Session.default_root}.
      def initialize(cwd:, home:, env:, identity:, hooks:, kernel: nil, agent: nil, arm_deadline_supervisor: true,
                     root: Agent::Session.default_root)
        @cwd = File.expand_path(cwd)
        @home = home
        @env = env
        @identity = identity
        @root = root
        @hooks = hooks
        @kernel = kernel
        @agent = agent
        @arm_deadline_supervisor = arm_deadline_supervisor
        @supervisor_channel = nil
        @mutex = Mutex.new
        @runs = []
        @supervisors = []
        @watcher = nil
        @shutdown = false
        FileUtils.mkdir_p(@home)
      end

      # Spawns one child (§2.2). async:true returns the run record
      # immediately (the watcher owns it); async:false BLOCKS on the
      # tool's worker thread until the child exits and the terminal
      # status is written — the returned record already carries the
      # settled state.
      def spawn_run(agent:, task:, async:, model: nil, timeout_ms: nil, tool_timeout_ms: nil,
                    tool_call_id: nil, parent_session: nil)
        # I49: the merged table (builtins < user < project profiles),
        # resolved fresh from disk EVERY spawn (no cache); raises the
        # unknown-agent ArgumentError (the retired unknown_agent_message's
        # shape lives in Profiles.resolve now).
        spec = Profiles.resolve(agent.to_s, cwd: @cwd, root: @root, env: @env)

        # The model tier (I49 Spec §3b): call `model:` > the profile's
        # `model:` > the parent's current pair — the profile rides the
        # SAME resolve_model path (`provider/id[:level]`).
        source = model || spec[:model]
        provider, model_id, level =
          source ? Subagents.resolve_model(source, catalog: nil, fallback: parent_model_pair) : parent_model_pair
        # I49 D5: every gate-on child gets the intercom bridge —
        # contact_supervisor appended to its tools and the instruction
        # appended to its prompt (pi applyIntercomBridgeToAgent, mode
        # "always"; never mutates the resolved spec).
        spec = Supervisor.apply_bridge(spec)
        # pi's implicit-fork fallback (tool-reference.md "Fork context
        # details"): a :fork agent with no parent session available runs
        # fresh — no preamble, no --resume.
        forked = spec[:context] == :fork && !parent_session.to_s.empty?
        task_text = forked ? "#{DEFAULT_FORK_PREAMBLE}\n\nTask:\n#{task}" : task.to_s
        deadline = normalize_deadline(timeout_ms)
        tool_deadline = positive_int(tool_timeout_ms)

        id = Agent::Session.uuidv7
        dir = File.join(@home, id)
        FileUtils.mkdir_p([dir,
                           File.join(dir, "control", "steer-requests"),
                           File.join(dir, "control", "stop-requests"),
                           File.join(dir, "control", "supervisor-requests"),
                           File.join(dir, "control", "supervisor-replies"),
                           File.join(dir, "sessions")])
        File.write(File.join(dir, "system-prompt.md"), spec[:system_prompt])

        exit_rd, exit_wr = IO.pipe
        record = {
          id:, agent: spec[:name], state: :running, dir:, pid: nil, pgid: nil, async: !!async,
          timed_out: false, started_at: now_ms, tool_call_id:,
          # Port-internal keys (beyond the §2.2 public contract) that
          # #spawn_argv_and_env derives the child harness from:
          task_chars: task.to_s.length, tools: spec[:tools], provider:, model_id:, level:,
          timeout_ms: deadline, tool_timeout_ms: tool_deadline, parent_session: parent_session.to_s,
          fork: forked, task_text:, exit_pipe: exit_rd, stopped: false, deadline_due: false, signaled: nil
        }
        write_status(record)

        begin
          argv, env = spawn_argv_and_env(record)
          out = File.open(File.join(dir, "runner.stdout.log"), "w")
          err = File.open(File.join(dir, "runner.stderr.log"), "w")
          pid = Process.spawn(env, *argv, chdir: @cwd, pgroup: true, in: File::NULL,
                              out: out, err: err, 3 => exit_wr, unsetenv_others: true)
          out.close
          err.close
          # T3: the detach thread owns the reap — the parent never
          # waitpids, so there is no early reap and no zombie.
          Process.detach(pid)
          @mutex.synchronize do
            record[:pid] = pid
            record[:pgid] = pid
          end
          write_status(record)
          @mutex.synchronize { @runs << record }
        rescue StandardError
          close_exit_pipe(record)
          raise
        ensure
          # The parent drops its write end NOW: the only remaining copy
          # lives in the child, so EOF on exit_rd means the child exited.
          exit_wr.close rescue nil
        end

        arm_deadline_supervisor(record)
        unless record[:async]
          wait_for_exit(record)
          settle_run(record)
        end
        ensure_watcher if record[:async]
        record
      end

      # §2.3 — the steering inbox write + the correlated-consumption wait
      # (T1): the receipt reports :delivered ONLY on the CHILD's
      # steer-log.jsonl entry for THIS request id — never mere inbox
      # acceptance.
      def steer(id:, message:, mode: "auto", ack_timeout_ms: DEFAULT_ACK_MS)
        unless %w[steer follow_up auto].include?(mode)
          raise ArgumentError, "steer mode must be steer, follow_up, or auto (got #{mode.inspect})"
        end

        request_id = Fast::UUID.uuid_v4
        # An UNKNOWN id errors naming the active ids (§3's management
        # rule); a TERMINAL target misses (§2.3 — follow_up-on-terminal
        # is ENTRY 7's resume, cut here).
        record = find_run!(id.to_s)
        return receipt(:missed, id, request_id) if terminal?(record[:state])

        if message.to_s.bytesize > STEER_MESSAGE_CAP_BYTES
          return receipt(:failed, id, request_id,
                         "steer message exceeds #{STEER_MESSAGE_CAP_BYTES} UTF-8 bytes")
        end

        # Write the request FIRST (all modes — follow_up's file waits for
        # the child's next resume/boundary), then follow_up returns
        # queued immediately.
        ts = now_ms
        request = {"type" => "steer", "id" => request_id, "ts" => ts, "message" => message.to_s,
                   "mode" => mode, "source" => "tool"}
        begin
          atomic_write_json(File.join(steer_requests_dir(record[:dir]),
                                      "#{ts.to_s.rjust(13, "0")}-#{request_id}.json"), request)
        rescue SystemCallError => e
          return receipt(:failed, id, request_id, e.message)
        end
        return receipt(:queued, id, request_id) if mode == "follow_up"

        return receipt(:delivered, id, request_id) if consumed?(record, request_id)

        deadline = monotonic + ack_timeout_ms.to_f / 1000
        while monotonic < deadline
          return receipt(:delivered, id, request_id) if consumed?(record, request_id)
          return receipt(:missed, id, request_id) if terminal?(reconcile_run(record)[:state])
          sleep 0.05
        end
        receipt(:queued, id, request_id)
      end

      # §2.4 — stop: the request file, ≤5s graceful wait, TERM the pgroup,
      # ≤2s, KILL. The receipt text is pi byte-exact (async-stop-action.js
      # :198).
      def stop(id:)
        record = find_run!(id.to_s)
        raise ArgumentError, "async run #{record[:id]} already #{record[:state]}" if terminal?(record[:state])

        ts = now_ms
        atomic_write_json(File.join(stop_requests_dir(record[:dir]),
                                    "#{ts.to_s.rjust(13, "0")}-#{Fast::UUID.uuid_v4}.json"),
                          {"type" => "stop", "ts" => ts})
        @mutex.synchronize { record[:stopped] = true }
        await_exit(record, STOP_GRACE_SECONDS)
        escalate(record, "TERM", TERM_GRACE_SECONDS)
        escalate(record, "KILL", POLL_INTERVAL)
        settle_run(record)
        "Stop requested for async run #{record[:id]}."
      end

      # §2.5 — disk-first status (reconcile). With id: the §7 lines for
      # one run; without: the fleet (running first, newest first).
      def status(id: nil)
        return render_status(reconcile_run(find_run!(id.to_s))) if id

        list = @mutex.synchronize { @runs.dup }
        list.each { |record| reconcile_run(record) }
        ordered = list.sort_by { |record| [record[:state] == :running ? 0 : 1, -(record[:started_at] || 0)] }
        return FLEET_EMPTY_LINE if ordered.empty?

        "Active async runs: #{ordered.size}\n\n" +
          ordered.map { |record| "- #{record[:id]} | #{record[:state]} | single | #{record[:agent]}" }.join("\n")
      end

      # The result.json Hash (or nil — unknown id / not settled yet).
      def result(id:)
        record = find_run(id.to_s)
        return nil unless record

        read_json(result_path(record))
      end

      # The registry snapshot (the §2.2 record hashes, spawn order).
      def runs
        @mutex.synchronize { @runs.map(&:dup) }
      end

      # Any non-terminal run — the print drain's predicate.
      def outstanding?
        @mutex.synchronize { @runs.any? { |record| record[:state] == :running } }
      end

      # §5.4 — the print agent-end drain: waits for every outstanding run
      # (each bounded by its own deadline — the supervisors enforce it),
      # the watcher recording each completion notification on the hooks
      # queue as it settles. Returns when nothing is outstanding.
      def drain
        ensure_watcher
        sleep POLL_INTERVAL / 5 while outstanding?
        nil
      end

      # Test teardown: stop every running run (the full graceful ladder),
      # then join the watcher + supervisor threads; the I49 supervisor
      # channel stops LAST (its terminal sweep sees the settled runs).
      def shutdown
        @mutex.synchronize { @shutdown = true }
        ids = @mutex.synchronize { @runs.select { |record| record[:state] == :running }.map { |record| record[:id] } }
        ids.each do |id|
          begin
            stop(id:)
          rescue StandardError
            nil
          end
        end
        watcher = @mutex.synchronize { @watcher }
        watcher&.join(POLL_INTERVAL * 8)
        threads = @mutex.synchronize { supervisors = @supervisors; @supervisors = []; supervisors }
        threads.each { |thread| thread.join(1) rescue nil }
        begin
          @supervisor_channel&.stop
        rescue StandardError
          nil
        end
        nil
      end

      # §4 — the child harness builder, PUBLIC (the gate's pin target):
      # `[argv, env]`. The argv is exactly the frozen shape; the env is
      # CLOSED (spawned with unsetenv_others — OQ-7): the parent's
      # PATH/HOME, the identity + resolved model facts, the child knobs
      # (timeouts, the runs root), nil keys omitted, NO subagents gate
      # row (children never nest), NO MCP config.
      def spawn_argv_and_env(run)
        argv = [RbConfig.ruby, bin_tart_path, "-p", run[:task_text],
                "--tools", Array(run[:tools]).join(","),
                "--system-prompt-file", File.join(run[:dir], "system-prompt.md"),
                "--session-root", File.join(run[:dir], "sessions"),
                "--steer-inbox", steer_requests_dir(run[:dir])]
        argv += ["--resume", run[:parent_session]] if run[:fork]
        [argv, child_env(run)]
      end

      # The current parent session path (the :fork seeding source via the
      # live loop's recorder). nil when unavailable (print parents pass
      # neither kernel nor agent — their fork children fall back to
      # fresh, pi's implicit-fork fallback).
      def current_session_path
        loop = @agent.respond_to?(:call) ? @agent.call : @agent
        loop&.recorder&.path
      rescue StandardError
        nil
      end

      private

      # --- spawn internals ---

      def child_env(run)
        key = ->(suffix) { Identity.env_key(@identity, suffix) }
        env = {}
        env["PATH"] = @env["PATH"] if @env["PATH"]
        env["HOME"] = @env["HOME"] if @env["HOME"]
        env[key.("IDENTITY")] = @identity
        api_key = @env[key.("API_KEY")] || global_llm_config&.openai_api_key
        env[key.("API_KEY")] = api_key if api_key
        api_base = @env[key.("API_BASE")] || global_llm_config&.openai_api_base
        env[key.("API_BASE")] = api_base if api_base
        env[key.("MODEL")] = run[:model_id] if run[:model_id]
        env[key.("PROVIDER")] = run[:provider] if run[:provider]
        env[key.("MODEL_REASONING")] = @env[key.("MODEL_REASONING")] if @env[key.("MODEL_REASONING")]
        env[key.("THINKING_LEVEL")] = run[:level] if run[:level]
        env[key.("CONTEXT_WINDOW")] = @env[key.("CONTEXT_WINDOW")] if @env[key.("CONTEXT_WINDOW")]
        env[key.("TOOL_TIMEOUT_MS")] = run[:tool_timeout_ms].to_s if run[:tool_timeout_ms]
        # The child self-deadline (T2 both-sides): the deadline EPOCH —
        # Print.run arms sleep(remaining) → TERM on its own pgroup.
        env[key.("RUN_DEADLINE_MS")] = (run[:started_at] + run[:timeout_ms]).to_s if run[:timeout_ms]
        env[key.("SUBAGENTS_HOME")] = @home
        # I49 — the intercom channel (Spec §3d): the run-dir control dir +
        # the agent label for the surfaced ask. UNCONDITIONAL: the run-dir
        # mkdir always creates the channel dirs, so the child's tool is
        # never inert in a real child.
        env[key.("SUPERVISOR_CHANNEL")] = File.join(run[:dir], "control")
        env[key.("SUBAGENTS_AGENT")] = run[:agent]
        env
      end

      # The parent's resolved endpoint facts when the env tier is unset:
      # the gem's global config (the gate stages NO env key; production
      # boots resolve identically from the same staged HOME/cwd, so the
      # fallback is convergence-neutral there — PHASE 0 item).
      def global_llm_config
        return nil unless defined?(RubyLLM) && RubyLLM.respond_to?(:config)

        RubyLLM.config
      rescue StandardError
        nil
      end

      def bin_tart_path
        File.expand_path("../../../bin/tart", __dir__)
      end

      def parent_model_pair
        key = ->(suffix) { Identity.env_key(@identity, suffix) }
        [@env[key.("PROVIDER")], @env[key.("MODEL")], @env[key.("THINKING_LEVEL")]]
      end

      def normalize_deadline(value)
        int = value.nil? ? DEFAULT_TIMEOUT_MS : Integer(value)
        int.positive? ? int : nil # 0/nil = unbounded (T2's first kind)
      rescue ArgumentError, TypeError
        raise ArgumentError, "timeout_ms must be an integer (got #{value.inspect})"
      end

      def positive_int(value)
        return nil if value.nil?

        int = Integer(value)
        raise ArgumentError, "tool_timeout_ms must be an integer (got #{value.inspect})" if int.negative?

        int.positive? ? int : nil
      rescue ArgumentError, TypeError
        raise ArgumentError, "tool_timeout_ms must be an integer (got #{value.inspect})"
      end

      # --- lifecycle internals ---

      def terminal?(state)
        TERMINAL_STATES.include?(state.to_s)
      end

      # The foreground tool worker's blocking wait (§2.2): bounded select
      # on the child-held sentinel pipe — EOF means the child exited —
      # with the cancellation checkpoints (a parent-interrupt kills the
      # child's pgroup, the Bash-tool discipline). Process.detach owns
      # the reap; this loop never waitpids.
      def wait_for_exit(record)
        pipe = record[:exit_pipe]
        loop do
          RubyLLM::Support::Cancellation.check
          break if pipe.nil? || pipe.wait_readable(0.05)
        end
      rescue RubyLLM::CancelledError, Async::Cancel
        # A parent-interrupt cancels the delegation: kill the child's
        # pgroup, settle the run stopped, and propagate (the bash tool's
        # cancellation discipline).
        kill_process_group(record[:pid], "KILL")
        @mutex.synchronize { record[:stopped] = true }
        begin
          await_exit(record, TERM_GRACE_SECONDS)
          settle_run(record)
        rescue StandardError
          nil
        end
        raise
      end

      def await_exit(record, seconds)
        deadline = monotonic + seconds
        sleep 0.05 while monotonic < deadline && !exited?(record) && !terminal?(record[:state])
      end

      def escalate(record, signal, grace)
        return if exited?(record) || terminal?(record[:state])

        kill_process_group(record[:pid], signal)
        @mutex.synchronize { record[:signaled] = signal == "TERM" ? 15 : 9 }
        await_exit(record, grace)
      end

      # Negative-pid kill hits the whole group; fall back to the child
      # alone if the group is gone (the bash tool's idiom).
      def kill_process_group(pid, signal)
        Process.kill("-#{signal}", pid)
      rescue Errno::ESRCH, Errno::EPERM
        begin
          Process.kill(signal, pid)
        rescue Errno::ESRCH, Errno::EPERM
          nil
        end
      end

      # Observed exit (T3): ESRCH on BOTH pid and pgid — the detach
      # thread reaped, so the pid is unrecoverably gone. A live pid (or
      # an unkillable one — EPERM) keeps the run running.
      def exited?(record)
        return true unless record[:pid]

        [record[:pid], record[:pgid]].all? do |pid|
          Process.kill(0, pid)
          false
        rescue Errno::ESRCH
          true
        rescue Errno::EPERM
          false
        end
      end

      # The terminal processor (§2.1/§2.2): read the child's output,
      # write result.json BEFORE the terminal status flip, then flip the
      # in-memory state; async runs notify (§2.6) under the SAME mutex as
      # the flip so `outstanding? == false` implies the notification is
      # queued (no observation window between the two).
      def settle_run(record)
        @mutex.synchronize do
          return record if terminal?(record[:state])

          output = read_output(record)
          error_line = first_error_line(record)
          # The deadline flag rides BOTH sides (T2): the parent supervisor
          # sets it explicitly; when only the CHILD self-deadline fired,
          # the settle observes it from the clock (the child may die by
          # its own TERM a hair before the parent flags).
          timed_out = record[:deadline_due] == true || deadline_expired?(record)
          if timed_out && !record[:deadline_due]
            record[:deadline_due] = true
            record[:timed_out] = true
          end
          parent_killed = record[:stopped] == true || timed_out || record[:signaled]
          # The print-mode invariant stands in for the unreadable exit
          # status (the detach owns the reap — no waitpid): the final
          # response reaches stdout only on a clean run; errors go to
          # stderr and stdout stays empty.
          success = !parent_killed && !output.empty?
          state = parent_killed ? :stopped : (success ? :completed : :failed)

          result = {"output" => output, "success" => success, "timedOut" => timed_out}
          result["error"] = error_line if !success && error_line
          result["signal"] = record[:signaled] if record[:signaled]
          atomic_write_json(result_path(record), result) # BEFORE the flip

          payload = base_status(record).merge(
            "state" => state.to_s,
            "lastUpdate" => now_ms,
            "endedAt" => now_ms,
            "timedOut" => timed_out,
            "outputFile" => result_path(record)
          )
          payload["error"] = error_line if !success && error_line
          payload["signal"] = record[:signaled] if record[:signaled]
          atomic_write_json(status_path(record), payload)

          record[:state] = state
          record[:timed_out] = timed_out
          # JUDGE FIX (post-merge, recorded in the verdict): the notification
          # must queue INSIDE this mutex — the state flip above was observable
          # before send_next_turn ran, so `drain`'s outstanding? poll could
          # return in that window and the print flush would see an empty
          # queue (leg B flaked 1-in-3 under the loaded rake suite exactly
          # here). Hooks#send_next_turn is a leaf queue-append (own mutex, no
          # callbacks) — safe under this lock. With this, `outstanding? ==
          # false` REALLY implies the notification is queued, as the comment
          # below always claimed.
          notify_completion(record) if record[:async]
        end
        close_exit_pipe(record)
        record
      end

      # Disk-first reconcile (§2.1/§2.5 — T3): a non-terminal run whose
      # result.json + terminal status.json are BOTH on disk adopts the
      # terminal state even if the watcher never saw it live; an observed
      # exit settles through the full processor.
      def reconcile_run(record)
        return record if terminal?(record[:state])

        disk = read_json(status_path(record))
        if disk.is_a?(Hash) && TERMINAL_STATES.include?(disk["state"]) && File.file?(result_path(record))
          @mutex.synchronize do
            record[:state] = disk["state"].to_sym
            record[:timed_out] = disk["timedOut"] == true
          end
          close_exit_pipe(record)
        elsif exited?(record)
          settle_run(record)
        end
        record
      end

      def close_exit_pipe(record)
        record[:exit_pipe]&.close rescue nil
        record[:exit_pipe] = nil
      end

      # --- the watcher (§2.6) ---

      def ensure_watcher
        @mutex.synchronize do
          return if @shutdown || @watcher&.alive?

          @watcher = Thread.new { watch_loop }
        end
      end

      def watch_loop
        loop do
          records = @mutex.synchronize { @runs.select { |record| record[:state] == :running } }
          break if records.empty?

          pipes = records.filter_map { |record| record[:exit_pipe] }
          ready = pipes.empty? ? [] : IO.select(pipes, nil, nil, POLL_INTERVAL)&.fetch(0, []) || []
          ready.each do |pipe|
            record = records.find { |candidate| candidate[:exit_pipe] == pipe }
            settle_run(record) if record
          end
          records.each do |record|
            next if record[:state] != :running

            # Deadline backstop (arms here too when the §2.2 supervisor
            # thread is absent/disarmed — both-sides T2) + the belt-and-
            # braces exit sweep.
            enforce_deadline(record) if deadline_due?(record)
            settle_run(record) if record[:state] == :running && exited?(record)
          end
        end
      rescue StandardError
        sleep 0.05 # a transient IO error never kills the watcher
        retry
      end

      def deadline_due?(record)
        record[:timeout_ms] && !record[:deadline_due] && deadline_expired?(record)
      end

      def deadline_expired?(record)
        !!(record[:timeout_ms] && now_ms >= record[:started_at] + record[:timeout_ms])
      end

      # The deadline path (§2.2): stop request → 5s → TERM → 2s → KILL;
      # state stopped + timedOut (pi's terminal vocabulary — OQ-6).
      def enforce_deadline(record)
        @mutex.synchronize do
          record[:deadline_due] = true
          record[:timed_out] = true
        end
        write_stop_request(record)
        await_exit(record, STOP_GRACE_SECONDS)
        escalate(record, "TERM", TERM_GRACE_SECONDS)
        escalate(record, "KILL", POLL_INTERVAL)
        settle_run(record)
      end

      def arm_deadline_supervisor(record)
        return unless @arm_deadline_supervisor && record[:timeout_ms]

        thread = Thread.new do
          remaining = record[:started_at] + record[:timeout_ms] - now_ms
          sleep(remaining / 1000.0) if remaining.positive?
          next if terminal?(record[:state]) || exited?(record)

          enforce_deadline(record)
        end
        thread.name = "tart-subagent-deadline" if thread.respond_to?(:name=)
        @mutex.synchronize { @supervisors << thread }
      end

      def write_stop_request(record)
        ts = now_ms
        atomic_write_json(File.join(stop_requests_dir(record[:dir]),
                                    "#{ts.to_s.rjust(13, "0")}-#{Fast::UUID.uuid_v4}.json"),
                          {"type" => "stop", "ts" => ts})
      rescue SystemCallError
        nil
      end

      # --- registry lookup ---

      def find_run(id)
        hit = @mutex.synchronize { @runs.find { |record| record[:id] == id } }
        return hit if hit

        disk_find(id)
      end

      def find_run!(id)
        find_run(id) || begin
          known = @mutex.synchronize { @runs.map { |record| record[:id] } }
          raise ArgumentError,
                "unknown subagent run #{id.inspect}. Active runs: #{known.empty? ? "(none)" : known.join(", ")}."
        end
      end

      # A run unknown to this process's registry but present on disk (the
      # stale-run-reconciler discipline — T3): synthesized from its
      # status.json and adopted into the registry.
      def disk_find(id)
        dir = File.join(@home, id)
        status = read_json(File.join(dir, "status.json"))
        return nil unless status.is_a?(Hash)

        record = {
          id: status["id"].to_s, agent: status["agent"].to_s,
          state: status["state"].to_s.to_sym, dir:, pid: status["pid"], pgid: status["pid"],
          async: true, timed_out: status["timedOut"] == true, started_at: status["started_at"],
          tool_call_id: status["toolCallId"], exit_pipe: nil, stopped: false,
          deadline_due: false, signaled: nil
        }
        @mutex.synchronize do
          existing = @runs.find { |candidate| candidate[:id] == record[:id] }
          return existing if existing

          @runs << record
        end
        record
      end

      # --- notifications (§2.6 + §7) ---

      def notify_completion(record)
        state = record[:state].to_s
        output = read_json(result_path(record))&.[]("output").to_s
        preview = output.strip.empty? ? "(no output)" : truncate_utf8_head(output)
        body = ["Background task #{state}: **#{record[:agent]}**", ""]
        error_line = first_error_line(record)
        body += ["Error: #{error_line}", ""] if state != "completed" && error_line
        body += [preview, "", "Run dir: #{record[:dir]}", "Session file: #{find_session_file(record) || "(none)"}"]
        @hooks&.send_next_turn(custom_type: NOTIFY_CUSTOM_TYPE, content: body.join("\n"),
                               display: state != "completed")
        kick_wake
      end

      # The interactive wake (§2.6 — pi triggerTurn on the port's seams):
      # the bridge lands `agent.wake` on the reactor (Loop#wake no-ops
      # when a run is in flight — race-safe by construction). Best-effort:
      # the notification is already queued and rides the next drain.
      def kick_wake
        return unless @kernel

        @kernel.async { loop_for_wake&.wake }
      rescue StandardError => e
        warn "subagents: completion wake failed: #{e.message}"
      end

      def loop_for_wake
        loop = @agent.respond_to?(:call) ? @agent.call : @agent
        loop
      end

      # --- status rendering (§7) ---

      def render_status(record)
        disk = read_json(status_path(record)) || {}
        lines = ["Run: #{disk["id"] || record[:id]}",
                 "State: #{disk["state"] || record[:state]}",
                 "Mode: #{disk["mode"] || "single"}",
                 "Started: #{render_time(disk["startedAt"] || record[:started_at])}",
                 "Updated: #{disk["lastUpdate"] ? render_time(disk["lastUpdate"]) : "n/a"}",
                 "Dir: #{disk["asyncDir"] || record[:dir]}"]
        lines << "Output: #{disk["outputFile"]}" if disk["outputFile"]
        lines << "Error: #{disk["error"]}" if disk["error"]
        lines << "Timed out: true" if disk["timedOut"]
        lines.join("\n")
      end

      def render_time(ms)
        return "n/a" unless ms

        Time.at(ms / 1000.0).utc.iso8601
      end

      # --- disk helpers ---

      def base_status(record)
        payload = {
          "id" => record[:id],
          "agent" => record[:agent],
          "task" => nil, # the task text is NEVER recorded (taskChars only)
          "taskChars" => record[:task_chars],
          "mode" => "single",
          "state" => record[:state].to_s,
          "pid" => record[:pid],
          "cwd" => @cwd,
          "asyncDir" => record[:dir],
          "sessionRoot" => File.join(record[:dir], "sessions"),
          "startedAt" => record[:started_at],
          "lastUpdate" => now_ms,
          "toolCallId" => record[:tool_call_id]
        }
        payload["timeoutMs"] = record[:timeout_ms] if record[:timeout_ms]
        payload["toolTimeoutMs"] = record[:tool_timeout_ms] if record[:tool_timeout_ms]
        payload
      end

      def write_status(record)
        atomic_write_json(status_path(record), base_status(record))
      end

      def status_path(record)
        File.join(record[:dir], "status.json")
      end

      def result_path(record)
        File.join(record[:dir], "result.json")
      end

      def steer_requests_dir(dir)
        File.join(dir, "control", "steer-requests")
      end

      def stop_requests_dir(dir)
        File.join(dir, "control", "stop-requests")
      end

      def read_output(record)
        path = File.join(record[:dir], "runner.stdout.log")
        File.file?(path) ? File.read(path).sub(/\n\z/, "") : ""
      rescue StandardError
        ""
      end

      def first_error_line(record)
        path = File.join(record[:dir], "runner.stderr.log")
        return nil unless File.file?(path)

        File.foreach(path) do |line|
          stripped = line.strip
          return stripped unless stripped.empty?
        end
        nil
      rescue StandardError
        nil
      end

      def find_session_file(record)
        Dir.glob(File.join(record[:dir], "sessions", "**", "*.jsonl")).first
      end

      def consumed?(record, request_id)
        log = File.join(record[:dir], "control", "steer-log.jsonl")
        return false unless File.file?(log)

        File.readlines(log).any? do |line|
          entry = JSON.parse(line)
          entry.is_a?(Hash) && entry["requestId"] == request_id
        rescue JSON::ParserError
          false
        end
      rescue StandardError
        false
      end

      def read_json(path)
        return nil unless File.file?(path)

        JSON.parse(File.read(path))
      rescue JSON::ParserError, StandardError
        nil
      end

      # Atomic temp+rename (the control-channel idiom; rename over an
      # existing path is atomic on POSIX).
      def atomic_write_json(path, payload)
        temp = "#{path}.#{Process.pid}.#{Thread.current.object_id}.tmp"
        File.write(temp, JSON.generate(payload))
        File.rename(temp, path)
      ensure
        File.delete(temp) if defined?(temp) && temp && File.exist?(temp)
      end

      # pi notify.js truncateUtf8Head: UTF-8-head truncation to the byte
      # bound with the marker, never splitting a multibyte character.
      def truncate_utf8_head(value, max_bytes = PREVIEW_MAX_BYTES)
        bytes = value.b
        return value if bytes.bytesize <= max_bytes

        content_bytes = max_bytes - PREVIEW_TRUNCATION_MARKER.bytesize
        end_index = content_bytes
        end_index -= 1 while end_index.positive? && (bytes.getbyte(end_index) & 0xC0) == 0x80
        "#{bytes.byteslice(0, end_index).force_encoding(Encoding::UTF_8)}#{PREVIEW_TRUNCATION_MARKER}"
      end

      def now_ms
        (Process.clock_gettime(Process::CLOCK_REALTIME) * 1000).round
      end

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def receipt(state, id, request_id, error = nil)
        text =
          case state
          when :delivered then "Steering delivered to async run #{id} (request #{request_id})."
          when :queued then "Steering queued for async run #{id} (request #{request_id})."
          when :missed then "Steering missed async run #{id} (request #{request_id}): the run ended before consumption."
          else "Failed to queue steering for async run #{id}: #{error}."
          end
        {state:, request_id:, text:}
      end
    end
  end
end
