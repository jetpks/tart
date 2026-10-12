# frozen_string_literal: true

require_relative "text"

module Tart
  module Render
    # The selector menu family (I27) — ONE component serving both the
    # /thinking level menu and the /model menu (pi ships two classes,
    # thinking-selector.ts + model-selector.ts, over the same tui
    # SelectList shape; the port unifies on the shared shape,
    # variant-parameterized — the itemized choice). Ported surface:
    # bordered block (the picker's in-place-of-editor mount), fuzzy
    # search Input over word+description (thinking) / pi's
    # getModelSelectorSearchText id+provider+name text (model,
    # model-search.ts:15-19), up/down with wrap, enter selects,
    # escape/ctrl+c cancels, ctrl+s selects-and-persists (the callback
    # seam — the Settings write + status stay on the Chat coordinator),
    # click-to-select (select-list.ts:109-134 press/release index
    # tracking), the (n/N) scroll indicator at the 10-row window, the ✓
    # current marker and · default badge, the model menu's
    # current-first / default-second / by-provider sort and
    # "  Model Name: <name>" line, the thinking menu's title +
    # shift+tab hint + LEVEL_DESCRIPTIONS description column, and the
    # dim help line. Unsynchronized by design (I22 shape rule a): the
    # Chat surface owns the mutex.
    class ModelMenu
      # The visible list window (pi model-selector.ts maxVisible 10; the
      # thinking SelectList is sized to its 7 items — the same window
      # while everything fits).
      MAX_VISIBLE = 10

      # pi thinking-selector.ts LEVEL_DESCRIPTIONS :18-27.
      LEVEL_DESCRIPTIONS = {
        "off" => "No reasoning",
        "minimal" => "Very brief reasoning (~1k tokens)",
        "low" => "Light reasoning (~2k tokens)",
        "medium" => "Moderate reasoning (~8k tokens)",
        "high" => "Deep reasoning (~16k tokens)",
        "xhigh" => "Extra-high reasoning (~32k tokens)",
        "max" => "Maximum reasoning"
      }.freeze

      # pi's hint text with the default keys resolved (keyDisplayText of
      # tui.select.confirm / app.models.save+app.thinking.save /
      # tui.select.cancel — all static defaults in the port, as in the
      # picker's rows).
      HELP_LINE = "Enter to select · Ctrl+S to set as default · Escape/Ctrl+C to cancel"

      # pi showThinkingSelector (:5168-5183): the session level (the
      # settings default when unset) is the ✓ row; the settings default
      # carries the · default badge; the description column is the
      # LEVEL_DESCRIPTIONS table.
      def self.thinking(current:, default:, on_select:, on_select_as_default:)
        items = Settings::THINKING_LEVELS.map do |level|
          description = default == level ? "#{LEVEL_DESCRIPTIONS.fetch(level)} · default" : LEVEL_DESCRIPTIONS.fetch(level)
          {value: level, label: level, description:, current: current == level, default: false}
        end
        new(variant: :thinking, items:, query_seed: nil,
          search_text: ->(item) { "#{item[:value]} #{item[:description]}" },
          on_select:, on_select_as_default:)
      end

      # pi showModelSelector (:5342-5361) + ModelSelectorComponent: the
      # entries are the models.json catalog flattened; +current+ and
      # +default+ are {provider:, id:} refs for the ✓ marker and the
      # · default badge; +seed+ pre-fills the search (/model
      # <unknown-arg>, pi's initialSearchInput). Sort (pi sortModels):
      # current first, default second, then by provider. Reductions,
      # itemized: no catalog network refresh, no scoped/all tab toggle,
      # no isDefaultSearch query boost, no /login hint line.
      def self.model(entries:, current:, default:, seed: nil, on_select:, on_select_as_default:)
        current_key = ref_key(current)
        default_key = ref_key(default)
        items = entries.sort_by do |entry|
          key = ref_key(entry)
          rank = key == current_key ? 0 : (default_key && key == default_key ? 1 : 2)
          [rank, entry[:provider], entry[:id]]
        end.map do |entry|
          entry.merge(value: entry[:id], label: entry[:id],
            current: current_key == ref_key(entry), default: default_key == ref_key(entry))
        end
        new(variant: :model, items:, query_seed: seed,
          search_text: ->(item) { "#{item[:provider]} #{item[:provider]}/#{item[:id]} #{item[:provider]} #{item[:id]} #{item[:name]}" },
          on_select:, on_select_as_default:)
      end

      def self.ref_key(ref)
        ref ? "#{ref[:provider]}/#{ref[:id]}".downcase : nil
      end

      # The visible window's selection index and the query — the Chat
      # readbacks' targets.
      attr_reader :selected

      def initialize(variant:, items:, query_seed:, search_text:, on_select:, on_select_as_default:)
        @variant = variant
        @items = items
        @search_text = search_text
        @on_select = on_select
        @on_select_as_default = on_select_as_default
        @query = +query_seed.to_s
        @filtered = filter(@query)
        # pi buildSelectList's preselect (thinking-selector.ts:103-107):
        # the selection opens on the current item (the model menu's
        # current-first sort puts it at the top; here the flag pins it).
        @selected = [@filtered.index { |item| item[:current] } || 0, [@filtered.size - 1, 0].max].min
        @mouse_pressed = nil
        @closed = false
      end

      # The menu owns every key while open (pi: the selector takes focus
      # — showSelector { focus: selector }). Returns true while open;
      # enter fires on_select, escape/ctrl+c cancel (false from then on
      # — the Chat coordinator drops its holder); everything else edits
      # the search input (pi handleInput's fall-through).
      def handle(event)
        return false if @closed

        case event.code
        when "up" then navigate(-1)
        when "down" then navigate(+1)
        when "enter" then select_current
        when "esc" then close
        when "backspace" then edit_query { @query = @query[0..-2].to_s }
        when "c"
          # tui.select.cancel covers ctrl+c too (select-list.ts:171).
          event.modifiers.include?("ctrl") ? close : edit_query { @query << event.code }
        else
          edit_query { @query << event.code } if event.text?
        end
        !@closed
      end

      # The filtered item at the selection (nil = none).
      def selection
        @filtered[@selected]
      end

      # ctrl+s (pi app.models.save / app.thinking.save): select-and-
      # persist — fires on_select_as_default and closes (pi
      # selectLevel(level, true) → done()).
      def select_as_default
        item = selection
        return unless item

        close
        @on_select_as_default&.call(item)
      end

      # The content rows: heading, search input, the visible list window
      # (+ the (n/N) info line when it scrolls), the model menu's
      # "  Model Name:" line, then the dim help line.
      def lines(width)
        rows = heading_rows + [input_row, blank]
        rows.concat(list_rows(width))
        rows << model_name_row if @variant == :model && !@filtered.empty?
        rows << blank << help_row
        rows
      end

      # The widget — the editor area is REPLACED by the menu while open
      # (pi showSelector swaps the container and moves focus).
      def widget(width)
        TUI.block(
          borders: [:top, :bottom],
          border_style: TUI.style(fg: Theme[:border]),
          title_style: TUI.style(fg: Theme[:dim]),
          children: [TUI.paragraph(text: lines(width), wrap: false)]
        )
      end

      # The menu's row budget (the editor-area height calc; +2 borders).
      def widget_rows
        lines(80).size
      end

      # The list window's offset within {lines} — the Chat's click
      # mapping (a terminal row above the list is not an item).
      def list_offset
        heading_rows.size + 2
      end

      # --- mouse: click-to-select (pi SelectList.handleMouse :109-134).
      # +row+ is a list-window row (0-based from the list's first
      # visible line — the Chat maps the terminal cell). Press moves the
      # selection and records the pressed row; the release on the same
      # row selects. Hover never changes the selection (the window is
      # centered on it).

      def press(row)
        index = row_index(row)
        return false unless index

        @mouse_pressed = index
        @selected = index unless @selected == index
        true
      end

      def release(row)
        index = row_index(row)
        pressed = @mouse_pressed
        @mouse_pressed = nil
        return false unless index && index == pressed

        select_current
        true
      end

      private

      def close
        @closed = true
      end

      def select_current
        item = selection
        return unless item

        close
        @on_select&.call(item)
      end

      def navigate(direction)
        size = @filtered.size
        return if size.zero?

        @selected = direction == -1 ? (@selected.zero? ? size - 1 : @selected - 1) : (@selected == size - 1 ? 0 : @selected + 1)
      end

      # Re-filter on every edit (pi filterModels / applyFilter): a query
      # moves the selection to the top row (the best match); a cleared
      # query keeps the position, clamped to the restored list.
      def edit_query
        yield
        @filtered = filter(@query)
        @selected = @query.empty? ? [@selected, @filtered.size - 1].max : 0
        @mouse_pressed = nil
      end

      # pi fuzzyFilter over the variant's search text (the port's
      # fuzzy_filter — the same engine the autocomplete list runs).
      def filter(query)
        Autocomplete.fuzzy_filter(@items, query) { |item| @search_text.call(item) }
      end

      def row_index(row)
        return nil if row.negative?

        index = visible_start + row
        index if index < @filtered.size && index < visible_start + MAX_VISIBLE
      end

      # pi getVisibleRange (select-list.ts:162-168): the window centered
      # on the selection.
      def visible_start
        [[@selected - MAX_VISIBLE / 2, @filtered.size - MAX_VISIBLE].min, 0].max
      end

      # --- rows ---

      # pi ThinkingSelectorComponent's inner Text rows (title, hint);
      # the model menu's /login hint line is cut (itemized).
      def heading_rows
        return [] if @variant == :model

        [
          TUI.line(" Thinking Level"),
          blank,
          TUI.line("shift+tab cycles thinking levels in-session", fg: Theme[:dim]),
          blank
        ]
      end

      # The search Input: the query with the fake-cursor cell (the
      # editor's input shape).
      def input_row
        TUI.line([TUI.span("  #{@query}"), TUI.span(" ", modifiers: [:reversed])])
      end

      def list_rows(width)
        return [TUI.line(no_match_text, fg: Theme[:muted])] if @filtered.empty?

        start = visible_start
        window = @filtered[start, MAX_VISIBLE]
        rows = window.map.with_index { |item, i| item_row(item, start + i, selected_row?(start + i), width) }
        if start.positive? || start + window.size < @filtered.size
          rows << TUI.line("  (#{@selected + 1}/#{@filtered.size})", fg: Theme[:muted])
        end
        rows
      end

      def selected_row?(index)
        index == @selected
      end

      def no_match_text
        @variant == :model ? "  No matching models" : "  No matching commands"
      end

      # The variant's item row. Thinking (select-list.ts renderItem,
      # two-column): cursor prefix, "✓ level" primary in the clamped
      # column, the description muted after the gap (only when the width
      # affords it, width > 40); the selected row renders accent
      # end-to-end (selectedText). Model (model-selector.ts updateList
      # :317-339): cursor, current marker, id, " [provider]" muted, the
      # · default badge muted.
      def item_row(item, index, selected, width)
        @variant == :model ? model_row(item, selected, width) : thinking_row(item, selected, column_width, width)
      end

      def thinking_row(item, selected, column, width)
        label = "#{item[:current] ? "✓" : " "} #{item[:label]}"
        prefix = selected ? "→ " : "  "
        return TUI.line("#{prefix}#{label}", fg: Theme[:accent]) if width <= 40

        pad = " " * (column - TUI.text_width(label))
        desc = Text.clip_text(" #{item[:description]}", width - 2 - prefix.length - column)
        # selectedText colors the WHOLE row (select-list.ts:206-208)
        return TUI.line("#{prefix}#{label}#{pad}#{desc}", fg: Theme[:accent]) if selected

        TUI.line([TUI.span("#{prefix}#{label}"), TUI.span("#{pad}#{desc}", fg: Theme[:muted])])
      end

      def model_row(item, selected, width)
        cursor = selected ? "→ " : "  "
        marker = item[:current] ? "✓ " : "  "
        TUI.line(Text.clip_spans([
          TUI.span(cursor, fg: selected ? Theme[:accent] : nil),
          TUI.span(marker, fg: item[:current] ? Theme[:accent] : nil),
          TUI.span(item[:id], fg: selected ? Theme[:accent] : nil),
          TUI.span(" [#{item[:provider]}]", fg: Theme[:muted]),
          item[:default] ? TUI.span(" · default", fg: Theme[:muted]) : nil
        ].compact, width - 1))
      end

      # The model menu's bottom line (pi updateList :374-379): the
      # selected entry's registry name.
      def model_name_row
        TUI.line("  Model Name: #{selection[:name]}", fg: Theme[:muted])
      end

      def help_row
        TUI.line("  #{HELP_LINE}", fg: Theme[:dim])
      end

      def blank
        Panel.blank_line
      end

      # pi getPrimaryColumnWidth (select-list.ts:216-222): clamp(widest
      # label + gap, 12, 32) — the thinking layout's 12/32 bounds.
      def column_width
        widest = @filtered.map { |item| TUI.text_width("#{item[:current] ? "✓" : " "} #{item[:label]}") + 2 }.max || 0
        [[widest, 12].max, 32].min
      end
    end
  end
end
