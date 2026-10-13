# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"

module Tart
  # Basic behavior of the find/grep/ls tools (pi semantics: sorting, '/ '
  # suffixes, limits, notices, pi's output text).
  class ToolsTest < Test
    def setup
      @dir = Dir.mktmpdir("tart-tools-")
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

      # Tools execute unconditionally (pi agent-loop.ts:832): the full
      # loadout instantiates bare, nothing extended, nothing gated.
      all = Tools::Registry.build(selected: Tools::ALL, cwd: @dir)
      assert_equal Tools::ALL.sort, all.keys.sort
    end

    # I41 (AC2): the SELECTED list's order is the wire order — pi
    # _applyToolLoadout iterates the name list in order (agent-session.ts
    # :1571-1581). At the default configuration the request's tools array
    # is exactly [read, bash, edit, write], pi's captured wire order.
    def test_registry_preserves_the_selected_order
      assert_equal %w[read bash edit write],
        Tools::Registry.build(selected: Settings.selected_tools({}), cwd: @dir).keys
      assert_equal %w[write find read], Tools::Registry.build(selected: %w[write find read], cwd: @dir).keys,
        "modifier-resolved lists declare in resolved order too"
    end

    def test_registry_rejects_unknown_tools
      assert_raises(ArgumentError) { Tools::Registry.build(selected: %w[rm_rf], cwd: @dir) }
    end

    # ---- §5 toggle seam: write-boundary trailing-whitespace strip ----

    def test_registry_plumbs_strip_toggle_to_edit_and_write
      tools = Tools::Registry.build(selected: Tools::ALL, cwd: @dir, strip_trailing_whitespace: true)
      assert tools.fetch("write").instance_variable_get(:@strip_trailing_whitespace)
      assert tools.fetch("edit").instance_variable_get(:@strip_trailing_whitespace)

      default = Tools::Registry.build(selected: Tools::ALL, cwd: @dir)
      refute default.fetch("write").instance_variable_get(:@strip_trailing_whitespace)
      refute default.fetch("edit").instance_variable_get(:@strip_trailing_whitespace)
    end

    def test_write_default_stays_byte_verbatim
      content = "trailing spaces  \ntab\t\nlast line no newline"
      Tools::Write.new(cwd: @dir).execute(path: "off.txt", content:)
      assert_equal content, File.binread(File.join(@dir, "off.txt"))
    end

    def test_write_on_strips_trailing_spaces_and_tabs_per_line
      content = "spaces  \ttabs\t  \n\t  \nnone\r\nno trailing newline  "
      result = Tools::Write.new(cwd: @dir, strip_trailing_whitespace: true).execute(path: "on.txt", content:)

      assert_equal "Successfully wrote to on.txt", result
      # Internal runs preserved; whitespace-only line strips to empty; the
      # space before \r stays (lines split on "\n" — spec-literal).
      assert_equal "spaces  \ttabs\n\nnone\r\nno trailing newline",
        File.binread(File.join(@dir, "on.txt"))
    end

    def test_write_on_preserves_line_count_and_final_newline_presence
      # Final newline present.
      Tools::Write.new(cwd: @dir, strip_trailing_whitespace: true).execute(path: "nl.txt", content: "a  \nb\t\n")
      assert_equal "a\nb\n", File.binread(File.join(@dir, "nl.txt"))

      # Final newline absent.
      Tools::Write.new(cwd: @dir, strip_trailing_whitespace: true).execute(path: "no-nl.txt", content: "a  \nb\t")
      assert_equal "a\nb", File.binread(File.join(@dir, "no-nl.txt"))
    end

    def test_edit_default_stays_byte_verbatim
      path = File.join(@dir, "off.txt")
      File.binwrite(path, "alpha\nbeta  \n")
      result = Tools::Edit.new(cwd: @dir).execute(path: "off.txt", edits: [{old_text: "alpha", new_text: "ALPHA  "}])

      assert_equal "Successfully replaced 1 block(s) in off.txt.", result
      assert_equal "ALPHA  \nbeta  \n", File.binread(path)
    end

    def test_edit_on_strips_trailing_whitespace_from_committed_bytes
      path = File.join(@dir, "on.txt")
      File.binwrite(path, "alpha\nbeta  \n")
      result = Tools::Edit.new(cwd: @dir, strip_trailing_whitespace: true)
        .execute(path: "on.txt", edits: [{old_text: "alpha", new_text: "ALPHA  "}])

      assert_equal "Successfully replaced 1 block(s) in on.txt.", result
      assert_equal "ALPHA\nbeta\n", File.binread(path)
    end

    def test_edit_on_preserves_line_count_and_final_newline_presence
      path = File.join(@dir, "crlf.txt")
      File.binwrite(path, "a\r\nb  \r\n")
      result = Tools::Edit.new(cwd: @dir, strip_trailing_whitespace: true)
        .execute(path: "crlf.txt", edits: [{old_text: "a", new_text: "A  "}])

      assert_equal "Successfully replaced 1 block(s) in crlf.txt.", result
      # Line count (2), CRLF endings, and every non-trailing byte identical;
      # the space before \r is untouched (lines split on "\n" — spec-literal).
      assert_equal "A  \r\nb  \r\n", File.binread(path)
    end

    # ---- I43: the input-validation seam (wrong-typed args come back as
    # pi's loop-level wrapper vocabulary; runtime raises stay raises) ----

    def assert_wrapper_error(result, pi_name)
      assert result.is_a?(Hash) && result.key?(:error), "expected an {error:} result, got #{result.inspect}"
      assert result[:error].start_with?("Validation failed for tool \"#{pi_name}\":\n  - "),
        "#{result[:error].inspect} lacks the wrapper vocabulary"
      assert_includes result[:error], "Received arguments:", "the wrapper carries the received arguments"
    end

    def test_wrong_typed_args_reject_with_the_wrapper_vocabulary
      assert_wrapper_error Tools::Ls.new(cwd: @dir).execute(limit: "x"), "ls"
      assert_wrapper_error Tools::Grep.new(cwd: @dir).execute(pattern: 5), "grep"
      assert_wrapper_error Tools::Grep.new(cwd: @dir).execute(pattern: "hello", ignore_case: "yes"), "grep"
      assert_wrapper_error Tools::Find.new(cwd: @dir).execute(pattern: "*.rb", limit: {}), "find"
      assert_wrapper_error Tools::Write.new(cwd: @dir).execute(path: "w.txt", content: 5), "write"
      assert_wrapper_error Tools::Read.new(cwd: @dir).execute(path: "apple.txt", offset: "x"), "read"
    end

    def test_valid_args_still_execute_through_the_seam
      assert Tools::Ls.new(cwd: @dir).execute
      assert_includes Tools::Grep.new(cwd: @dir).execute(pattern: "hello", ignore_case: true), "hello world"
      assert_includes Tools::Read.new(cwd: @dir).execute(path: "apple.txt", offset: 1), "one"
    end
  end
end
