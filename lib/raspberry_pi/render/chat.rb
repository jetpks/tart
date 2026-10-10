# frozen_string_literal: true

module RaspberryPi
  module Render
    # The interactive chat surface (BRIEF §7.1) — the I04 consumer of the I03
    # agent event surface on the I02 kernel.
    #
    # Render model (ported from pi's tui-main-screen.ts): completed content
    # lands as scrollback *above* the live region, the live region at the
    # bottom carries status/spinner, the pending-approval prompt, and the
    # input line. Mechanism is §5.1-sanctioned foundation mechanics: pi
    # diff-redraws the main screen itself; here the ratatui_ruby inline
    # viewport is the live region and {TUI} scrollback insertion
    # (+insert_before+) is how completed content lands above it. Observable
    # contract is parity: completed messages readable above a live bottom
    # region, streaming visible while it happens, terminal restored on
    # exit/interrupt.
    #
    # Threading: all draws and scrollback insertions happen on the kernel's
    # frame loop (the renderer proc); agent events mutate state under a mutex
    # from the agent fiber; key events arrive through the kernel's on_event.
    # The agent runs as a kernel task (+kernel.async { agent.run }+, event-only
    # run mode) so a kernel interrupt (Ctrl+C) cancels the in-flight turn.
    #
    # Approval: the approval callback runs on the kernel fiber and waits on an
    # +Async::Queue#pop+ — interruptible at the suspension point by
    # Task#stop. The decision is pushed cross-thread (the I03 lost-wakeup
    # cure: a fiber-to-fiber +Async::Queue+ push on the same thread can fail
    # to wake a blocked pop; a cross-thread push is the proven path).
    class Chat
      SPINNER = %w[⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏].freeze

      # How long one draw re-arms the animation window while the agent works
      # (frame pacing: deadline-paced at the frame rate while busy, purely
      # event-driven when idle — the I02 static-loop property).
      BUSY_FRAME_SECONDS = 0.25

      # @param session the TUI session (inline viewport).
      # @param kernel [Core::Loop] the kernel; used to open animation windows
      #   and to submit agent runs as kernel tasks.
      def initialize(session:, kernel:)
        @session = session
        @kernel = kernel
        @agent = nil
        @mutex = Mutex.new
        @input = +""
        @live = +""
        @busy = false
        @tool = nil
        @pending = nil
        @frames = 0
        @decisions = Async::Queue.new
        # Completed lines awaiting scrollback insertion on the next frame
        # (thread-safe: agent fiber produces, frame loop consumes).
        @scrollback = Queue.new
      end

      # The agent loop this surface drives (wired after construction: the
      # agent's on_event/approval procs reference this chat).
      attr_accessor :agent

      # @return [Object, nil] the tool call awaiting an approval decision.
      def pending_approval
        @mutex.synchronize { @pending }
      end

      # @return [Boolean] whether an agent run is in flight.
      def busy?
        @mutex.synchronize { @busy }
      end

      # @return [String] the input line buffer (input is not rendered while
      #   an approval prompt is pending; keys are consumed by the prompt).
      attr_reader :input

      # The kernel renderer proc: drains queued scrollback above the viewport,
      # then builds the live-region widget. A String result would be wrapped
      # in TUI.status_panel by the kernel; this returns the widget itself.
      def renderer
        @renderer_proc ||= -> { render_frame }
      end

      def render_frame
        flush_scrollback
        widget = nil
        @mutex.synchronize do
          @frames += 1
          widget = build_widget
        end
        # Keep frames deadline-paced while the agent works (spinner, live
        # region); idle goes event-driven again on agent_end.
        @kernel.animate(duration: BUSY_FRAME_SECONDS) if busy?
        widget
      end

      # Kernel event sink (every dispatched event, native or synthetic).
      # Ctrl+C never reaches here — the kernel owns it (interrupt).
      def on_event(event, _source = nil)
        return unless event.key? || event.paste?

        decided = nil
        @mutex.synchronize { decided = @pending }
        if decided
          decide(event)
        else
          edit_input(event)
        end
      end

      # Agent event sink (I03 event surface). Runs on the agent fiber.
      def on_agent_event(event)
        handled = nil
        @mutex.synchronize do
          case event[:type]
          when :agent_start
            @busy = true
          when :message_start
            @live = +""
          when :message_update
            chunk = event[:chunk]
            @live << chunk.content if chunk.content.is_a?(String) && !chunk.content.empty?
          when :message_end
            message = event[:message]
            handled = complete(message.content) if message.role == :assistant
          when :tool_execution_start
            @tool = event[:tool_call].name
          when :tool_execution_end
            @tool = nil
            handled = tool_line(event[:tool_call].name, event[:result])
          when :agent_end
            @busy = false
            handled = if event[:interrupted] == true
              "interrupted"
            elsif event[:error]
              "error: #{event[:error].message}"
            end
            # A message submitted in the wind-down window (after the agent's
            # final steering check, before agent_end) sits queued with no run
            # in flight — continue the run (pi's queued-message semantics:
            # pi polls the queue at loop start, agent-loop.ts:175).
            if handled.nil? && @agent&.queued_messages?
              @kernel.async { @agent.run }
            end
          end
        end
        enqueue_scrollback(handled) if handled
        @kernel.animate(duration: BUSY_FRAME_SECONDS)
      end

      # The agent loop's approval callback (runs on the kernel fiber).
      # Waits interruptibly for the key-driven decision; +false+ (deny) is
      # the default outcome, pi's permission-dialog semantics.
      def approval(tool_call)
        @mutex.synchronize { @pending = tool_call }
        decision = false
        begin
          @kernel.animate(duration: BUSY_FRAME_SECONDS)
          decision = @decisions.pop # interruptible: Task#stop raises here
        ensure
          @mutex.synchronize { @pending = nil }
          # A raced decision must not pre-approve a later call.
          @decisions.pop until @decisions.empty?
        end
        decision
      end

      class << self
        # Greedy word wrap to +width+ visible columns; over-long words hard-split.
        # pi wraps with ANSI/grapheme awareness (utils.ts); plain text is this
        # iteration's recorded scope.
        def wrap(text, width)
          return [""] if text.empty?

          text.lines(chomp: true).flat_map { |line| wrap_line(line, width) }
        end

        def wrap_line(line, width)
          out = []
          while TUI.text_width(line) > width
            head, consumed = fit(line, width)
            out << head
            line = line[consumed..]
          end
          out << line
          out
        end

        # Longest prefix of +line+ fitting +width+, preferring a word break.
        # Returns [head, chars_consumed].
        def fit(line, width)
          w = 0
          line.chars.each_with_index do |char, i|
            char_width = TUI.text_width(char)
            break if w + char_width > width

            w += char_width
          end
          return [line, w] if w == line.length

          if line[w] == " "
            [line[0, w], w + 1] # word boundary at the width edge; consume the space
          elsif (space_break = line[0, w].rindex(" "))
            [line[0, space_break], space_break + 1] # break before the last word; consume the space
          elsif w.positive?
            [line[0, w], w] # hard split
          else
            [line.chars.first, 1] # over-wide first grapheme; force progress
          end
        end
      end

      private

      # Completed content: queued for insertion above the live region,
      # wrapped to the viewport width. Mutex context (called from
      # on_agent_event); returns the final text (nil when nothing to show).
      def complete(text)
        @live = +""
        return nil if !text.is_a?(String) || text.empty?

        text
      end

      def enqueue_scrollback(line)
        return if line.nil? || line.empty?

        @scrollback << Chat.wrap(line, viewport_width)
      end

      def tool_line(name, result)
        text = result.is_a?(Hash) ? (result[:error] || result[:content] || "").to_s : result.to_s
        preview = text.lines(chomp: true).first.to_s
        "  ⎿ #{name}: #{preview}"
      end

      def viewport_width
        area = @session.viewport_area
        area ? area.width : 80
      end

      # Pending-approval keys: y/Y approve, n/N deny, everything else is
      # consumed by the prompt (never reaches the chat input line).
      def decide(event)
        return unless event.key?

        case event.code
        when "y", "Y" then resolve(true)
        when "n", "N" then resolve(false)
        end
      end

      # Cross-thread push (the I03 lost-wakeup cure): the waiting fiber is on
      # the reactor thread; a fiber-to-fiber Async::Queue push can fail to
      # wake it, a cross-thread push is the proven path.
      def resolve(value)
        Thread.new { @decisions << value }.join
      end

      def edit_input(event)
        if event.paste?
          @input << event.content
        else
          case event.code
          when "enter" then submit
          when "backspace" then @input.chop!
          else
            printable = event.text? && !(event.modifiers & %w[ctrl alt]).any?
            @input << event.code if printable
          end
        end
      end

      def submit
        text = @input.dup
        return if text.strip.empty?

        @input.clear
        enqueue_scrollback("❯ #{text}")
        if busy?
          @agent.push_message(text) # steering: consumed at the next turn boundary
        else
          @kernel.async { @agent.run(text) }
        end
      end

      # pi's live region: the bottom viewport shows status, the streaming
      # message tail, and the input line — as many rows as the viewport
      # affords, everything beyond clipped at the top. During an approval
      # prompt the input line is displaced (pi: the dialog replaces the
      # editor in the editor container) and its keys are consumed.
      def build_widget
        lines = []
        lines << status_line if @busy
        lines.concat(live_lines)
        if @pending
          lines.concat(approval_lines)
        else
          lines << "❯ #{@input}"
        end
        lines = lines.last(viewport_height) if viewport_height
        TUI.paragraph(text: lines.join("\n"), wrap: false)
      end

      def status_line
        detail = @tool ? "tool: #{@tool}" : (@live.empty? ? "thinking" : "…")
        "#{SPINNER[@frames % SPINNER.size]} #{detail}"
      end

      # The streaming text, wrapped to the viewport width, as many tail
      # lines as fit above the status/input rows (deltas append; the
      # window slides).
      def live_lines
        return [] if @live.empty?

        wrapped = self.class.wrap(@live, viewport_width)
        budget = viewport_height ? viewport_height - 1 - (@busy ? 1 : 0) - (@pending ? 0 : 1) : wrapped.size
        wrapped.last([budget, 0].max)
      end

      def viewport_height
        area = @session.viewport_area
        area ? area.height : nil
      end

      def approval_lines
        args = JSON.generate(@pending.arguments) rescue @pending.arguments.to_s
        [
          "approve #{@pending.name}?",
          args.length > viewport_width ? args[0, viewport_width] : args,
          "y = yes, n = no"
        ]
      end

      # Insert queued lines above the live viewport (pi: completed content
      # into scrollback). Must never run inside a draw — the kernel calls the
      # renderer before drawing, and insert_before itself raises during draw.
      def flush_scrollback
        until @scrollback.empty?
          lines = @scrollback.pop
          @session.insert_before(lines.size, TUI.paragraph(text: lines.join("\n")))
        end
      end
    end
  end
end
