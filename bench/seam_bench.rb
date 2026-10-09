# frozen_string_literal: true

# Seam bench (Design B) — the event-loop kernel's measured properties,
# in-repo and unattended. Reproduces the I01 common workload scaled to
# ~17 s wall: SSE 500 chunks @ ~50/s over local TCP, subprocess (`pgroup:
# true`) streaming 100 lines with the timeout-kill probe, timer 100 ticks,
# synthetic events 200 @ ~20/s with injection→dispatch latency, a minimal
# draw every frame, a 3 s animation window for the fps measurement and a
# 3 s static window whose wake count and CPU are reported.
#
# Self-asserting: internal hard deadline (< 60 s) kills and fails the run;
# prints SEAM_BENCH_OK and exits 0 iff mean fps_while_animating >= 58 AND
# event_p95_ms <= 30 AND every delivered == expected AND the timeout-kill
# verdict is clean; otherwise SEAM_BENCH_FAIL: <reason> and exit 1.
#
# The child runs inside its own 80x24 pty (real crossterm init — the I01
# 0x0-pty fix); the parent wraps it with the hard deadline and forwards a
# clean JSON report to stdout.

require "json"
require "socket"
require "tmpdir"

SSE_CHUNKS = 500
SSE_INTERVAL = 0.02 # ~50/s
SUBPROCESS_LINES = 100
SUBPROCESS_INTERVAL = 0.1
TIMER_TICKS = 100
TIMER_PERIOD = 0.1
SYNTHETIC_EVENTS = 200
SYNTHETIC_INTERVAL = 0.05 # ~20/s
ANIMATION_WINDOW = 3.0
STATIC_WINDOW = 3.0
CHILD_DEADLINE = 45.0 # internal, well under the 60 s gate budget
PARENT_DEADLINE = 55.0

def mono_now
  Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

def pct(sorted, p)
  sorted[((sorted.size - 1) * p / 100.0).ceil]
end

def write_report(path, results, verdict)
  File.write(path, JSON.generate("results" => results, "verdict" => verdict))
end

# ---- parent: run the child in a fresh 80x24 pty, enforce the deadline ----

def run_in_pty
  require "pty"

  # darwin: 0x80087467 (TIOCSWINSZ); linux: 0x5413
  tiocswinsz = RUBY_PLATFORM =~ /darwin/ ? 0x80087467 : 0x5413
  results_path = File.expand_path(ENV["SEAM_BENCH_RESULTS"] || File.join(Dir.tmpdir, "seam_bench_#{Process.pid}.json"))
  FileUtils.rm_f(results_path)

  master, slave = PTY.open
  master.ioctl(tiocswinsz, [24, 80, 0, 0].pack("SSSS"))
  env = {
    "TERM" => "xterm-256color",
    "SEAM_BENCH_IN_PTY" => "1",
    "SEAM_BENCH_RESULTS" => results_path,
  }
  pid = Process.spawn(env, RbConfig.ruby, __FILE__, in: slave, out: slave, err: slave, pgroup: true)
  slave.close

  drain = Thread.new do
    out = +""
    while (chunk = master.readpartial(65_536) rescue nil)
      out << chunk
    end
    out
  end

  t0 = mono_now
  timed_out = false
  status = nil
  loop do
    _, status = Process.waitpid2(pid, Process::WNOHANG)
    break if status
    if mono_now - t0 > PARENT_DEADLINE
      timed_out = true
      Process.kill("-KILL", pid) rescue Process.kill("KILL", pid)
      _, status = Process.waitpid2(pid)
      break
    end
    sleep 0.05
  end
  # Bounded drain join (I02 carry-in): a stuck pty drain must not wedge the
  # parent past the deadline.
  drain.join(5)
  pty_tail = drain.value.to_s[-2000..]
  master.close rescue nil

  if timed_out || !status.success? || !File.exist?(results_path)
    report = File.exist?(results_path) ? JSON.parse(File.read(results_path)) : nil
    puts JSON.pretty_generate(report&.fetch("results") || {
      "error" => "bench child failed",
      "timed_out" => timed_out,
      "exit_status" => status.inspect,
      "pty_tail" => pty_tail,
    })
    puts "SEAM_BENCH_FAIL: child #{timed_out ? "exceeded #{PARENT_DEADLINE}s deadline" : "exited #{status.inspect}"}"
    exit 1
  end

  report = JSON.parse(File.read(results_path))
  puts JSON.pretty_generate(report["results"])
  puts report["verdict"]
  exit report["verdict"] == "SEAM_BENCH_OK" ? 0 : 1
rescue StandardError => e
  warn "#{e.class}: #{e.message}\n#{e.backtrace&.join("\n")}"
  puts "SEAM_BENCH_FAIL: parent error #{e.class}: #{e.message}"
  exit 1
end

# ---- child: the measured workload inside the pty ----

def run_workload
  require "bundler/setup"
  require_relative "../lib/raspberry_pi"

  state = {
    mutex: Mutex.new,
    sse_port: nil,
    sse_ts: [],            # SSE chunk arrival timestamps
    lines: 0,              # subprocess stdout lines
    dispatched: 0,         # synthetic events dispatched by the kernel
    latencies: [],         # injection -> dispatch, ms
    inject_ts: Queue.new,  # injection timestamps (thread-safe)
    draw_ts: Queue.new,    # renderer invocation timestamps
    ticks: 0,
    native_seen: 0,        # native events seen by on_event (I02 carry-in: initialized)
    kill_probe: {},
    pids: [],
    reapers: [],
    extras: nil,
  }
  t_start = mono_now

  RaspberryPi::TUI.run do |session|
    renderer = lambda do
      snapshot = state[:mutex].synchronize do
        "chunks=#{state[:sse_ts].size} lines=#{state[:lines]} ticks=#{state[:ticks]} events=#{state[:dispatched]}"
      end
      state[:draw_ts] << mono_now
      snapshot
    end
    on_event = lambda do |event, source|
      if source == :synthetic
        t_in = state[:inject_ts].pop
        state[:mutex].synchronize do
          state[:dispatched] += 1
          state[:latencies] << (mono_now - t_in) * 1000.0
        end
      else
        state[:mutex].synchronize { state[:native_seen] += 1 }
      end
    end

    kernel = RaspberryPi::Core::Loop.new(session:, renderer:, on_event:)

    # Internal hard deadline: kill and fail the run (self-asserting).
    Thread.new do
      sleep CHILD_DEADLINE
      write_report(ENV.fetch("SEAM_BENCH_RESULTS"), {},
        "SEAM_BENCH_FAIL: exceeded internal #{CHILD_DEADLINE}s deadline")
      Process.exit!(1)
    end

    begin
      kernel.run do
        state[:sse_port] = spawn_sse_server(state)
        sse_task = spawn_sse_client(kernel, state)
        emitter_pid, out_task, err_task = spawn_subprocess(kernel, state)
        spawn_timeout_kill_probe(state)
        timer_task = kernel.every(TIMER_PERIOD, ticks: TIMER_TICKS) { state[:ticks] += 1 }
        injector_task = spawn_injector(kernel, state, session)

        sse_task.wait
        out_task.wait
        err_task.wait
        timer_task.wait
        injector_task.wait

        # Animation window: deadline-paced 60 Hz fps measurement.
        anim_start = mono_now
        kernel.animate(duration: ANIMATION_WINDOW)
        sleep(ANIMATION_WINDOW + 0.2)
        anim_end = anim_start + ANIMATION_WINDOW # window closes here

        # Static window: event-driven — bounded wakes, no draws.
        wakes_before = kernel.stats[:wakes]
        sleep(STATIC_WINDOW)

        state[:mutex].synchronize do
          state[:extras] = {
            anim_start:,
            anim_end:,
            static_wakes: kernel.stats[:wakes] - wakes_before,
            draws: kernel.stats[:draws],
            t_start:,
          }
        end
      end
    ensure
      # Never leave children behind, whatever happened above.
      state[:mutex].synchronize { state[:pids].dup }.each do |pid|
        Process.kill("-TERM", -pid) rescue Process.kill("TERM", pid) rescue nil
      end
      state[:reapers].each { |t| t.join(2) rescue nil }
    end
  end

  finish(state)
rescue StandardError => e
  warn "#{e.class}: #{e.message}\n#{e.backtrace&.join("\n")}"
  puts "SEAM_BENCH_FAIL: workload error #{e.class}: #{e.message}"
  exit 1
end

# Mock SSE source: streams `data: chunk-N` lines at ~50/s to the first
# client, then closes. Runs on its own thread in this process.
def spawn_sse_server(state)
  server = TCPServer.new("127.0.0.1", 0)
  port = server.addr[1]
  Thread.new do
    client = server.accept
    t0 = mono_now
    SSE_CHUNKS.times do |i|
      client.write("data: chunk-#{i}\n")
      target = t0 + (i + 1) * SSE_INTERVAL
      sleep [target - mono_now, 0].max
    end
    client.close
    server.close
  end
  port
end

# Reactor-owned socket reader task: counts delivered SSE chunks.
def spawn_sse_client(kernel, state)
  kernel.async do
    sock = TCPSocket.new("127.0.0.1", state[:sse_port])
    sock.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
    last_line = +""
    loop do
      sock.wait_readable(0.5) or next
      data = sock.read_nonblock(65_536, exception: false)
      break if data.nil? || data == :eof
      last_line << data
      while (nl = last_line.index("\n"))
        last_line = last_line[(nl + 1)..]
        state[:mutex].synchronize { state[:sse_ts] << mono_now }
      end
    end
  ensure
    sock&.close rescue nil
  end
end

# Subprocess streamer (`pgroup: true`) plus reactor-owned stdout/stderr
# reader fibers. Returns [pid, out_task, err_task].
def spawn_subprocess(kernel, state)
  code = "t0=Process.clock_gettime(Process::CLOCK_MONOTONIC); " \
    "#{SUBPROCESS_LINES}.times { |i| puts \"line-\#{i}\"; $stdout.flush; " \
    "d = t0 + (i+1)*#{SUBPROCESS_INTERVAL} - Process.clock_gettime(Process::CLOCK_MONOTONIC); sleep d if d > 0 }"
  out_rd, out_wr = IO.pipe
  err_rd, err_wr = IO.pipe
  pid = Process.spawn(RbConfig.ruby, "-e", code, pgroup: true, out: out_wr, err: err_wr)
  out_wr.close
  err_wr.close
  state[:mutex].synchronize { state[:pids] << pid }
  state[:reapers] << Thread.new { Process.waitpid(pid) rescue nil }

  out_task = kernel.async { drain_pipe(out_rd) { state[:mutex].synchronize { state[:lines] += 1 } } }
  err_task = kernel.async { drain_pipe(err_rd) }
  [pid, out_task, err_task]
end

def drain_pipe(io)
  loop do
    io.wait_readable(0.5) or next
    data = io.read_nonblock(65_536, exception: false)
    break if data.nil? || data == :eof
    data.count("\n").times { yield } if block_given?
  end
ensure
  io.close rescue nil
end

# Timeout-kill probe: `sleep 600` in its own process group, killed by
# negative-pid Process.kill after ~1 s, reaped, verified zombie-free. All
# stdio is redirected (I02 carry-in): the probe must not hold the pty slave
# in its own process group.
def spawn_timeout_kill_probe(state)
  Thread.new do
    sleep 1.0
    kpid = Process.spawn("sleep", "600", pgroup: true,
                         in: File::NULL, out: File::NULL, err: File::NULL)
    state[:mutex].synchronize { state[:pids] << kpid }
    sleep 1.0
    t_kill = mono_now
    killed = Process.kill("-TERM", kpid)
    _pid, status = Process.waitpid2(kpid)
    zombie_gone = begin
      Process.kill(0, kpid)
      false
    rescue Errno::ESRCH
      true
    end
    state[:mutex].synchronize do
      state[:kill_probe] = {
        "verdict" => (killed == 1 && status.termsig == 15 && zombie_gone ? "clean" : "dirty"),
        "kill_calls" => killed,
        "termsig" => status.termsig,
        "zombie_gone" => zombie_gone,
        "seconds_to_reap" => (mono_now - t_kill).round(4),
      }
    end
  rescue StandardError => e
    state[:mutex].synchronize do
      state[:kill_probe] = {"verdict" => "dirty", "error" => "#{e.class}: #{e.message}"}
    end
  end
end

# Synthetic-event injector: 200 Event::Sync at ~20/s via the TUI module's
# SyntheticEvents bridge, timestamping each injection.
def spawn_injector(kernel, state, session)
  kernel.async do
    t0 = mono_now
    SYNTHETIC_EVENTS.times do |i|
      state[:inject_ts] << mono_now
      session.push_event(RaspberryPi::TUI.sync_event)
      d = t0 + (i + 1) * SYNTHETIC_INTERVAL - mono_now
      sleep d if d > 0
    end
  end
end

def finish(state)
  extras = state[:mutex].synchronize { state[:extras] }
  # I02 carry-in: if the workload never completed, extras is nil — report
  # the failure (the workload error already printed) instead of crashing on
  # nil and masking it.
  unless extras
    write_report(ENV.fetch("SEAM_BENCH_RESULTS"), {},
      "SEAM_BENCH_FAIL: workload did not complete (see workload error above)")
    puts "SEAM_BENCH_FAIL: workload did not complete; extras missing"
    exit 1
  end
  wall = mono_now - extras[:t_start]
  tms = Process.times

  anim_draw_ts = Array.new(state[:draw_ts].size) { state[:draw_ts].pop }
    .select { |t| t.between?(extras[:anim_start], extras[:anim_end]) }
  cadence = anim_draw_ts.each_cons(2).map { |a, b| (b - a) * 1000.0 }.sort
  fps_mean = anim_draw_ts.size / (extras[:anim_end] - extras[:anim_start])

  latencies = state[:mutex].synchronize { state[:latencies].dup.sort }
  sse_delivered = gaps = nil
  state[:mutex].synchronize do
    sse_delivered = state[:sse_ts].size
    gaps = state[:sse_ts].each_cons(2).map { |a, b| (b - a) * 1000.0 }
  end
  lines = state[:mutex].synchronize { state[:lines] }
  kill_probe = state[:mutex].synchronize { state[:kill_probe] }

  results = {
    "fps_while_animating" => {"mean" => fps_mean.round(2), "p05_cadence_ms" => (pct(cadence, 5).round(2) unless cadence.empty?)},
    "event_p50_ms" => (pct(latencies, 50).round(2) unless latencies.empty?),
    "event_p95_ms" => (pct(latencies, 95).round(2) unless latencies.empty?),
    "sse_delivered" => sse_delivered,
    "sse_expected" => SSE_CHUNKS,
    "sse_max_gap_ms" => (gaps.max.round(2) unless gaps.empty?),
    "subprocess_lines" => lines,
    "timeout_kill" => kill_probe,
    "timer_ticks" => state[:ticks],
    "timer_expected" => TIMER_TICKS,
    "static_wakes" => extras[:static_wakes],
    "cpu_pct" => ((tms.utime + tms.stime) / wall * 100).round(1),
    "cpu_method" => "Process::Tms self utime+stime (excludes children) / wall",
    "draws" => extras[:draws],
    "workload" => {
      "sse_chunks" => SSE_CHUNKS, "sse_interval_s" => SSE_INTERVAL,
      "subprocess_lines" => SUBPROCESS_LINES, "subprocess_interval_s" => SUBPROCESS_INTERVAL,
      "timer_ticks" => TIMER_TICKS, "timer_period_s" => TIMER_PERIOD,
      "synthetic_events" => SYNTHETIC_EVENTS, "synthetic_interval_s" => SYNTHETIC_INTERVAL,
      "animation_window_s" => ANIMATION_WINDOW, "static_window_s" => STATIC_WINDOW,
      "child_deadline_s" => CHILD_DEADLINE,
    },
  }

  # Self-assertion: one-sided floors/ceilings.
  failures = []
  failures << "mean fps #{results['fps_while_animating']['mean']} < 58" if fps_mean < 58
  failures << "event_p95_ms #{results['event_p95_ms']} > 30" if results["event_p95_ms"].to_f > 30
  failures << "sse #{sse_delivered}/#{SSE_CHUNKS}" unless sse_delivered == SSE_CHUNKS
  failures << "subprocess #{lines}/#{SUBPROCESS_LINES}" unless lines == SUBPROCESS_LINES
  failures << "timer #{state[:ticks]}/#{TIMER_TICKS}" unless state[:ticks] == TIMER_TICKS
  failures << "synthetic #{latencies.size}/#{SYNTHETIC_EVENTS}" unless latencies.size == SYNTHETIC_EVENTS
  failures << "timeout-kill #{kill_probe.inspect}" unless kill_probe["verdict"] == "clean"

  verdict = failures.empty? ? "SEAM_BENCH_OK" : "SEAM_BENCH_FAIL: #{failures.join("; ")}"
  write_report(ENV.fetch("SEAM_BENCH_RESULTS"), results, verdict)
  puts verdict
  exit verdict == "SEAM_BENCH_OK" ? 0 : 1
end

if ENV["SEAM_BENCH_IN_PTY"]
  run_workload
else
  require "fileutils"
  run_in_pty
end
