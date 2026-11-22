# frozen_string_literal: true

require "async"
require "json"

require_relative "../child_env"

module Tart
  module Mcp
    # The stdio transport (port of pi's packages/mcp/src/transports/stdio.ts):
    # newline-delimited JSON-RPC over the server child's stdin/stdout.
    #
    # - the child runs in its own process group, killed as a group on close
    #   (wrappers like npx/uvx leave no orphans);
    # - stderr is capped at 64KB and passed through chunk by chunk
    #   (default: $stderr);
    # - close: close stdin and let the server exit, then SIGTERM the group,
    #   then SIGKILL; the child is reaped before close returns.
    #
    # I107 (T6/V2 — the concurrency law): the reader, the stderr drainer,
    # and the stdin writer run as tasks on the HOST REACTOR (TRANSIENT —
    # they never hold the reactor open; the teardown cancel is their
    # unwind path, and close() stops them explicitly). The stdin write
    # serializes through a single-writer mailbox (an Async::Queue + one
    # writer task — the @write_mutex replacement): a payload larger than
    # PIPE_BUF parks mid-write, so two concurrent writer fibers could
    # interleave bytes; the mailbox FIFO makes the ordering exact. A write
    # failure is recorded and the NEXT send fails fast with the same
    # ConnectionClosedError class (an in-flight request fails through the
    # transport-close path, as before). start/close run on a reactor seat
    # (production: the tool-call tasks; tests: Sync-wrapped scenarios).
    class Stdio
      DEFAULT_MAX_MESSAGE_BYTES = 16 * 1024 * 1024
      DEFAULT_MAX_STDERR_BYTES = 64 * 1024
      # How long a server gets to exit on its own after stdin closes, before
      # it is sent SIGTERM.
      STDIN_CLOSE_GRACE_MS = 500
      DEFAULT_CLOSE_TIMEOUT_MS = 2_000

      # Process groups of running servers, killed if the host exits without
      # closing them (pi's liveProcessGroups + exit hook).
      LIVE_GROUPS = []
      private_constant :LIVE_GROUPS

      at_exit do
        LIVE_GROUPS.each { |pid| Stdio.kill_group(pid, "TERM") }
      end

      attr_reader :pid
      attr_accessor :on_message, :on_error, :on_close, :on_stderr

      def initialize(command:, args: [], env: nil, cwd: nil,
                     max_message_bytes: DEFAULT_MAX_MESSAGE_BYTES,
                     max_stderr_bytes: DEFAULT_MAX_STDERR_BYTES,
                     close_timeout_ms: DEFAULT_CLOSE_TIMEOUT_MS)
        @command = command
        @args = args || []
        @env = env
        @cwd = cwd
        @max_message_bytes = max_message_bytes
        @max_stderr_bytes = max_stderr_bytes
        @close_timeout_ms = close_timeout_ms
        @on_message = @on_error = @on_close = @on_stderr = nil
        @started = false
        @closed = false
        # The single-writer mailbox (I107 T6): send() enqueues; the writer
        # task writes FIFO. The first write failure lands here (bare flag)
        # and the next send fails fast.
        @mailbox = Async::Queue.new
        @writer_error = nil
        @reader = @stderr_task = @writer = nil
      end

      # @raise [Errno::ENOENT, Errno::EACCES] when the command cannot spawn
      #   (pi rejects start's promise with the spawn error).
      def start
        raise "MCP stdio transport already started" if @started
        raise ConnectionClosedError if @closed
        task = Async::Task.current? or raise ArgumentError,
          "MCP stdio start runs on the host reactor (Sync-wrapped scenario or tool task)"

        @started = true
        spawn_child
        @writer = task.async(transient: true) { write_loop }
        @reader = task.async(transient: true) do
          read_loop
        rescue StandardError => e
          emit_error(e)
        end
        @stderr_task = task.async(transient: true) { stderr_loop }
      end

      def send(message)
        raise ConnectionClosedError if @closed || !@stdin_w || @stdin_w.closed?
        raise ConnectionClosedError.new(@writer_error.message) if @writer_error

        @mailbox << "#{JSON.generate(message)}\n"
        nil
      end

      # Shutdown per the spec: close stdin and let the server exit, then
      # SIGTERM, then SIGKILL (stdio.ts close()). The transport tasks are
      # stopped first (Cancel lands at their parks — bounded); the child
      # ladder is unchanged and the child is reaped before close returns.
      def close
        return if @closed

        @closed = true
        stop_transport_tasks
        @stdin_w&.close unless @stdin_w.nil? || @stdin_w.closed?
        reap_child
        close_pipes
        emit_close
      end

      def closed?
        @closed
      end

      # The stderr accumulated so far, capped to the last max_stderr_bytes
      # (pi's stderr getter).
      def stderr
        @stderr_buffer ||= +""
      end

      def self.kill_group(pid, signal)
        Process.kill(signal, -pid)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end

      private

      def spawn_child
        stdin_r, @stdin_w = IO.pipe
        @stdout_r, stdout_w = IO.pipe
        @stderr_r, stderr_w = IO.pipe
        # I73: the child gets an explicit scrubbed copy of the parent env
        # (Tart::ChildEnv.scrub — the bundler-export cure) with the config
        # env merged on top, config wins (the current @env handling,
        # byte-preserved), spawned EXPLICITLY with unsetenv_others —
        # pi's letter (stdio.ts:94: node always passes a full env copy;
        # Ruby's Process.spawn(env, …) merges over inherit, which was the
        # letter-divergent shape). Observable-identical when tart is
        # launched clean (the scrub is a no-op there).
        base = ChildEnv.scrub(ENV.to_h)
        base.merge!(@env) if @env
        options = {pgroup: true, in: stdin_r, out: stdout_w, err: stderr_w, unsetenv_others: true}
        options[:chdir] = @cwd if @cwd
        @pid = Process.spawn(base, @command, *@args, **options)
        LIVE_GROUPS << @pid
        # The child owns its ends now.
        stdin_r.close
        stdout_w.close
        stderr_w.close
      end

      # Frames stdout into lines (pi's handleStdout buffer): split on newlines,
      # drop an unterminated tail with the oversize error, report an
      # incomplete trailing message when the server closes mid-frame.
      def read_loop
        buffer = +""
        while (chunk = @stdout_r.readpartial(4096))
          buffer << chunk
          while (newline = buffer.index("\n"))
            handle_line(buffer.slice!(0, newline + 1))
          end
          if buffer.bytesize > @max_message_bytes
            buffer.clear
            emit_error(StandardError.new("MCP stdio message exceeds #{@max_message_bytes} bytes"))
          end
        end
        return if buffer.strip.empty?

        emit_error(StandardError.new("MCP stdio server closed with an incomplete JSON-RPC message"))
      rescue EOFError
        nil # the server closed its stdout
      ensure
        emit_close
      end

      def handle_line(line)
        line = line.chomp.sub(/\r$/, "")
        return if line.strip.empty?
        if line.bytesize > @max_message_bytes
          emit_error(StandardError.new("MCP stdio message exceeds #{@max_message_bytes} bytes"))
          return
        end

        message = JSON.parse(line)
        @on_message&.call(JsonRpc.parse_message(message))
      rescue JSON::ParserError, Mcp::Error => e
        emit_error(e)
      end

      def stderr_loop
        while (chunk = @stderr_r.readpartial(4096))
          buffer = stderr
          buffer << chunk
          buffer.slice!(0, buffer.bytesize - @max_stderr_bytes) if buffer.bytesize > @max_stderr_bytes
          @on_stderr&.call(chunk)
        end
      rescue IOError, Errno::EBADF, EOFError
        nil # closed under us at teardown
      end

      def reap_child
        return unless @pid

        unless exited_within?(STDIN_CLOSE_GRACE_MS)
          kill_group("TERM")
          unless exited_within?(@close_timeout_ms)
            kill_group("KILL")
            Process.waitpid(@pid)
          end
        end
      ensure
        LIVE_GROUPS.delete(@pid) if @pid
      end

      def exited_within?(ms)
        deadline = clock_ms + ms
        while clock_ms < deadline
          _, status = Process.waitpid2(@pid, Process::WNOHANG)
          return true if status

          sleep 0.005
        end
        _, status = Process.waitpid2(@pid, Process::WNOHANG)
        !status.nil?
      end

      def reap_threads
        close_pipes
      end

      # The transport tasks' unwind (D2 — bounded reap before the drain
      # waits): Task#stop cancels each at its park (the mailbox pop, the
      # stdout/stderr readpartial); a dead task is a no-op (the post-
      # reactor close seat). The cancelled reader's ensure fires
      # emit_close, same as the EOF path.
      def stop_transport_tasks
        [@writer, @reader, @stderr_task].each do |task|
          next unless task&.alive?

          task.stop
          begin
            task.wait
          rescue Async::Cancel, StandardError
            nil # the unwind is the point; the parks are bounded
          end
        end
      end

      def close_pipes
        @stdout_r&.close
        @stderr_r&.close
      rescue IOError
        nil
      end

      # The single writer: FIFO over the mailbox (the @write_mutex
      # replacement). A write failure is recorded — send() fails fast on
      # the next call with the same ConnectionClosedError class — and the
      # task ends (the transport is dying either way).
      def write_loop
        while (payload = @mailbox.pop)
          @stdin_w.write(payload)
          @stdin_w.flush
        end
      rescue Errno::EPIPE, IOError, SystemCallError => e
        @writer_error = e
      ensure
        begin
          @mailbox.close
        rescue StandardError
          nil
        end
      end

      def kill_group(signal)
        return unless @pid

        Stdio.kill_group(@pid, signal)
      end

      def emit_error(error)
        @on_error&.call(error)
      end

      # Fired once, whether the server closed or close() was called.
      def emit_close
        return if @close_emitted

        @close_emitted = true
        @on_close&.call
      end

      def clock_ms
        Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000
      end
    end
  end
end
