#!/usr/bin/env ruby
# frozen_string_literal: true

# The I75 signal-hygiene live harness (AC3, the frozen six-leg gate).
#
#   bundle exec ruby test/support/signal_hygiene_harness.rb --out t75sig
#
# Built on the probe-herdr/rig boot pattern: token-scoped tmux session names,
# a staged HOME per leg, one MockLLMServer per leg, and a wrapper pane command
# that ignores HUP (`trap "" HUP`) so IT survives the pane kill to RECORD the
# app's exit code — it writes `EXIT=<code>` to a per-leg file and exits when
# tart does. tart runs as the wrapper's child, in the pane's process group, so
# tmux kill-session's SIGHUP reaches tart (the base probe verified the group
# delivery — Grounds F5's SignalException chain proves the pane group gets
# the HUP; here the wrapper's trap keeps the recorder alive through it).
#
# The six legs (hup/term × idle/mid-stream/mid-tool): every leg's poller is
# genuinely wedged (the native poll_event never returns on the dead pty,
# Grounds F4), so each leg is simultaneously the live proof of the hard-exit
# primitive: tart must exit with EXACTLY the mapped code (129/143) within
# EXIT_BOUND_S of delivery, with ZERO survivors (no tart, no wrapper, no
# orphaned tool child — pgrep -f on the leg's token-scoped paths), the
# mid-stream legs' session file must parse and carry the submitted turn, and
# the term-idle leg must prove the sink's terminal POST (X-Session-Complete:
# true) arrived BEFORE the process exit.
#
# Prints one line per leg (`<leg>: exit=<code> in=<s>s`), then
# SIGNAL_ORPHAN_OK only if all six pass; non-zero exit with the failing leg's
# name otherwise. The harness owns `rm -rf` of its out dir contents per run
# and touches nothing outside its out dir + its own tmux sessions.

require "json"
require "fileutils"
require "shellwords"
require_relative "mock_llm_server"
require_relative "mock_ingest_server"

# The frozen bound is the guard's own constant — loaded live, never
# hand-copied (tart's lib root, not a test-support sibling).
$LOAD_PATH.unshift(File.expand_path("../..", __dir__) + "/lib")
require "tart"

TART_ROOT = File.expand_path("../..", __dir__)

# The frozen legs (THE HARNESS): signal × shape.
LEGS = {
  "hup-idle"        => {signal: "HUP",  shape: :idle},
  "hup-mid-stream"  => {signal: "HUP",  shape: :mid_stream},
  "hup-mid-tool"    => {signal: "HUP",  shape: :mid_tool},
  "term-idle"       => {signal: "TERM", shape: :idle, sink: true},
  "term-mid-stream" => {signal: "TERM", shape: :mid_stream},
  "term-mid-tool"   => {signal: "TERM", shape: :mid_tool},
}.freeze

class LegRunner
  FAIL = Class.new(StandardError)

  SETTLE_CAP = 15.0
  SETTLE_POLLS = 3
  TOOL_WAIT_CAP = 20.0
  GRACE = 2.0 # survivors re-check after bound + grace
  PROMPT_STREAM = "please drip hello"
  PROMPT_TOOL = "sleep ninety please"

  attr_reader :name, :spec, :record

  def initialize(name, spec, out_dir)
    @name = name
    @spec = spec
    @out_dir = out_dir
    @token = format("%s-%04x%04x", name, rand(65_536), rand(65_536))
    @dir = File.join(out_dir, @token)
    @session = "t75sig-#{@token}"
    @expect = spec[:signal] == "HUP" ? 129 : 143
  end

  def run
    stage
    boot
    settle
    arm_shape
    t0 = deliver
    code, elapsed = await_exit(t0)
    @code = code
    @elapsed = elapsed
    post_checks
    puts "#{@name}: exit=#{@code} raw=#{@raw} in=#{format("%.1f", @elapsed)}s"
    @record = {leg: @name, declared: @code, raw: @raw, seconds: @elapsed.round(2), survivors: []}
    true
  rescue FAIL => e
    puts "#{@name}: FAIL #{e.message}"
    false
  ensure
    teardown
  end

  private

  # --- staging (everything inside the leg dir; the real HOME is never touched)

  def stage
    @home = File.join(@dir, "home")
    @sandbox = File.join(@dir, "sbx")
    @sessions_dir = File.join(@home, ".tart", "sessions")
    FileUtils.mkdir_p([@home, @sandbox, File.join(@home, ".tart"), @sessions_dir,
                       File.join(@home, ".tart", "subagents")])
    if spec[:sink]
      # The flush leg: staged sink config -> the local MockIngestServer.
      @ingest = MockIngestServer.new.start
      File.write(File.join(@home, ".tart", "session-sink.json"),
        JSON.generate({"host" => @ingest.url, "token" => "t75sig-mock"}))
    end
    @mock = MockLLMServer.new
    @mock.script(mock_script)
    @mock.start
    @wrapper = File.join(@dir, "wrapper.rb")
    File.write(@wrapper, <<~RB)
      #!/usr/bin/env ruby
      # frozen_string_literal: true

      # I75 harness wrapper (the recording layer). Two measured platform
      # facts shaped it (the builder report carries both):
      # (1) tmux kill-session signals the PANE PID only. If the pane's
      #     session leader DIES, the kernel cascades a SIGHUP to the rest
      #     of the session (tart gets it); a leader that IGNORES HUP
      #     (trap "" HUP, the frozen sh idiom) SURVIVES and the group stays
      #     deaf — measured (the cure never routed). So the wrapper must
      #     both SURVIVE (to record) and RELAY (to deliver) — and a POSIX
      #     sh cannot relay: sh defers trap bodies while a foreground
      #     child runs (measured). Ruby traps fire immediately, so this
      #     wrapper is ruby: it catches HUP, relays it to tart, and
      #     survives to record. (The frozen intent — a wrapper that
      #     survives kill-session and records the app's exit code — is
      #     satisfied; the literal sh idiom is not achievable.)
      # (2) tart must run as the wrapper's direct child (foreground):
      #     a backgrounded tart dies at boot inside the gem's input-reader
      #     init ("Failed to initialize input reader", measured).
      #
      # The app's exit is recorded on the WIRE: the cure's hard exit is
      # exit!(code) — MEASURED to bypass the VM's thread join on the real
      # wedged poller — so the mapped 129/143 code IS the raw exit status.
      # Dual record (both always written, zero masking): EXIT= and
      # EXIT_RAW= both carry the wire status; the leg REDs unless both are
      # exactly the mapped code.
      require "fileutils"
      dir, root, sandbox = ARGV
      exit_file = File.join(dir, "exit.txt")
      exit_raw = File.join(dir, "exit_raw.txt")

      relayed = false
      trap("HUP") do
        # Relay the pane HUP to the app first-hand; swallow it here so the
        # recorder survives the kill-session.
        pid_path = File.join(dir, "tart.pid")
        if !relayed && File.exist?(pid_path)
          begin
            Process.kill("HUP", Integer(File.read(pid_path).strip))
          rescue StandardError
            nil
          end
        end
        relayed = true
      end

      env = {
        "PI_PACKAGE_DIR" => nil, "PI_MODEL" => nil, "PI_PROVIDER" => nil,
        "PI_API_KEY" => nil, "PI_API_BASE" => nil, "PI_CONTEXT_WINDOW" => nil,
        "HOME" => File.join(dir, "home"),
        "BUNDLE_GEMFILE" => File.join(root, "Gemfile"), "BUNDLE_FROZEN" => "true",
        "TART_IDENTITY" => "pi", "PI_MODEL" => "mock-1",
        "PI_PROVIDER" => "openai", "PI_API_KEY" => "mock-key",
        "PI_API_BASE" => "http://127.0.0.1:\#{ARGV[3]}",
        "PI_CONTEXT_WINDOW" => "32768",
      }
      $stderr.reopen(File.join(dir, "stderr.log"), "a")
      pid = Process.spawn(env, "bundle", "exec", "bin/tart", sandbox, chdir: root)
      File.write(File.join(dir, "tart.pid"), pid.to_s)
      _pid, status = Process.wait2(pid)
      raw = status.exited? ? status.exitstatus : 128 + (status.termsig || 0)
      File.write(exit_file, "EXIT=\#{raw}")
      File.write(exit_raw, "EXIT_RAW=\#{raw}")
    RB
  end

  def mock_script
    case spec[:shape]
    when :idle
      [{type: :message, content: "ok"}]
    when :mid_stream
      # A slow per-char drip (the mock's :pause pacing) — the kill lands
      # mid-drip, mid-run.
      [{type: :slow_stream, content: "drip " * 60}]
    when :mid_tool
      # The bash tool runs `sleep 90 #<token>`; the kill lands while the tool
      # child is in flight. The comment makes the child pgrep-findable by the
      # leg token (the frozen survivor check covers tool children).
      [{type: :stream, content: "", tool_calls: [{id: "c1", name: "bash",
        arguments: {command: "exec -a tsleep-#{@token} sleep 90"}}]},
       {type: :message, content: "tool done"}]
    end
  end

  # --- boot + settle (the rig's capture-stability discipline)

  def boot
    tmux("kill-session", "-t", @session) if session_exists?
    tmux("new-session", "-d", "-x", "120", "-y", "40", "-c", @sandbox,
         "-s", @session,
         "exec ruby #{@wrapper.shellescape} #{@dir.shellescape} #{TART_ROOT.shellescape} #{@sandbox.shellescape} #{@mock.port}")
  end

  def settle
    # Phase 1: the boot window — the pane's wrapper spawns tart (writes
    # tart.pid within ~10-50ms) and the TUI boots to its settled idle screen.
    deadline = monotonic + SETTLE_CAP
    until tart_pid
      fail!("boot never settled (tmux session gone)") unless session_exists?
      fail!("boot never settled (tart pid missing at the cap)") if monotonic > deadline
      sleep 0.1
    end
    # Phase 2: the screen-stability settle (the rig's capture-stability
    # discipline: SETTLE_POLLS identical captures, then one extra breath).
    prev = nil
    stable = 0
    deadline = monotonic + SETTLE_CAP
    while stable < SETTLE_POLLS
      fail!("boot never settled (tmux session gone)") unless session_exists?
      cur = capture_digest
      stable = cur == prev && cur != "" ? stable + 1 : 0
      prev = cur
      break if stable >= SETTLE_POLLS
      fail!("boot never settled (screen still changing at the cap)") if monotonic > deadline
      sleep 0.3
    end
    sleep 0.5
    fail!("tart died before delivery") unless pid_alive?(tart_pid)
  end

  def arm_shape
    case spec[:shape]
    when :idle then nil
    when :mid_stream
      tmux("send-keys", "-t", @session, PROMPT_STREAM, "Enter")
      deadline = monotonic + TOOL_WAIT_CAP
      while @mock.request_count.zero?
        fail!("the submitted turn never reached the mock") if monotonic > deadline
        sleep 0.05
      end
      sleep 0.6 # inside the drip (a 0.1s/char stream over ~240 chars)
    when :mid_tool
      tmux("send-keys", "-t", @session, PROMPT_TOOL, "Enter")
      deadline = monotonic + TOOL_WAIT_CAP
      while pgrep("tsleep-#{@token}").empty?
        fail!("the bash tool child never started") if monotonic > deadline
        sleep 0.1
      end
      @tool_child = pgrep("tsleep-#{@token}").first
    end
  end

  # --- delivery + the bound

  def deliver
    case spec[:signal]
    when "HUP" then tmux("kill-session", "-t", @session) # the pane group's SIGHUP
    when "TERM"
      fail!("tart already dead before TERM delivery") unless pid_alive?(tart_pid)
      Process.kill("TERM", tart_pid) # delivered DIRECTLY, not via tmux
    end
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  # Polls the wrapper's exit file with the EXIT_BOUND_S deadline, watching
  # the flush leg's ingest count in the same loop: a POST observed while the
  # exit file does NOT exist yet proves the flush ran BEFORE the exit.
  def await_exit(t0)
    exit_file = File.join(@dir, "exit.txt")
    deadline = t0 + EXIT_BOUND
    until File.exist?(exit_file)
      fail!(format("no exit within the %ds bound", EXIT_BOUND)) if monotonic > deadline
      @post_seen ||= monotonic if @ingest && @ingest.post_count >= 1
      sleep 0.05
    end
    [Integer(File.read(exit_file).strip.sub(/\AEXIT=/, "")),
     Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0]
  end

  # --- the frozen per-leg assertions

  def post_checks
    fail!("exit code #{@code.inspect}, want exactly #{@expect}") unless @code == @expect
    @raw = read_raw
    fail!("raw wire status #{@raw.inspect}, want exactly #{@expect} — the mapped code must ride the wire (dual record, zero masking)") unless @raw == @expect
    fail!(format("exit took %.1fs, over the %ds bound", @elapsed, EXIT_BOUND)) if @elapsed > EXIT_BOUND
    check_flush if spec[:sink]
    check_session_file if spec[:shape] == :mid_stream
    sleep GRACE
    survivors = pgrep(@token)
    fail!("survivors after bound+grace: #{survivors.join(" ")}") unless survivors.empty?
    fail!("the leg's tmux session is still alive") if session_exists?
    @clean = true
  end

  def read_raw
    path = File.join(@dir, "exit_raw.txt")
    fail!("the wrapper recorded no raw wire status (exit_raw.txt missing)") unless File.exist?(path)
    Integer(File.read(path).strip.sub(/\AEXIT_RAW=/, ""))
  end

  # The flush leg: the ingest server received the terminal POST (with
  # X-Session-Complete: true) BEFORE the process exit (the flush tail ran —
  # the load-bearing F5 fix). Ordering proof: a POST observed while the exit
  # file did not exist yet (the causal chain POST -> process death -> the
  # wrapper's EXIT= write), or — fallback — the observation time no later
  # than the exit file's mtime + slack.
  def check_flush
    fail!("the ingest server received no POST") unless @ingest.wait_posts(1, 5.0)
    last = @ingest.posts.last
    header = last[:headers]["x-session-complete"]
    fail!("no X-Session-Complete header on the terminal POST (got #{last[:headers].inspect})") unless header == "true"
    return if @post_seen # observed before the exit file existed — airtight
    exit_at = File.mtime(File.join(@dir, "exit.txt"))
    fail!("the POST's arrival could not be ordered before the exit") unless Time.now <= exit_at + 0.05
  end

  def check_session_file
    files = Dir[File.join(@sessions_dir, "**", "*.jsonl")]
    fail!("no session file under #{File.join(@home, '.tart', 'sessions')}") if files.empty?
    path = files.max_by { |f| File.mtime(f) }
    lines = File.readlines(path)
    fail!("session file #{path} is empty") if lines.empty?
    lines.each_with_index do |line, i|
      begin
        JSON.parse(line)
      rescue JSON::ParserError => e
        fail!("session file line #{i + 1} does not parse: #{e.message[0, 80]}")
      end
    end
    fail!("the session file lost the submitted turn") unless File.read(path).include?(PROMPT_STREAM)
  end

  # --- teardown (self-owned token only)

  def teardown
    tmux("kill-session", "-t", @session) if @session
    out = pgrep(@token)
    out.each { |pid| Process.kill("KILL", pid.to_i) rescue nil } unless out.empty?
    @mock&.stop
    @ingest&.stop
    FileUtils.rm_r(@dir) if File.exist?(@dir) && @clean
  rescue StandardError
    nil
  end

  # --- plumbing

  def tmux(*args)
    out, err, st = Open3.capture3("tmux", *args)
    # kill-session tolerates an already-dead session/server (leg teardown).
    return out if st.success? || args.first == "kill-session"
    fail!("tmux #{args.first}: #{err[0, 120]}")
  end

  def session_exists?
    system("tmux", "has-session", "-t", @session, out: File::NULL, err: File::NULL)
  end

  def capture_digest
    out, _err, _st = Open3.capture3("tmux", "capture-pane", "-p", "-t", @session)
    out.lines.reject { |l| l.strip.empty? }.last(3).join
  end

  def tart_pid
    path = File.join(@dir, "tart.pid")
    @tart_pid ||= (File.exist?(path) ? Integer(File.read(path).strip) : nil)
  end

  def pid_alive?(pid)
    Process.kill(0, pid)
    true
  rescue StandardError
    false
  end

  def pgrep(pattern)
    out, _err, _st = Open3.capture3("pgrep", "-f", pattern)
    out.split("\n").map(&:strip).reject(&:empty?)
  end

  def monotonic
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def fail!(message)
    @failed = true
    raise FAIL, message
  end

  EXIT_BOUND = Tart::TUI::SignalGuard::EXIT_BOUND_S # the frozen constant, live
end

def main
  out = "t75sig"
  ARGV.each_with_index { |arg, i| out = ARGV[i + 1] if arg == "--out" && ARGV[i + 1] }
  out_dir = File.expand_path(out, Dir.pwd)
  FileUtils.rm_rf(out_dir) # the harness owns its out dir per run
  FileUtils.mkdir_p(out_dir)

  records = []
  failures = []
  LEGS.each do |name, spec|
    runner = LegRunner.new(name, spec, out_dir)
    next failures << name unless runner.run
    records << runner.record
    $stdout.flush
  end
  File.write(File.join(out_dir, "legs.json"), JSON.pretty_generate(records))
  if failures.empty?
    puts "SIGNAL_ORPHAN_OK"
    exit 0
  end
  warn "SIGNAL_ORPHAN_FAIL: failing legs: #{failures.join(", ")}"
  exit 1
end

main if $PROGRAM_NAME == __FILE__
