# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"

module RaspberryPi
  # Basic behavior of the find/grep/ls tools (pi semantics: sorting, '/ '
  # suffixes, limits, notices, pi's output text).
  class ToolsTest < Test
    def setup
      @dir = Dir.mktmpdir("raspberry-pi-tools-")
      Dir.mkdir(File.join(@dir, "sub"))
      File.write(File.join(@dir, "apple.txt"), "one\n")
      File.write(File.join(@dir, "banana.md"), "hello world\n")
      File.write(File.join(@dir, "sub", "cherry.rb"), "x = 1\ny = 2\n")
      File.write(File.join(@dir, "sub", "deep.rb"), "hello here\n")
    end

    def teardown
      FileUtils.rm_rf(@dir)
    end

    def test_ls_sorts_case_insensitively_with_directory_slashes
      result = Tools::Ls.new(cwd: @dir).execute
      lines = result.split("\n")
      assert_equal ["apple.txt", "banana.md", "sub/", "apple.txt"].first(3), lines.first(3)
      assert lines.last.end_with?("sub/")
    end

    def test_ls_limit_notice
      result = Tools::Ls.new(cwd: @dir).execute(limit: 2)
      assert_includes result, "[2 entries limit reached. Use limit=4 for more]"
    end

    def test_ls_missing_path
      result = Tools::Ls.new(cwd: @dir).execute(path: "nope")
      assert result.key?(:error)
      assert_includes result[:error], "Path not found:"
    end

    def test_find_respects_limit_and_relativizes
      result = Tools::Find.new(cwd: @dir).execute(pattern: "*.rb", path: "sub")
      assert_includes result, "cherry.rb"
      assert_includes result, "deep.rb"
      refute_includes result, "/"
      # no leading directories in results
      refute result.split("\n").first.to_s.start_with?(@dir)
    end

    def test_find_full_path_pattern
      result = Tools::Find.new(cwd: @dir).execute(pattern: "sub/**/*.rb")
      assert_includes result, "cherry.rb"
    end

    def test_find_no_matches
      result = Tools::Find.new(cwd: @dir).execute(pattern: "*.zzz")
      assert_equal "No files found matching pattern", result
    end

    def test_grep_matches_with_relative_paths
      result = Tools::Grep.new(cwd: @dir).execute(pattern: "hello")
      assert_includes result, "banana.md:1: hello world"
      assert_includes result, "sub/deep.rb:1: hello here"
    end

    def test_grep_literal_and_ignore_case
      result = Tools::Grep.new(cwd: @dir).execute(pattern: "HELLO", ignore_case: true)
      assert_includes result, "hello world"
      literal = Tools::Grep.new(cwd: @dir).execute(pattern: "x =", path: "sub")
      assert_includes literal, "cherry.rb:1: x = 1"
    end

    def test_grep_context_blocks
      result = Tools::Grep.new(cwd: @dir).execute(pattern: "y = 2", path: "sub", context: 1)
      assert_includes result, "cherry.rb-1- x = 1"
      assert_includes result, "cherry.rb:2: y = 2"
    end

    def test_grep_no_matches
      result = Tools::Grep.new(cwd: @dir).execute(pattern: "zzz-nowhere")
      assert_equal "No matches found", result
    end

    def test_grep_long_lines_truncated
      File.write(File.join(@dir, "long.txt"), "needle #{'z' * 900}")
      result = Tools::Grep.new(cwd: @dir).execute(pattern: "needle")
      assert_includes result, "... [truncated]"
      assert_includes result, "Some lines truncated to 500 chars"
    end

    def test_registry_schema_gating
      tools = Tools::Registry.build(selected: %w[read ls], cwd: @dir)
      assert_equal %w[ls read], tools.keys.sort
      refute Tools::Registry.approval_required?("read")

      destructive = Tools::Registry.build(selected: Tools::ALL, cwd: @dir)
      Tools::DESTRUCTIVE.each do |name|
        assert destructive.fetch(name).requires_approval?,
          "#{name} must gate behind approval"
      end
      %w[read find grep ls].each do |name|
        refute destructive.fetch(name).requires_approval?
      end
    end

    def test_registry_rejects_unknown_tools
      assert_raises(ArgumentError) { Tools::Registry.build(selected: %w[rm_rf], cwd: @dir) }
    end
  end
end
