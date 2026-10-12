# frozen_string_literal: true

require_relative "../test_helper"

module Tart
  # The selector menu family (I27 AC2): one component, both variants —
  # filter/nav/select/persist/cancel/click driven on the public
  # interface (keys via TUI.key_event, rows via lines). The Chat wiring
  # (dispatch, ctrl+l/ctrl+s routes, the switch seams) stays in
  # test/chat_test.rb.
  class ModelMenuTest < Test
    THINKING_ITEMS = Settings::THINKING_LEVELS.map do |level|
      {value: level, label: level, description: "d-#{level}", current: level == "high", default: level == "medium"}
    end

    MODEL_ENTRIES = [
      {provider: "glm", id: "glm-5.3", name: "GLM 5.3", reasoning: true, context_window: 200_000, max_tokens: nil},
      {provider: "zai", id: "glm-5-air", name: "Air", reasoning: false, context_window: nil, max_tokens: nil}
    ]

    def thinking_menu(items = THINKING_ITEMS)
      @thinking = {select: [], default: []}
      Render::ModelMenu.new(variant: :thinking, items:, query_seed: "",
        search_text: ->(item) { "#{item[:value]} #{item[:description]}" },
        on_select: ->(item) { @thinking[:select] << item },
        on_select_as_default: ->(item) { @thinking[:default] << item })
    end

    def model_menu(entries = MODEL_ENTRIES, seed: nil)
      @model = {select: [], default: []}
      Render::ModelMenu.model(entries:, current: {provider: "zai", id: "glm-5-air"},
        default: {provider: "glm", id: "glm-5.3"}, seed:,
        on_select: ->(item) { @model[:select] << item },
        on_select_as_default: ->(item) { @model[:default] << item })
    end

    def rows(menu, width = 80)
      menu.lines(width).map { |line| line.spans.map(&:content).join }
    end

    def filtered_values(menu)
      menu.instance_variable_get(:@filtered).map { |item| item[:value] }
    end

    # --- thinking menu surface ---

    def test_thinking_menu_renders_title_descriptions_and_help
      menu = thinking_menu
      text = rows(menu).join("\n")

      assert_includes text, "Thinking Level", "the title row"
      assert_includes text, "✓ high", "the current marker"
      assert_includes text, "d-high", "the description column"
      assert_includes text, Render::ModelMenu::HELP_LINE, "the dim help line"
      assert_equal 6, menu.list_offset, "the click map's list offset (4 heading rows + input + blank)"
    end

    def test_thinking_menu_opens_on_the_current_level
      menu = thinking_menu
      assert_equal "high", menu.selection&.fetch(:value), "pi's preselect (buildSelectList)"
    end

    def test_thinking_menu_default_badge_rides_the_description
      menu = Render::ModelMenu.thinking(current: "high", default: "medium",
        on_select: ->(_item) {}, on_select_as_default: ->(_item) {})

      assert_includes rows(menu).join("\n"), "Moderate reasoning (~8k tokens) · default"
      assert_includes rows(menu).join("\n"), "Deep reasoning (~16k tokens)", "the LEVEL_DESCRIPTIONS table"
      refute_includes rows(menu).join("\n"), "Deep reasoning (~16k tokens) · default"
    end

    # --- filter ---

    def test_printable_keys_filter_and_reset_the_selection
      menu = thinking_menu
      "hig".each_char { |char| menu.handle(TUI.key_event(char)) }

      assert_equal ["high", "xhigh"], filtered_values(menu),
        "the fuzzy filter narrows (both levels carry h-i-g as a subsequence; best score first)"
      assert_equal 0, menu.selected, "a query moves the selection to the top row"
    end

    def test_backspace_edits_the_query
      menu = thinking_menu
      "maxx".each_char { |char| menu.handle(TUI.key_event(char)) }
      menu.handle(TUI.key_event("backspace"))

      assert_equal ["max"], filtered_values(menu)
    end

    def test_a_cleared_query_restores_the_full_list
      menu = thinking_menu
      "zzz".each_char { |char| menu.handle(TUI.key_event(char)) }
      3.times { menu.handle(TUI.key_event("backspace")) }

      assert_equal Settings::THINKING_LEVELS, filtered_values(menu)
    end

    # --- navigation + select/cancel ---

    def test_navigation_wraps
      menu = thinking_menu # opens on the current level, "high" (index 4)
      2.times { menu.handle(TUI.key_event("down")) }
      assert_equal Settings::THINKING_LEVELS.size - 1, menu.selected, "down reaches the bottom"
      menu.handle(TUI.key_event("down"))
      assert_equal 0, menu.selected, "down wraps to the top (pi select-list wrap)"

      menu.handle(TUI.key_event("up"))
      assert_equal Settings::THINKING_LEVELS.size - 1, menu.selected, "up wraps back to the bottom"
    end

    def test_enter_selects_and_closes
      menu = thinking_menu # opens on "high" (index 4)
      menu.handle(TUI.key_event("down"))
      menu.handle(TUI.key_event("enter"))

      assert_equal ["xhigh"], @thinking[:select].map { |item| item[:value] }
      refute menu.handle(TUI.key_event("enter")), "the closed menu handles nothing"
      assert_empty @thinking[:default]
    end

    def test_escape_cancels_without_selecting
      menu = thinking_menu
      refute menu.handle(TUI.key_event("esc")), "escape closes the menu (pi onCancel)"
      refute menu.handle(TUI.key_event("enter")), "a cancelled menu never selects"
      assert_empty @thinking[:select]
    end

    def test_ctrl_c_cancels
      menu = thinking_menu
      refute menu.handle(TUI.key_event("c", modifiers: ["ctrl"])), "ctrl+c cancels (tui.select.cancel)"
    end

    # --- ctrl+s select-and-persist ---

    def test_ctrl_s_routes_through_the_default_callback
      menu = thinking_menu # opens on "high" (index 4)
      menu.handle(TUI.key_event("down"))
      menu.select_as_default

      assert_equal ["xhigh"], @thinking[:default].map { |item| item[:value] }
      assert_empty @thinking[:select], "ctrl+s never double-fires the plain select"
      refute menu.handle(TUI.key_event("enter")), "the menu closed through the default path"
    end

    # --- click-to-select (pi select-list.ts:109-134) ---

    def test_click_press_moves_the_selection_and_release_selects
      menu = thinking_menu
      assert menu.press(2)
      assert_equal 2, menu.selected, "the press moves the selection"

      assert menu.release(2)
      assert_equal ["low"], @thinking[:select].map { |item| item[:value] }, "the release on the pressed row selects"
    end

    def test_click_release_off_the_pressed_row_never_selects
      menu = thinking_menu
      menu.press(2)
      refute menu.release(0), "the release must land on the pressed row"
      assert_empty @thinking[:select]
      assert_equal 2, menu.selected, "the selection holds"
    end

    def test_click_off_the_list_window_is_ignored
      menu = thinking_menu
      refute menu.press(-1)
      refute menu.press(99), "beyond the visible window"
      refute menu.release(3), "a release with no press never selects"
      assert_empty @thinking[:select]
    end

    # --- model menu surface ---

    def test_model_menu_sorts_current_first_default_second_then_provider
      menu = model_menu
      assert_equal ["glm-5-air", "glm-5.3"], menu.instance_variable_get(:@filtered).map { |i| i[:id] },
        "current (zai/glm-5-air) first, default (glm/glm-5.3) second (pi sortModels)"
    end

    def test_model_menu_rows_carry_the_provider_and_default_badges
      menu = model_menu
      text = rows(menu).join("\n")

      assert_includes text, "glm-5-air [zai]", "the id + provider badge shape"
      assert_includes text, "· default", "the default badge"
      assert_includes text, "  Model Name: Air", "the selected entry's name line"
      assert_includes text, Render::ModelMenu::HELP_LINE
    end

    def test_model_menu_filters_over_id_provider_and_name
      menu = model_menu
      "glm".each_char { |char| menu.handle(TUI.key_event(char)) }
      menu.handle(TUI.key_event("5"))
      menu.handle(TUI.key_event("."))
      menu.handle(TUI.key_event("3"))

      assert_equal ["glm-5.3"], menu.instance_variable_get(:@filtered).map { |i| i[:id] },
        "the getModelSelectorSearchText shape (id+provider+name) filters"
      assert_equal 0, menu.selected
    end

    def test_model_menu_seed_prefills_the_search
      menu = model_menu(seed: "air")
      assert_equal ["glm-5-air"], menu.instance_variable_get(:@filtered).map { |i| i[:id] },
        "the /model <unknown-arg> pre-seed filters immediately"
    end

    def test_model_menu_scroll_indicator_at_the_window
      entries = 12.times.map do |i|
        {provider: "p", id: "m-#{format('%02d', i)}", name: "m", reasoning: false, context_window: nil, max_tokens: nil}
      end
      menu = model_menu(entries)

      assert_match(/\(1\/12\)/, rows(menu).join, "the (n/N) indicator renders past the 10-row window")
      assert_operator menu.widget_rows, :>, Render::ModelMenu::MAX_VISIBLE + 4
    end

    def test_model_menu_ctrl_s_fires_the_default_callback
      menu = model_menu
      menu.select_as_default

      assert_equal ["glm-5-air"], @model[:default].map { |item| item[:id] },
        "ctrl+s persists the selection (the Chat writes Settings)"
      refute menu.handle(TUI.key_event("enter")), "the menu closed"
    end

    def test_model_menu_no_matching_models_row
      menu = model_menu([])
      assert_includes rows(menu).join("\n"), "No matching models"
    end
  end
end
