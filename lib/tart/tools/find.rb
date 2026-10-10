# frozen_string_literal: true

require_relative "safe_execute"

module Tart
  module Tools
    # The find tool (port of pi's find.ts): glob search returning paths
    # relative to the search root, .gitignore-aware, truncated to 1000
    # results or 50KB.
    #
    # Parity note: pi downloads the `fd` binary at runtime (ensureTool); the
    # port uses `fd` from PATH and pi's error message when it is missing —
    # recorded deviation (no runtime downloads).
    class Find < RubyLLM::Tool
      include SafeExecute

      pi_name "find"

      DEFAULT_LIMIT = 1000

      DESCRIPTION = "Search for files by glob pattern. Returns matching file paths relative to the search " \
        "directory. Respects .gitignore. Output is truncated to 1000 results or 50KB (whichever is hit first)."

      PARAMETERS_SCHEMA = {
        type: "object",
        properties: {
          "pattern" => {type: "string",
                        description: "Glob pattern to match files, e.g. '*.ts', '**/*.json', or 'src/**/*.spec.ts'"},
          "path" => {type: "string", description: "Directory to search in (default: current directory)"},
          "limit" => {type: "number", description: "Maximum number of results (default: 1000)"}
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

      # @return [String] newline-joined relative paths, or {error:} on failure.
      def execute(pattern:, path: nil, limit: nil)
        safe_execute do
          RubyLLM::Support::Cancellation.check
          fd_path = fd_binary
          raise ArgumentError, "fd is not available and could not be downloaded" unless fd_path

          search_path = PathUtils.resolve_to_cwd(path || ".", @cwd)
          raise ArgumentError, "Path not found: #{search_path}" unless File.exist?(search_path)

          effective_limit = limit || DEFAULT_LIMIT
          args = ["--glob", "--color=never", "--hidden"]
          args << "--no-require-git" unless inside_git_repo?(search_path)
          args += ["--max-results", effective_limit.to_s]
          effective_pattern = pattern
          if pattern.include?("/")
            args << "--full-path"
            if !pattern.start_with?("/", "**/") && pattern != "**"
              effective_pattern = "**/#{pattern}"
            end
          end
          args += ["--", effective_pattern, search_path]

          stdout, stderr, status = run_fd(fd_path, args)
          RubyLLM::Support::Cancellation.check

          unless status.exitstatus == 0 || status.exitstatus == 1
            error_message = stderr.strip.empty? ? "fd exited with code #{status.exitstatus}" : stderr.strip
            raise ArgumentError, error_message if stdout.empty?

            return format_results(stdout.split("\n"), search_path, effective_limit)
          end
          return "No files found matching pattern" if stdout.strip.empty?

          format_results(stdout.split("\n"), search_path, effective_limit)
        end
      end

      private

      def fd_binary
        @fd_binary ||= find_on_path("fd")
      end

      def find_on_path(name)
        paths = ENV["PATH"].to_s.split(File::PATH_SEPARATOR)
        paths.lazy.map { |dir| File.join(dir, name) }.find { |candidate| File.file?(candidate) && File.executable?(candidate) }
      end

      # pi walks up from the search path looking for a .git directory so that
      # fd's default git-aware ignore behavior only applies inside repos.
      def inside_git_repo?(search_path)
        current = search_path
        loop do
          return true if File.exist?(File.join(current, ".git"))

          parent = File.dirname(current)
          break if parent == current

          current = parent
        end
        false
      end

      def run_fd(fd_path, args)
        stdout = +"" # steep:ignore
        stderr = +""
        out_rd, out_wr = IO.pipe
        err_rd, err_wr = IO.pipe
        pid = Process.spawn(fd_path, *args, out: out_wr, err: err_wr, chdir: @cwd)
        out_wr.close
        err_wr.close
        out_t = Thread.new { stdout << out_rd.read }
        err_t = Thread.new { stderr << err_rd.read }
        _, status = Process.waitpid2(pid)
        out_t.join
        err_t.join
        out_rd.close
        err_rd.close
        [stdout, stderr, status]
      rescue RubyLLM::CancelledError
        Process.kill("TERM", pid) if pid
        raise
      end

      def format_results(lines, search_path, effective_limit)
        relativized = lines.map { |line| line.delete_suffix("\r").strip }
                           .reject(&:empty?)
                           .map { |line| relativize_find_result_path(line, search_path) }

        result_limit_reached = relativized.length >= effective_limit
        raw_output = relativized.join("\n")
        truncation = Truncate.truncate_head(raw_output, max_lines: Float::MAX.to_i)
        result_output = truncation.content
        notices = []
        @details = {}
        if result_limit_reached
          notices << "#{effective_limit} results limit reached. Use limit=#{effective_limit * 2} for more, " \
            "or refine pattern"
          @details[:result_limit_reached] = effective_limit
        end
        if truncation.truncated
          notices << "#{Truncate.format_size(Truncate::DEFAULT_MAX_BYTES)} limit reached"
          @details[:truncation] = truncation.to_h
        end
        result_output += "\n\n[#{notices.join('. ')}]" unless notices.empty?
        result_output
      end

      # pi's relativizeFindResultPath: results are relative to the search
      # root with posix separators; a trailing separator is preserved.
      def relativize_find_result_path(result_path, search_path)
        had_trailing_separator = result_path.end_with?(File::SEPARATOR)
        relative_path = result_path.start_with?("/") ? Pathname.new(result_path).relative_path_from(Pathname.new(search_path)).to_s : result_path
        posix_path = relative_path
        had_trailing_separator && !posix_path.end_with?("/") ? "#{posix_path}/" : posix_path
      end
    end
  end
end
