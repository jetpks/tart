# frozen_string_literal: true

require_relative "../test_helper"

module Tart
  module Render
    # The I58 render-perf pins (AC2/AC4): the live region's conversion
    # cache (recompute iff the [width, live bytes, reasoning bytes] key
    # changes; rows byte-identical to the uncached computation incl. reset
    # cycles), the dirty marks (agent events request one draw each), the
    # spinner tick (armed while busy / a user-bash stream runs, cancelled
    # at the ends, fired at the spinner interval), and the agent_end
    # wind-down's single request_draw. Builder-level pins; the retired
    # animation-window re-arms' re-pin lives in chat_test (the bash loader
    # class), the kernel tick's own pins in loop_test.
    class RenderPerfTest < Test
      WIDTH = 60

      # The event doubles (the recorded streaming shapes — chat_test's
      # local shapes, restated here: the render_perf filter keeps this
      # file self-contained under its own -n run).
      Chunk = Struct.new(:content, :thinking)
      Msg = Struct.new(:role, :content, :tokens)
      ToolCall = Struct.new(:name, :arguments)

      # The tick-recording kernel double (IdleKernel's shape — chat_test's
      # double is out of this file's load path): records the armed tick
      # intervals + their cancel handles and the request_draw count.
      class TickKernel
        attr_reader :ticks, :tick_handles, :draws, :animate_calls

        def initialize
          @ticks = []
          @tick_handles = []
          @draws = 0
          @animate_calls = []
        end

        def animate(duration:)
          @animate_calls << duration
          nil
        end

        def request_draw
          @draws += 1
          nil
        end

        def tick(interval)
          @ticks << interval
          TickHandle.new.tap { |handle| @tick_handles << handle }
        end

        def async(&block)
          self
        end

        def stop! = nil

        # The task role (tick's return): records its cancel.
        class TickHandle
          def initialize
            @stopped = false
          end

          def stop
            @stopped = true
          end

          def stopped? = @stopped
        end
      end

      def setup
        @dir = Dir.mktmpdir("tart-render-perf-")
      end

      def teardown
        FileUtils.rm_rf(@dir)
      end

      # --- the live-region conversion cache (D2/AC2) ---

      # Recompute iff the key changes: a same-key frame (the spinner
      # tick's cached window) re-serves the SAME rows object; a delta (a
      # key change) recomputes; the reset sites clear the cache.
      def test_render_perf_live_cache_recomputes_only_when_the_key_changes
        with_chat do |chat, session|
          stream_delta(chat, "hello")
          compose(chat, session)
          first = chat.instance_variable_get(:@live_region_cache)
          assert first, "a drawn streaming frame populated the cache"

          compose(chat, session) # same key — the tick's cached window
          assert_same first[1], chat.instance_variable_get(:@live_region_cache)[1],
            "a same-key frame re-serves the cached rows (no recompute)"

          stream_delta(chat, " world", start: false) # the bytesize key moves
          compose(chat, session)
          refute_same first[1], chat.instance_variable_get(:@live_region_cache)[1],
            "a key change recomputes"

          chat.on_agent_event({type: :message_end, message: Msg.new(:assistant, "hello world")})
          assert_nil chat.instance_variable_get(:@live_region_cache),
            "the :message_end reset clears the cache (no stale size hits)"
        end
      end

      # The rows are byte-identical to the uncached computation at every
      # live/reasoning size and across reset cycles — including the
      # same-size different-content collision a naive size key would
      # serve stale (the reset-site clearing is what makes the size key
      # exact; the fresh chat's single end-state draw IS the uncached
      # computation).
      def test_render_perf_live_cache_rows_are_byte_identical_across_sizes_and_reset_cycles
        script = [
          [:message_start, Msg.new(:assistant, nil)],
          [:delta, "hello "], # 6 B
          [:delta, "world **bold** row"], # 22 B
          [:thinking_delta, "pondering"],
          [:delta, "x" * 60],
          [:message_end, Msg.new(:assistant, "hello world **bold** row ...")],
          # The reset cycle: new message grows through the SAME sizes with
          # DIFFERENT content — a stale size hit would serve message 1's rows.
          [:message_start, Msg.new(:assistant, nil)],
          [:delta, "goodbye "], # 8 B
          [:delta, "cruel **italic** world"], # 23 B
          [:delta, "y" * 60], # same size class, different bytes
          [:message_end, Msg.new(:assistant, "goodbye cruel **italic** world")]
        ]

        TUI.run(headless: true, viewport: :fullscreen, width: WIDTH, screen_height: 24) do |session|
          # Two identical surfaces on one terminal: the cached chat draws at
          # EVERY step (max cache pressure); the fresh chat draws ONCE at the
          # end — its single compose IS the uncached computation.
          cached = build_chat(session, TickKernel.new)
          fresh = build_chat(session, TickKernel.new)
          script.each do |kind, payload|
            fire_event(cached, kind, payload)
            fire_event(fresh, kind, payload)
            compose(cached, session)
          end
          compose(fresh, session)

          assert_equal fingerprints(fresh.display_lines), fingerprints(cached.display_lines),
            "cached rows byte-identical to the uncached computation at every size and across resets"
        end
      end

      # --- the dirty marks (AC1/AC4): one draw request per state change ---

      def test_render_perf_agent_events_each_request_exactly_one_draw
        kernel = TickKernel.new
        TUI.run(headless: true, viewport: :fullscreen, width: WIDTH, screen_height: 24) do |session|
          chat = build_chat(session, kernel)
          chat.on_agent_event({type: :message_start, message: Msg.new(:assistant, nil)})
          baseline = kernel.draws

          chat.on_agent_event({type: :message_update, chunk: Chunk.new("delta text", nil)})
          assert_equal baseline + 1, kernel.draws, "a streaming delta requests exactly one paint"

          chat.on_agent_event({type: :tool_execution_start, tool_call: ToolCall.new("bash", {command: "ls"})})
          assert_equal baseline + 2, kernel.draws, "a tool start requests exactly one paint"

          chat.on_agent_event({type: :tool_execution_end, tool_call: ToolCall.new("bash", {command: "ls"}),
                               result: "fixture", duration: 0.01})
          assert_equal baseline + 3, kernel.draws, "a tool end requests exactly one paint"

          chat.on_agent_event({type: :compaction_start, reason: :threshold})
          assert_equal baseline + 4, kernel.draws, "a compaction start requests exactly one paint"

          chat.on_agent_event({type: :compaction, entries: [], summary: "Earlier turns summarized.",
                               tokens_before: 15})
          assert_equal baseline + 5, kernel.draws, "the compaction result requests exactly one paint"
        end
      end

      # The wind-down replacement (D1): the retired arm re-opened a 0.25 s
      # animation window at :agent_end; now the sink's tail requests ONE
      # paint of the settled state.
      def test_render_perf_agent_end_paints_once_via_request_draw
        kernel = TickKernel.new
        TUI.run(headless: true, viewport: :fullscreen, width: WIDTH, screen_height: 24) do |session|
          chat = build_chat(session, kernel)
          chat.on_agent_event({type: :agent_start})
          chat.on_agent_event({type: :message_start, message: Msg.new(:assistant, nil)})
          chat.on_agent_event({type: :message_update, chunk: Chunk.new("streaming", nil)})
          before = kernel.draws

          chat.on_agent_event({type: :agent_end})
          assert_equal before + 1, kernel.draws,
            "the wind-down is exactly one request_draw (no animation window)"
          assert_empty kernel.animate_calls, "no animate call remains on the busy path"
        end
      end

      # --- the spinner tick (D1/AC4) ---

      def test_render_perf_spinner_tick_arms_while_busy_and_cancels_at_agent_end
        kernel = TickKernel.new
        TUI.run(headless: true, viewport: :fullscreen, width: WIDTH, screen_height: 24) do |session|
          chat = build_chat(session, kernel)

          chat.on_agent_event({type: :agent_start})
          assert_equal [Chat::SPINNER_INTERVAL_SECONDS], kernel.ticks,
            "the tick arms at :agent_start at pi's Loader interval"
          assert kernel.tick_handles.none?(&:stopped?), "the tick is live for the run"

          # The compaction re-anchor must not double-arm (a live tick is kept).
          chat.on_agent_event({type: :compaction_start, reason: :threshold})
          assert_equal 1, kernel.ticks.length, "a live tick is kept, not re-armed"

          chat.on_agent_event({type: :agent_end})
          assert kernel.tick_handles.all?(&:stopped?), "the tick cancels at :agent_end"
        end
      end

      def test_render_perf_user_bash_stream_arms_and_cancels_the_spinner_tick
        kernel = TickKernel.new
        TUI.run(headless: true, viewport: :fullscreen, width: WIDTH, screen_height: 24) do |session|
          chat = build_chat(session, kernel)

          chat.send(:start_user_bash_stream, "echo hi", false)
          assert_equal [Chat::SPINNER_INTERVAL_SECONDS], kernel.ticks,
            "the tick arms at the user-bash stream start"
          draws_after_start = kernel.draws
          chat.send(:append_user_bash_stream, "hi\n")
          assert_operator kernel.draws, :>, draws_after_start,
            "the chunk sink still requests its draw per chunk (the I38 discipline)"

          chat.send(:end_user_bash_stream)
          assert kernel.tick_handles.all?(&:stopped?), "the tick cancels at the stream's end"
        end
      end

      # The tick's cadence is pi's own (loader.ts:12/:82-99 — the interval
      # advances the frame, then updateDisplay calls requestRender): fired
      # against the REAL kernel (Loop#tick's absolute schedule — the
      # reactor clock; Loop takes no injected clock, so the cadence rides
      # the real monotonic one) at the spinner dwell itself.
      def test_render_perf_spinner_tick_fires_at_the_spinner_interval
        session = ScriptedSession.new
        fire_times = Queue.new
        event_loop = Core::Loop.new(session:, renderer: -> {
          fire_times << Process.clock_gettime(Process::CLOCK_MONOTONIC)
          "frame"
        })

        event_loop.run do
          wait_until { !session.drawn.empty? } # the boot render
          task = event_loop.tick(Chat::SPINNER_INTERVAL_SECONDS)
          wait_until { fire_times.size >= 5 } # the boot + ≥4 fires at 80 ms
          task.stop
        end

        times = []
        begin
          loop { times << fire_times.pop(true) }
        rescue ThreadError
          nil
        end
        gaps = times.each_cons(2).map { |a, b| b - a }
        assert_operator gaps.length, :>=, 3, "enough fires to judge the cadence"
        gaps.each do |gap|
          assert_operator gap, :>=, Chat::SPINNER_INTERVAL_SECONDS - 0.005,
            "fires no faster than the dwell (got #{gap.round(4)}s)"
          assert_operator gap, :<=, Chat::SPINNER_INTERVAL_SECONDS + 0.05,
            "fires at ~80 ms (got #{gap.round(4)}s — the dwell + the reactor sleep overshoot)"
        end
      end

      private

      # Builds the chat on the headless test terminal (chat_test's
      # with_chat shape, local to this file).
      def with_chat
        TUI.run(headless: true, viewport: :fullscreen, width: WIDTH, screen_height: 24) do |session|
          chat = build_chat(session, TickKernel.new)
          yield chat, session
        end
      end

      # One render_frame compose through the real renderer seam.
      def compose(chat, session)
        session.draw(chat.renderer.call)
      end

      def build_chat(session, kernel)
        Chat.new(session:, kernel:, branch_reader: ->(_cwd) { nil }, motd: false,
                 settings_root: @dir)
      end

      # The fake event flow (the I03 surface's shapes — chat_test's stream
      # helper, restated): a :message_start reset, then the delta.
      def stream_delta(chat, text, start: true)
        chat.on_agent_event({type: :message_start, message: Msg.new(:assistant, nil)}) if start
        chat.on_agent_event({type: :message_update, chunk: Chunk.new(text, nil)})
      end

      def fire_event(chat, kind, payload)
        case kind
        when :message_start, :message_end
          chat.on_agent_event({type: kind, message: payload})
        when :delta
          chat.on_agent_event({type: :message_update, chunk: Chunk.new(payload, nil)})
        when :thinking_delta
          chat.on_agent_event({type: :message_update,
                               chunk: Chunk.new("", Agent::Thinking.new(text: payload))})
        end
      end

      # The row fingerprints (the byte pins): every span's content + its
      # color/modifier facts — text AND presentation must match the
      # uncached computation.
      def fingerprints(lines)
        lines.map do |line|
          line.spans.map do |span|
            style = span.style
            [span.content, style&.fg, style&.bg, style&.modifiers]
          end
        end
      end
    end
  end
end
