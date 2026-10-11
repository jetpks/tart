# frozen_string_literal: true

require_relative "../test_helper"

module Tart
  # The autocomplete list + its SlashSource (I22 wave 2): the moved
  # fuzzy/source tests plus the list's state behavior (navigation wrap,
  # apply-token surgery) — driving Autocomplete over a real Editor
  # directly. The Chat-side list routing (list-wins keys, tab/typing
  # triggers) stays in test/chat_test.rb.
  class AutocompleteTest < Test
    def test_fuzzy_match_scores_like_pi
      assert_equal 0, Render::Autocomplete.fuzzy_match("", "new"), "an empty query matches everything"
      assert Render::Autocomplete.fuzzy_match("ar", "architect"), "a subsequence matches"
      assert_nil Render::Autocomplete.fuzzy_match("zx", "architect"), "no subsequence = no match"
      assert Render::Autocomplete.fuzzy_match("new", "new") <= -100, "an exact match scores best (pi's -100 bonus)"
      assert Render::Autocomplete.fuzzy_match("ab12", "12abc"), "the swapped alnum query retries (+5)"
    end

    def test_fuzzy_filter_ranks_word_boundary_matches_first
      items = %w[skills compact].map { |value| {value:} }
      ranked = Render::Autocomplete.fuzzy_filter(items, "c") { |item| item[:value] }
      assert_equal "compact", ranked.first[:value], "a word-boundary match outranks a mid-word one"
    end

    # Stable order (item 4/AC4, pi fuzzy.ts:138): JS sort is stable — ties
    # keep the pre-sort catalog order; Ruby's sort_by is not, so the
    # pre-sort index is the tie-break. The owner's case: every
    # architect-family entry ties identically on "ar" and must land in
    # catalog order (pi's provider order: commands, then skills).
    def test_fuzzy_filter_ties_keep_the_pre_sort_catalog_order
      items = %w[skill:architect-research skill:architect skill:architect-vocabulary new].map { |value| {value:} }
      ranked = Render::Autocomplete.fuzzy_filter(items, "ar") { |item| item[:value].delete_prefix("skill:") }
      assert_equal %w[skill:architect-research skill:architect skill:architect-vocabulary], ranked.map { |item| item[:value] },
        "identical scores keep the pre-sort order (pi's stable sort)"
    end

    def test_slash_source_lists_builtin_commands_and_skills
      skill = Skills::Skill.new(name: "greet", description: "Says hi", file_path: "/tmp/x",
        base_dir: "/tmp", disable_model_invocation: false)
      source = Render::SlashSource.new(commands: {"new" => {description: "Start a new session"}}, skills: [skill])
      assert_equal [
        {value: "new", label: "new", description: "Start a new session"},
        {value: "skill:greet", label: "skill:greet", description: "Says hi"}
      ], source.items
    end

    def test_list_navigation_wraps
      editor = Render::Editor.new
      list = Render::Autocomplete.new(source: slash_source("new", "help", "quit"))
      editor.insert_printable(TUI.key_event("/"))
      list.update(editor)
      assert_equal 0, list.selected
      list.navigate(1)
      assert_equal 1, list.selected, "down moves the selection"
      list.navigate(1)
      assert_equal 2, list.selected
      list.navigate(1)
      assert_equal 0, list.selected, "down wraps to the first item (pi select-list.ts:146-155)"
      list.navigate(-1)
      assert_equal 2, list.selected, "up wraps to the last item"
    end

    def test_apply_suggestion_replaces_the_token
      editor = Render::Editor.new
      list = Render::Autocomplete.new(source: slash_source("architect"))
      "/ar".each_char { |char| editor.insert_printable(TUI.key_event(char)) }
      list.update(editor)
      list.apply(editor)
      assert_equal "/architect ", editor.input, "pi applyCompletion: /<value> with a trailing space"
      assert_equal 11, editor.cursor, "the cursor lands after the applied value"
      assert_nil list.suggestions, "the list closes on apply"
    end

    private

    # A SlashSource over bare builtin names (description = "<name>
    # description") — the synthetic catalog.
    def slash_source(*names)
      Render::SlashSource.new(
        commands: names.each_with_object({}) { |name, table| table[name] = {description: "#{name} description"} },
        skills: []
      )
    end
  end
end
