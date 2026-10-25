# frozen_string_literal: true

require "delegate"
require_relative "../mcp"
require_relative "../schemas/tools"

module Tart
  module Tools
    # The tool registry: builds the built-in tool instances and gates the
    # loadout (BRIEF §4 schema gating).
    #
    # Schema gating: a tool not in the selected set is never instantiated and
    # never registered on the chat, so it never appears in the tool
    # declarations sent to the model (asserted in tests against the captured
    # wire payload). Tools execute unconditionally — pi ships no permissions
    # system (agent-loop.ts:832).
    module Registry
      TOOL_CLASSES = {
        "read" => "Tart::Tools::Read",
        "edit" => "Tart::Tools::Edit",
        "write" => "Tart::Tools::Write",
        "bash" => "Tart::Tools::Bash",
        "find" => "Tart::Tools::Find",
        "grep" => "Tart::Tools::Grep",
        "ls" => "Tart::Tools::Ls",
        "contact_supervisor" => "Tart::Tools::ContactSupervisor"
      }.freeze

      # I81 Law 2 — the nested-grant acceptance vocabulary: names the
      # registry ACCEPTS in a selected list but NEVER builds (no
      # TOOL_CLASSES entry, no constructor). Today exactly `subagent` —
      # the hooks registered-tools merge (below) supplies the instance,
      # LAST on the wire (the I47 merge order); a selected `subagent`
      # with no registered instance drops from the loadout silently (pi
      # loadout parity, agent-session.ts:1575-1582).
      SELECTABLE_SUBAGENT = %w[subagent].freeze

      # Classes whose write boundary accepts the §5 toggle (registry.rb doc).
      WRITE_BOUNDARY_CLASSES = %w[
        Tart::Tools::Edit
        Tart::Tools::Write
      ].freeze

      module_function

      # @param selected [Array<String>] enabled tool names (schema gating).
      #   The list's ORDER is the wire order (pi _applyToolLoadout iterates
      #   the active-name list in order, agent-session.ts:1571-1581).
      # @param cwd [String] working directory for all tools.
      # @param strip_trailing_whitespace [Boolean] §5 toggle (default off):
      #   edit/write strip trailing spaces/tabs from each committed line.
      # @param mcp_servers [Hash{String => Hash}, nil] MCP server name =>
      #   mcp.json-shaped stdio config ({Mcp::Config.load} shape); nil = no
      #   MCP tools and no connections. Configured servers' tools register
      #   behind the schema gate as mcp__<server>__<tool>, declared direct.
      # @param identity [String] the resolved face — threaded to the bash
      #   tool, whose session-env keys ride its namespace (the other
      #   built-ins ignore it).
      # @param session_env [Hash{String => Proc}] suffix → reader, resolved
      #   at spawn (bash tool only; see {Tools::Bash}).
      # @param hooks [Tart::Hooks, nil] the extension seam (I47): nil (the
      #   default) = EXACTLY the pre-seam build — unwrapped instances. With
      #   tool_call handlers registered, EVERY tool (built-in, MCP, and
      #   registered) wraps in a {ToolGate}; registered tools merge after
      #   built-ins + MCP (same name overrides — pi's registry merge,
      #   agent-session.ts _refreshToolRegistry).
      # @return [Hash{String => Fast::Completions::Tool}] instances for the selected
      #   tools only, keyed by wire name IN SELECTED ORDER.
      def build(selected:, cwd:, strip_trailing_whitespace: false, mcp_servers: nil,
                identity: Identity::DEFAULT, session_env: {}, hooks: nil)
        selected.each do |name|
          raise ArgumentError, "Unknown tool: #{name}" unless TOOL_CLASSES.key?(name) || SELECTABLE_SUBAGENT.include?(name)
        end

        # Selected-order keys (the I41 fix — Hash#slice kept TOOL_CLASSES'
        # receiver order, diverging from the resolved list pi declares).
        # I81 Law 2: a selectable-but-unbuilt name (subagent) never
        # instantiates here — it joins the loadout ONLY through the
        # registered-tools merge below.
        builtins = selected.filter_map do |name|
          next if SELECTABLE_SUBAGENT.include?(name)

          [name, build_tool(TOOL_CLASSES.fetch(name), cwd:,
                            strip_trailing_whitespace:, identity:, session_env:)]
        end.to_h
        loadout = mcp_servers ? builtins.merge(Mcp.tools_for(mcp_servers)) : builtins
        return loadout unless hooks

        hooks.registered_tools.each { |tool| loadout[tool.name.to_s] = tool }
        return loadout unless hooks.tool_call_handlers?

        # One wrap, never two: the merged loadout passes through the gate
        # uniformly (pi extension tools ride the wire like any other tool).
        loadout.transform_values { |tool| ToolGate.new(tool, hooks) }
      end

      # Per-class constructor kwargs: the write-boundary tools take the §5
      # toggle; the bash tool takes the session-env exposure seams (I41);
      # the supervisor tool takes the face for its env namespace (I49) —
      # the other built-ins take neither.
      def build_tool(class_name, cwd:, strip_trailing_whitespace:,
                     identity: Identity::DEFAULT, session_env: {})
        kwargs = {cwd:}
        kwargs[:strip_trailing_whitespace] = strip_trailing_whitespace if WRITE_BOUNDARY_CLASSES.include?(class_name)
        if class_name == "Tart::Tools::Bash"
          kwargs[:identity] = identity
          kwargs[:session_env] = session_env
        end
        if class_name == "Tart::Tools::ContactSupervisor"
          kwargs[:identity] = identity
        end
        Object.const_get(class_name).new(**kwargs)
      end

    end

    # The tool_call gate (pi prepareToolCall, agent-loop.ts:711-781). The
    # gem's before_tool_call callback RETURN IS IGNORED (chat.rb:1625-1635),
    # so the gate wraps the TOOL, never the callback; invoke_tool lands here
    # through tool.call(**arguments, tool_call:) (chat.rb:1682-1694). The
    # wrapper delegates EVERYTHING else (name/description/parameters_schema/
    # provider_options/resume/…) so the wire declarations stay byte-identical
    # — the tools digest (7360fd1e…) is the regression proof.
    class ToolGate < SimpleDelegator
      # pi's block-result default (agent-loop.ts: `reason || "Tool execution
      # was blocked"`).
      DEFAULT_BLOCK_REASON = "Tool execution was blocked"

      def initialize(inner, hooks)
        super(inner)
        @hooks = hooks
      end

      # with_tools reads tool.class.deferred? (chat.rb:476) — SimpleDelegator
      # forwards instance methods only, so the class reader bridges to the
      # wrapped tool's class (the delegation contract: everything but #call
      # reaches the inner tool, class methods included).
      def class
        __getobj__.class
      end

      # pi's order, in one seam:
      # 1. validate FIRST (Schemas::Tools — the I43 one-seam call): a
      #    failure returns the pinned {error:} result and handlers NEVER see
      #    the call. Tools without an I43 contract (registered customs) skip
      #    this arm — they self-validate (OQ-3's cousin).
      # 2. dispatch with `input:` a splat-fresh, string-keyed Hash — the
      #    recorded ToolCall#arguments object is NEVER handed to handlers
      #    and NEVER mutated (pi's structuredClone semantics, held by
      #    construction: `**args` collection always builds a new Hash).
      #    {block:, reason:, terminate:} results follow pi's
      #    ToolCallEventResult (extensions/types.ts:1426-1435).
      # 3. blocked → the reason (or the default) as a plain String result
      #    (OQ-7); terminate: true records the tool_call_id for the loop's
      #    batch consult. NO isolation: a handler StandardError blocks
      #    fail-safe with the error's message (agent-session.ts:685-687);
      #    Fast::Completions::CancelledError ALWAYS propagates (never blocked-on).
      # 4. unblocked → the inner tool's call with the possibly
      #    handler-mutated input (Tool#call re-symbolizes the keys).
      def call(tool_call: nil, **args)
        name = __getobj__.name
        if Schemas::Tools::CONTRACTS.key?(name)
          failure = Schemas::Tools.validate(name, args)
          return failure if failure
        end

        input = args.transform_keys(&:to_s)
        event = {"type" => "tool_call", "tool_name" => name, "tool_call_id" => tool_call&.id, "input" => input}
        begin
          result = @hooks.dispatch_tool_call(event)
        rescue Fast::Completions::CancelledError
          raise
        rescue StandardError => e
          return e.message
        end

        if result.is_a?(Hash) && result[:block]
          @hooks.record_terminate(tool_call.id) if result[:terminate] && tool_call
          reason = result[:reason]
          return reason ? reason.to_s : DEFAULT_BLOCK_REASON
        end

        __getobj__.call(**input, tool_call:)
      end
    end
  end
end
