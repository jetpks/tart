# frozen_string_literal: true

module Tart
  # The minimal internal extension seam (BRIEF §6 amended 2026-10-13; I47).
  # One instance per boot, threaded into every Agent::Loop construction and
  # the tool/command build; the owner-facing modules (Memory, Herdr) register
  # onto it natively.
  #
  # pi seam semantics, preserved (I47 Grounds §3):
  # - plain channels (emit, runner.ts:1089-1120): registration order, the
  #   handler list SNAPSHOTTED before dispatch (mid-dispatch registrations
  #   take effect on the next emit), per-handler error reported once to
  #   stderr and swallowed — dispatch continues; after handlers the event
  #   forwards UNCHANGED to the base sink (the surface's on_agent_event).
  # - the tool_call channel (emitToolCall, runner.ts:1242-1262): the same
  #   order + snapshot, but NO isolation — the first truthy `block` result
  #   wins and ends dispatch, and a raised error PROPAGATES to the tool gate
  #   (Registry's wrapper), which converts it to the fail-safe block
  #   (agent-session.ts:685-687). RubyLLM::CancelledError always escapes.
  # - nextTurn injection (sendCustomMessage :2293-2331): queue only — no
  #   append, no events at send time; the loop drains after the user
  #   message (:2086-2095).
  class Hooks
    # The injected custom message the loop emits through
    # :message_start/:message_end (pi's role-"custom" AgentMessage; the
    # render's custom-message arm keys off role :custom).
    CustomMessage = Struct.new(:role, :custom_type, :content, :display, keyword_init: true)

    # @param on_event [Proc, nil] the base sink every emitted event forwards
    #   to AFTER handler dispatch (the surface's on_agent_event). Hooks
    #   holds the surface sink; a loop constructed with +hooks:+ must not
    #   also deliver through its own on_event (double delivery).
    def initialize(on_event: nil)
      @on_event = on_event
      @mutex = Mutex.new
      @handlers = {}
      @tool_call_handlers = []
      @next_turn = []
      @registered_tools = []
      @registered_commands = []
      @command_handlers = {}
      @terminate_ledger = {}
      @last_context = nil
    end

    # Subscribes +handler+ to +channel+ (String or Symbol, normalized to
    # the String form; dispatch keys off the event's :type/"type" value
    # normalized the same way — the loop's symbol-keyed events and String
    # channels like "herdr:blocked" meet on one table). Returns the
    # unsubscribe Proc.
    def on(channel, &handler)
      key = channel_key(channel)
      @mutex.synchronize { (@handlers[key] ||= []) << handler }
      lambda do
        @mutex.synchronize do
          list = @handlers[key]
          list&.delete(handler)
        end
      end
    end

    # The tool_call channel with BLOCK semantics (see the class comment);
    # driven by the Registry gate, not by #emit.
    def on_tool_call(&handler)
      @mutex.synchronize { @tool_call_handlers << handler }
      lambda do
        @mutex.synchronize { @tool_call_handlers.delete(handler) }
      end
    end

    # Dispatches to the channel's handlers in registration order
    # (pre-dispatch snapshot), then forwards the event UNCHANGED to the
    # base sink. A handler StandardError warns once to stderr and is
    # swallowed (pi emit's emitError discipline — OQ-4; the mcp.rb idiom).
    def emit(event, context:)
      channel = channel_key(event[:type] || event["type"])
      handlers = @mutex.synchronize do
        @last_context = context
        (@handlers[channel] || []).dup
      end
      handlers.each do |handler|
        begin
          handler.call(event, context)
        rescue StandardError => e
          warn "hooks[#{channel}] handler failed: #{e.message}"
        end
      end
      @on_event&.call(event)
    end

    # The tool_call dispatch (pi emitToolCall, runner.ts:1242-1262):
    # registration order, snapshot, the FIRST truthy `block` result wins
    # and ends dispatch, NO isolation — a raised error propagates to the
    # gate. The context is the most recent one #emit carried (the loop's
    # per-event emission precedes any tool execution in a run).
    def dispatch_tool_call(event)
      handlers = @mutex.synchronize { @tool_call_handlers.dup }
      context = @mutex.synchronize { @last_context }
      handlers.each do |handler|
        result = handler.call(event, context)
        return result if result.is_a?(Hash) && result[:block]
      end
      nil
    end

    # Whether any tool_call handler is registered (the Registry's wrap
    # predicate; false = unwrapped build, zero behavior change).
    def tool_call_handlers?
      @mutex.synchronize { !@tool_call_handlers.empty? }
    end

    # Queues a nextTurn message (pi sendCustomMessage :2293-2331 — queue
    # only, no append, no events). The loop drains after the next user
    # message.
    def send_next_turn(custom_type:, content:, display: false)
      @mutex.synchronize { @next_turn << {custom_type:, content:, display:} }
      nil
    end

    # The drain source (loop-internal): returns the pending queue FIFO and
    # clears it atomically.
    def pending_next_turn
      @mutex.synchronize { drain = @next_turn; @next_turn = []; drain }
    end

    # Registers a RubyLLM::Tool instance; Registry.build merges these
    # AFTER built-ins + MCP (same name overrides — pi's registry merge).
    def register_tool(tool)
      @mutex.synchronize { @registered_tools << tool }
      self
    end

    def registered_tools
      @mutex.synchronize { @registered_tools.dup }
    end

    # Registers a slash command (pi registerCommand): exact match when
    # +args:+ is false, "/name " prefix when true; builtins always win
    # (Commands.builtin_name dispatches first). The +handler+ receives the
    # command's argument string ("" on an exact match).
    def register_command(name, description:, args: false, &handler)
      key = name.to_s
      @mutex.synchronize do
        @registered_commands << {name: key, description:, args:}
        @command_handlers[key] = handler
      end
      self
    end

    # {name:, description:, args:} hashes in registration order.
    def registered_commands
      @mutex.synchronize { @registered_commands.dup }
    end

    # The dispatch table's handler for one registered command (the
    # Commands::Handler consult).
    def command_handler(name)
      @mutex.synchronize { @command_handlers[name.to_s] }
    end

    # pi shouldTerminateToolBatch (agent-loop.ts:690-691): TRUE iff the
    # batch is non-empty AND every id was a terminate-marked block. The
    # ledger is filled by the Registry gate and cleared per batch by the
    # loop ({clear_terminate_ledger}).
    def batch_terminate?(ids)
      ledger = @mutex.synchronize { @terminate_ledger.dup }
      ids.is_a?(Array) && !ids.empty? && ids.all? { |id| ledger.key?(id) }
    end

    # Records one terminate-marked block (Registry gate-internal; the id
    # is the ToolCall's).
    def record_terminate(tool_call_id)
      @mutex.synchronize { @terminate_ledger[tool_call_id] = true }
      nil
    end

    # The loop clears the ledger after every batch consult (stale ids
    # never leak into the next batch).
    def clear_terminate_ledger
      @mutex.synchronize { @terminate_ledger = {} }
      nil
    end

    private

    def channel_key(channel)
      channel.to_s
    end
  end
end
