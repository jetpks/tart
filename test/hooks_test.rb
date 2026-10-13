# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/mock_llm_server"
require "tmpdir"
require "fileutils"
require "json"

module Tart
  # The seam (I47 — AC1): registration-order dispatch with a pre-dispatch
  # snapshot, per-handler isolation on plain channels (warn + continue), the
  # tool_call gate's block/fail-safe/terminate/mutation semantics, the
  # registry merge, and the nextTurn queue. The gate `hooks-semantics`
  # drives the same surface through the registry; these pins hold the
  # Hooks-level contract (pi runner.ts:1089-1120 / :1242-1262).
  class HooksTest < Test
    def setup
      @hooks = Hooks.new
      @stderr, $stderr = $stderr, StringIO.new
    end

    def teardown
      $stderr = @stderr
    end

    # --- plain channels ---

    def test_dispatch_runs_in_registration_order_and_isolates_handler_errors
      order = []
      @hooks.on(:custom) { order << 1 }
      @hooks.on("custom") { raise "boom" }
      @hooks.on(:custom) { order << 3 }

      @hooks.emit({"type" => "custom"}, context: {})

      assert_equal [1, 3], order, "the failed handler is skipped, dispatch continues"
      assert_includes $stderr.string, "hooks[custom] handler failed: boom", "ONE stderr warn (OQ-4)"
    end

    def test_symbol_and_string_channels_meet_on_one_table
      seen = []
      @hooks.on(:herdr_blocked) { seen << :sym }
      @hooks.emit({type: :herdr_blocked}, context: {})
      @hooks.emit({"type" => "herdr_blocked"}, context: {})
      assert_equal [:sym, :sym], seen
    end

    def test_unsubscribe_proc_removes_exactly_its_handler
      order = []
      gone = @hooks.on("custom") { order << 1 }
      @hooks.on("custom") { order << 2 }
      gone.call

      @hooks.emit({"type" => "custom"}, context: {})

      assert_equal [2], order
    end

    def test_mid_dispatch_registrations_take_effect_on_the_next_emit
      seen = []
      late = nil
      @hooks.on("custom") do
        seen << 1
        late ||= @hooks.on("custom") { seen << 2 }
      end

      @hooks.emit({"type" => "custom"}, context: {})
      @hooks.emit({"type" => "custom"}, context: {})

      assert_equal [1, 1, 2], seen, "the handler list is snapshotted before dispatch"
    end

    def test_emit_forwards_the_event_to_the_base_sink_after_handlers
      sink_events = []
      hooks = Hooks.new(on_event: ->(event) { sink_events << event })
      hooks.on("custom") { |_event, _ctx| nil }

      event = {"type" => "custom", "payload" => "x"}
      hooks.emit(event, context: {})

      assert_equal [event], sink_events, "the same event object forwards after handler dispatch"
      assert_equal "x", sink_events.first["payload"], "the seam never alters the event"
    end

    # --- the tool_call gate (through the Registry, like the loop) ---

    def test_tool_gate_block_wins_first_with_the_reason_as_a_plain_string
      dir = Dir.mktmpdir("tart-hooks-")
      hooks = Hooks.new
      calls = []
      hooks.on_tool_call do |event, _ctx|
        calls << event
        {block: true, reason: "denied by policy"}
      end
      hooks.on_tool_call { flunk "the first block wins — later handlers are skipped" }

      tools = Tools::Registry.build(selected: %w[write], cwd: dir, hooks: hooks)
      result = tools["write"].call(path: "new.txt", content: "x")

      assert_equal "denied by policy", result
      assert_equal ["write"], calls.map { |event| event["tool_name"] }
      refute File.exist?(File.join(dir, "new.txt")), "the blocked write never executes"
    ensure
      FileUtils.rm_rf(dir)
    end

    def test_tool_gate_default_reason
      dir = Dir.mktmpdir("tart-hooks-")
      hooks = Hooks.new
      hooks.on_tool_call { |_event, _ctx| {block: true} }

      tools = Tools::Registry.build(selected: %w[read], cwd: dir, hooks: hooks)

      assert_equal "Tool execution was blocked", tools["read"].call(path: "x")
    ensure
      FileUtils.rm_rf(dir)
    end

    def test_tool_gate_handler_error_blocks_fail_safe_with_the_message
      dir = Dir.mktmpdir("tart-hooks-")
      hooks = Hooks.new
      hooks.on_tool_call { |_event, _ctx| raise StandardError, "gate broke" }

      tools = Tools::Registry.build(selected: %w[read], cwd: dir, hooks: hooks)

      assert_equal "gate broke", tools["read"].call(path: "x")
    ensure
      FileUtils.rm_rf(dir)
    end

    def test_tool_gate_cancelled_error_always_propagates
      dir = Dir.mktmpdir("tart-hooks-")
      hooks = Hooks.new
      hooks.on_tool_call { |_event, _ctx| raise RubyLLM::CancelledError }

      tools = Tools::Registry.build(selected: %w[read], cwd: dir, hooks: hooks)

      assert_raises(RubyLLM::CancelledError) { tools["read"].call(path: "x") }
    ensure
      FileUtils.rm_rf(dir)
    end

    def test_tool_gate_recorded_arguments_never_mutate_and_mutations_flow
      dir = Dir.mktmpdir("tart-hooks-")
      File.write(File.join(dir, "a.txt"), "A")
      File.write(File.join(dir, "b.txt"), "B")
      hooks = Hooks.new
      hooks.on_tool_call { |event, _ctx| event["input"]["path"] = "b.txt"; nil }

      tools = Tools::Registry.build(selected: %w[read], cwd: dir, hooks: hooks)
      tool_call = RubyLLM::ToolCall.new(id: "c1", name: "read", arguments: {"path" => "a.txt"})
      result = tools["read"].call(path: "a.txt", tool_call: tool_call)

      assert_includes result.to_s, "B", "the handler-mutated input executes"
      assert_equal({"path" => "a.txt"}, tool_call.arguments,
        "the recorded ToolCall's arguments hash is never handed out (structuredClone semantics)")
    ensure
      FileUtils.rm_rf(dir)
    end

    def test_tool_gate_validates_before_dispatch
      dir = Dir.mktmpdir("tart-hooks-")
      hooks = Hooks.new
      seen = 0
      hooks.on_tool_call { |_event, _ctx| seen += 1 }

      tools = Tools::Registry.build(selected: %w[read], cwd: dir, hooks: hooks)
      result = tools["read"].call(path: 123)

      assert result.is_a?(Hash) && result[:error], "invalid args return the pinned {error:} result"
      assert_equal 0, seen, "invalid args never reach handlers (pi validateToolArguments order)"
    ensure
      FileUtils.rm_rf(dir)
    end

    def test_tool_gate_wrapper_preserves_the_declaration_bytes
      dir = Dir.mktmpdir("tart-hooks-")
      plain = Tools::Registry.build(selected: %w[read], cwd: dir)
      hooks = Hooks.new
      hooks.on_tool_call { |_event, _ctx| nil }
      wrapped = Tools::Registry.build(selected: %w[read], cwd: dir, hooks: hooks)["read"]

      assert_equal plain["read"].name, wrapped.name
      assert_equal plain["read"].description, wrapped.description
      assert_equal JSON.generate(plain["read"].parameters_schema), JSON.generate(wrapped.parameters_schema)
    ensure
      FileUtils.rm_rf(dir)
    end

    def test_registry_build_without_tool_call_handlers_stays_unwrapped
      dir = Dir.mktmpdir("tart-hooks-")
      tools = Tools::Registry.build(selected: %w[read], cwd: dir, hooks: Hooks.new)

      assert_instance_of Tools::Read, tools["read"], "no handlers: no gate object exists"
    ensure
      FileUtils.rm_rf(dir)
    end

    def test_batch_terminate_requires_every_id_and_a_non_empty_batch
      hooks = Hooks.new
      hooks.on_tool_call { |_event, _ctx| {block: true, reason: "t", terminate: true} }
      dir = Dir.mktmpdir("tart-hooks-")
      tools = Tools::Registry.build(selected: %w[read], cwd: dir, hooks: hooks)
      tools["read"].call(path: "x", tool_call: RubyLLM::ToolCall.new(id: "x1", name: "read", arguments: {}))
      tools["read"].call(path: "x", tool_call: RubyLLM::ToolCall.new(id: "x2", name: "read", arguments: {}))

      assert hooks.batch_terminate?(%w[x1 x2])
      refute hooks.batch_terminate?(%w[x1 y9]), "an unmarked id fails the batch"
      refute hooks.batch_terminate?([]), "an empty batch is never a terminate"

      hooks.clear_terminate_ledger
      refute hooks.batch_terminate?(%w[x1 x2]), "the ledger clears per batch"
    ensure
      FileUtils.rm_rf(dir)
    end

    # --- register_tool / register_command ---

    def test_register_tool_appends_and_registry_overrides_by_name
      dir = Dir.mktmpdir("tart-hooks-")
      tool = Tools::Read.new(cwd: dir)
      hooks = Hooks.new
      hooks.register_tool(tool)

      assert_equal [tool], hooks.registered_tools

      tools = Tools::Registry.build(selected: %w[read], cwd: dir, hooks: hooks)
      assert_equal [tool], tools.values, "same-name registered tool overrides the builtin (OQ-8)"
    ensure
      FileUtils.rm_rf(dir)
    end

    def test_registered_commands_surface_and_dispatch_without_shadowing_builtins
      handled = []
      hooks = Hooks.new
      hooks.register_command("mem", description: "memory ops") { |args| handled << [:mem, args] }
      hooks.register_command("grepish", description: "takes args", args: true) { |args| handled << [:grepish, args] }

      assert_equal [
        {name: "mem", description: "memory ops", args: false},
        {name: "grepish", description: "takes args", args: true}
      ], hooks.registered_commands

      handler = Commands::Handler.new(
        skills: [], settings: {}, output: ->(_text) {}, spawn: ->(&block) { block.call },
        agent: -> { nil }, reset: -> {}, quit: -> {}, hooks:
      )
      assert handler.dispatch("/mem")
      assert_equal [[:mem, ""]], handled
      assert handler.dispatch("/grepish one two")
      assert_equal [[:mem, ""], [:grepish, "one two"]], handled
      # Builtins dispatch first — a registered name can never shadow one.
      assert handler.dispatch("/new")
      assert_equal [[:mem, ""], [:grepish, "one two"]], handled
      refute handler.dispatch("/nope"), "an unknown slash goes to the agent"
    end

    def test_help_lists_registered_commands_after_the_builtins
      hooks = Hooks.new
      hooks.register_command("mem", description: "memory ops")
      lines = []
      handler = Commands::Handler.new(
        skills: [], settings: {}, output: ->(text) { lines << text }, spawn: ->(&block) { block.call },
        agent: -> { nil }, reset: -> {}, quit: -> {}, hooks:
      )
      handler.dispatch("/help")

      text = lines.join
      assert_includes text, "  /quit  Quit tart"
      assert_includes text, "  /mem  memory ops", "registered commands list after the builtins"
      assert lines.join.index("/quit") < lines.join.index("/mem")
    end

    # --- nextTurn queue ---

    def test_send_next_turn_queues_and_pending_next_turn_drains_fifo
      @hooks.send_next_turn(custom_type: "memory-recall", content: "one", display: true)
      @hooks.send_next_turn(custom_type: "other", content: "two")

      assert_equal [
        {custom_type: "memory-recall", content: "one", display: true},
        {custom_type: "other", content: "two", display: false}
      ], @hooks.pending_next_turn, "FIFO with the display default false"
      assert_empty @hooks.pending_next_turn, "the drain source clears the queue"
    end
  end
end
