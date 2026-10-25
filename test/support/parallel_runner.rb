# frozen_string_literal: true

# The I84 parallel test runner (plan TEST-RIG-SPEED ENTRY 3, arch
# Specification Law 1): runs the canonical minitest suite across concurrent
# worker PROCESSES — the same files `rake test` runs, the same framework, a
# merged verdict that must match the serial one. `rake test` stays THE
# canonical gate; this path is purely additive (`rake test:par`).
#
# The eight laws (architecture/I84-parallel-test-runner.md):
# 1. canonical set — the Rakefile's own FileList globs (both trees),
#    resolved and sorted. One source of truth is the Rakefile text; the pins
#    battery (Law 3) extracts the globs FROM the Rakefile and pins equality.
# 2. enumeration pass — ONE load-only subprocess requiring every canonical
#    file under minitest/autorun with a Minitest.run override that dumps the
#    sorted `Klass#method` lines and exit!(0)s — NEVER running a test.
#    Mechanical belts (measured defects, the Grounds): Minitest.seed is set
#    BEFORE runnable_methods (5.27 does `srand Minitest.seed` — a nil seed
#    raises TypeError), and $stdout.flush precedes exit! (exit! SKIPS the
#    stdio flush and silently truncates the dump — this spec measured
#    1374-of-1474 lines lost without it). The same pass also writes a
#    method→defining-file map (the method's own source location — exact for
#    the metaprogrammed md_battery tests a textual def-scan cannot see),
#    which is what each worker's FILES set is narrowed from.
# 3. shard law — deterministic round-robin over the sorted Klass#method
#    list: worker i takes indices ≡ i (mod N) (union = full set, pairwise
#    disjoint, sizes within 1).
# 4. worker law — each worker is `bundle exec ruby -Itest -Ilib -e 'require
#    "minitest/autorun"; ENV["FILES"]…' -- --name /<escaped Klass#method
#    alternation>/ --seed <n>`; the FULL Klass#method form discriminates
#    same-named methods across classes (minitest matches
#    `pos === m || pos === "#{self}##{m}"`). Worker stdout+stderr go to a
#    per-worker LOG FILE — never a shared pipe read serially (a chatty
#    worker deadlocks that, the I83 lesson).
# 5. merge law — parse each worker's "N runs, M assertions, F failures, E
#    errors, S skips" line + exit code; exit nonzero iff any worker exited
#    nonzero or F+E > 0; one attribution line per worker (index, files,
#    runs, seed, status) and the final PARALLEL_OK literal — PARALLEL_FAIL
#    with the failing workers on red.
# 6. coverage audit — every worker's runs must equal its shard size and the
#    summed runs must equal the enumerated total (nothing dropped, nothing
#    run twice); prints `COVERAGE_OK runs=<n> enum=<n>` or fails loudly.
#    NOTE: the frozen parallel-parity gate greps the log UNANCHORED for the
#    first `enum=` — no other line may contain that substring.
# 7. jobs — TART_TEST_JOBS env override, default 8; values outside 1..32
#    refused loudly (nonzero, message) BEFORE any spawn.
# 8. interruption — INT/TERM kill in-flight workers first (kill + reap, the
#    I83 sweep Law-7 idiom), then exit nonzero — no orphaned workers.

require "open3"
require "rbconfig"
require "fileutils"
require "tmpdir"

module Tart
  module ParallelRunner
    DEFAULT_JOBS = 8
    JOBS_RANGE = (1..32).freeze

    # Law 1.1: the Rakefile's own FileList globs (byte-equal to the
    # Rakefile's `t.test_files = FileList[...]` literals — pinned by the
    # units battery, which extracts them from the Rakefile text).
    CANONICAL_GLOBS = ["test/**/*_test.rb", "gems/tui-split-rig/test/**/*_test.rb"].freeze

    ROOT = File.expand_path("../..", __dir__)

    # One worker's raw + parsed record (the merge law's unit).
    Result = Struct.new(:index, :shard_size, :seed, :files, :pid, :status,
      :log_path, :log_text, :runs, :assertions, :failures, :errors, :skips,
      keyword_init: true)

    # Law 1.2's child program. QUOTED heredoc: the interpolation belongs to
    # the CHILD's bindings, not the runner's.
    ENUM_PROGRAM = <<~'RUBY'
      require "minitest/autorun"
      srand 42; Minitest.seed = 42
      ENV.fetch("FILES").split(File::PATH_SEPARATOR).each { |f| require f }
      module Minitest
        def self.run(*)
          attrib = File.open(ENV.fetch("ATTRIB"), "w")
          Runnable.runnables.each do |k|
            k.runnable_methods.each do |m|
              name = "#{k.name}##{m}"
              loc = begin
                k.instance_method(m).source_location
              rescue StandardError
                nil
              end
              $stdout.puts name
              attrib.puts "#{name}\t#{loc ? loc[0] : ""}"
            end
          end
          attrib.close
          $stdout.flush
          exit! 0
        end
      end
    RUBY

    # Law 1.4's child program: load, then let minitest's own optparse
    # (autorun parses ARGV at at_exit) apply the --name / --seed filters.
    WORKER_PROGRAM = 'require "minitest/autorun"; ' \
      'ENV.fetch("FILES").split(File::PATH_SEPARATOR).each { |f| require f }'

    # The worker summary line minitest prints (the merge law parses the LAST
    # occurrence — a test's own output can coincidentally match).
    SUMMARY_RE = /(\d+) runs?, (\d+) assertions?, (\d+) failures?, (\d+) errors?, (\d+) skips?/

    module_function

    # --- Law 7: jobs ----------------------------------------------------

    # Parses TART_TEST_JOBS (default 8); ANY invalid value aborts loudly
    # before this run spawns anything — the run() call order pins it.
    def parse_jobs(env = ENV)
      raw = env["TART_TEST_JOBS"] || DEFAULT_JOBS.to_s
      jobs = Integer(raw, 10)
      return jobs if JOBS_RANGE.cover?(jobs)

      abort "test:par: TART_TEST_JOBS=#{raw.inspect} is outside #{JOBS_RANGE.first}..#{JOBS_RANGE.last} — refusing before any spawn"
    rescue ArgumentError, TypeError
      abort "test:par: TART_TEST_JOBS=#{raw.inspect} is not an integer (valid: #{JOBS_RANGE.first}..#{JOBS_RANGE.last}) — refusing before any spawn"
    end

    # --- Law 1.1: canonical set -----------------------------------------

    def canonical_files(root = ROOT)
      CANONICAL_GLOBS.flat_map { |g| Dir.glob(File.join(root, g)) }.sort
    end

    # --- Law 1.2: enumeration pass --------------------------------------

    # ONE load-only subprocess; returns the sorted, deduped Klass#method
    # list. The child's FILES env carries the canonical set; BUNDLE_GEMFILE
    # is pinned to the repo's Gemfile so the child resolves the bundle from
    # any launcher context.
    def enumerate(root: ROOT, env: ENV, scratch:, pids:, err: $stderr)
      log = File.join(scratch, "enumeration.log")
      child = child_env(root, env).merge("ATTRIB" => File.join(scratch, "attrib.log"))
      pid = Process.spawn(child, "bundle", "exec", RbConfig.ruby,
        "-Itest", "-Ilib", "-e", ENUM_PROGRAM,
        chdir: root, out: [log, "w"], err: [:child, :out])
      pids << pid
      _pid, status = Process.wait2(pid)
      pids.delete(pid)
      dump = File.read(log)
      unless status.success?
        err.puts dump
        abort "test:par: the enumeration pass failed (#{status}) — no worker spawned"
      end
      dump.split("\n").uniq.sort
    end

    # --- Law 1.3: shard -------------------------------------------------

    # Deterministic round-robin: worker i takes the sorted list's indices
    # ≡ i (mod jobs). Union = full set, pairwise disjoint, sizes within 1.
    def shard(names, jobs)
      shards = Array.new(jobs) { [] }
      names.each_with_index { |name, i| shards[i % jobs] << name }
      shards
    end

    # --- Law 1.4: workers -----------------------------------------------

    # method full name => its defining file (written by the enumeration
    # pass from the method's own source location — exact for the
    # metaprogrammed md_battery tests a textual def-scan cannot see).
    def attrib_map(path)
      map = {}
      File.foreach(path) do |line|
        name, file = line.chomp.split("\t", 2)
        map[name] = file unless file.nil? || file.empty?
      end
      map
    end

    # Which files a worker must load for its shard: exactly the files that
    # define the shard's methods (measured at base: every enumerated
    # method's own source file also defines its class, so loading it brings
    # both). Belt: any method the attribution cannot place falls back to
    # loading the FULL canonical set for that worker — an exotic definition
    # may slow a worker, never silently drop a test (the coverage audit
    # would catch the drop as a loud nonzero).
    def worker_files(files, map, shard_names)
      if shard_names.any? { |name| map[name].nil? }
        files
      else
        shard_names.map { |name| map[name] }.uniq.sort
      end
    end

    # The frozen full-form filter: a Regexp-escaped alternation of the
    # shard's FULL Klass#method entries (same-named methods across classes
    # stay discriminated; at base no test-method name is a strict prefix of
    # another in its class, and the coverage audit makes any future
    # collision a loud nonzero rather than silent drift).
    def filter_for(shard_names)
      "/" + shard_names.map { |n| Regexp.escape(n) }.join("|") + "/"
    end

    def child_env(root, env)
      env.to_h.merge("FILES" => canonical_files(root).join(File::PATH_SEPARATOR),
        "BUNDLE_GEMFILE" => File.join(root, "Gemfile"))
    end

    # --- Law 8: interruption -------------------------------------------

    # The I83 sweep Law-7 idiom: TERM the in-flight workers, wait a short
    # grace, KILL survivors, reap every pid — no orphans.
    def kill_and_reap(pids, err)
      return if pids.empty?

      live = pids.dup
      live.each { |pid| Process.kill("TERM", pid) rescue nil }
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
      until live.empty? || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        live.reject! do |pid|
          begin
            Process.waitpid(pid, Process::WNOHANG) # reaps, returns pid or 0
            true
          rescue Errno::ECHILD
            true
          end
        end
        sleep 0.05 unless live.empty?
      end
      live.each { |pid| Process.kill("KILL", pid) rescue nil }
      live.each do |pid|
        Process.waitpid(pid)
      rescue Errno::ECHILD
        nil
      end
      err.puts "test:par: killed and reaped #{pids.size} in-flight child(ren)"
    end

    # --- Law 5: merge ---------------------------------------------------

    # Parses each worker's log (the LAST "N runs, M assertions, …" line);
    # a crashed worker (no summary line) parses as all-zero counts — the
    # nonzero exit code carries the verdict.
    def merge!(results)
      results.each do |r|
        m = (r.log_text || "").scan(SUMMARY_RE).last
        if m
          r.runs, r.assertions, r.failures, r.errors, r.skips = m.map(&:to_i)
        else
          r.runs = r.assertions = r.failures = r.errors = r.skips = 0
        end
      end
      results
    end

    def totals(results)
      {
        runs: results.sum(&:runs),
        assertions: results.sum(&:assertions),
        failures: results.sum(&:failures),
        errors: results.sum(&:errors),
        skips: results.sum(&:skips)
      }
    end

    # Law 5's per-worker attribution line: index, files, runs, seed, status.
    def attribution_lines(results)
      results.map do |r|
        state = worker_state(r)
        "worker=#{r.index} files=#{r.files.size} shard=#{r.shard_size} " \
          "runs=#{r.runs} seed=#{r.seed} ec=#{r.status.exitstatus} #{state}"
      end
    end

    def worker_state(r)
      r.status.success? && (r.failures + r.errors).zero? ? "ok" : "FAIL"
    end

    # --- Law 6: coverage audit ------------------------------------------

    # Every worker's runs == its shard size AND summed runs == enumerated
    # total. Returns [ok, line, detail_lines]. The line is the frozen
    # literal the gates grep; `enum=` appears NOWHERE else in the output.
    def coverage(results, enum_total)
      total = results.sum(&:runs)
      mismatched = results.reject { |r| r.runs == r.shard_size }
      return [true, "COVERAGE_OK runs=#{total} enum=#{enum_total}", nil] if
        mismatched.empty? && total == enum_total

      detail = mismatched.map { |r|
        "coverage: worker=#{r.index} ran #{r.runs} for a shard of #{r.shard_size}"
      }
      unless total == enum_total
        detail << "coverage: summed #{total} != enumerated #{enum_total}"
      end
      [false, "COVERAGE_FAIL runs=#{total} enum=#{enum_total}", detail]
    end

    # --- Law 5: verdict line --------------------------------------------

    def verdict_line(results, wall, ok)
      t = totals(results)
      head = ok ? "PARALLEL_OK" : "PARALLEL_FAIL"
      "#{head} runs=#{t[:runs]} assertions=#{t[:assertions]} failures=#{t[:failures]} " \
        "errors=#{t[:errors]} skips=#{t[:skips]} workers=#{results.size} " \
        "wall=#{format('%.1f', wall)}s"
    end

    # --- the run ---------------------------------------------------------

    # Runs the whole flow and returns the exit code (0 green, 1 red; the
    # interruption trap exits 1 directly).
    def run(root: ROOT, env: ENV, out: $stdout, err: $stderr)
      wall0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      jobs = parse_jobs(env) # Law 7: the FIRST act — nothing spawns before it
      files = canonical_files(root)
      scratch = Dir.mktmpdir("t84par-")
      pids = []

      # Law 8: the traps are live from the first spawn on. The registry is
      # swept by kill_and_reap from the trap handler (there is one
      # unobservable window between Process.spawn and the registry push —
      # a signal landing exactly there would orphan that single child;
      # every other moment is covered).
      %w[INT TERM].each do |sig|
        trap(sig) do
          err.puts "\ntest:par: #{sig} — killing in-flight workers (kill + reap), then exiting nonzero"
          kill_and_reap(pids, err)
          out.flush
          err.flush
          exit! 1
        end
      end

      names = enumerate(root: root, env: env, scratch: scratch, pids: pids, err: err)
      map = attrib_map(File.join(scratch, "attrib.log"))
      shards = shard(names, jobs)
      out.puts "test:par: jobs=#{jobs} files=#{files.size} tests=#{names.size} scratch=#{scratch}"

      workers = shards.each_with_index.map do |shard_names, i|
        seed = 12_345 + i
        shard_files = worker_files(files, map, shard_names)
        log = File.join(scratch, "worker-#{i}.log")
        pid = Process.spawn(child_env(root, env).merge("FILES" => shard_files.join(File::PATH_SEPARATOR)),
          "bundle", "exec", RbConfig.ruby,
          "-Itest", "-Ilib", "-e", WORKER_PROGRAM,
          "--", "--name", filter_for(shard_names), "--seed", seed.to_s,
          chdir: root, out: [log, "w"], err: [:child, :out])
        pids << pid
        Result.new(index: i, shard_size: shard_names.size, seed: seed, files: shard_files,
          pid: pid, log_path: log)
      end

      workers.each do |w|
        _pid, status = Process.wait2(w[:pid])
        pids.delete(w.pid)
        w.status = status
        w.log_text = File.read(w.log_path)
      end
      merge!(workers)

      wall = Process.clock_gettime(Process::CLOCK_MONOTONIC) - wall0
      attribution_lines(workers).each { |l| out.puts l }
      cov_ok, cov_line, cov_detail = coverage(workers, names.size)
      out.puts cov_line
      (cov_detail || []).each { |l| out.puts l }

      red = workers.any? { |w| !w.status.success? || (w.failures + w.errors).positive? }
      ok = cov_ok && !red
      out.puts verdict_line(workers, wall, ok)
      unless ok
        workers.select { |w| !w.status.success? || (w.failures + w.errors).positive? }
               .each { |w| out.puts "failing worker=#{w.index} log=#{w.log_path}" }
      end
      ok ? 0 : 1
    end
  end
end

exit(Tart::ParallelRunner.run) if $PROGRAM_NAME == __FILE__