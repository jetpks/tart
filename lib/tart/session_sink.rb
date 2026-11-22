# frozen_string_literal: true

require "json"
require "net/http"
require "time"
require "uri"
require "yaml"

require_relative "agent/session"
require_relative "identity"

module Tart
  # The observation-deck session sink (I74 — port of the deck contract
  # repos/pi-extensions/session-sink.ts, frozen at its I08; plan
  # ENTRY 6). Streams live sessions to the deck's ingest mouth as pi's
  # `--mode json` bytes over the I47 hooks seam: the sink OBSERVES the
  # loop's event stream — the recorder's session bytes are untouched
  # (the sink rides the seam, never the session file).
  #
  # The deck contract, carried verbatim (Grounds §"The mouth contract"):
  # - config: <home>/.tart/session-sink.json {"host","token","disabled"}
  #   (tart's OWN home — the architect ruling, never ~/.pi) with
  #   identity-namespaced env overrides evaluated per field (env beats
  #   file both ways; `disabled` — ANY present env value decides);
  #   unreadable/malformed = unconfigured = fully inert and silent.
  # - projection: `message_end` for roles user/assistant ONLY (the port's
  #   raw-String content is PROJECTED into pi's typed block arrays — the
  #   deck's parser walks content as an ARRAY of blocks; a verbatim
  #   String serialization would lose the text), `tool_execution_end`
  #   for every tool call; the session record opens EVERY body.
  # - engine: herdr's discipline (Grounds §"The seams") — enqueue-only
  #   handlers, ONE flusher task on the host reactor (I107 T3/V2 — the
  #   concurrency law; TRANSIENT, so it never holds the reactor open and
  #   the reactor's teardown cancel is its unwind path), coalescing
  #   debounce, FIFO order end to end, every failure caught, nothing
  #   thrown into the host; loss lines on stderr, the token NEVER in any
  #   URL or error text. NO MOTD row (the ruling — silent ambient
  #   capture; herdr got one because it is owner-visible pane state).
  # - an OFF-REACTOR seat (the bare hygiene probe, the post-reactor
  #   shutdown tail) spawns no flusher: enqueues accumulate, and the
  #   terminal flush posts synchronously on the caller thread — today's
  #   bounded tail, unchanged.
  module SessionSink
    # The frozen tuning (session-sink.ts :29-40), pinned by the config
    # gate; `register(tuning:)` is the test seam ONLY (production callers
    # pass nothing).
    QUEUE_CAP = 2000
    DEBOUNCE_MS = 250
    POST_TIMEOUT_MS = 8000
    MAX_ATTEMPTS = 3
    RETRY_BACKOFF_MS = [500, 1000].freeze
    SHUTDOWN_WAIT_MS = 1000
    SHUTDOWN_POST_TIMEOUT_MS = 2000

    # The frozen mouth path (session-sink.ts ingestUrl).
    INGEST_PATH = "/conversations/ingest"

    module_function

    # Subscribes the four channels onto the seam. Registration is
    # UNCONDITIONAL — config resolves per bind (session_start), so a
    # config file that appears mid-process arms the next session.
    # `system_prompt:` is a callable (or String) evaluated lazily at
    # FIRST POST (the system prompt may not be built at session_start).
    def register(hooks:, identity: Identity::DEFAULT, env: ENV,
                 config_path: default_config_path, system_prompt: nil, tuning: {})
      engine = Engine.new(identity:, env:, config_path:, system_prompt:, tuning:)
      hooks.on("session_start") { |event, context| engine.handle_session_start(event, context) }
      hooks.on("message_end") { |event, context| engine.handle_event(event, context) }
      hooks.on("tool_execution_end") { |event, context| engine.handle_event(event, context) }
      hooks.on("session_shutdown") { |event, context| engine.handle_shutdown(event, context) }
      engine
    end

    # The tart-native config file (the architect ruling — tart's own
    # home, the recorder's default_root convention).
    def default_config_path(home = Dir.home)
      File.join(home, ".tart", "session-sink.json")
    end

    # POST URL = host with trailing slashes stripped + the frozen path
    # (session-sink.ts ingestUrl).
    def ingest_url(host)
      "#{host.to_s.sub(%r{/+\z}, "")}#{INGEST_PATH}"
    end

    # Content-record ids: "<session-id>/<n>", n monotonic per session id
    # ACROSS rebinds (session-sink.ts :185-190).
    def record_id(session_id, n)
      "#{session_id}/#{n}"
    end

    # The config law (AC1): file + per-field env overrides. Env beats
    # file both ways — host/token: a non-empty env value wins, else the
    # file's; disabled: ANY present env value decides ("1"/"true" mute,
    # any other present value unmutes), else the file's disabled == true.
    # Unreadable/malformed/non-object file = {} (unconfigured; silent).
    def resolve_config(env, identity: Identity::DEFAULT, config_path: default_config_path)
      file = read_config_file(config_path)
      key = ->(suffix) { Identity.env_key(identity, suffix) }
      disabled_env = env_value(env, key.("SESSION_SINK_DISABLED"))
      {
        "host" => env_value(env, key.("SESSION_SINK_HOST")) || file["host"],
        "token" => env_value(env, key.("SESSION_SINK_TOKEN")) || file["token"],
        "disabled" => disabled_env.nil? ? file["disabled"] == true : disabled_env == "1" || disabled_env == "true"
      }
    end

    # Configured ⇔ host non-empty AND token non-empty AND not disabled.
    def configured?(config)
      config["host"].is_a?(String) && !config["host"].empty? &&
        config["token"].is_a?(String) && !config["token"].empty? && !config["disabled"]
    end

    # The session record minted at bind (opens EVERY body): the minted
    # timestamp is the sink's bind time, not the recorder's header
    # timestamp — the server keys on id; re-sent session records are
    # metadata no-ops (declared).
    def session_record(session_id, cwd, timestamp: nil)
      {
        "type" => "session", "version" => Agent::Session::CURRENT_VERSION, "id" => session_id,
        "timestamp" => timestamp || Agent::Session.now_iso, "cwd" => cwd
      }
    end

    # The projection law (AC2): the three record shapes, pi's `--mode
    # json` bytes. `message_end` projects roles user/assistant ONLY —
    # `tool`/`custom`/`system` and every other event type → nil (not
    # emitted, consumes NO id). n arrives only when the caller has
    # already committed to a projection consuming it.
    def project_event(event, session_id, n)
      # the loop emits symbol-keyed types (:message_end); the seam
      # normalizes channels on one table — project the same way.
      type = (event[:type] || event["type"]).to_s
      message = event[:message] || event["message"]
      case type
      when "message_end"
        case message_role(message)
        when :user then message_record("message_end", session_id, n, user_message_hash(message))
        when :assistant then message_record("message_end", session_id, n, assistant_message_hash(message))
        end
      when "tool_execution_end"
        tool_execution_record(event, session_id, n)
      end
    end

    # The seed law: count the session-file entries the sink would have
    # emitted — `type == "message"` whose message.role is user,
    # assistant, or `tool` (the PORT's recorded spelling — pi counts
    # toolResult; the port's recorded byte family uses `tool`; declared
    # adaptation), skipping custom_message/compaction/session entries;
    # unreadable → 0. Over-count safe, under-count not.
    def seed_count(session_path)
      return 0 unless session_path.is_a?(String) && !session_path.empty? && File.file?(session_path)

      count = 0
      File.foreach(session_path) do |line|
        begin
          entry = JSON.parse(line)
        rescue StandardError
          next # blank/malformed lines skipped (the recorder's parse discipline)
        end
        next unless entry.is_a?(Hash) && entry["type"] == "message"
        count += 1 if %w[user assistant tool].include?(entry.dig("message", "role"))
      end
      count
    rescue StandardError
      0
    end

    # X-Space-Slug: walk up from the bind cwd for space.yaml
    # (YAML.safe_load; malformed → treated as absent, walk continues);
    # slug = slugify(title) when the title is a non-empty String, else
    # the id; no space.yaml to the filesystem root → nil.
    def space_slug_for(cwd)
      path = File.expand_path(cwd.to_s)
      loop do
        data = read_space_yaml(File.join(path, "space.yaml"))
        if data.is_a?(Hash)
          slug = slugify(data["title"]) if data["title"].is_a?(String) && !data["title"].empty?
          slug = slugify(data["id"]) if slug.nil? && data["id"].is_a?(String) && !data["id"].empty?
          return slug unless slug.to_s.empty?
        end
        parent = File.dirname(path)
        return nil if parent == path
        path = parent
      end
    end

    def slugify(text)
      text.to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")
    end

    # X-Agent-Name resolution (priority): (1) the system prompt opens
    # with <active_agent name="X"/> (pi-subagents' prompt tag — the deck
    # contract's source seam); (2) the env <IDENTITY>_SESSION_SINK_AGENT_NAME
    # pick (the tart subagent-child seam — pi-subagents tags prompts, the
    # port plumbs the label, keeping the child LLM wire untouched);
    # (3) nil.
    def agent_name_for(system_prompt, env: ENV, identity: Identity::DEFAULT)
      prompt = system_prompt.respond_to?(:call) ? system_prompt.call : system_prompt
      if prompt.is_a?(String)
        match = prompt.match(/\A\s*<active_agent name="([^"]*)"\s*\/>/)
        return match[1] if match && !match[1].empty?
      end
      env_value(env, Identity.env_key(identity, "SESSION_SINK_AGENT_NAME"))
    end

    # X-Agent-Role = the name with a leading architect- prefix stripped,
    # else the name.
    def agent_role_for(name)
      name.to_s.sub(/\Aarchitect-/, "")
    end

    # X-Parent-Session-Id (priority): (1) the recorder file's header
    # `parentSession` (a session FILE path) — resolve its id from that
    # file's FIRST line "id" (bounded first-line read, never the whole
    # file), fallback the _<uuid>.jsonl filename segment; (2) the env
    # <IDENTITY>_SESSION_SINK_PARENT_SESSION_ID pick (a bare session id,
    # verbatim); (3) nil.
    def parent_session_id_for(session_path, env: ENV, identity: Identity::DEFAULT)
      if session_path.is_a?(String) && !session_path.empty?
        header = first_line_hash(session_path)
        parent_path = header.is_a?(Hash) ? header["parentSession"] : nil
        if parent_path.is_a?(String) && !parent_path.empty?
          parent_header = first_line_hash(parent_path)
          id = parent_header.is_a?(Hash) ? parent_header["id"] : nil
          return id if id.is_a?(String) && !id.empty?
          return filename_session_id(parent_path)
        end
      end
      env_value(env, Identity.env_key(identity, "SESSION_SINK_PARENT_SESSION_ID"))
    end

    # The `_<uuid>.jsonl` filename segment (pi's session file naming:
    # <timestamp>_<id>.jsonl).
    def filename_session_id(path)
      base = File.basename(path.to_s, ".jsonl")
      segment = base[/_(.+)\z/, 1] || base
      segment.empty? ? nil : segment
    end

    # The stop-reason map: stop→end_turn, tool_calls→toolUse,
    # length→maxTokens, everything else verbatim (error stays error).
    def stop_reason(finish_reason)
      case finish_reason
      when "stop" then "end_turn"
      when "tool_calls" then "toolUse"
      when "length" then "maxTokens"
      when String, Symbol then finish_reason.to_s
      end
    end

    # The usage map — the port's reported facts, camelCase per pi's
    # stream, NOTHING fabricated: present only when any of
    # input/output/cache_read/cache_write is reported positive; cacheWrite
    # rides the port's recorded reported-or-0 convention. NO totalTokens,
    # NO cost (no pricing layer — recorded convention: nothing reported
    # persists nothing).
    def usage_map(tokens)
      return nil unless tokens

      input = token_count(tokens, :input)
      output = token_count(tokens, :output)
      cache_read = token_count(tokens, :cache_read)
      cache_write = token_count(tokens, :cache_write)
      return nil unless [input, output, cache_read, cache_write].any? { |value| value.is_a?(Numeric) && value.positive? }

      usage = {}
      usage["input"] = input if input.is_a?(Numeric) && input.positive?
      usage["output"] = output if output.is_a?(Numeric) && output.positive?
      usage["cacheRead"] = cache_read if cache_read.is_a?(Numeric) && cache_read.positive?
      usage["cacheWrite"] = cache_write || 0
      usage
    end

    # The port's result_content law (chat.rb :286): String verbatim,
    # Hash/Array JSON-generated, else to_s.
    def result_content(result)
      case result
      when String then result
      when Hash, Array then JSON.generate(result)
      else result.to_s
      end
    end

    # isError is derivable ONLY from the result shape (the loop's
    # error_tool_result returns BEFORE the hooks fire — no event): a Hash
    # carrying a truthy "error" key.
    def error_result?(result)
      !!(result.is_a?(Hash) && result["error"])
    end

    def message_role(message)
      role = message.respond_to?(:role) ? message.role : nil
      role&.to_sym
    end

    def message_record(type, session_id, n, message)
      {"type" => type, "id" => record_id(session_id, n), "message" => message}
    end

    # user: {"role":"user","content":[{"type":"text","text":…}],
    # "timestamp":<emit epoch-ms>} (the deck fixture's user bytes).
    def user_message_hash(message)
      {
        "role" => "user",
        "content" => [{"type" => "text", "text" => message.content}],
        "timestamp" => epoch_ms
      }
    end

    # assistant: blocks IN ORDER — the thinking block when
    # message.thinking&.text, the text block when content is a String,
    # then one toolCall block per tool call in provider (insertion)
    # order; optional passthrough keys present-only.
    def assistant_message_hash(message)
      blocks = []
      if message.thinking&.text
        block = {"type" => "thinking", "thinking" => message.thinking.text}
        block["thinkingSignature"] = message.thinking.signature if message.thinking.signature
        blocks << block
      end
      blocks << {"type" => "text", "text" => message.content} if message.content.is_a?(String)
      message.tool_calls.each_value do |call|
        blocks << {"type" => "toolCall", "id" => call.id, "name" => call.name, "arguments" => call.arguments}
      end
      h = {"role" => "assistant", "content" => blocks, "timestamp" => epoch_ms}
      h["provider"] = message.provider if message.provider
      h["model"] = message.model if message.model
      usage = usage_map(message.tokens)
      h["usage"] = usage if usage
      stop = stop_reason(message.finish_reason)
      h["stopReason"] = stop if stop
      h["errorMessage"] = message.error_message if message.error_message
      h
    end

    # tool_execution_end: the call's facts + the result under the
    # content law + the Hash-error-key isError rule; parentToolCallId
    # present-only (no emitter today — the projection is ready, pinned).
    def tool_execution_record(event, session_id, n)
      call = event[:tool_call] || event["tool_call"]
      result = event[:result] || event["result"]
      record = {
        "type" => "tool_execution_end", "id" => record_id(session_id, n),
        "toolCallId" => call&.id, "toolName" => call&.name,
        "result" => {"content" => [{"type" => "text", "text" => result_content(result)}]},
        "isError" => error_result?(result),
        "durationMs" => (duration_seconds(event) * 1000).round
      }
      parent = event[:parent_tool_call_id] || event["parent_tool_call_id"]
      record["parentToolCallId"] = parent if parent
      record
    end

    def duration_seconds(event)
      duration = event[:duration] || event["duration"] || 0
      duration.is_a?(Numeric) ? duration : 0
    end

    def token_count(tokens, name)
      return nil unless tokens.respond_to?(name)

      value = tokens.public_send(name)
      value.is_a?(Integer) ? value : nil
    end

    def read_config_file(path)
      parsed = JSON.parse(File.read(path))
      parsed.is_a?(Hash) ? parsed : {}
    rescue StandardError
      {}
    end

    def read_space_yaml(path)
      return nil unless File.file?(path)

      YAML.safe_load(File.read(path), permitted_classes: [], aliases: false)
    rescue StandardError
      nil
    end

    def first_line_hash(path)
      return nil unless File.file?(path)

      line = File.open(path) { |file| file.gets.to_s }
      parsed = JSON.parse(line)
      parsed.is_a?(Hash) ? parsed : nil
    rescue StandardError
      nil
    end

    # nil/empty env values are absent (Open3's nil-value semantics — the
    # CLOSED test envs carry nil keys for unset vars).
    def env_value(env, key)
      value = env[key]
      value = value.to_s
      value.empty? ? nil : value
    end

    def epoch_ms
      (Time.now.to_f * 1000).round
    end

    # The engine (herdr's discipline): ONE flusher task on the host
    # reactor, enqueue-only handlers, every failure swallowed. Per-boot
    # object — `register` builds it, the boot wiring drops the reference
    # (the handlers close over it). I107 (V4/M6): the guard Mutex + both
    # CondVars die — every mutation funnel (bind/registry, the queue
    # push/splice, the due-window arm/reset, the capture close/unbind,
    # the POST-completion flip, the stop flip) is a same-reactor
    # operation with no scheduler-visible suspension, and the bare-seat
    # callers (the shutdown tail) cannot interleave with fibers.
    class Engine
      # The scheduler-ready rider (Notification::Signal's mechanism — async
      # clone lib/async/notification.rb): the selector processes its ready
      # list by calling #transfer, which pushes the same queue.
      attr_reader :identity, :env, :config_path, :system_prompt

      # @param tuning [Hash] register-time test seam — may shrink the
      #   timing constants (production callers pass {}).
      def initialize(identity:, env:, config_path:, system_prompt:, tuning: {})
        @identity = identity
        @env = env
        @config_path = config_path
        @system_prompt = system_prompt
        @tuning = {
          queue_cap: tuning[:queue_cap] || QUEUE_CAP,
          debounce_ms: tuning[:debounce_ms] || DEBOUNCE_MS,
          post_timeout_ms: tuning[:post_timeout_ms] || POST_TIMEOUT_MS,
          backoff_ms: tuning[:backoff_ms] || RETRY_BACKOFF_MS,
          shutdown_wait_ms: tuning[:shutdown_wait_ms] || SHUTDOWN_WAIT_MS,
          shutdown_post_timeout_ms: tuning[:shutdown_post_timeout_ms] || SHUTDOWN_POST_TIMEOUT_MS
        }.freeze
        # I107 (V4/M6 + the V1 seam): bare same-reactor state + the wake
        # queue (a plain Thread::Queue timed pop parks a reactor FIBER;
        # blocks a plain thread) + the plain-Integer version.
        @ready = Async::Queue.new
        @state_version = 0
        @captures = []
        @counters = {}
        @due = nil
        @flusher = nil
        @stop = false
        @posting = false
      end

      # The effective timing (the test seam's readback).
      def timing
        @tuning.dup
      end

      # The bound captures (the test seam's readback; inert = empty).
      def captures
        @captures.dup
      end

      # The in-process counter registry: n is monotonic per session id
      # ACROSS rebinds — a rebind seeds max(process counter, file seed).
      def counter_for(session_id)
        @counters[session_id] || 0
      end

      # Structural quiescence reader (I103 additive — the D-family's
      # non-event predicate): queue-empty ∧ no due-window ∧ no in-flight
      # POST across every capture. False mid-POST would break the
      # then-assert-zero/one proofs (the queue is spliced before the POST
      # runs, so queue-empty alone is not quiescence).
      def idle?
        @due.nil? && !@posting && @captures.all? { |capture| capture.queue.empty? }
      end

      # --- I103 state-signal seam (I107 V1 mechanics) ---------------------
      # The await-loop's version read + the test-only park, riding the V1
      # wake: a plain-Integer version and a Thread::Queue timed-pop park
      # (parks a reactor FIBER; blocks a plain thread). The footprint is
      # these two methods, idle?, signal_state_change, and its call
      # sites: deleting them restores base behavior byte-for-byte (a
      # ping with no waiter is a no-op; production never waits).
      def state_version
        @state_version
      end

      # Parks until the version moves past from_version, belt-bounded (nil
      # on belt expiry with no change). Production never calls this.
      def wait_state_change(from_version, belt: 60)
        loop do
          return @state_version if @state_version > from_version

          return nil if @ready.pop(timeout: belt).nil?
        end
      end

      def handle_session_start(event, context)
        context = context.is_a?(Hash) ? context : {}
        ref = context[:session].is_a?(Hash) ? context[:session] : nil
        bind_identity = context[:identity].is_a?(String) && !context[:identity].empty? ? context[:identity] : @identity
        config = SessionSink.resolve_config(@env, identity: bind_identity, config_path: @config_path)
        flush_previous_captures
        return unless SessionSink.configured?(config)

        session_id = ref && (ref["agent_session_id"] || SessionSink.filename_session_id(ref["agent_session_path"]))
        return unless session_id.is_a?(String) && !session_id.empty?

        capture = Capture.new(session_id:, session_path: ref["agent_session_path"],
                              cwd: context[:cwd], mode: context[:mode], identity: bind_identity,
                              config: config, engine: self)
        @captures << capture unless @captures.include?(capture)
        @counters[capture.session_id] = capture.counter
        ensure_flusher
        ping
        signal_state_change
      rescue StandardError
        nil # swallowed — nothing thrown into the host, ever
      end

      def handle_event(event, _context)
        capture = current_capture
        return unless capture

        n = capture.counter + 1
        record = SessionSink.project_event(event, capture.session_id, n)
        return if record.nil? # a nil projection consumes NO id

        enqueue(capture, record, n)
      rescue StandardError
        nil
      end

      # reason "quit" → TERMINAL flush (bounded: wait ≤ SHUTDOWN_WAIT_MS
      # for an in-flight POST, splice the queue — pending content rides
      # the terminal body, order preserved — ONE terminal POST with
      # X-Session-Complete: true, NO retry, even with an empty queue).
      # Any other reason → non-terminal flush + unbind (today nothing
      # emits other reasons). Returns within ≤ ~3 s ALWAYS.
      def handle_shutdown(event, _context)
        reason = event["reason"] || event[:reason]
        capture = current_capture
        return unless capture

        if reason == "quit"
          terminal_flush(capture)
        else
          unbind(capture)
        end
      rescue StandardError
        nil
      end

      # The flusher's stop (the test seam AND the terminal path): the
      # V1 ping wakes the parked drain; the bounded stop is Task#stop (the
      # Cancel lands at the pop park — the D2 unwind). A dead task (the
      # post-reactor seat) is a no-op. The transient task never holds the
      # reactor open regardless.
      def stop
        @stop = true
        ping
        signal_state_change
        if (flusher = @flusher) && flusher.alive?
          flusher.stop
          begin
            flusher.wait
          rescue Async::Cancel, StandardError
            nil # the unwind is the point; the parks are bounded
          end
        end
        @flusher = nil
        nil
      end

      private

      # The V1 ping (the wake's producer side): the direct queue push
      # plus the scheduler-ready rider when a scheduler is present on the
      # producer's thread (Notification::Signal's mechanism) — both paths
      # honor the standing same-thread lost-wakeup claim.
      def ping
        @ready.push(:wake)
        Fiber.scheduler&.push(::Tart::Wake.new(@ready, :wake))
        nil
      end

      # I103 — the state-signal broadcast (additive observability): the
      # tail of every observed flusher mutation funnel (bind/registry,
      # queue push/pop, due-window arm/reset, capture close/unbind, POST
      # completion, the stop flip). A ping with no waiter is a no-op.
      def signal_state_change
        @state_version += 1
        ping
        nil
      end

      # The last-bound capture (the one live events project into); a
      # closed capture is never re-projected.
      def current_capture
        @captures.reverse.find { |capture| !capture.closed? }
      end

      # Rebind: flush the previous captures NON-terminally (best-effort
      # splice + POST — the due-now signal hands the pending queue to the
      # flusher) and mark them closed; the flusher drops them drained.
      def flush_previous_captures
        previous = @captures.select { |capture| !capture.closed? }
        previous.each { |capture| capture.close }
        unless previous.empty?
          @due = now_ms
          ping
        end
        signal_state_change
      end

      def unbind(capture)
        capture.close
        @due = now_ms if @captures.any? { |c| !c.closed? && !c.queue.empty? }
        ping
        signal_state_change
      end

      def enqueue(capture, record, n)
        dropped = 0
        capture.counter = n
        @counters[capture.session_id] = n
        capture.queue << record
        dropped = capture.queue.size - @tuning[:queue_cap]
        dropped.times { capture.queue.shift } if dropped.positive?
        @due ||= now_ms + @tuning[:debounce_ms]
        ensure_flusher
        ping
        signal_state_change
        report_loss(capture, "queue overflow: dropped #{dropped} oldest record(s) for session #{capture.session_id}") if dropped.positive?
      end

      def terminal_flush(capture)
        # Bounded wait for an in-flight POST (the flusher's), then the
        # capture is gone from the registry — pending content splices,
        # order preserved. The wait parks on the V1 wake (the POST-
        # completion ping); the belt is the shutdown bound itself.
        deadline = now_ms + @tuning[:shutdown_wait_ms]
        records = nil
        @ready.pop(timeout: remaining_ms(deadline) / 1000.0) while @posting && remaining_ms(deadline).positive?
        capture.close
        @captures.delete(capture)
        @due = nil
        records = capture.splice
        signal_state_change
        with_post_lock { post_batch(capture, records, terminal: true) }
        stop
      end

      # The post lock: ≤ 1 in-flight POST by construction — the flusher
      # never splices under one, and the terminal handler holds the lock
      # across its own one-shot POST.
      def with_post_lock
        @posting = true
        begin
          yield
        ensure
          @posting = false
          ping
          signal_state_change # I103 — the POST completed
        end
      end

      # ONE flusher task (TRANSIENT on the host reactor — it never holds
      # the reactor open; the teardown cancel is its unwind path): waits
      # to due on the V1 wake (the debounce window is the pop's timeout —
      # a task TIMER shape, never a wall-clock poll loop), splices the
      # WHOLE queue (per capture), posts FIFO — ≤ 1 in-flight POST by
      # construction (the @posting flag + the wake ping; same-reactor
      # funnels cannot interleave).
      def drain_loop
        loop do
          work = wait_for_work
          break if @stop || work.nil?

          work.each do |capture, records|
            with_post_lock { post_batch(capture, records, terminal: false) }
          end
        end
      rescue StandardError
        nil # swallowed — the harness NEVER crashes on the sink
      end

      # The flusher's park: the V1 timed pop. Nil due → park on the wake
      # (the belt bounds the park purely as the wedge guard — a lost wake
      # re-checks after IDLE_BELT_S); a due window → park until the wake
      # or the due TIMER fires; @posting → park until the POST-completion
      # ping (never splice under an in-flight POST).
      IDLE_BELT_S = 30

      def wait_for_work
        loop do
          return nil if @stop

          if @posting
            @ready.pop(timeout: IDLE_BELT_S)
          elsif @due.nil?
            @ready.pop(timeout: IDLE_BELT_S)
          else
            remaining = remaining_ms(@due)
            if remaining <= 0
              @due = nil
              work = splice_all
              signal_state_change # I103 — the queue pop
              return work
            end
            @ready.pop(timeout: remaining / 1000.0)
          end
        end
      end

      def splice_all
        work = []
        @captures.each do |capture|
          records = capture.splice
          work << [capture, records] unless records.empty?
        end
        @captures.reject! { |capture| capture.closed? && capture.queue.empty? }
        work
      end

      # POST: Net::HTTP (stdlib), per-POST connection, success ⇔ 202;
      # non-202/exception → retry the SAME batch, MAX_ATTEMPTS total,
      # sleeps RETRY_BACKOFF_MS[min(attempt-1, last)] between attempts;
      # final failure → drop the batch + one loss line. The session
      # record leads EVERY body (re-sent session records are metadata
      # no-ops server-side — identity survives even a dropped first
      # batch). The terminal POST is one-shot, NO retry.
      def post_batch(capture, records, terminal:)
        headers = capture.headers(self)
        headers = headers.merge("X-Session-Complete" => "true") if terminal # one-shot, no retry
        body = [capture.session_line, *records.map { |record| JSON.generate(record) }].join("\n")
        attempts = terminal ? 1 : MAX_ATTEMPTS
        last_error = nil
        attempts.times do |attempt|
          ok, error = post_once(capture.config["host"], headers, body)
          return true if ok

          last_error = error
          break if terminal || attempt == attempts - 1

          sleep(@tuning[:backoff_ms][[attempt, @tuning[:backoff_ms].size - 1].min] / 1000.0)
        end
        report_loss(capture, "dropped #{records.size} record(s) for session #{capture.session_id} " \
                             "after #{attempts} attempt(s): #{last_error}")
        false
      rescue StandardError => e

        report_loss(capture, "dropped #{records.size} record(s) for session #{capture.session_id}: #{e.class}")
        false
      end

      def post_once(host, headers, body)
        uri = URI(SessionSink.ingest_url(host))
        timeout = @tuning[:post_timeout_ms] / 1000.0
        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                        open_timeout: timeout, read_timeout: timeout, write_timeout: timeout) do |http|
          response = http.post(uri.request_uri, body, headers)
          return [response.code == "202", "status #{response.code}"]
        end
      rescue StandardError => e
        [false, e.class.to_s] # the message may echo response metadata — the class only
      end

      # Loss reporting: `session-sink: <first line, ≤ 200 chars>` on
      # stderr; the TOKEN never appears in any message (it lives only in
      # the Authorization header). Non-TUI: one line per dropped batch;
      # TUI: at most ONE line per capture (bounded noise — the port has
      # no ui.notify surface for this; declared deviation from pi's
      # notify-then-stderr ladder). Inert captures NEVER log.
      def report_loss(capture, message)
        line = "session-sink: #{message.to_s.split("\n").first.to_s[0, 200]}"
        return if capture&.mode == "tui" && capture.loss_reported?

        capture&.mark_loss_reported if capture&.mode == "tui"
        $stderr.write("#{line}\n")
      rescue StandardError
        nil
      end

      # The flusher task spawns on the HOST REACTOR (the handler seats);
      # TRANSIENT — never holds the reactor open. An off-reactor seat
      # spawns nothing (the terminal flush covers the bare tail).
      def ensure_flusher
        @stop = false
        return if @flusher&.alive?

        task = Async::Task.current? or return
        @flusher = task.async(transient: true) { drain_loop }
      end

      def remaining_ms(due)
        (due - now_ms).clamp(0.0, nil)
      end

      def now_ms
        (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000).round
      end
    end

    # Per-session state (session-sink.ts Capture): the resolved config
    # (a stale capture never re-resolves), the minted session record
    # line, the seeded record counter, the pending queue. Queue ops run
    # under the engine's mutex (the engine IS the concurrency boundary).
    class Capture
      attr_reader :session_id, :session_path, :cwd, :mode, :identity, :config,
                  :session_line, :queue
      attr_accessor :counter

      def initialize(session_id:, session_path:, cwd:, mode:, identity:, config:, engine:)
        @session_id = session_id
        @session_path = session_path
        @cwd = cwd
        @mode = mode
        @identity = identity
        @config = config
        @counter = [engine.counter_for(session_id), SessionSink.seed_count(session_path)].max
        @session_line = JSON.generate(SessionSink.session_record(session_id, cwd))
        @queue = []
        @closed = false
        @headers = nil
        @loss_reported = false
      end

      def closed?
        @closed
      end

      def close
        @closed = true
      end

      def splice
        drained = @queue
        @queue = []
        drained
      end

      # Optional headers, resolved lazily at FIRST POST (the system
      # prompt may not be built at session_start) — present-only, cached.
      def headers(engine)
        @headers ||= begin
          h = {"Authorization" => "Bearer #{@config["token"]}",
               "Content-Type" => "application/x-ndjson"}
          slug = SessionSink.space_slug_for(@cwd)
          h["X-Space-Slug"] = slug if slug
          parent = SessionSink.parent_session_id_for(@session_path, env: engine.env, identity: @identity)
          h["X-Parent-Session-Id"] = parent if parent
          name = SessionSink.agent_name_for(engine.system_prompt, env: engine.env, identity: @identity)
          if name
            h["X-Agent-Name"] = name
            h["X-Agent-Role"] = SessionSink.agent_role_for(name)
          end
          h
        end
      end

      def loss_reported?
        @loss_reported
      end

      def mark_loss_reported
        @loss_reported = true
      end
    end
  end
end
