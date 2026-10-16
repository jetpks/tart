# frozen_string_literal: true

require_relative "safe_execute"

module Tart
  module Tools
    # The edit tool (port of pi's edit.ts + edit-diff.ts): exact text
    # replacement with pi's fuzzy matcher — match-space-only normalization
    # (trailing-whitespace strip per line, smart-quote/dash/space folding),
    # unchanged-line byte preservation, line-ending detect/restore, BOM
    # preservation, and display-diff context truncation.
    class Edit < Fast::Completions::Tool
      include SafeExecute

      pi_name "edit"

      DESCRIPTION = "Edit a single file using exact text replacement. Every edits[].oldText must match a unique, " \
        "non-overlapping region of the original file. If two changes affect the same block or nearby lines, " \
        "merge them into one edit instead of emitting overlapping edits. Do not include large unchanged " \
        "regions just to connect distant changes."

      # STRING-KEYED THROUGHOUT (I64): the gem's strict engine reads string
      # keys (pi's JS node["type"] shape) — a symbol-keyed root makes the
      # "prefer" declaration SILENTLY INERT (the resolver falls back loose
      # with zero errors). Serialization-neutral: JSON.generate emits
      # identical bytes for either key form, so the non-strict wire holds.
      PARAMETERS_SCHEMA = {
        "type" => "object",
        "properties" => {
          "path" => {"type" => "string", "description" => "Path to the file to edit (relative or absolute)"},
          "edits" => {
            "type" => "array",
            "description" => "One or more targeted replacements. Each edit is matched against the original file, " \
              "not incrementally. Do not include overlapping or nested edits. If two changes touch the same " \
              "block or nearby lines, merge them into one edit instead.",
            "items" => {
              "type" => "object",
              "properties" => {
                "oldText" => {"type" => "string", "description" => "Exact text for one targeted replacement. It must " \
                  "be unique in the original file and must not overlap with any other edits[].oldText in the same call."},
                "newText" => {"type" => "string", "description" => "Replacement text for this targeted edit."}
              },
              "required" => ["oldText", "newText"]
            }
          }
        },
        "required" => ["path", "edits"]
      }.freeze

      attr_reader :cwd, :details

      # @param strip_trailing_whitespace [Boolean] §5 toggle (default off):
      #   strip trailing spaces/tabs from each line of the committed bytes.
      def initialize(cwd:, strip_trailing_whitespace: false)
        @cwd = cwd
        @strip_trailing_whitespace = strip_trailing_whitespace
        @details = nil
      end

      description DESCRIPTION

      parameters PARAMETERS_SCHEMA.dup

      # pi edit.ts :156 — one of EXACTLY four core tools pi tags with
      # constrainedSampling; the strict engine rewrites `parameters` and
      # ships `strict: true` on a strict-capable dialect (I64).
      constrained_sampling({"type" => "json_schema", "strict" => "prefer"})

      # pi's prepareEditArguments hook: some models send edits as a JSON
      # string, a single edit object, or legacy top-level oldText/newText.
      # The agent loop normalizes arguments before execution (pi: agent-loop
      # prepareToolCallArguments); the port does it in #call, which the
      # executor invokes for every model-issued call.
      #
      # pi's renderCall carries the call's EditToolDetails on the tool
      # result object (edit.ts:210); the port rides the per-call ToolCall
      # side channel (I57 P3 — never the wire String, which is
      # byte-unchanged). camelCase values, pi's EditToolDetails names
      # (edit.ts:70-76), from the values execute already computed — and
      # only on success (an error result carries no details).
      def call(tool_call: nil, **arguments)
        result = super(tool_call:, **self.class.normalize_arguments(arguments))
        if tool_call && @details
          tool_call.details = {diff: @details[:diff], patch: @details[:patch],
                               firstChangedLine: @details[:first_changed_line]}
        end
        result
      end

      # Port of pi's prepareEditArguments.
      def self.normalize_arguments(arguments)
        args = arguments.dup
        edits = args[:edits]
        if edits.is_a?(String)
          begin
            parsed = JSON.parse(edits)
            args[:edits] = if parsed.is_a?(Array)
              parsed
            elsif single_edit?(parsed)
              [parsed]
            end
          rescue JSON::ParserError
            nil
          end
        elsif single_edit?(edits)
          args[:edits] = [edits]
        end

        if args[:oldText].is_a?(String) && args[:newText].is_a?(String)
          edits_array = args[:edits].is_a?(Array) ? args[:edits].dup : []
          edits_array << {oldText: args[:oldText], newText: args[:newText]}
          args = args.except(:oldText, :newText)
          args[:edits] = edits_array
        end
        args
      end

      def self.single_edit?(value)
        value.is_a?(Hash) &&
          (value["oldText"] || value[:oldText]).is_a?(String) &&
          (value["newText"] || value[:newText]).is_a?(String)
      end

      # @return [String] pi's success text, or {error:} on failure.
      def execute(path:, edits:)
        # The per-call reset: +@details+ carries the LAST success otherwise
        # (the tool instance is shared across calls), and an error result
        # must ride no details (pi's error toolResults carry none).
        @details = nil
        safe_execute do
          failure = validate_input(path:, edits:)
          return failure if failure

          edits = normalize_edit_shapes(edits)
          absolute_path = PathUtils.resolve_to_cwd(path, @cwd)

          FileMutationQueue.with(absolute_path) do
            Fast::Completions::Cancellation.check
            # pi checks access R_OK|W_OK via fs/promises: a missing file
            # surfaces as ENOENT, an unreadable/unwritable one as EACCES.
            begin
              raise Errno::ENOENT unless File.exist?(absolute_path)
              raise Errno::EACCES unless File.readable?(absolute_path) && File.writable?(absolute_path)
            rescue SystemCallError => e
              raise ArgumentError, "Could not edit file: #{path}. Error code: #{e.class.name.delete_prefix('Errno::')}."
            end
            Fast::Completions::Cancellation.check

            raw_content = File.binread(absolute_path).force_encoding(Encoding::UTF_8)
            check_cancelled

            # Strip BOM before matching; the model will not include an
            # invisible BOM in oldText.
            bom = EditDiff.split_bom(raw_content)
            original_ending = EditDiff.detect_line_ending(bom[:text])
            normalized_content = EditDiff.normalize_to_lf(bom[:text])
            result = EditDiff.apply_edits_to_normalized_content(normalized_content, edits, path)
            check_cancelled

            final_content = bom[:bom] + EditDiff.restore_line_endings(result[:new_content], original_ending)
            final_content = EditDiff.strip_trailing_whitespace(final_content) if @strip_trailing_whitespace
            File.binwrite(absolute_path, final_content)
            check_cancelled

            diff_result = EditDiff.generate_diff_string(result[:base_content], result[:new_content])
            patch = EditDiff.generate_unified_patch(path, result[:base_content], result[:new_content])
            @details = {diff: diff_result[:diff], patch:,
                        first_changed_line: diff_result[:first_changed_line]}
            "Successfully replaced #{edits.length} block(s) in #{path}."
          end
        end
      end

      private

      # pi's prepareEditArguments: some models send edits as a JSON string, a
      # single object, or legacy top-level oldText/newText.
      def normalize_edit_shapes(edits)
        edits.map do |e|
          {old_text: e[:old_text] || e["oldText"] || e[:oldText],
           new_text: e[:new_text] || e["newText"] || e[:newText]}
        end
      end

      def check_cancelled
        Fast::Completions::Cancellation.check
      end
    end
  end
end
