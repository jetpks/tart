# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/parallel_runner"
require "tmpdir"
require "fileutils"

module Tart
  # The I84 parallel-runner pin battery (arch Law 3): hermetic pins for the
  # runner's laws — enumeration determinism, the shard bijection, jobs
  # validation, merge aggregation on SYNTHETIC worker results, the coverage
  # audit, and the canonical-set pin against the Rakefile's own text. NO
  # live full-suite legs (the heavy legs live in the frozen gates);
  # mktmpdir staging only, no global mutation — the battery is shard-safe
  # by construction and grows the suite by exactly its run count.
  class ParallelRunnerTest < Test
    ROOT = File.expand_path("..", __dir__)

    # The enumeration subprocess writes one log + the method→file
    # attribution map into a class-level scratch (the list itself is
    # memoized — the battery spawns at most three enumeration children
    # across all its tests).
    ENUM_SCRATCH = Dir.mktmpdir("i84-pins-enum-")
    Minitest.after_run { FileUtils.rm_rf(ENUM_SCRATCH) }

    def self.enum_scratch
      ENUM_SCRATCH
    end

    # A Process::Status double for synthetic merge-law results (a real
    # Process::Status cannot be fabricated; the merge law reads only
    # .success?/.exitstatus of this stdlib type).
    FakeStatus = Struct.new(:exitstatus) do
      def success?
        exitstatus.zero?
      end
    end

    def setup
      @tmp = Dir.mktmpdir("i84-pins-")
    end

    def teardown
      FileUtils.rm_rf(@tmp)
    end

    def enum_list
      self.class.enum_list
    end

    def self.enum_list
      @enum_list ||= ParallelRunner.enumerate(root: ROOT, scratch: ENUM_SCRATCH, pids: [])
    end

    # --- Law 1.1: the canonical set pin ----------------------------------

    def test_canonical_files_match_the_rakefile_filelist
      text = File.read(File.join(ROOT, "Rakefile"))
      globs = text[/FileList\[(.*?)\]/m, 1].scan(/"([^"]+)"/).flatten
      assert_equal ParallelRunner::CANONICAL_GLOBS, globs,
        "the Rakefile's FileList globs moved — the runner's canonical set must be re-derived"
      expected = globs.flat_map { |g| Dir.glob(File.join(ROOT, g)) }.sort
      assert_equal expected, ParallelRunner.canonical_files(ROOT),
        "the runner's canonical set must equal the Rakefile's own FileList"
      assert ParallelRunner.canonical_files(ROOT).any? { |f| f.include?("gems/tui-split-rig/") },
        "the canonical set must sweep BOTH trees"
      assert_operator ParallelRunner.canonical_files(ROOT).size, :>=, 60,
        "the canonical set collapsed — the suite has ~66 test files at base"
    end

    # --- Law 1.2: enumeration -------------------------------------------

    def test_enumeration_is_deterministic_across_passes
      first = ParallelRunner.enumerate(root: ROOT, scratch: @tmp, pids: [])
      second = ParallelRunner.enumerate(root: ROOT, scratch: @tmp, pids: [])
      assert_equal first, second, "two enumeration passes must be byte-identical"
    end

    def test_enumeration_is_sorted_full_form_and_full_suite
      list = enum_list
      assert_equal list.sort, list, "the enumeration dump must be sorted"
      list.each do |entry|
        assert_match(/\A[\w:]+#test_\w+\z/, entry, "not a full Klass#method entry: #{entry}")
      end
      assert_operator list.size, :>=, 1400,
        "the enumerated set collapsed — the suite enumerates ~1474 tests at base"
    end

    # --- Law 1.3: the shard bijection ------------------------------------

    def test_shard_bijection_union_disjoint_balance_for_jobs_1_3_8
      list = enum_list
      [1, 3, 8].each do |jobs|
        shards = ParallelRunner.shard(list, jobs)
        flat = shards.flatten
        assert_equal list, flat.sort, "jobs=#{jobs}: the shard union != the full enumerated set"
        assert_equal flat.size, flat.uniq.size, "jobs=#{jobs}: a test is sharded twice (not disjoint)"
        sizes = shards.map(&:size)
        assert_operator sizes.max - sizes.min, :<=, 1, "jobs=#{jobs}: shard sizes not within 1 of each other"
        assert_operator sizes.min, :>=, 1, "jobs=#{jobs}: an empty shard (a worker would refuse to run)"
        shards.each_with_index do |shard, i|
          assert_equal list.select.with_index { |_n, idx| (idx % jobs) == i }, shard,
            "jobs=#{jobs}: worker #{i} is not its round-robin slice (indices ≡ i mod #{jobs})"
        end
      end
    end

    def test_shard_is_deterministic_for_repeated_calls
      assert_equal ParallelRunner.shard(enum_list, 8), ParallelRunner.shard(enum_list, 8)
    end

    # --- Law 7: jobs -----------------------------------------------------

    def test_jobs_default_is_8
      assert_equal 8, ParallelRunner.parse_jobs({})
    end

    def test_jobs_env_override_honored
      [1, 3, 8, 32].each do |n|
        assert_equal n, ParallelRunner.parse_jobs({"TART_TEST_JOBS" => n.to_s})
      end
    end

    def test_jobs_out_of_range_refused_loudly
      ["0", "33", "-1", "abc", ""].each do |raw|
        e = assert_raises(SystemExit) { ParallelRunner.parse_jobs({"TART_TEST_JOBS" => raw}) }
        assert_equal 1, e.status, "#{raw.inspect}: the refusal must be nonzero"
        assert_match(/TART_TEST_JOBS=#{Regexp.escape(raw.inspect)}/, e.message)
        assert_match(/1\.\.32/, e.message, "#{raw.inspect}: the refusal must name the valid range")
      end
    end

    def test_run_refuses_bad_jobs_before_any_spawn
      # parse_jobs is run()'s FIRST act — a reordered run would fail with an
      # enumeration/spawn error message instead of this refusal.
      e = assert_raises(SystemExit) { ParallelRunner.run(root: ROOT, env: {"TART_TEST_JOBS" => "0"}) }
      assert_equal 1, e.status
      assert_match(/refusing before any spawn/, e.message)
    end

    # --- Law 4: worker command shape -------------------------------------

    def test_filter_for_escapes_the_full_klass_method_form
      filter = ParallelRunner.filter_for(["Tart::Foo#test_bar", "Tart::Baz#test_qux"])
      assert_equal "/Tart::Foo\\#test_bar|Tart::Baz\\#test_qux/", filter,
        "the worker filter must be the Regexp-escaped alternation of FULL Klass#method entries"
    end

    def test_worker_files_load_the_shard_definers
      dir = Dir.mktmpdir("i84-pins-files-")
      a = File.join(dir, "a_test.rb")
      b = File.join(dir, "b_test.rb")
      File.write(a, "class ATest\n  def test_alpha; end\nend\n")
      File.write(b, "class BTest\n  def test_beta; end\nend\n")
      map = {"ATest#test_alpha" => a, "BTest#test_beta" => b}
      assert_equal [a], ParallelRunner.worker_files([a, b], map, ["ATest#test_alpha"])
      assert_equal [a, b], ParallelRunner.worker_files([a, b], map, ["ATest#test_alpha", "BTest#test_beta"])
      # Belt: a method the attribution cannot place falls back to the FULL
      # set — a worker may slow down, never silently drop a test.
      assert_equal [a, b], ParallelRunner.worker_files([a, b], map, ["ATest#test_exotic"])
    ensure
      FileUtils.rm_rf(dir)
    end

    def test_enumeration_attributes_every_method_to_its_defining_file
      list = enum_list
      map = ParallelRunner.attrib_map(File.join(self.class.enum_scratch, "attrib.log"))
      missing = list.select { |name| map[name].nil? }
      assert_empty missing, "every enumerated method must be attributed to a file"
      unplaced = list.select { |name| !map[name].start_with?(ROOT) }
      assert_empty unplaced, "every attributed file must live under the repo root"
      assert_equal [File.join(ROOT, "test/markdown_test.rb")],
        [map["Tart::MarkdownTest#test_md_battery_link_basic"]],
        "metaprogrammed define_method tests must attribute to their real defining file"
    end

    # --- Law 5: merge on synthetic results -------------------------------

    def synthetic_result(index:, shard_size:, runs: 0, assertions: 0, failures: 0,
      errors: 0, skips: 0, exitstatus: 0, log: nil)
      text = log || "#{runs} runs, #{assertions} assertions, #{failures} failures, " \
                    "#{errors} errors, #{skips} skips\n"
      ParallelRunner::Result.new(index: index, shard_size: shard_size, seed: 12_345 + index,
        files: [], pid: nil, status: FakeStatus.new(exitstatus), log_path: "/dev/null", log_text: text)
    end

    def test_merge_law_all_green_sums_to_success_and_the_parallel_ok_literal
      results = [synthetic_result(index: 0, shard_size: 3, runs: 3, assertions: 9),
        synthetic_result(index: 1, shard_size: 2, runs: 2, assertions: 5)]
      ParallelRunner.merge!(results)
      assert_equal({runs: 5, assertions: 14, failures: 0, errors: 0, skips: 0}, ParallelRunner.totals(results))
      line = ParallelRunner.verdict_line(results, 51.23, true)
      assert_match(/\APARALLEL_OK runs=5 assertions=14 failures=0 errors=0 skips=0 workers=2 wall=51\.2s\z/, line)
    end

    def test_merge_law_any_failure_is_nonzero_with_the_worker_attributed
      results = [synthetic_result(index: 0, shard_size: 3, runs: 3, assertions: 9),
        synthetic_result(index: 1, shard_size: 2, runs: 2, assertions: 3, failures: 1)]
      ParallelRunner.merge!(results)
      red = results.any? { |w| !w.status.success? || (w.failures + w.errors).positive? }
      assert red, "a worker with a failure must turn the merge red"
      line = ParallelRunner.verdict_line(results, 10.0, false)
      assert_match(/\APARALLEL_FAIL runs=5 assertions=12 failures=1 errors=0 skips=0 workers=2 wall=/, line)
      assert_equal [1], results.select { |w| !w.status.success? || (w.failures + w.errors).positive? }
        .map(&:index), "the failing worker must be attributed by index"
      assert_match(/worker=1 .* FAIL/, ParallelRunner.attribution_lines(results)[1])
    end

    def test_merge_law_any_crash_is_nonzero_with_the_worker_attributed
      results = [synthetic_result(index: 0, shard_size: 3, runs: 3, assertions: 9),
        synthetic_result(index: 1, shard_size: 2, exitstatus: 1, log: "worker crashed: Nothing ran for filter\n")]
      ParallelRunner.merge!(results)
      red = results.any? { |w| !w.status.success? || (w.failures + w.errors).positive? }
      assert red, "a crashed worker (nonzero exit, no summary) must turn the merge red"
      assert_equal 0, results[1].runs, "a crashed worker parses as zero counts — the exit code carries the verdict"
      assert_match(/worker=1 .* ec=1 FAIL/, ParallelRunner.attribution_lines(results)[1])
    end

    # --- Law 6: the coverage audit ---------------------------------------

    def test_coverage_audit_passes_when_every_worker_matches_its_shard
      results = [synthetic_result(index: 0, shard_size: 3, runs: 3, assertions: 9),
        synthetic_result(index: 1, shard_size: 2, runs: 2, assertions: 5)]
      ParallelRunner.merge!(results)
      ok, line, detail = ParallelRunner.coverage(results, 5)
      assert ok
      assert_equal "COVERAGE_OK runs=5 enum=5", line, "the frozen gate greps this exact literal"
      assert_nil detail
    end

    def test_coverage_audit_fails_loudly_on_a_discrepancy
      results = [synthetic_result(index: 0, shard_size: 3, runs: 3, assertions: 9),
        synthetic_result(index: 1, shard_size: 2, runs: 1, assertions: 2)]
      ParallelRunner.merge!(results)
      ok, line, detail = ParallelRunner.coverage(results, 5)
      refute ok, "summed runs (4) != enumerated total (5) must fail the audit"
      assert_match(/\ACOVERAGE_FAIL runs=4 enum=5\z/, line)
      assert_match(/worker=1 ran 1 for a shard of 2/, detail.join("\n"))
    end
  end
end