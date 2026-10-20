# frozen_string_literal: true

require_relative "../../../test/test_helper"
require "json"
require "open3"

module TuiSplitRig
  # The sweep wrapper's frozen contract (I83 Laws 1-8), pinned against the
  # real binary — the cli_test.rb pattern (Open3, public interface only).
  #
  # Hermetic legs (always run in-suite, no app boots — the suite grows
  # additively by exactly these): --list set selection, the flag refusal
  # vocabulary, --jobs default, and the out-dir geometry law.
  # Live aggregation legs ({s1}->0, {s1,s1_tart}->1, {s1,missing yml}->2,
  # the report shape) boot real apps and ride TUI_SPLIT_RIG_LIVE=1 — the
  # live_run_test discipline (the sweep-units gate sets it).
  class SweepTest < Tart::Test
    REPO_ROOT = File.expand_path("#{__dir__}/../../..")
    RIG_ROOT = File.join(REPO_ROOT, "gems/tui-split-rig")
    SWEEP = File.join(RIG_ROOT, "bin/tui-split-rig-sweep")
    SCENARIOS = File.join(RIG_ROOT, "scenarios")

    # Law 1's discovery source, mirrored: the s*.yml battery (sorted by
    # filename) and the opt-in probes.
    BATTERY = Dir.glob(File.join(SCENARIOS, "s*.yml")).sort
                  .map { |p| File.basename(p, ".yml") }.freeze
    PROBES = Dir.glob(File.join(SCENARIOS, "probe_*.yml")).sort
                .map { |p| File.basename(p, ".yml") }.freeze

    def test_list_default_set_is_the_sorted_s_battery
      output, = sweep_cmd("--list")
      jobs, entries = parse_plan(output)
      assert_equal 8, jobs, "--jobs defaults to 8"
      assert_equal 19, entries.size, "the s-battery is 19 scenarios today"
      assert_equal BATTERY, entries.map { |e| e.fetch(:name) }
      assert_includes entries.map { |e| e.fetch(:name) }, "s1_tart",
        "s1_tart matches s*.yml and IS a battery member"
    end

    def test_probes_add_the_three_probe_ymls
      output, = sweep_cmd("--list", "--probes")
      _jobs, entries = parse_plan(output)
      assert_equal 22, entries.size
      assert_equal (BATTERY + PROBES).sort, entries.map { |e| e.fetch(:name) }
    end

    def test_only_selects_the_exact_subset_in_set_order
      output, = sweep_cmd("--list", "--only", "s2_tool_turn,s3_tool_turn_files")
      jobs, entries = parse_plan(output)
      assert_equal 8, jobs
      assert_equal %w[s2_tool_turn s3_tool_turn_files], entries.map { |e| e.fetch(:name) }
      assert_equal %w[sw-01 sw-02], entries.map { |e| File.basename(e.fetch(:out)) },
        "ordinals restart at 1 in the restricted set"
    end

    def test_unknown_only_name_is_refused_loudly_naming_it
      output, status = sweep_cmd("--list", "--only", "nope_not_a_scenario")
      assert_equal 2, status.exitstatus, output
      assert_includes output, "nope_not_a_scenario"
    end

    def test_unknown_flag_exits_two
      output, status = sweep_cmd("--frobnicate")
      assert_equal 2, status.exitstatus, output
    end

    def test_out_dirs_are_unique_disjoint_and_inside_the_green_window
      output, = sweep_cmd("--list")
      _jobs, entries = parse_plan(output)
      outs = entries.map { |e| e.fetch(:out) }
      assert_equal outs.uniq, outs, "assigned out dirs are unique"
      outs.each do |out|
        assert(out.start_with?("#{REPO_ROOT}/"), "default-root out dir under the repo root: #{out}")
        rel = out.delete_prefix("#{REPO_ROOT}/")
        assert_match(/\Asw-\d+\z/, rel)
        assert(rel.length <= 20, "out dir #{rel.inspect} (#{rel.length} chars) inside the <=20-char green geometry window")
      end
    end

    def test_paths_resolve_from_the_scripts_own_dir_not_the_cwd
      # Law 3: invocation works from any cwd — the yml paths and default
      # out root must not drift with Dir.pwd.
      output, = sweep_cmd("--list")
      _jobs, entries = parse_plan(output)
      entries.each do |e|
        assert File.file?(e.fetch(:yml)), "yml path resolves absolutely: #{e.fetch(:yml)}"
      end
    end

    # ---- Live legs (TUI_SPLIT_RIG_LIVE=1 — the sweep-units gate sets it) ----

    def test_live_single_scenario_sweep_aggregates_zero
      skip "set TUI_SPLIT_RIG_LIVE=1 to run the live sweep legs" unless live?
      root = live_root("a")
      output, status = sweep_cmd("--only", "s1_text_turn", "--out", root)
      assert_equal 0, status.exitstatus, output
      report = read_report(root)
      assert_equal 0, report.fetch("aggregate_exit_code")
      assert_equal [["s1_text_turn", 0]],
        report.fetch("scenarios").map { |s| [s.fetch("name"), s.fetch("exit_code")] }
    ensure
      FileUtils.rm_rf(root) if defined?(root) && root
    end

    def test_live_tart_face_code_surfaces_as_one
      skip "set TUI_SPLIT_RIG_LIVE=1 to run the live sweep legs" unless live?
      root = live_root("b")
      output, status = sweep_cmd("--only", "s1_text_turn,s1_tart", "--out", root)
      assert_equal 1, status.exitstatus, "the tart-face ec surfaces as the aggregate: #{output}"
      report = read_report(root)
      codes = report.fetch("scenarios").map { |s| [s.fetch("name"), s.fetch("exit_code")] }.to_h
      assert_equal 0, codes.fetch("s1_text_turn")
      assert_equal 1, codes.fetch("s1_tart")
      assert_equal 1, report.fetch("aggregate_exit_code")
    ensure
      FileUtils.rm_rf(root) if defined?(root) && root
    end

    def test_live_missing_yml_child_failure_aggregates_two
      skip "set TUI_SPLIT_RIG_LIVE=1 to run the live sweep legs" unless live?
      root = live_root("c")
      missing = File.join(root, "no-such-scenario.yml")
      output, status = sweep_cmd("--only", "s1_text_turn,#{missing}", "--out", root)
      assert_equal 2, status.exitstatus, "a failed child aggregates to 2: #{output}"
      report = read_report(root)
      codes = report.fetch("scenarios").map { |s| [s.fetch("name"), s.fetch("exit_code")] }.to_h
      assert_equal 0, codes.fetch("s1_text_turn")
      assert_equal 2, codes.fetch("no-such-scenario")
      assert_equal 2, report.fetch("aggregate_exit_code")
      # The child's own refusal stays loud (Law 8) — captured in its log.
      entry = report.fetch("scenarios").find { |s| s.fetch("name") == "no-such-scenario" }
      assert_match(/no such scenario file/, File.read("#{entry.fetch('out_dir')}.log"))
    ensure
      FileUtils.rm_rf(root) if defined?(root) && root
    end

    def test_live_report_shape
      skip "set TUI_SPLIT_RIG_LIVE=1 to run the live sweep legs" unless live?
      root = live_root("d")
      output, status = sweep_cmd("--only", "s1_text_turn", "--out", root)
      assert_equal 0, status.exitstatus, output
      report = read_report(root)
      assert_equal %w[aggregate_exit_code jobs scenarios set wall_ms], report.keys.sort
      assert_equal %w[s1_text_turn], report.fetch("set")
      assert_equal 8, report.fetch("jobs")
      scenario = report.fetch("scenarios").first
      assert_equal %w[exit_code name out_dir path wall_ms], scenario.keys.sort
      assert_equal 0, scenario.fetch("exit_code")
      assert_operator scenario.fetch("wall_ms"), :>, 0
      assert File.directory?(scenario.fetch("out_dir"))
      assert_operator report.fetch("wall_ms"), :>, 0
      assert_equal report.fetch("scenarios").map { |s| s.fetch("exit_code") }.max,
        report.fetch("aggregate_exit_code"), "aggregate = max(per-scenario codes)"
    ensure
      FileUtils.rm_rf(root) if defined?(root) && root
    end

    private

    def live?
      ENV["TUI_SPLIT_RIG_LIVE"] == "1"
    end

    # Scratch root DIRECTLY under the repo root and hyphen-free: the
    # sweep's per-scenario dirs must stay inside the <= 20-char green
    # geometry window (Law 3 — the rig's captures embed the staged-home
    # path, and a wrapped footer line flips even s1's diff; measured red at
    # a 31-char root). "t83sl<PID><tag>" also matches the scope gate's t83
    # scratch family if a leg ever dies before its ensure.
    def live_root(tag)
      root = File.join(REPO_ROOT, "t83sl#{Process.pid}#{tag}")
      FileUtils.rm_rf(root)
      root
    end

    def read_report(root)
      path = File.join(root, "sweep-report.json")
      assert File.file?(path), "sweep-report.json written at #{path}"
      JSON.parse(File.read(path))
    end

    def sweep_cmd(*args)
      Open3.capture2e(SWEEP, *args)
    end

    # --list output: "jobs N" then "sw-NN <name> <yml> <out>" lines.
    def parse_plan(output)
      jobs = output[/^jobs (\d+)$/, 1].to_i
      entries = output.lines.grep(/\Asw-\d+ /).map do |line|
        _sw, name, yml, out = line.split
        {name: name, yml: yml, out: out}
      end
      [jobs, entries]
    end
  end
end