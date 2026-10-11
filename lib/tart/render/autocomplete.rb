# frozen_string_literal: true

require_relative "text"

module Tart
  module Render
    # The autocomplete list (pi editor.ts autocompleteState/autocompleteList
    # + SelectList): the filtered items, the selection index, and the
    # list's rendered rows. Driven by the Chat coordinator against an
    # {Editor} — the token is read via the editor (pi homes
    # isInSlashCommandContext in custom-editor.ts) and the completion
    # applied through its write surface (pi applyCompletion,
    # tui/autocomplete.ts:419-436). Unsynchronized by design (I22 shape
    # rule a): the Chat surface owns the mutex.
    class Autocomplete
      # Suggestion-list window (pi editor.ts:322 default 5; the 3-20 clamp
      # is settings-backed — cut, itemized deviation: fixed at the default).
      AUTOCOMPLETE_MAX = 5

      # The injected completion source (bin/tart's {SlashSource}): answers
      # +items+ with the full {value:, label:, description:} catalog the
      # list fuzzy-filters. nil offers no suggestions — headless tests
      # stay deterministic.
      attr_reader :source

      # The active list's filtered items (nil = no active list) and the
      # selection index — the Chat readbacks' targets.
      attr_reader :suggestions, :selected

      def initialize(source:)
        @source = source
        @suggestions = nil
        @selected = 0
      end

      # Re-query the completion source from the editor's current
      # input/cursor (pi editor.ts:1228-1251 update-on-typing +
      # applyAutocompleteSuggestions :2432-2442): in slash context,
      # fuzzy-filter the catalog on the command text (pi
      # CombinedAutocompleteProvider.getSuggestions tui/autocomplete.ts
      # :336-365 — bare skill names first, then full "skill:" names); no
      # context or no matches cancels the list.
      def update(editor)
        token = editor.slash_token
        items = token && @source ? filter_suggestions(token[1..]) : nil
        @suggestions = items&.any? ? items : nil
        return unless @suggestions

        @selected = best_match_index(items, token[1..])
      end

      def cancel
        @suggestions = nil
        @selected = 0
      end

      # pi SelectList.handleInput (select-list.ts:146-155): up/down WRAP.
      def navigate(direction)
        size = @suggestions.size
        @selected = direction == -1 ? (@selected.zero? ? size - 1 : @selected - 1) : (@selected == size - 1 ? 0 : @selected + 1)
      end

      # pi applyCompletion's slash branch (tui/autocomplete.ts:419-436):
      # the token (before the cursor) is replaced with "/<value> " — the
      # trailing space included — and the cursor lands after it.
      def apply(editor)
        item = @suggestions[@selected]
        cancel
        return unless item

        lead = editor.input.index(/\S/) || 0
        tail = editor.input[editor.cursor..] || ""
        editor.replace_token(lead, "/#{item[:value]} #{tail}", lead + item[:value].length + 2) # +2 for "/" and the space
      end

      # The list's extra editor-area rows: the visible window plus the
      # (i/N) scroll-info line (select-list.ts render).
      def rows
        return 0 unless @suggestions

        [@suggestions.size, AUTOCOMPLETE_MAX + (@suggestions.size > AUTOCOMPLETE_MAX ? 1 : 0)].min
      end

      # The list's display lines (pi select-list.ts renderItem +
      # getVisibleRange, two-column with descriptions): the visible window
      # centered on the selection (startIndex = max(0, min(selected −
      # maxVisible/2, size − maxVisible))), "→ " marking the selection —
      # accent-styled whole-line (theme.ts:1061-1068 selectedText) —
      # unselected labels default with the description muted. Descriptions
      # only fit when the editor's inner width affords them (width > 40,
      # select-list.ts:189); the command column clamps to 12-32
      # (SLASH_COMMAND_SELECT_LIST_LAYOUT, editor.ts:248-251, gap 2).
      def lines(width)
        return [] unless @suggestions

        items = @suggestions
        start = [[@selected - AUTOCOMPLETE_MAX / 2, items.size - AUTOCOMPLETE_MAX].min, 0].max
        column = column_width(items)
        column = [column, width - 2 - 4].min # pi: effectivePrimaryColumnWidth (select-list.ts:191)
        rows = items[start, AUTOCOMPLETE_MAX].map.with_index do |item, i|
          row(item, start + i == @selected, column, width)
        end
        rows << TUI.line("  (#{@selected + 1}/#{items.size})", fg: Theme[:muted]) if items.size > AUTOCOMPLETE_MAX
        rows
      end

      class << self

        # pi fuzzyMatch (fuzzy.ts:12-72): every query char in order (not
        # necessarily consecutive) in the lowercased text; the score is ≤ 0,
        # lower is better — consecutive matches −5·n, gaps +2·gap, word
        # boundaries −10, position +0.1·i, an exact match −100. nil = no
        # match. The alnum/num-alpha swap ("ab12" ⇄ "12ab") retries with a
        # +5 penalty (fuzzy.ts:68-93).
        def fuzzy_match(query, text)
          query = query.downcase
          text = text.downcase
          score = fuzzy_subsequence_score(query, text)
          return score if score

          swapped = query.match(/\A(?<letters>[a-z]+)(?<digits>[0-9]+)\z/) { |m| "#{m[:digits]}#{m[:letters]}" } ||
            query.match(/\A(?<digits>[0-9]+)(?<letters>[a-z]+)\z/) { |m| "#{m[:letters]}#{m[:digits]}" }
          swapped && (swapped_score = fuzzy_subsequence_score(swapped, text)) ? swapped_score + 5 : nil
        end

        def fuzzy_subsequence_score(query, text)
          return nil if query.length > text.length
          return 0 if query.empty?

          score = 0.0
          last = -1
          consecutive = 0
          query.chars.each do |char|
            i = text.index(char, last + 1)
            return nil unless i

            if last == i - 1
              consecutive += 1
              score -= consecutive * 5
            else
              consecutive = 0
              score += (i - last - 1) * 2 if last >= 0
            end
            score -= 10 if i.zero? || /[\s\-_.\/:]/.match?(text[i - 1])
            score += i * 0.1
            last = i
          end
          score -= 100 if query == text
          score
        end

        # pi fuzzyFilter (fuzzy.ts:75-106): whitespace/slash-separated query
        # tokens must ALL match the search text; matches sort best-first.
        # pi's Array#sort is stable (ties keep the pre-sort catalog order —
        # item 4); Ruby's sort_by is not, so the pre-sort index is the
        # tie-break (item 4 fix: /ar's architect-family ties land where
        # pi's do).
        def fuzzy_filter(items, query)
          return items if query.strip.empty?

          tokens = query.strip.split(/[\s\/]+/).reject(&:empty?)
          return items if tokens.empty?

          items.each_with_index.filter_map do |item, i|
            text = yield(item)
            scores = tokens.map { |token| fuzzy_match(token, text) }
            scores.all? ? [item, scores.sum, i] : nil
          end.sort_by { |_, score, i| [score, i] }.map(&:first)
        end

      end

      private

      def filter_suggestions(query)
        bare = Autocomplete.fuzzy_filter(@source.items, query) { |item| item[:value].delete_prefix("skill:") }
        bare + Autocomplete.fuzzy_filter(@source.items - bare, query) { |item| item[:value] }
      end

      # pi getBestAutocompleteMatchIndex (editor.ts:2207-2232): the exact
      # match always wins, else the first value with the prefix — else the
      # default (first) item.
      def best_match_index(items, prefix)
        return 0 if prefix.empty?

        first_prefix = nil
        items.each_with_index do |item, i|
          return i if item[:value] == prefix

          first_prefix ||= i if item[:value].start_with?(prefix)
        end
        first_prefix || 0
      end

      # clamp(widest label + gap, 12, 32) over the whole filtered list (pi
      # select-list.ts getPrimaryColumnWidth, gap 2, slash layout 12/32).
      def column_width(items)
        widest = items.map { |item| TUI.text_width(item[:label]) + 2 }.max || 0
        [[widest, 12].max, 32].min
      end

      def row(item, selected, column, width)
        label = Text.clip_text(item[:label], column - 2)
        spacing = " " * [1, column - TUI.text_width(label)].max
        desc = description(item[:description], width, label, spacing)
        return TUI.line("→ #{label}#{spacing}#{desc}", fg: Theme[:accent]) if selected

        TUI.line([TUI.span("  #{label}"), TUI.span("#{spacing}#{desc}", fg: Theme[:muted])])
      end

      # The description column (select-list.ts:189-210): only when the width
      # affords it (> 40) and at least MIN_DESCRIPTION_WIDTH (10) columns
      # remain after prefix + label + spacing − a two-cell safety margin;
      # hard-clipped (truncateToWidth with an empty tail).
      def description(desc, width, label, spacing)
        return "" unless desc && width > 40

        remaining = width - (2 + TUI.text_width(label) + spacing.length) - 2
        remaining >= 10 ? Text.clip_text(desc, remaining) : ""
      end
    end
  end
end
