# frozen_string_literal: true

require_relative "test_helper"

module Tart
  # The per-call details side channel (I57 P3 — pi's EditToolDetails
  # riding the toolResult, edit.ts:210 / session-manager.ts:153): the
  # edit tool fills the call's details at execution, the recorded entry
  # carries them camelCase (and nothing else moves), the context
  # projection drops them (never on the wire), the wire String is
  # byte-unchanged, and seeds ignore the key (declared-fields read).
  class EditDetailsTest < Test
    def setup
      @dir = Dir.mktmpdir("tart-edit-details-")
      File.write(File.join(@dir, "f.txt"), "alpha line one\nline two bravo\nline three\n")
    end

    def teardown
      FileUtils.remove_entry(@dir)
    end

    def tool_call
      Agent::ToolCall.new(id: "call_x1", name: "edit",
                                   arguments: { path: "f.txt", edits: [{ oldText: "line two bravo",
                                                                        newText: "line two charlie" }] })
    end

    # The edit tool sets the call's details (camelCase, pi's
    # EditToolDetails names) from the values it already computes.
    def test_the_call_carries_details_after_a_successful_edit
      call = tool_call
      edit = Tools::Edit.new(cwd: @dir)
      result = edit.call(**call.arguments, tool_call: call)

      details = call.details
      assert details.is_a?(Hash), "the call carries a details hash"
      assert_equal %i[diff patch firstChangedLine], details.keys, "pi's EditToolDetails names, in order"
      assert_includes details[:diff], "-2 line two bravo"
      assert_includes details[:diff], "+2 line two charlie"
      assert_equal 2, details[:firstChangedLine]
      assert details[:patch].is_a?(String) && !details[:patch].empty?, "the unified patch rides too"
      assert_equal "Successfully replaced 1 block(s) in f.txt.", result
    end

    # An error result carries NO details (and a stale prior success does
    # not leak through the shared tool instance).
    def test_an_error_result_carries_no_details
      call = tool_call
      edit = Tools::Edit.new(cwd: @dir)
      edit.call(**call.arguments, tool_call: call)
      assert call.details, "precondition: the success set details"

      miss = Agent::ToolCall.new(id: "call_x2", name: "edit",
                                          arguments: { path: "f.txt",
                                                       edits: [{ oldText: "NO SUCH LINE",
                                                                 newText: "x" }] })
      edit.call(**miss.arguments, tool_call: miss)
      assert_nil miss.details, "the error call stays detail-less"
    end

    # The recorded entry carries the camelCase details — and NO other
    # recorded byte moves (the frozen three-key shape otherwise).
    def test_the_recorded_entry_carries_details_camelcase
      message = Agent::Message.tool(tool_call_id: "call_x1", content: "ok",
                                    details: { diff: "-1 a\n+1 b", patch: "", firstChangedLine: 1 })
      hash = message.to_h

      assert_equal %i[role content tool_call_id details], hash.keys, "details appends LAST, only when present"
      assert_equal %i[diff patch firstChangedLine], hash[:details].keys, "camelCase value keys"
      assert_equal "-1 a\n+1 b", hash[:details][:diff]
    end

    # Non-edit tools record no key: a tool message without details
    # serializes to the frozen three-key shape (the session-golden
    # digests hold EXACT).
    def test_non_edit_tools_record_no_key
      message = Agent::Message.tool(tool_call_id: "call_1", content: "fixture.txt")
      assert_equal({ role: "tool", content: "fixture.txt", tool_call_id: "call_1" }, message.to_h)
      assert_nil message.details

      # Structs without the member (the recorded ToolCall-shape doubles)
      # read inertly at the render seam.
      double = Struct.new(:name, :arguments).new("grep", {})
      refute double.respond_to?(:details), "the doubles predate the member"
    end

    # The context projection DROPS details for tool messages (pi
    # session-manager.ts:153 "not sent to LLM") — and leaves every other
    # recorded key in its recorded order.
    def test_the_context_projection_drops_details
      entry = {
        "type" => "message",
        "message" => { "role" => "tool", "content" => "ok", "tool_call_id" => "call_x1",
                       "details" => { "diff" => "-1 a\n+1 b", "patch" => "", "firstChangedLine" => 1 } },
      }
      context = Agent::Session.entry_to_context_message(entry)

      assert_equal %i[role content tool_call_id], context.to_h.keys, "details gone, key order intact"
      assert_equal "ok", context.to_h[:content]

      # A tool message without details is untouched (the byte-frozen path).
      plain = Agent::Session.entry_to_context_message(
        "type" => "message", "message" => { "role" => "tool", "content" => "fixture.txt",
                                            "tool_call_id" => "call_1" }
      )
      assert_equal({ role: :tool, content: "fixture.txt", tool_call_id: "call_1" }, plain.to_h)
    end

    # The returned wire String is byte-unchanged — the same success text
    # pi's edit tool returns, with or without the side channel.
    def test_the_returned_wire_string_is_unchanged
      call = tool_call
      edit = Tools::Edit.new(cwd: @dir)
      result = edit.call(**call.arguments, tool_call: call)

      assert_equal "Successfully replaced 1 block(s) in f.txt.", result
      assert_instance_of String, result, "the wire content stays a bare String"
    end

    # Seeds read declared fields only: a `details` key on the recorded
    # entry is INERT for the seeded message (defense in depth's other
    # half — the wire conversion reads content only).
    def test_from_seed_hash_ignores_details
      message = Agent::Message.from_seed_hash(
        "role" => "tool", "content" => "ok", "tool_call_id" => "call_x1",
        "details" => { "diff" => "-1 a" }
      )

      assert_equal "ok", message.content
      assert_equal "call_x1", message.tool_call_id
      assert_nil message.details, "the seed never resurrects the key"
    end
  end
end
