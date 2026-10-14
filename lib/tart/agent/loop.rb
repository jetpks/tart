# frozen_string_literal: true

require_relative "../compaction"
require_relative "../hooks"
require_relative "../herdr"
require_relative "../memory"
require_relative "../models"
require_relative "../settings"
require_relative "session"
require_relative "status"
require_relative "system_prompt"

module Tart
  module Agent
    # The agent loop (port of pi's agent-loop.ts runAgentLoop/runLoop shape,
    # mapped onto ruby_llm 2.1 and the I02 kernel).
    #
    # pi's shape, preserved:
    # - outer loop: continues while queued user (steering/follow-up) messages
    #   arrive after the agent would stop;
    # - inner loop: model turn, then tool-call batches (ruby_llm's
    #   pending-tool-call execution on #step), until the model answers
    #   without tool calls; tools execute unconditionally (pi's
    #   agent-loop.ts:832 — no permissions system);
    # - an aborted turn emits turn_end/agent_end and stops.
    #
    # Kernel mapping: the loop runs as the work block (task subtree) on
    # {Core::Loop}; a kernel interrupt (Ctrl+C or the INT trap net) cancels
    # the in-flight turn — the Async::Cancel lands at the turn fiber's
    # current wait (the streaming HTTP read, or a tool's cooperative wait —
    # probe3: Net::HTTP over TLS is fiber-scheduler-cooperative), the chat
    # is cancelled at the ladder (tools kill their subprocess groups at
    # their checkpoints), and the cancel propagates.
    #
    # Events (minimal surface, pi's AgentEvent vocabulary plus the
    # compaction events): :agent_start, :turn_start, :message_start,
    # :message_update (streamed chunks), :message_end,
    # :tool_execution_start, :tool_execution_end, :turn_end,
    # :compaction_start, :compaction, :agent_end — ELEVEN emitted types
    # (Grounds §2 count correction: the :compaction_start border-status
    # event landed with the I30-era compaction work; this comment listed
    # ten until I47).
    #
    # Compaction (pi's auto-compaction, agent-session.ts:3007-3219): after
    # a completed turn, provider-reported context usage over the model's
    # context window minus the reserve compacts ("threshold"); a step that
    # fails with RubyLLM::ContextLengthExceededError omits the attempt (the
    # gem never appends the failed response), compacts and retries the turn
    # once ("overflow", latched — a second consecutive overflow surfaces as
    # the error). The compaction entry goes to the session recorder; the
    # chat history is replaced in place with [summary message, kept tail].
    class Loop
      # @param chat [RubyLLM::Chat] configured for the endpoint (model,
      #   provider, protocol).
      # @param tools [Hash{String => RubyLLM::Tool}] the selected loadout
      #   ({Tools::Registry.build}); disabled tools are never registered.
      # @param system_prompt [String, nil] set as the chat's instructions.
      # @param on_event [Proc, nil] called with each event Hash.
      # @param recorder [Session::Recorder, nil] the optional session
      #   recorder (pi's SessionManager, message subset): every message this
      #   run adds is appended to the session file in order; +nil+ = off.
      # @param seed_messages [Array<Hash, RubyLLM::Message>] prior context
      #   messages to seed the chat with before the run (resume:
      #   Agent::Session.context_messages) — the model sees them on the
      #   wire, they are never re-recorded as new messages.
      # @param context_window [Integer, nil] the model's context window,
      #   overriding the resolution order <IDENTITY>_CONTEXT_WINDOW →
      #   chat.model.context_window → nil (nil/<= 0 disables the threshold
      #   trigger only; the overflow trigger always fires).
      # @param identity [String] the resolved face (Tart::Identity) whose
      #   env namespace the context-window env tier reads (AC4).
      # @param compaction [Hash, Compaction::Settings, nil] compaction
      #   settings ({enabled:, reserve_tokens:, keep_recent_tokens:});
      #   nil = pi's defaults (enabled, reserve 16384, keep-recent 20000).
      # @param thinking_level [String] the session's thinking level (pi
      #   DEFAULT_THINKING_LEVEL "medium"); {set_thinking_level} changes
      #   it mid-session — the next request picks it up (the hook reads it
      #   at request time; no gem state to reset).
      # @param model_reasoning [Boolean] the model's reasoning capability
      #   (pi model.reasoning) — gates whether any reasoning_effort is
      #   ever sent.
      # @param thinking_level_map [Hash, nil] the model's thinkingLevelMap
      #   (pi's Partial Record<level, String|null>, symbolized); nil = the
      #   map-less rule (pi's ladder without xhigh/max, off sends nothing).
      # @param compat [Shapes::ModelCompat, nil] the model's pi-compat
      #   dialect subset (I46); nil = today's default arm (the I36 effort
      #   wiring, no thinking object/tool_stream/role rewrite/rename).
      #   {switch_model} swaps it mid-session — the hook reads it at
      #   request time, same idiom as the level.
      # @param hooks [Tart::Hooks, nil] the extension seam (I47): when
      #   present every emitted event routes through {Hooks#emit}
      #   (registration-order handlers, then the surface sink the Hooks
      #   holds), the tool batch consults the terminate ledger, and the
      #   pending nextTurn queue drains after every user message; nil =
      #   today's direct on_event path, byte-identical.
      # @param hooks_context [Proc, Hash, nil] the emission context the
      #   loop hands {Hooks#emit} ({cwd:, mode:, session:, identity:} —
      #   pi's ctx); a Proc re-reads per event (the boot wiring's seam —
      #   /new swaps the recorder). nil = the loop's own view.
      # @param steer_inbox [String, nil] the steering FILE inbox (I48 —
      #   the async child's `--steer-inbox` dir): drained at the SAME
      #   consumption points as the in-memory queue (§5.1). Steer request
      #   files join the queue + log their correlated consumption
      #   ({requestId, consumedAt} in steer-log.jsonl) + unlink
      #   (at-least-once); a stop request file interrupts the run exactly
      #   like a kernel interrupt (:agent_end interrupted: true); a file
      #   that fails to parse is unlinked and skipped (poison-pill
      #   safety). nil (interactive parents, tests) = today's behavior.
      def initialize(chat:, tools:, system_prompt: nil, on_event: nil,
        recorder: nil, seed_messages: [], context_window: nil, compaction: nil,
        identity: Identity::DEFAULT, thinking_level: "medium",
        model_reasoning: false, thinking_level_map: nil, compat: nil,
        hooks: nil, hooks_context: nil, steer_inbox: nil)
        @chat = chat
        @tools = tools
        @on_event = on_event
        @hooks = hooks
        @hooks_context = hooks_context
        @recorder = recorder
        @identity = identity
        @context_window = context_window
        @compaction_settings = Compaction::Settings.resolve(compaction)
        @thinking_level = thinking_level
        @model_reasoning = model_reasoning == true
        @thinking_level_map = thinking_level_map
        @compat = compat
        @overflow_recovery_attempted = false
        @pre_compaction_messages = {}.compare_by_identity
        @entry_ids = {}.compare_by_identity
        @new_messages = []
        @stream_started = false
        @steering_queue = Queue.new
        @steer_inbox = steer_inbox
        @wake_opening = false
        @in_run = false
        @last_error = nil
        @interrupted = false

        @chat.with_tools(*tools.values).with_tool_options(concurrency: :fibers) unless tools.empty?
        @chat.with_instructions(system_prompt) if system_prompt
        seed_messages.each { |message| @chat.add_message(message) }
        install_chat_callbacks
        install_thinking_seam
      end

      # Queues a user message. While the agent runs, it is consumed at the
      # next turn boundary (pi's steering queue); queued messages left after
      # the loop would stop continue it (pi's follow-up queue) — one queue,
      # pi's two consumption points.
      def push_message(text)
        @steering_queue << text
        self
      end

      # @return [Boolean] whether steering messages are queued but not yet
      #   consumed (thread-safe; the chat surface checks it on agent_end to
      #   close the submit/stop race).
      def queued_messages?
        !@steering_queue.empty?
      end

      # @return [Boolean] whether a run is in flight (I48 — one Loop one
      #   fiber: #wake no-ops while true, so the completion kick that
      #   lands mid-run is dropped and the queued notification rides the
      #   in-flight run's next add_user_message drain instead).
      def running?
        @in_run
      end

      # The subagents completion wake (I48 §5.3 — pi triggerTurn on the
      # port's existing seams): run-shaped with NO prompt — when no
      # steering message opens the run, the hooks' pending_next_turn
      # queue drains AS the turn's opening messages (the §I47 drain path:
      # user-role wire text, :message_start/:message_end with the
      # CustomMessage, the session custom_message entry). Empty queue +
      # empty steering (memory queue AND the file inbox) → returns
      # immediately with NO model call. NO-OP when a run is in flight
      # (race-safe: the loop's own running flag guards it — never two
      # fibers driving one Loop). Must be called on the kernel reactor
      # fiber, like #run. Returns whether a run was started.
      def wake
        return false if @in_run

        pending = @hooks ? @hooks.pending_next_turn : []
        if pending.empty? && !queued_messages? && !steer_inbox_pending?
          return false
        end

        # The peek drained the hooks queue atomically (the seam's only
        # read is a drain); restore it verbatim so the run's own §I47
        # drain delivers the messages in order.
        pending.reverse_each { |item| @hooks.send_next_turn(**item) } if @hooks && !pending.empty?

        @wake_opening = true
        begin
          run(nil)
        ensure
          @wake_opening = false
        end
        true
      end

      # The resolved context window (the compaction threshold's
      # denominator) — the test/launcher readback for the switch seam.
      attr_reader :context_window

      # The session's thinking level (pi agent.state.thinkingLevel) — the
      # surface's readback ({Render::Chat#apply_thinking_selection} drives
      # it through {set_thinking_level}).
      attr_reader :thinking_level

      # The session recorder (pi SessionManager) — the launcher's session-env
      # readers expose the CURRENT session's id + file through it (I41: the
      # bash tool's <IDENTITY>_SESSION_ID/_SESSION_FILE; /new and resume
      # swap the loop, and the readers re-resolve at every spawn).
      attr_reader :recorder

      # The thinking level's runtime seam (pi setThinkingLevel :5163-5172 →
      # session state): stored only — the request hook reads it at request
      # time, so the NEXT request carries the new level (pi's per-request
      # clampThinkingLevel, streamSimple :749). The surface calls it.
      def set_thinking_level(level)
        @thinking_level = level
        self
      end

      # The model-switch seam (I27, /model + the selector menus): swaps
      # the runtime chat model in place — ruby_llm Chat#with_model
      # (live-verified, chat.rb:609: re-resolves provider + connection)
      # — and re-resolves the context window the compaction math uses.
      # The provider/protocol/assumption kwargs match the launcher's
      # build_chat (+provider+ is the WIRE slug — Models.wire_provider;
      # the openai provider would otherwise pick :responses; the port's
      # models are assumed, not registry-resolved). Idle-only: the menus
      # open when no turn runs.
      #
      # I36: the reasoning facts re-resolve alongside (pi setModel swaps
      # the Model object, so its reasoning/thinkingLevelMap come from the
      # switched entry): +model_reasoning:+/+thinking_level_map:+ carry the
      # switched entry's composed facts ({Settings.thinking_facts}'s rule
      # — the surface passes them; nil = the entry declares none, the
      # map-less rule). I46: +compat:+ rides the same wholesale re-resolve
      # (nil IS "the switched model declares none" — the default arm — not
      # "keep the previous").
      def switch_model(model_id, provider:, context_window: nil, model_reasoning: nil, thinking_level_map: nil,
        compat: nil)
        @chat.with_model(model_id, provider:, protocol: :chat_completions, assume_model_exists: true)
        # pi has no cached window to go stale: setModel swaps the Model
        # object (agent-session.ts:2484) and every check reads
        # model.contextWindow live (:2965). The port's cache re-resolves
        # instead, through the boot chain's resolution (Settings
        # .resolve_context_window, settings tier excluded — the loop holds
        # no settings; bin/tart resolves them at boot): the catalog-
        # declared window, else TART_CONTEXT_WINDOW, else the switched
        # chat's model (the gem's registry resolution — under the boot
        # path's assume_model_exists a mock lands on Model.default with no
        # context_window), else the known-models table (I30: a table entry
        # with no declared window keeps the threshold armed instead of
        # nil-disabling it). nil still = threshold disabled, pi's
        # `contextWindow ?? 0`.
        @context_window = Settings.resolve_context_window(explicit: context_window, model: @chat.model)
        # The facts re-resolve wholesale (pi setModel swaps the Model
        # object — no stale map survives onto the switched model): the
        # surface passes fully composed facts, so nil IS "the entry
        # declares none" (the map-less rule), not "keep the previous".
        @model_reasoning = model_reasoning == true
        @thinking_level_map = thinking_level_map
        @compat = compat
        self
      end

      # Runs the agent to completion of the prompt and every queued message.
      # Must be called on the kernel reactor fiber (as the Core::Loop work
      # block): every model/tool step runs INLINE on this fiber — the LLM
      # HTTP I/O and tool execution are fiber-scheduler-cooperative, so the
      # reactor keeps scheduling while the step runs.
      #
      # @return [Array<RubyLLM::Message>] the messages added by this run.
      def run(prompt = nil)
        @new_messages = []
        @last_error = nil
        @interrupted = false
        @in_run = true
        emit(type: :agent_start)

        begin
          run_loop(prompt)
        rescue Async::Cancel
          @interrupted = true
          emit(type: :turn_end, interrupted: true)
          emit(type: :agent_end, interrupted: true, messages: new_messages)
          raise
        ensure
          @in_run = false
        end

        emit(type: :agent_end, interrupted: false, messages: new_messages) unless @last_error
        new_messages
      end

      # @return [Boolean] whether a kernel interrupt cancelled the run.
      def interrupted?
        @interrupted
      end

      # @return [RubyLLM::Error, StandardError, nil] the error that stopped
      #   the last run, if any (pi's stopReason "error").
      def last_error
        @last_error
      end

      # @return [Array<RubyLLM::Message>] messages added by the last run.
      def new_messages
        @new_messages.dup
      end

      # Manual compaction (pi session.compact, agent-session.ts:2764 — the
      # /compact command's seam): runs the I08 machinery now, on demand.
      # Like #run, it must be called on the kernel reactor fiber (the
      # summarization call runs inline — cooperative I/O). @return [Boolean]
      # whether a compaction happened — false when there is nothing to
      # compact (pi raises "Nothing to compact (session too small)"); pi
      # aborts a running turn first — the port dispatches /compact only when
      # idle.
      def compact
        run_compaction(reason: :manual)
      end

      # The !-prefix bash execution record (pi recordBashResult
      # agent-session.ts:3879): a bashExecution message entry on the same
      # leaf chain — the chat surface calls this when the executor
      # completes. +message+ is the pi-shaped hash
      # ({Session.bash_execution_message}).
      def record_bash_execution(message)
        @recorder&.append_bash_execution(message)
      end

      private

      # Session recording (pi SessionManager.appendMessage): the recorder
      # appends each new message as a message entry, in conversation order.
      # The entry id is kept for the message so a later compaction can name
      # its first-kept entry (pi's firstKeptEntryId).
      def record(message)
        entry_id = @recorder&.append_message(message)
        @entry_ids[message] = entry_id if entry_id
        entry_id
      end

      def run_loop(prompt)
        # Outer loop (pi): keep going while queued messages keep arriving.
        # pi also polls the steering queue at loop start (agent-loop.ts:175:
        # "user may have typed while waiting"); the port consumes pre-run
        # queued messages there only when no prompt opens the run — with a
        # prompt they are consumed at the first turn boundary (I03-locked:
        # test_queued_message_continues_the_outer_loop, two requests), a
        # recorded parity deviation.
        first = true
        loop do
          emit(type: :turn_start)
          if first && prompt
            add_user_message(prompt)
          else
            before = @new_messages.size
            steering_messages.each { |text| add_user_message(text) }
            # I48 wake: with no prompt and no steering opening the run, the
            # pending nextTurn queue IS the opening turn (each pending
            # rides the §I47 drain path). Nothing added (the queue raced
            # empty between #wake's check and here) → no model call.
            drain_next_turn_messages if first && @wake_opening
            break if first && @wake_opening && @new_messages.size == before
          end
          first = false
          inner_loop
          break if steering_messages.empty?
        end
      end

      # Inner loop (pi): model turn, then tool-call batches, until the model
      # answers without tool calls and no steering messages wait.
      def inner_loop
        loop do
          message = step_on_reactor
          next if recover_overflow?

          # The error check precedes the nil-message break: a step the worker
          # failed before producing a message (e.g. the request itself 400s)
          # must surface through the error path, not stop silently.
          return if stopped_on_error?
          break if message.nil?

          if message.role == :tool
            # The batch's terminate consult (I47 — pi
            # shouldTerminateToolBatch, agent-loop.ts:690-691: non-empty AND
            # every): an all-terminate blocked batch stops the INNER loop;
            # the outer steering loop is untouched. The ledger clears per
            # batch (stale ids never leak into the next consult).
            if @hooks && batch_terminated?
              @hooks.clear_terminate_ledger
              return
            end
            next # tool batch executed; the model responds on the next step
          elsif @chat.complete?
            # pi _handlePostAgentRun checks compaction after EVERY
            # completed turn, queued steering or not (agent-session.ts:
            # 1861-1885); the run then continues with the queued messages.
            run_threshold_compaction(message)
            pending = steering_messages
            if pending.empty?
              emit(type: :turn_end, message:)
              break
            end

            pending.each { |text| add_user_message(text) }
          end
          # Assistant message with tool calls: the batch executes on the
          # next step.
        end
      end

      # pi _checkCompaction's overflow branch (agent-session.ts:3007-3047):
      # a context-overflow step failure compacts and retries the turn once;
      # the second consecutive overflow surfaces as the error
      # (_overflowRecoveryAttempted, :3040). The latch resets on a clean
      # assistant response (:1168-1171). The gem never appends a failed
      # response to chat.messages (chat.rb: provider_completion raises
      # before record_generated_message), so the overflowing attempt is
      # already omitted. False here lets stopped_on_error? surface it.
      def recover_overflow?
        return false unless @last_error.is_a?(RubyLLM::ContextLengthExceededError)
        return false if @overflow_recovery_attempted

        @overflow_recovery_attempted = true
        return false unless run_compaction(reason: :overflow)

        @last_error = nil
        true
      end

      # pi _checkCompaction Case 3 (agent-session.ts:3050-3090): after a
      # completed turn, the direct usage of that turn's final assistant
      # message vs the model's context window and the reserve; zero/absent
      # usage falls back to the estimate (Compaction.trigger_tokens).
      def run_threshold_compaction(message)
        return unless threshold_exceeded?(message)

        run_compaction(reason: :threshold)
      end

      def threshold_exceeded?(message)
        window = resolved_context_window
        return false unless window.is_a?(Integer) && window.positive?

        tokens = Compaction.trigger_tokens(@chat.messages, message,
          pre_compaction_messages: @pre_compaction_messages, tools: @chat.tools)
        return false if tokens.nil?

        Compaction.should_compact?(tokens, window, @compaction_settings)
      end

      # Explicit kwarg → <IDENTITY>_CONTEXT_WINDOW → chat.model.context_
      # window → nil. The gem's assume_model_exists resolution lands on
      # Model.default, which carries no context_window (models.rb:210,
      # model.rb:65-75) — nil disables the threshold trigger only. The env
      # tier speaks the identity's namespace (AC4); +identity+ defaults to
      # pi — the launcher threads the resolved face (print.rb's frozen
      # construction cannot).
      def resolved_context_window
        return @context_window if @context_window

        env = ENV[Identity.env_key(@identity, "CONTEXT_WINDOW")]
        return Integer(env, 10) if env&.match(/\A\d+\z/)

        @chat.model&.context_window
      end

      # pi _runAutoCompaction (agent-session.ts:3097-3219) on the flat chat
      # history: prepare → summarize (the standalone one-shot call) →
      # replace the history with [summary message, kept tail] → record the
      # compaction entry → emit the compaction event. Returns whether a
      # compaction happened.
      def run_compaction(reason:)
        preparation = Compaction.prepare(@chat.messages, @compaction_settings, tools: @chat.tools)
        return false unless preparation

        # pi emits compaction_start once per started compaction, after
        # prepare returns truthy and before the summarization call
        # (agent-session.ts:3119, the auto path's placement, unified across
        # reasons) — the surface's "Compacting context..." border status
        # keys off it; the completed-compaction event below clears it.
        emit(type: :compaction_start, reason:)
        summarized = summarize(preparation)
        return false unless summarized

        lists = Compaction.compute_file_lists(
          Compaction.extract_file_ops(preparation.messages_to_summarize)
        )
        summary = summarized.content + Compaction.format_file_operations(lists[:read_files], lists[:modified_files])
        # pi CompactionResult.usage — the summarization call's own usage
        # (compaction.ts:1085, populated) — data only: the render is the
        # compaction-panel fast-follow's.
        preparation.usage = summarized.tokens

        keep_from = preparation.first_kept_index
        system_messages = @chat.messages.select { |message| message.role == :system }
        kept = @chat.messages[keep_from..] || []
        summary_message = @chat.add_message(role: :user, content: compaction_summary_content(summary))
        @chat.messages = [*system_messages, summary_message, *kept]

        # pi CompactionResult.estimatedTokensAfter (agent-session.ts:2850):
        # the pure estimateMessagesTokens over the post-compaction history
        # (:366-371 — chars/4, never usage-backed). Data only.
        preparation.estimated_tokens_after = Compaction.full_estimate(@chat.messages, tools: @chat.tools)[:tokens]
        @recorder&.append_compaction(
          summary:,
          first_kept_entry_id: @entry_ids[kept.first],
          tokens_before: preparation.tokens_before,
          # pi CompactionDetails (compaction.ts:37-40).
          details: {"readFiles" => lists[:read_files], "modifiedFiles" => lists[:modified_files]},
          usage: Session.compaction_usage(preparation.usage),
        )
        @pre_compaction_messages = @chat.messages.each_with_object({}.compare_by_identity) { |message, set| set[message] = true }
        # pi's rebuild source (interactive-mode.ts:3698-3705):
        # buildContextEntries + renderSessionEntries(entries.slice(1)) —
        # the recorder's context projection minus the leading compaction
        # entry: the kept post-compaction replay entries, chronological,
        # no system/summary message. No recorder, nothing recorded,
        # nothing to replay.
        entries = @recorder ? @recorder.context_entries.drop(1) : []
        emit(type: :compaction, reason:, tokens_before: preparation.tokens_before, summary:, entries:)
        true
      end

      def compaction_summary_content(summary)
        "#{Compaction::COMPACTION_SUMMARY_PREFIX}#{summary}#{Compaction::COMPACTION_SUMMARY_SUFFIX}"
      end

      # The standalone summarization call (pi generateSummaryWithUsage on
      # buildSummarizationContext, compaction.ts:637-647 + :671-741): a
      # fresh one-shot chat on the same context/endpoint — system =
      # SUMMARIZATION_SYSTEM_PROMPT, one user message carrying the serialized
      # conversation; not the chat history, no tools. max_tokens =
      # min(floor(0.8 * reserve_tokens), model max) (:683-686); the gem's
      # model.max_output_tokens is the model max (model.rb:36). Runs INLINE
      # on the turn fiber (cooperative I/O — a kernel interrupt cancels it
      # natively, the Cancel arm re-raises). nil (compaction aborted) when
      # the call fails. The full reply Message is returned — its usage is
      # pi's CompactionResult.usage (compaction.ts:1085).
      def summarize(preparation)
        prompt = Compaction.summarization_prompt(preparation.messages_to_summarize,
          previous_summary: preparation.previous_summary)
        summary_chat = build_summary_chat
        summary_chat.ask(prompt)
      rescue Async::Cancel
        # Belt-and-braces (Grounds §3 probe3 ARM2): the flag stops any
        # surviving request at its next checkpoint; the Cancel itself is
        # re-raised — run()'s rescue owns the interrupted bookkeeping.
        summary_chat.cancel
        raise
      rescue RubyLLM::CancelledError, StandardError
        nil # compaction aborts, the run continues (today's ANY-Failure rule)
      end

      def build_summary_chat
        # The protocol must ride along: the gem has no public reader for it
        # (chat.rb stores @protocol, no attr_reader), and a summary chat
        # built without it speaks the default protocol — never matching
        # the endpoint the main chat was built for.
        chat = @chat.context.chat(model: @chat.model&.id, provider: @chat.provider&.slug,
                                  protocol: @chat.instance_variable_get(:@protocol),
                                  assume_model_exists: true)
        chat.with_instructions(Compaction::SUMMARIZATION_SYSTEM_PROMPT)
        chat.with_max_output_tokens(summarization_max_tokens)
        install_summary_chat_seam(chat)
        chat
      end

      # The summarization one-shot's dialect (I46): ruby_llm callbacks are
      # per-Chat-instance (chat.rb :142 — @callbacks starts empty on a
      # fresh context.chat), so the construction hook never ran here and
      # today's summary bytes carry NO reasoning_effort and the gem's
      # max_completion_tokens. pi's summarization rides the SAME dialect
      # branch (compaction.ts:605-607 — the session level into the request
      # options), so for a zai-compat model the zai arm installs here too:
      # the thinking object, the mapped effort, and the max_tokens rename
      # land on the one-shot (the role rewrite with it — the instruction
      # renders developer on this protocol). The I36 effort arm stays OFF:
      # the summary request's compat-less bytes are the zero-change bar's
      # "today's exact shapes" (pin 8). The fresh chat reads the loop
      # state at BUILD time — a compaction builds it per call, so a
      # mid-session switch is already settled (idle-only menus).
      def install_summary_chat_seam(chat)
        compat = @compat
        return unless compat && compat.thinking_format == "zai"

        chat.before_request { |payload| apply_zai_dialect(payload, compat) }
      end

      def summarization_max_tokens
        reserve = @compaction_settings.reserve_tokens
        model_max = @chat.model&.max_output_tokens
        cap = model_max.is_a?(Integer) && model_max.positive? ? model_max : Float::INFINITY
        [(reserve * 0.8).floor, cap].min
      end

      # One ruby_llm #step INLINE on the turn fiber (the de-bridged seam —
      # probe1/probe3: the faraday :net_http I/O is fiber-scheduler-
      # cooperative). Returns the step's message (assistant message or tool
      # result), or nil when the step produced no message (chat pause).
      def step_on_reactor
        @last_message = nil
        @stream_started = false
        message = @chat.step { |chunk| handle_item({type: :chunk, chunk:}) }
        handle_item({type: :step, message:}) if message
        @last_message
      rescue Async::Cancel
        # Belt-and-braces (Grounds §3 probe3 ARM2): the flag stops any
        # surviving stream at its next chunk boundary. The Cancel itself is
        # re-raised — run()'s rescue owns the interrupted bookkeeping
        # (loop.rb's run rescue) and Core::Loop teardown relies on the raise.
        @chat.cancel
        # The Bridge-era consumer of that flag — the worker thread's stream
        # callback, raising at the next chunk boundary (probe3 ARM2) — died
        # with the Bridge: the cancelled step's stream unwinds with THIS
        # fiber, and the gem's only consumer is the NEXT operation's first
        # checkpoint (raise_if_cancelled! clears the flag as it raises,
        # chat.rb:1193-1199). Left standing, the residue would spuriously
        # cancel the run AFTER the interrupt (esc → resubmit). So the belt
        # sets the flag and this unwind consumes it immediately — the gem's
        # own checkpoint, whose clear-on-raise IS the documented reuse
        # contract ("the next cancellation checkpoint ... clears the flag so
        # the chat can be reused").
        begin
          @chat.send(:raise_if_cancelled!)
        rescue RubyLLM::CancelledError
          nil # consumed — the flag is clear for the next run
        end
        raise
      rescue RubyLLM::CancelledError
        # cancelled: today's shape — no @last_error, no error emit; the nil
        # message breaks the loop.
        nil
      rescue StandardError => e
        # The step's error lands in @last_error with the same assistant
        # message_end error emit as before (the flow contract's
        # no-silent-swallow discipline).
        record_terminal_error(e)
        @last_message
      end

      # The error terminal's recording (the arm that used to sit behind the
      # terminal-Hash check): the payload becomes @last_error — the loop's
      # existing error branches (stopped_on_error?, recover_overflow?)
      # classify it by class.
      def record_terminal_error(error)
        @last_error = error
        message = @last_message
        emit(type: :message_end, message:, error: true) if message&.role == :assistant
      end

      def stopped_on_error?
        return false unless @last_error

        emit(type: :turn_end, message: @last_message, error: true)
        emit(type: :agent_end, interrupted: false, error: @last_error, messages: new_messages)
        true
      end

      # Drains queued steering messages (thread-safe consumer side). The
      # I48 file inbox (steer_inbox:) folds into the SAME seam: drained at
      # every consumption point (the outer-loop boundary, the inner loop's
      # complete branch, and this outer break condition) — a stop request
      # found here interrupts the run exactly like a kernel interrupt.
      def steering_messages
        drain_steer_inbox
        messages = []
        loop do
          begin
            messages << @steering_queue.pop(true)
          rescue ThreadError
            break
          end
        end
        messages
      end

      # @return [Boolean] whether any request file waits in the steer
      #   inbox or the stop-requests inbox (the wake's emptiness check
      #   reads it).
      def steer_inbox_pending?
        return false unless @steer_inbox

        steer_inbox_files(@steer_inbox).any? || steer_inbox_files(stop_inbox_dir).any?
      end

      # The file inbox drain (I48 §5.1 — pi's control-channel discipline,
      # consumed child-side): sorted (the ts-padded names make
      # lexicographic = temporal); each steer file → queue + steer-log
      # entry + unlink (read → queue → log → unlink: a crash before the
      # unlink re-delivers — at-least-once, never lost); a stop request
      # (written to the SIBLING control/stop-requests/ dir per §2.4 —
      # read at the same consumption points) interrupts the run exactly
      # like a kernel interrupt (Async::Cancel — run() turns it into the
      # interrupted :agent_end, the child exits non-zero with the abort
      # message); a file that fails JSON parse is unlinked and skipped
      # (poison-pill safety).
      def drain_steer_inbox
        return unless @steer_inbox

        steer_inbox_files(@steer_inbox).each do |path|
          request = parse_request_file(path)
          if request.nil?
            File.unlink(path) rescue nil # poison: unlink + skip, never crash the run
            next
          end
          next unless request["type"] == "steer"

          @steering_queue << request["message"].to_s
          append_steer_consumption(request)
          File.unlink(path) rescue nil # LAST — a crash before this re-delivers
        end
        steer_inbox_files(stop_inbox_dir).each do |path|
          request = parse_request_file(path)
          File.unlink(path) rescue nil # the interrupt must not re-fire
          next unless request.is_a?(Hash) && request["type"] == "stop"

          raise Async::Cancel, "stop request"
        end
      end

      # The stop-requests inbox: the SIBLING of the steer-requests dir
      # (the §2.4 write path), read at the same consumption points.
      def stop_inbox_dir
        File.expand_path("../stop-requests", @steer_inbox)
      end

      def steer_inbox_files(dir)
        Dir.glob(File.join(dir, "*.json")).sort
      end

      def parse_request_file(path)
        JSON.parse(File.read(path))
      rescue StandardError
        nil
      end

      # The correlated-consumption log (T1): {requestId, consumedAt} per
      # consumed request — the receipt source the parent's steer call
      # polls for THAT request id (never mere inbox acceptance).
      def append_steer_consumption(request)
        log = File.join(File.dirname(@steer_inbox), "steer-log.jsonl")
        File.open(log, "a") do |io|
          io.write(JSON.generate({"requestId" => request["id"], "consumedAt" =>
            (Process.clock_gettime(Process::CLOCK_REALTIME) * 1000).round}))
          io.write("\n")
        end
      rescue StandardError
        nil # the log never blocks delivery (the message is already queued)
      end

      def add_user_message(text)
        message = @chat.add_message(role: :user, content: text)
        @new_messages << message
        emit(type: :message_start, message:)
        emit(type: :message_end, message:)
        record(message)
        drain_next_turn_messages
        message
      end

      # The nextTurn drain (I47 — pi _handleUserPrompt, agent-session.ts
      # :2086-2095): AFTER the user message is added/emitted/recorded, the
      # pending queue drains FIFO — each message is a user-role chat
      # message carrying the text (pi convertToLlm, messages.ts:161-170),
      # emits :message_start/:message_end carrying a Hooks::CustomMessage
      # (pi agent-loop.ts:105-126, message_start/end per initial message),
      # and records a custom_message session entry. Wire order
      # [system…, user prompt, *customs-as-user].
      def drain_next_turn_messages
        return unless @hooks

        @hooks.pending_next_turn.each do |pending|
          content = pending[:content]
          chat_message = @chat.add_message(role: :user, content:)
          @new_messages << chat_message
          custom = Hooks::CustomMessage.new(role: :custom, custom_type: pending[:custom_type],
            content:, display: pending[:display])
          emit(type: :message_start, message: custom)
          emit(type: :message_end, message: custom)
          @recorder&.append_custom_message(custom_type: pending[:custom_type], content:, display: pending[:display])
        end
      end

      # The batch consult (pi shouldTerminateToolBatch, agent-loop.ts
      # :690-691): the ids are the PRECEDING assistant message's tool_call
      # ids; TRUE iff the batch is non-empty AND every call was a
      # terminate-marked block.
      def batch_terminated?
        messages = @chat.messages
        tool_index = messages.rindex { |message| message.role == :tool }
        return false unless tool_index

        assistant = messages[0...tool_index].reverse.find { |message| message.role == :assistant }
        return false unless assistant&.tool_calls.is_a?(Hash)

        @hooks.batch_terminate?(assistant.tool_calls.keys.map(&:to_s))
      end

      def install_chat_callbacks
        @chat.before_tool_call do |tool_call|
          # ruby_llm calls after_tool_result with the result only (chat.rb:
          # run_callbacks(:after_tool_result, result)); pair the call back by
          # fiber-local storage — Thread#[] is FIBER-local on CRuby (Grounds
          # §3 probe4: sibling tool fibers isolate, no stomp), and before/after
          # run on the SAME fiber per call, in both of ToolConcurrency's
          # modes (under :fibers, inside the tool's own task fiber).
          Thread.current[:tart_tool_call] = tool_call
          # I17: arm the per-execution clock (monotonic — pi's
          # performance.now() delta, nested-tool-calls.ts:82).
          Thread.current[:tart_tool_started_at] = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          handle_item({type: :tool_execution_start, tool_call:})
        end
        @chat.after_tool_result do |result|
          duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) -
                     Thread.current[:tart_tool_started_at]
          handle_item({type: :tool_execution_end,
                       tool_call: Thread.current[:tart_tool_call], result:, duration:})
        end
        @chat.after_message do |message|
          # Tool result messages appear atomically; streamed assistant
          # messages get their events from the chunk flow and step handling.
          handle_item({type: :tool_message, message:}) if message.role == :tool
        end
      end

      # The request seam (I36 — pi's thinking wiring, ONE hook installed at
      # construction; ruby_llm's before_request runs LAST in Protocol#render,
      # mutating the symbol-keyed payload in place before serialization, on
      # BOTH the streaming and sync paths):
      #
      # (a) the resolved level reaches the wire (pi streamSimple :745-755 +
      #     the generic branch :969-976): reasoning_effort =
      #     Models.resolve_reasoning_effort — the map's value for the clamped
      #     level, else the level; off sends the map's String `off` value or
      #     NOTHING (non-reasoning models, map-less off). The gem's own
      #     thinking config is never set (with_thinking is registry-driven
      #     and unsettable — Thinking::Controls), so this hook owns the
      #     field outright. Reading @thinking_level at request time makes
      #     mid-session changes apply to the next request.
      #
      # (b) the replay protocol (pi :1340-1352 — assistantMsg[signature],
      #     the delta-carried field; live-verified for fireworks:
      #     reasoning_content): recorded assistant messages KEEP their
      #     thinking (memory, session file, resume — the I05 strip
      #     deviation is gone), and the request normalization drops
      #     ruby_llm's duplicate `reasoning` field so the wire carries
      #     `reasoning_content` ONLY — the shape pi sends, and the shape the
      #     strict endpoint accepts (the I05 400 class cannot recur through
      #     the port's own payload).
      # (c) the zai dialect (I46 — pi's zai arm of the else-if chain,
      #     openai-completions.ts :880-892): for a model whose compat says
      #     thinkingFormat "zai" the hook emits pi's exact wire instead of
      #     the generic effort arm — the thinking object, the map-then-
      #     level reasoning_effort, tool_stream, the instruction-role
      #     rewrite, and the max_tokens field rename ({apply_zai_dialect}).
      #     compat nil (or a non-zai thinkingFormat) runs arm (a)
      #     BYTE-EXACT — the zero-change bar (fireworks default and every
      #     compat-less catalog).
      def install_thinking_seam
        @chat.before_request do |payload|
          compat = @compat
          if compat && compat.thinking_format == "zai"
            apply_zai_dialect(payload, compat)
          else
            effort = Models.resolve_reasoning_effort(@thinking_level,
              map: @thinking_level_map, reasoning: @model_reasoning)
            if effort
              payload[:reasoning_effort] = effort
            else
              payload.delete(:reasoning_effort)
            end
          end
          payload[:messages]&.each do |message|
            message.delete(:reasoning) if message.is_a?(Hash) && message[:role] == "assistant"
          end
        end
      end

      # The zai arm (pi openai-completions.ts :880-892 + :749-755 +
      # :855-860 + :1233 + :841-848), muting the symbol-keyed payload in
      # place. Runs on the session chat AND (zai only) the compaction
      # summarization one-shot — pi's summarization carries the session
      # level through the same dialect branch (compaction.ts:605-607).
      def apply_zai_dialect(payload, compat)
        if @model_reasoning
          clamped = Models.clamp_thinking_level(@thinking_level, map: @thinking_level_map, reasoning: true)
          # pi :751 — the CLAMPED level is the input and a clamped "off" is
          # NO effort: the I36 String-off floor does not apply on this arm
          # (OQ-5 — the generic off-arm is unreachable for zai-format
          # models, the zai branch takes the chain first).
          effort_present = !clamped.nil? && clamped != "off"
          payload[:thinking] = effort_present ? {type: "enabled", clear_thinking: false} : {type: "disabled"}
          if effort_present && compat.supports_reasoning_effort == true
            # pi :889-891 — the map's String value for the clamped level;
            # a MISSING key sends the level itself (a null value cannot
            # reach here: supported levels never carry null).
            mapped = @thinking_level_map&.[](clamped.to_sym)
            payload[:reasoning_effort] = mapped.is_a?(String) ? mapped : clamped
          else
            # no effort (clamped off), or the compat says the endpoint
            # refuses the field (pi's detected-false default for zai).
            payload.delete(:reasoning_effort)
          end
        else
          # pi :880 gates the arm on model.reasoning — a non-reasoning
          # model sends no thinking object and no reasoning_effort (the
          # generic arms cannot fire for it either).
          payload.delete(:reasoning_effort)
        end
        # pi :855-860 — tool_stream iff zaiToolStream AND the request
        # carries tools; the tool-less fallback sends tools: [] without
        # the field (:861-863).
        if compat.zai_tool_stream == true && payload[:tools].is_a?(Array) && !payload[:tools].empty?
          payload[:tool_stream] = true
        end
        # pi :1233 — the wire role is developer iff the model reasons AND
        # the compat supports it; nil falls to the DETECTION stand-in (a
        # zai URL detects false, :1593-1675), so on this arm nil == false.
        # The gem renders the instruction as developer on this protocol
        # (format_role, chat.rb :376-383) — the rewrite puts the wire role
        # back to system. With compat nil: NO rewrite (the default arm
        # never touches roles).
        unless @model_reasoning && compat.supports_developer_role == true
          payload[:messages]&.each do |message|
            message[:role] = "system" if message.is_a?(Hash) && message[:role] == "developer"
          end
        end
        # pi :841-848 — maxTokensField "max_tokens" renames the gem's
        # max_completion_tokens (chat.rb :96-99 — the openai slug names it
        # so) for endpoints that only accept the deprecated field. Today
        # only the compaction summarization sets max output tokens, so the
        # rename lands there; "max_completion_tokens" and nil rename
        # nothing. NO store field is ever added (OQ-4); NO strict on tool
        # defs (OQ-1 — the five-key subset ends here).
        if compat.max_tokens_field == "max_tokens" && payload.key?(:max_completion_tokens)
          payload[:max_tokens] = payload.delete(:max_completion_tokens)
        end
      end

      def handle_item(item)
        case item[:type]
        when :chunk
          chunk = item[:chunk]
          unless @stream_started
            @stream_started = true
            emit(type: :message_start, message: chunk)
          end
          emit(type: :message_update, chunk:)
        when :step
          @stream_started = false
          message = item[:message]
          @last_message = message
          # A clean assistant response resets the overflow-recovery latch
          # (pi agent-session.ts:1168-1171).
          @overflow_recovery_attempted = false if message.role == :assistant
          # Tool results are recorded by the :tool_message item (ruby_llm's
          # after_message); the step's own return would double-count them.
          unless message.role == :tool
            @new_messages << message
            emit(type: :message_end, message:) if message.role == :assistant
            record(message)
          end
        when :tool_message
          @new_messages << item[:message]
          emit(type: :message_start, message: item[:message])
          emit(type: :message_end, message: item[:message])
          record(item[:message])
        when :tool_execution_start
          emit(type: :tool_execution_start, tool_call: item[:tool_call])
        when :tool_execution_end
          emit(type: :tool_execution_end, tool_call: item[:tool_call], result: item[:result],
               duration: item[:duration])
        end
      end

      # The event sink: hooks present → the seam (registration-order
      # handlers, then the surface sink the Hooks holds — the loop never
      # double-delivers through its own on_event); nil → today's direct
      # path, byte-identical.
      def emit(event)
        if @hooks
          @hooks.emit(event, context: hooks_context)
        else
          @on_event&.call(event)
        end
      end

      # The emission context (pi's ctx, {cwd:, mode:, session:, identity:}):
      # built by the boot wiring (a Proc re-read per event — /new swaps the
      # recorder), defaulting to the loop's own view (the tests/gates).
      def hooks_context
        return @hooks_context.call if @hooks_context.is_a?(Proc)

        session = @recorder ? {path: @recorder.path, id: @recorder.id} : nil
        {cwd: Dir.pwd, mode: nil, session:, identity: @identity}
      end
    end
  end
end
