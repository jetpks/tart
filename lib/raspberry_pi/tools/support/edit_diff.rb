# frozen_string_literal: true

require "diff/lcs"
require "diff/lcs/hunk"

module RaspberryPi
  module Tools
    # Shared diff computation utilities for the edit tool (port of pi's
    # edit-diff.ts).
    #
    # Parity notes (pi is the oracle):
    # - Match-space normalization only: NFKC, per-line trailing-whitespace
    #   strip, smart quotes/dashes/special spaces folded to ASCII. Leading
    #   and internal whitespace runs are NOT normalized.
    # - Unchanged lines keep their original bytes: replacements are matched
    #   against the normalized base but overlaid line-wise onto the original.
    # - Line endings are detected on the file content, stripped to LF for
    #   matching, and restored on write; the BOM is split off before matching
    #   and written back verbatim.
    module EditDiff
      BOM = "\uFEFF"

      # §5 toggle seam (port extension — NOT pi code; pi normalizes trailing
      # whitespace only inside fuzzy matching). Applied to the exact bytes a
      # write boundary commits to disk when enabled: trailing spaces and tabs
      # removed from each line (lines split on "\n"); line count, final-newline
      # presence, and every other byte unchanged. Non-string input passes
      # through so error semantics downstream stay identical.
      def self.strip_trailing_whitespace(content)
        return content unless content.is_a?(String)

        content.split("\n", -1).map { |line| line.sub(/[ \t]+\z/, "") }.join("\n")
      end

      # The line ending detected in content (pi's detectLineEnding): CRLF wins
      # only when the first CRLF precedes the first LF.
      def self.detect_line_ending(content)
        crlf_index = content.index("\r\n")
        lf_index = content.index("\n")
        return "\n" if lf_index.nil? || crlf_index.nil?

        crlf_index < lf_index ? "\r\n" : "\n"
      end

      def self.normalize_to_lf(text)
        text.gsub("\r\n", "\n").tr("\r", "\n")
      end

      def self.restore_line_endings(text, ending)
        ending == "\r\n" ? text.gsub("\n", "\r\n") : text
      end

      # Split off a leading BOM; the model will not include it in oldText
      # (pi's splitBom).
      def self.split_bom(content)
        content.start_with?(BOM) ? {bom: BOM, text: content[1..] || ""} : {bom: "", text: content}
      end

      # Normalize text for fuzzy matching (pi's normalizeForFuzzyMatch).
      def self.normalize_for_fuzzy_match(text)
        text
          .unicode_normalize(:nfkc)
          .split("\n", -1).map(&:rstrip).join("\n")
          .gsub(/[\u2018\u2019\u201A\u201B]/, "'")
          .gsub(/[\u201C\u201D\u201E\u201F]/, '"')
          .gsub(/[\u2010\u2011\u2012\u2013\u2014\u2015\u2212]/, "-")
          .gsub(/[\u00A0\u2002-\u200A\u202F\u205F\u3000]/, " ")
      end

      # Lines with their newline terminators kept (pi's splitLinesWithEndings).
      def self.split_lines_with_endings(content)
        content.scan(/[^\n]*\n|[^\n]+/)
      end

      # Find oldText in content, trying exact match first, then fuzzy match
      # (pi's fuzzyFindText).
      def self.fuzzy_find_text(content, old_text)
        exact_index = content.index(old_text)
        unless exact_index.nil?
          return {found: true, index: exact_index, match_length: old_text.length,
                  used_fuzzy_match: false, content_for_replacement: content}
        end

        fuzzy_content = normalize_for_fuzzy_match(content)
        fuzzy_old_text = normalize_for_fuzzy_match(old_text)
        fuzzy_index = fuzzy_content.index(fuzzy_old_text)
        if fuzzy_index.nil?
          return {found: false, index: -1, match_length: 0, used_fuzzy_match: false,
                  content_for_replacement: content}
        end

        {found: true, index: fuzzy_index, match_length: fuzzy_old_text.length,
         used_fuzzy_match: true, content_for_replacement: fuzzy_content}
      end

      def self.count_occurrences(content, old_text)
        normalize_for_fuzzy_match(content).scan(normalize_for_fuzzy_match(old_text)).length
      end

      # Apply replacements matched against base_content to original_content
      # while preserving unchanged line blocks from the original (pi's
      # applyReplacementsPreservingUnchangedLines).
      def self.apply_replacements_preserving_unchanged_lines(original_content, base_content, replacements)
        original_lines = split_lines_with_endings(original_content)
        base_lines = line_spans(base_content)
        if original_lines.length != base_lines.length
          raise ArgumentError, "Cannot preserve unchanged lines because the base content has a different line count."
        end

        groups = []
        replacements.sort_by { |r| r[:match_index] }.each do |replacement|
          range = replacement_line_range(base_lines, replacement)
          current = groups.last
          if current && range[:start_line] < current[:end_line]
            current[:end_line] = [current[:end_line], range[:end_line]].max
            current[:replacements] << replacement
          else
            groups << {start_line: range[:start_line], end_line: range[:end_line], replacements: [replacement]}
          end
        end

        result = +""
        original_line_index = 0
        groups.each do |group|
          result << original_lines[original_line_index...group[:start_line]].join
          group_start = base_lines[group[:start_line]][:start]
          group_end = base_lines[group[:end_line] - 1][:end]
          result << apply_replacements(base_content[group_start...group_end], group[:replacements], group_start)
          original_line_index = group[:end_line]
        end
        result << original_lines[original_line_index..].join
        result
      end

      def self.line_spans(content)
        offset = 0
        split_lines_with_endings(content).map do |line|
          span = {start: offset, end: offset + line.length}
          offset = span[:end]
          span
        end
      end

      def self.replacement_line_range(lines, replacement)
        replacement_start = replacement[:match_index]
        replacement_end = replacement_start + replacement[:match_length]

        start_line = lines.index { |line| replacement_start >= line[:start] && replacement_start < line[:end] }
        raise ArgumentError, "Replacement range is outside the base content." if start_line.nil?

        end_line = start_line
        end_line += 1 while end_line < lines.length && lines[end_line][:end] < replacement_end
        raise ArgumentError, "Replacement range is outside the base content." if end_line >= lines.length

        {start_line:, end_line: end_line + 1}
      end

      # Apply replacements in reverse order so offsets remain stable (pi's
      # applyReplacements). +offset+ rebases match indices into the slice.
      # Indices and lengths are character offsets, consistent with
      # #fuzzy_find_text and #line_spans.
      def self.apply_replacements(content, replacements, offset = 0)
        result = content
        replacements.reverse_each do |replacement|
          match_index = replacement[:match_index] - offset
          result = result[0, match_index] + replacement[:new_text] +
            (result[(match_index + replacement[:match_length])..] || "")
        end
        result
      end

      # Apply one or more exact-text replacements to LF-normalized content
      # (pi's applyEditsToNormalizedContent). All edits are matched against
      # the same original content. If any edit needs fuzzy matching, the
      # operation runs in fuzzy-normalized space and overlays the line-level
      # changes onto the original content.
      #
      # Returns {base_content:, new_content:}; raises ArgumentError with pi's
      # error strings on not-found, duplicate, overlap, empty, and no-change.
      def self.apply_edits_to_normalized_content(normalized_content, edits, path)
        normalized_edits = edits.map { |edit| {old_text: normalize_to_lf(edit[:old_text]),
                                               new_text: normalize_to_lf(edit[:new_text])} }

        normalized_edits.each_with_index do |edit, i|
          raise empty_old_text_error(path, i, normalized_edits.length) if edit[:old_text].empty?
        end

        initial_matches = normalized_edits.map { |edit| fuzzy_find_text(normalized_content, edit[:old_text]) }
        used_fuzzy_match = initial_matches.any? { |match| match[:used_fuzzy_match] }
        replacement_base = used_fuzzy_match ? normalize_for_fuzzy_match(normalized_content) : normalized_content

        matched_edits = []
        normalized_edits.each_with_index do |edit, i|
          match = fuzzy_find_text(replacement_base, edit[:old_text])
          raise not_found_error(path, i, normalized_edits.length) unless match[:found]

          occurrences = count_occurrences(replacement_base, edit[:old_text])
          raise duplicate_error(path, i, normalized_edits.length, occurrences) if occurrences > 1

          matched_edits << {edit_index: i, match_index: match[:index],
                            match_length: match[:match_length], new_text: edit[:new_text]}
        end

        matched_edits.sort_by! { |m| m[:match_index] }
        matched_edits.each_cons(2) do |previous, current|
          if previous[:match_index] + previous[:match_length] > current[:match_index]
            raise ArgumentError,
              "edits[#{previous[:edit_index]}] and edits[#{current[:edit_index]}] overlap in #{path}. " \
              "Merge them into one edit or target disjoint regions."
          end
        end

        base_content = normalized_content
        new_content = if used_fuzzy_match
          apply_replacements_preserving_unchanged_lines(normalized_content, replacement_base, matched_edits)
        else
          apply_replacements(replacement_base, matched_edits)
        end

        raise no_change_error(path, normalized_edits.length) if base_content == new_content

        {base_content:, new_content:}
      end

      # Display-oriented diff with line numbers and context (pi's
      # generateDiffString). Returns {diff:, first_changed_line:}.
      def self.generate_diff_string(old_content, new_content, context_lines = 4)
        parts = line_diff_parts(old_content, new_content)
        output = []

        old_lines = old_content.split("\n")
        new_lines = new_content.split("\n")
        width = [old_lines.length, new_lines.length].max.to_s.length

        old_line_num = 1
        new_line_num = 1
        last_was_change = false
        first_changed_line = nil

        parts.each_with_index do |part, i|
          raw = part[:value].split("\n", -1)
          raw.pop if raw.last == ""

          if part[:added] || part[:removed]
            first_changed_line ||= new_line_num
            raw.each do |line|
              if part[:added]
                output << "+#{new_line_num.to_s.rjust(width)} #{line}"
                new_line_num += 1
              else
                output << "-#{old_line_num.to_s.rjust(width)} #{line}"
                old_line_num += 1
              end
            end
            last_was_change = true
          else
            next_part_is_change = i < parts.length - 1 && (parts[i + 1][:added] || parts[i + 1][:removed])
            has_leading_change = last_was_change
            has_trailing_change = next_part_is_change

            if has_leading_change && has_trailing_change && raw.length > context_lines * 2
              leading = raw.slice(0, context_lines)
              trailing = raw.slice(raw.length - context_lines, context_lines)
              skipped = raw.length - leading.length - trailing.length
              leading.each do |line|
                output << " #{old_line_num.to_s.rjust(width)} #{line}"
                old_line_num += 1
                new_line_num += 1
              end
              output << " #{' ' * width} ..."
              old_line_num += skipped
              new_line_num += skipped
              trailing.each do |line|
                output << " #{old_line_num.to_s.rjust(width)} #{line}"
                old_line_num += 1
                new_line_num += 1
              end
            elsif has_leading_change && has_trailing_change
              raw.each do |line|
                output << " #{old_line_num.to_s.rjust(width)} #{line}"
                old_line_num += 1
                new_line_num += 1
              end
            elsif has_leading_change
              shown = raw.slice(0, context_lines)
              skipped = raw.length - shown.length
              shown.each do |line|
                output << " #{old_line_num.to_s.rjust(width)} #{line}"
                old_line_num += 1
                new_line_num += 1
              end
              if skipped.positive?
                output << " #{' ' * width} ..."
                old_line_num += skipped
                new_line_num += skipped
              end
            elsif has_trailing_change
              skipped = [0, raw.length - context_lines].max
              if skipped.positive?
                output << " #{' ' * width} ..."
                old_line_num += skipped
                new_line_num += skipped
              end
              raw.slice(skipped, raw.length - skipped).each do |line|
                output << " #{old_line_num.to_s.rjust(width)} #{line}"
                old_line_num += 1
                new_line_num += 1
              end
            else
              old_line_num += raw.length
              new_line_num += raw.length
            end

            last_was_change = false
          end
        end

        {diff: output.join("\n"), first_changed_line:}
      end

      # Standard unified patch (pi's generateUnifiedPatch via jsdiff's
      # createTwoFilesPatch, context 4, headers only).
      def self.generate_unified_patch(path, old_content, new_content, context_lines = 4)
        hunks = build_hunks(old_content, new_content, context_lines)
        return "" if hunks.empty?

        "--- #{path}\n+++ #{path}\n#{hunks}"
      end

      # The diff-lcs ldiff recipe: build hunks, merging overlapping ones, in
      # unified format. Lines follow File.readlines semantics (no trailing
      # empty element for a final newline).
      def self.build_hunks(old_content, new_content, context_lines)
        old_lines = old_content.split("\n")
        new_lines = new_content.split("\n")
        lcs_diff = Diff::LCS.diff(old_lines, new_lines)
        return "" if lcs_diff.empty?

        output = +""
        old_hunk = nil
        file_length_difference = 0
        lcs_diff.each do |piece|
          hunk = Diff::LCS::Hunk.new(old_lines, new_lines, piece, context_lines, file_length_difference)
          file_length_difference = hunk.file_length_difference
          if old_hunk && !hunk.overlaps?(old_hunk)
            output << old_hunk.diff(:unified)
            old_hunk = hunk
          elsif old_hunk
            old_hunk.unshift(hunk)
          else
            old_hunk = hunk
          end
        end
        output << old_hunk.diff(:unified, true)
        output
      end

      # Group line changes into jsdiff-style parts (runs of
      # common/removed/added lines), each carrying the raw line text with its
      # newline kept. Each maximal changed region becomes a removed part
      # followed by an added part, like jsdiff's diffLines.
      def self.line_diff_parts(old_content, new_content)
        old_lines = split_keep_newlines(old_content)
        new_lines = split_keep_newlines(new_content)
        parts = []
        common = []
        removed = []
        added = []

        flush_change = lambda do
          unless common.empty?
            parts << {added: false, removed: false, value: common.join}
            common = []
          end
          unless removed.empty?
            parts << {added: false, removed: true, value: removed.join}
            removed = []
          end
          unless added.empty?
            parts << {added: true, removed: false, value: added.join}
            added = []
          end
        end

        Diff::LCS.sdiff(old_lines.map(&:chomp), new_lines.map(&:chomp)).each do |change|
          if change.unchanged?
            common << old_lines[change.old_position]
          else
            # A change closes the common run (jsdiff groups runs).
            flush_change.call
            if change.changed?
              removed << old_lines[change.old_position]
              added << new_lines[change.new_position]
            elsif change.deleting?
              removed << old_lines[change.old_position]
            else # adding
              added << new_lines[change.new_position]
            end
            # Emit the removed/added runs immediately so parts stay in
            # document order.
            flush_change.call
          end
        end
        flush_change.call
        merge_change_runs(parts)
      end

      # jsdiff groups a changed region as one removed run followed by one
      # added run; sdiff can split a region (e.g. change + trailing delete),
      # so consecutive change parts merge back into jsdiff's form.
      def self.merge_change_runs(parts)
        out = []
        removed = []
        added = []
        flush = lambda do
          unless removed.empty?
            out << {added: false, removed: true, value: removed.join}
            removed = []
          end
          unless added.empty?
            out << {added: true, removed: false, value: added.join}
            added = []
          end
        end
        parts.each do |part|
          if part[:added] || part[:removed]
            (part[:removed] ? removed : added) << part[:value]
          else
            flush.call
            out << part
          end
        end
        flush.call
        out
      end

      # Split content into lines each keeping their "\n" terminator, with
      # jsdiff's line semantics (a final newline does not open an empty line;
      # no trailing newline leaves the last line unterminated).
      def self.split_keep_newlines(content)
        return [] if content.empty?

        lines = content.split("\n", -1)
        if content.end_with?("\n")
          lines.pop
          lines = lines.map { |l| "#{l}\n" }
        else
          last = lines.pop
          lines = lines.map { |l| "#{l}\n" }
          lines << last unless last.nil?
        end
        lines
      end

      def self.not_found_error(path, edit_index, total_edits)
        if total_edits == 1
          ArgumentError.new(
            "Could not find the exact text in #{path}. The old text must match exactly including all " \
            "whitespace and newlines."
          )
        else
          ArgumentError.new(
            "Could not find edits[#{edit_index}] in #{path}. The oldText must match exactly including all " \
            "whitespace and newlines."
          )
        end
      end

      def self.duplicate_error(path, edit_index, total_edits, occurrences)
        if total_edits == 1
          ArgumentError.new(
            "Found #{occurrences} occurrences of the text in #{path}. The text must be unique. " \
            "Please provide more context to make it unique."
          )
        else
          ArgumentError.new(
            "Found #{occurrences} occurrences of edits[#{edit_index}] in #{path}. Each oldText must be unique. " \
            "Please provide more context to make it unique."
          )
        end
      end

      def self.empty_old_text_error(path, edit_index, total_edits)
        if total_edits == 1
          ArgumentError.new("oldText must not be empty in #{path}.")
        else
          ArgumentError.new("edits[#{edit_index}].oldText must not be empty in #{path}.")
        end
      end

      def self.no_change_error(path, total_edits)
        if total_edits == 1
          ArgumentError.new(
            "No changes made to #{path}. The replacement produced identical content. This might indicate an " \
            "issue with special characters or the text not existing as expected."
          )
        else
          ArgumentError.new("No changes made to #{path}. The replacements produced identical content.")
        end
      end
    end
  end
end
