# frozen_string_literal: true

require "async"
require_relative "safe_execute"

module Tart
  module Tools
    # The grep tool (port of pi's grep.ts): ripgrep-backed content search
    # returning matching lines with paths and line numbers, optional context
    # blocks, 100-match limit, 500-char line truncation, 50KB byte limit.
    #
    # Parity note: pi downloads `rg` at runtime (ensureTool); the port uses
    # `rg` from PATH and pi's error message when missing — recorded deviation.
    class Grep < Fast::Completions::Tool
      include SafeExecute

      pi_name "grep"

      DEFAULT_LIMIT = 100

      # I102 (KB I17 S1) — the rg deadline default (seconds); TOOL_TIMEOUT_S env
      # overrides per call.
      DEFAULT_TIMEOUT_SECONDS = 120

      DESCRIPTION = "Search file contents for a pattern. Returns matching lines with file paths and line numbers. " \
        "Respects .gitignore. Output is truncated to 100 matches or 50KB (whichever is hit first). " \
        "Long lines are truncated to 500 chars."

      PARAMETERS_SCHEMA = {
        type: "object",
        properties: {
          "pattern" => {type: "string", description: "Search pattern (regex or literal string)"},
          "path" => {type: "string", description: "Directory or file to search (default: current directory)"},
          "glob" => {type: "string", description: "Filter files by glob pattern, e.g. '*.ts' or '**/*.spec.ts'"},
          "ignoreCase" => {type: "boolean", description: "Case-insensitive search (default: false)"},
          "literal" => {type: "boolean", description: "Treat pattern as literal string instead of regex (default: false)"},
          "context" => {type: "number", description: "Number of lines to show before and after each match (default: 0)"},
          "limit" => {type: "number", description: "Maximum number of matches to return (default: 100)"}
        },
        required: ["pattern"]
      }.freeze

      attr_reader :cwd, :details

      def initialize(cwd:)
        @cwd = cwd
        @details = nil
      end

      description DESCRIPTION

      parameters PARAMETERS_SCHEMA.dup

      schema_contract

      # @return [String] formatted matches, or {error:} on failure.
      def execute(pattern:, path: nil, glob: nil, ignore_case: nil, literal: nil, context: nil, limit: nil)
        safe_execute do
          failure = validate_input(pattern:, path:, glob:, ignore_case:, literal:, context:, limit:)
          return failure if failure

          Fast::Completions::Cancellation.check
          rg_path = rg_binary
          raise ArgumentError, "ripgrep (rg) is not available and could not be downloaded" unless rg_path

          search_path = PathUtils.resolve_to_cwd(path || ".", @cwd)
          is_directory = stat_directory?(search_path)

          context_value = context && context.positive? ? context : 0
          effective_limit = [1, limit || DEFAULT_LIMIT].max
          output_lines, match_count, match_limit_reached, lines_truncated, output_line_count, output_bytes, exit_ok = run_rg(
            rg_path, pattern, search_path, glob, ignore_case, literal, effective_limit, context_value, is_directory
          )
          Fast::Completions::Cancellation.check
          raise ArgumentError, "ripgrep exited with code #{exit_ok}" unless exit_ok

          format_output(output_lines, match_count, match_limit_reached, effective_limit,
            lines_truncated, output_line_count, output_bytes)
        end
      end

      private

      def rg_binary
        @rg_binary ||= find_on_path("rg")
      end

      def find_on_path(name)
        ENV["PATH"].to_s.split(File::PATH_SEPARATOR).lazy.map { |dir| File.join(dir, name) }
                   .find { |candidate| File.file?(candidate) && File.executable?(candidate) }
      end

      def stat_directory?(path)
        File.stat(path).directory?
      rescue StandardError
        raise ArgumentError, "Path not found: #{path}"
      end

      # Streams `rg --json` match AND context events until EOF or the proven
      # match limit. Returns [output_lines, match_count, match_limit_reached,
      # lines_truncated, output_line_count, output_bytes, exit_code_or_nil].
      #
      # #9276 (pi grep.ts:168): rg emits the surrounding lines as `context`
      # events when --context is passed, so NO matched file is ever read here
      # — the pre-fix File.read shape (the OOM-on-large-files exposure) is
      # dead. The byte-cap arm (pi grep.ts:231, the same fix): rows past the
      # 50KB cap are COUNTED but never STORED, so the output buffer stays
      # bounded no matter how much rg streams.
      #
      # I106 (owner concurrency law, PR-#28 review) — the process shape:
      # `Kernel#Sync` is the one gateway (the live tool task yields inline;
      # a bare caller gets a fresh reactor on its own fiber), the deadline
      # is a `with_timeout` fiber timer, the stderr drain is a sibling
      # reactor task, and every wait — pipe reads, Process.waitpid2 — parks
      # evented in the scheduler. Behavior is the I102 contract unchanged:
      # the TOOL_TIMEOUT_S parse law (default 120), the teaching refusal on
      # expiry, TERM→KILL escalation by TIME (never probed), and the
      # ToolTimeout raise instead of a hung session.
      REAP_BUDGET_SECONDS = 5

      def run_rg(rg_path, pattern, search_path, glob, ignore_case, literal, effective_limit,
                 context_value, is_directory)
        timeout = tool_timeout_seconds
        args = ["--json", "--line-number", "--color=never", "--hidden"]
        args << "--ignore-case" if ignore_case
        args << "--fixed-strings" if literal
        args += ["--glob", glob] if glob
        # rg emits the surrounding lines as `context` events, so no matched
        # file is ever read here (#9276).
        args += ["--context", context_value.to_s] if context_value.positive?
        args += ["--", pattern, search_path]

        Sync do
          out_rd, out_wr = IO.pipe
          err_rd, err_wr = IO.pipe
          pid = Process.spawn(rg_path, *args, out: out_wr, err: err_wr, in: :close,
                                              pgroup: true, chdir: @cwd)
          out_wr.close
          err_wr.close

          stderr = +""
          # Stderr drains on a sibling fiber; the group's death closes the
          # last write-end, the read EOFs, and #wait joins after the reap.
          drain = Async::Task.current.async { stderr << err_rd.read }

          status = nil
          match_limit_reached = false
          match_count = 0
          output_lines = []
          lines_truncated = false
          # #9276's counting arm (pi grep.ts:172-186): the byte cap counts
          # EVERY row but stores only up to it — output_bytes counts a
          # newline after every line; the joined output has one fewer.
          output_bytes = 0
          output_line_count = 0
          # The proven-limit window (pi grep.ts:185-190): rg still sends the
          # last allowed match's trailing context (kept up to
          # trailing_context_end), and only ANOTHER match proves the limit
          # actually cut results off — the notice waits for that proof.
          limit_hit = false
          trailing_context_end = 0
          last_file = nil
          push_line = lambda do |file_path, line_number, line_text, is_match|
            last_file = file_path
            relative = format_path(file_path, search_path, is_directory)
            # Strip only the line terminator: a lone CR inside a line is
            # content (pi's /\r?\n?$/ replace).
            sanitized = line_text.gsub(/\r?\n?\z/, "")
            truncated = Truncate.truncate_line(sanitized)
            lines_truncated ||= truncated[:was_truncated]
            line = is_match ? "#{relative}:#{line_number}: #{truncated[:text]}" :
              "#{relative}-#{line_number}- #{truncated[:text]}"
            output_lines << line if output_bytes - 1 <= Truncate::DEFAULT_MAX_BYTES
            output_bytes += line.bytesize + 1
            output_line_count += 1
          end
          begin
            Async::Task.current.with_timeout(timeout, Async::TimeoutError) do
              out_rd.each_line do |line|
                event = safe_parse(line)
                next unless event
                is_match = event["type"] == "match"
                next unless is_match || event["type"] == "context"

                data = event["data"]
                file_path = decode_rg_text(data.is_a?(Hash) ? data["path"] : nil)
                line_number = data.is_a?(Hash) ? data["line_number"] : nil
                next if file_path.empty? || !line_number.is_a?(Integer)

                if limit_hit
                  in_window = file_path == last_file && line_number <= trailing_context_end
                  # A match inside the last match's trailing context is
                  # shown as context (pi grep.ts:186-189).
                  push_line.call(file_path, line_number, decode_rg_text(data["lines"]), false) if in_window
                  match_limit_reached = true if is_match
                  if match_limit_reached && !(in_window && line_number < trailing_context_end)
                    kill_group(pid, "TERM") # the whole GROUP — the deadline path's shape
                    break
                  end
                  next
                end

                push_line.call(file_path, line_number, decode_rg_text(data["lines"]), is_match)
                next unless is_match

                match_count += 1
                if match_count >= effective_limit
                  limit_hit = true
                  trailing_context_end = line_number + context_value
                end
              end
              status = match_limit_reached ? expire_group(pid) : waitpid_status(pid)
            end
          rescue Async::TimeoutError
            # The deadline: TERM the group, wait for death under the grace
            # timer, KILL a survivor, reap bounded — then the teaching
            # refusal goes out through SafeExecute's ToolTimeout arm.
            expire_group(pid)
            raise ToolTimeout, timeout_message(pattern, search_path, glob, timeout)
          rescue Fast::Completions::CancelledError, Async::Cancel
            # Interrupted mid-search: the group dies with the call and the
            # cancellation propagates (Async::Cancel < Exception — the
            # StandardError belt must never swallow it).
            kill_group(pid, "KILL")
            raise
          ensure
            # No unwind leaves rg behind — deadline, limit, cancellation,
            # and plain errors all end in the same group hygiene. A reactor
            # waits for its tasks, so the drain must ride the EOF that
            # death guarantees before anything escapes the Sync body.
            status ||= expire_group(pid)
            drain.wait
            out_rd.close unless out_rd.closed?
            err_rd.close unless err_rd.closed?
          end

          [output_lines, match_count, match_limit_reached, lines_truncated, output_line_count,
           output_bytes, match_limit_reached ? 0 : status&.exitstatus]
        end
      end

      # TOOL_TIMEOUT_S (I102, KB I17 S1) read at call time: a positive integer wins;
      # absent, non-numeric, or non-positive falls back to the 120 s default.
      def tool_timeout_seconds
        raw = ENV["TOOL_TIMEOUT_S"]
        parsed = raw.is_a?(String) && raw.match?("\\A\\d+\\z") ? Integer(raw, 10) : nil
        parsed&.positive? ? parsed : DEFAULT_TIMEOUT_SECONDS
      end

      # Nested timers: the escalation bounds raise their OWN expiry so a
      # bound can never swallow the deadline's Async::TimeoutError, and the
      # deadline can never be mistaken for a bound.
      class EscalationExpiry < StandardError
      end

      # TERM→KILL escalation is TIME-based, not send-failure-based (I102's
      # law, kept): a target that ignores TERM must not wedge the call, and
      # the grace TIMER replaces any liveness probe — wait-bounded-then-KILL
      # is strictly stronger than probe-then-KILL.
      KILL_GRACE_SECONDS = 2

      def expire_group(pid)
        kill_group(pid, "TERM")
        status = bounded_wait(pid, KILL_GRACE_SECONDS)
        unless status
          kill_group(pid, "KILL")
          status = bounded_wait(pid, REAP_BUDGET_SECONDS)
        end
        status
      end

      # ONE evented wait under a timer: REAP_BUDGET_SECONDS is the
      # never-reached net after SIGKILL — on net expiry nil stands in for
      # the unreapable status and the refusal still goes out.
      def bounded_wait(pid, seconds)
        Async::Task.current.with_timeout(seconds, EscalationExpiry) do
          Process.waitpid2(pid).last
        end
        # ESRCH joins ECHILD: through the scheduler, io-event's EPoll
        # process_wait can TOCTOU its own internal reap (waitid reaps the
        # just-dead child, pidfd_open then finds the pid gone) and raises
        # ESRCH where a direct waitpid raises ECHILD. Gone means exited;
        # nil stands in for the unknowable status.
      rescue EscalationExpiry, Errno::ECHILD, Errno::ESRCH
        nil
      end

      # Same law for the happy-path reap: a vanished pid is an exited
      # child; nil flows to the output-only result path (the ensure's
      # expire_group backfill is ESRCH-safe via bounded_wait above).
      def waitpid_status(pid)
        Process.waitpid2(pid).last
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end

      # Negative-pid signal hits the whole process group; the bare pid is
      # the fallback when the group is already dissolved (Errno races
      # between death and signal are normal).
      def kill_group(pid, signal)
        Process.kill("-#{signal}", pid)
      rescue Errno::ESRCH, Errno::EPERM
        begin
          Process.kill(signal, pid)
        rescue Errno::ESRCH, Errno::EPERM
          nil
        end
      end

      # The I102 (KB I17 S1) teaching refusal: what ran, that it was killed, and how
      # to narrow. Renders verbatim as the {error:} envelope via
      # SafeExecute's ToolTimeout branch.
      def timeout_message(pattern, search_path, glob, timeout)
        "TOOL_TIMEOUT: grep exceeded #{timeout}s and was killed " \
          "(pattern=#{pattern} path=#{search_path} glob=#{glob || '-'}). " \
          "Narrow the search: a smaller path, a tighter glob, or a more specific pattern."
      end
      def safe_parse(line)
        JSON.parse(line)
      rescue JSON::ParserError
        nil
      end

      # pi grep.ts:70-76 (decodeRgText): rg's JSON text fields carry UTF-8
      # data as `text` and NON-UTF-8 data base64-encoded in `bytes` — the
      # no-matched-file-reads law (#9276) needs the bytes arm or a binary
      # match would render empty. Returns "" for a missing/foreign-shaped
      # field (pi's fallthrough).
      def decode_rg_text(field)
        return "" unless field.is_a?(Hash)
        return field["text"] if field["text"].is_a?(String)
        return field["bytes"].unpack1("m0").force_encoding(Encoding::UTF_8).scrub if field["bytes"].is_a?(String)

        ""
      end

      # The collected stream rows become the final output (pi grep.ts
      # :276-302). The truncation totals carry the COUNTED rows — the
      # stored ones stop at the byte cap (#9276's :231 note), so the raw
      # content alone would understate them; pi overwrites both after
      # truncateHead and the port follows.
      def format_output(output_lines, match_count, match_limit_reached, effective_limit,
                        lines_truncated, output_line_count, output_bytes)
        return "No matches found" if match_count.zero?

        raw_output = output_lines.join("\n")
        truncation = Truncate.truncate_head(raw_output, max_lines: Float::MAX.to_i)
        truncation.total_lines = output_line_count
        truncation.total_bytes = output_bytes - 1
        output = truncation.content
        notices = []
        @details = {}
        if match_limit_reached
          notices << "#{effective_limit} matches limit reached. Use limit=#{effective_limit * 2} for more, " \
            "or refine pattern"
          @details[:match_limit_reached] = effective_limit
        end
        if truncation.truncated
          notices << "#{Truncate.format_size(Truncate::DEFAULT_MAX_BYTES)} limit reached"
          @details[:truncation] = truncation.to_h
        end
        if lines_truncated
          notices << "Some lines truncated to #{Truncate::GREP_MAX_LINE_LENGTH} chars. Use read tool to see full lines"
          @details[:lines_truncated] = true
        end
        output += "\n\n[#{notices.join('. ')}]" unless notices.empty?
        output
      end

      def format_path(file_path, search_path, is_directory)
        if is_directory
          relative = Pathname.new(file_path).relative_path_from(Pathname.new(search_path)).to_s
          return relative unless relative.empty? || relative.start_with?("..")
        end
        File.basename(file_path)
      end
    end
  end
end
