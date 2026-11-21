# frozen_string_literal: true

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
          matches, match_limit_reached, exit_ok = run_rg(
            rg_path, pattern, search_path, glob, ignore_case, literal, effective_limit
          )
          Fast::Completions::Cancellation.check
          raise ArgumentError, "ripgrep exited with code #{exit_ok}" unless exit_ok

          return "No matches found" if matches.empty?

          format_matches(matches, search_path, is_directory, context_value, effective_limit, match_limit_reached)
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

      # Streams `rg --json` lines until the match limit or EOF. Returns
      # [matches, match_limit_reached, exit_code_or_nil].
      #
      # I102 (KB I17 S1) — the deadline: rg spawns pgroup'd with stdin closed, and a
      # watchdog thread enforces TOOL_TIMEOUT_S (default 120; ENV parsed at
      # call time, non-numeric/absent/non-positive → the default). At the
      # deadline it kills rg's whole process GROUP (TERM, KILL escalation)
      # and closes the write-end copies so blocked reads EOF; every wait
      # below is bounded (WNOHANG poll ≤ REAP_BUDGET_SECONDS then detach;
      # err-drainer join 5 s then Thread#kill), and the call raises
      # ToolTimeout — the teaching refusal — instead of hanging the session.
      REAP_BUDGET_SECONDS = 5

      def run_rg(rg_path, pattern, search_path, glob, ignore_case, literal, effective_limit)
        timeout = tool_timeout_seconds
        args = ["--json", "--line-number", "--color=never", "--hidden"]
        args << "--ignore-case" if ignore_case
        args << "--fixed-strings" if literal
        args += ["--glob", glob] if glob
        args += ["--", pattern, search_path]

        matches = []
        match_limit_reached = false
        timed_out = false
        status = nil
        out_rd, out_wr = IO.pipe
        err_rd, err_wr = IO.pipe
        pid = Process.spawn(rg_path, *args, out: out_wr, err: err_wr, in: :close,
                                            pgroup: true, chdir: @cwd)
        out_wr.close
        err_wr.close
        stderr = +""
        err_t = Thread.new { stderr << err_rd.read }
        # TERM→KILL escalation is TIME-based, not send-failure-based: a
        # target that merely IGNORES TERM must not wedge the call (probed:
        # a rescue-only chain never escalates — the TERM send succeeds and
        # the stream read blocks forever). Grace, then a liveness probe on
        # the group, then KILL.
        watchdog = Thread.new do
          sleep(timeout)
          timed_out = true
          Process.kill("TERM", -pid) rescue nil
          sleep(KILL_GRACE_SECONDS)
          begin
            Process.kill(0, -pid)
            Process.kill("KILL", -pid)
          rescue StandardError
            nil # group already gone — TERM did the job
          end
          begin
            out_wr.close unless out_wr.closed?
            err_wr.close unless err_wr.closed?
          rescue IOError
            nil
          end
        end
        begin
          out_rd.each_line do |line|
            break if match_limit_reached

            event = safe_parse(line)
            next unless event&.fetch("type", nil) == "match"

            data = event["data"]
            matches << {file_path: data.dig("path", "text"), line_number: data["line_number"],
                        line_text: data.dig("lines", "text")}
            if matches.length >= effective_limit
              match_limit_reached = true
              Process.kill("TERM", pid) rescue Process.kill("KILL", pid) rescue nil
            end
          end
        ensure
          # Fast path (limit hit or EOF before the deadline): retire the
          # watchdog before it can fire under us, then reap with bounded
          # waits only — no unbounded waitpid, no unbounded join.
          unless timed_out
            watchdog.kill
          else
            # already fired: let the KILL escalation land (≤ grace + ε)
            watchdog.join(REAP_BUDGET_SECONDS)
            watchdog.kill
          end
          watchdog.join
          Process.kill("TERM", pid) rescue nil
          status = reap_rg(pid)
          err_t.join(REAP_BUDGET_SECONDS) || err_t.kill
          out_rd.close
          err_rd.close
        end
        raise ToolTimeout, timeout_message(pattern, search_path, glob, timeout) if timed_out

        killed_due_to_limit = match_limit_reached
        [matches, match_limit_reached, killed_due_to_limit ? 0 : status&.exitstatus]
      end

      # TOOL_TIMEOUT_S (I102, KB I17 S1) read at call time: a positive integer wins;
      # absent, non-numeric, or non-positive falls back to the 120 s default.
      KILL_GRACE_SECONDS = 2

      def tool_timeout_seconds
        raw = ENV["TOOL_TIMEOUT_S"]
        parsed = raw.is_a?(String) && raw.match?("\\A\\d+\\z") ? Integer(raw, 10) : nil
        parsed&.positive? ? parsed : DEFAULT_TIMEOUT_SECONDS
      end

      # Bounded reap: WNOHANG poll within REAP_BUDGET_SECONDS, then
      # Process.detach fallback — the session never blocks on a child that
      # refuses to die; nil stands in for the un-reaped status.
      def reap_rg(pid)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + REAP_BUDGET_SECONDS
        loop do
          waited, status = Process.waitpid2(pid, Process::WNOHANG)
          return status if waited
          break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

          sleep 0.05
        end
        Process.detach(pid)
        nil
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

      def format_matches(matches, search_path, is_directory, context_value, effective_limit, match_limit_reached)
        lines_truncated = false
        output_lines = matches.flat_map do |match|
          if context_value.zero? && match[:line_text]
            relative = format_path(match[:file_path], search_path, is_directory)
            sanitized = match[:line_text].gsub("\r\n", "\n").tr("\r", "").delete_suffix("\n")
            truncated = Truncate.truncate_line(sanitized)
            lines_truncated ||= truncated[:was_truncated]
            "#{relative}:#{match[:line_number]}: #{truncated[:text]}"
          else
            format_block(match[:file_path], match[:line_number], search_path, is_directory, context_value) do |was|
              lines_truncated ||= was
            end
          end
        end

        raw_output = output_lines.join("\n")
        truncation = Truncate.truncate_head(raw_output, max_lines: Float::MAX.to_i)
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

      # Context blocks: `path:line: text` for the match line,
      # `path-line- text` for context (pi's formatBlock).
      def format_block(file_path, line_number, search_path, is_directory, context_value)
        relative = format_path(file_path, search_path, is_directory)
        lines = file_lines(file_path)
        return ["#{relative}:#{line_number}: (unable to read file)"] if lines.empty?

        start = context_value.positive? ? [1, line_number - context_value].max : line_number
        finish = context_value.positive? ? [lines.length, line_number + context_value].min : line_number
        (start..finish).map do |current|
          line_text = lines[current - 1] || ""
          sanitized = line_text.tr("\r", "")
          truncated = Truncate.truncate_line(sanitized)
          yield truncated[:was_truncated]
          if current == line_number
            "#{relative}:#{current}: #{truncated[:text]}"
          else
            "#{relative}-#{current}- #{truncated[:text]}"
          end
        end
      end

      def file_lines(file_path)
        File.read(file_path).gsub("\r\n", "\n").tr("\r", "\n").split("\n")
      rescue StandardError
        []
      end
    end
  end
end
