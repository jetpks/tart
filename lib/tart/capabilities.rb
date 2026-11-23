# frozen_string_literal: true

module Tart
  # The terminal capability seam (I111): the hyperlinks arm of pi's
  # detection, ported from
  # repos/pi/packages/tui/src/terminal-image.ts:50-175 (Grounds §2) —
  # detection order, the tmux probe, the override env, the cache. ENTRY 9
  # (terminal images) extends this module's arms additively: the cache is a
  # capabilities HASH, never a bare boolean, and the override parse is
  # shared. One namespace, frozen: Tart::Capabilities.
  #
  # Determinism law (I111): the module reads ambient detection env (TERM,
  # TERM_PROGRAM, …) only at the FIRST consult — the suite's test-helper
  # force-off (ENV["TART_HYPERLINKS"] ||= "0") makes every non-injecting
  # test render the OFF arm regardless of the seat's terminal, and the
  # reset!/inject seam forces the ON arm in pins. No Threads, no Mutex —
  # the probe's deadline is an IO/wait idiom (stdlib only).
  module Capabilities
    # pi probeTmuxHyperlinks' execSync timeout (terminal-image.ts:57) —
    # production-boot-only; tests inject the probe (never the clock).
    PROBE_BUDGET_S = 0.25

    class << self
      # @return [Boolean] whether the terminal supports OSC-8 hyperlinks —
      #   the CACHED first-read value (pi getCapabilities' cache,
      #   terminal-image.ts:163-175).
      def hyperlinks?
        capabilities[:hyperlinks]
      end

      # @return [Hash] the detected capability table (pi's
      #   TerminalCapabilities shape; images stays nil until ENTRY 9).
      #   Cached after the first read; +TART_HYPERLINKS=1|0+ beats
      #   detection including the tmux probe (pi PI_HYPERLINKS).
      def capabilities
        @capabilities ||= detect_capabilities
      end

      # The test seam: drops the cache so the next consult re-detects.
      # An injected probe stays armed until overwritten.
      def reset!
        @capabilities = nil
      end

      # The probe seam (injectable in tests; NO wall-clock in the suite —
      # the injected proc replaces the real tmux probe entirely).
      attr_writer :probe

      def probe
        @probe ||= -> { tmux_hyperlinks_probe }
      end

      # The probe's parse letter (public: the inject seam composes it —
      # the pin drives the split/trim/match over the raw features string):
      # tmux re-emits a comma list; hyperlinks must be a member after trim.
      def features_list_hyperlinks?(features)
        features.to_s.split(",").map(&:strip).include?("hyperlinks")
      end

      private

      # pi detectCapabilitiesFromEnvironment (terminal-image.ts:70-139),
      # every arm in order. The tmux arm consults the (possibly injected)
      # probe; the override env substitutes the probe wholesale (:146-160).
      def detect_capabilities
        override = parse_boolean(ENV["TART_HYPERLINKS"])
        tmux_forwards = override.nil? ? probe : -> { override }

        term = ENV["TERM"].to_s.downcase
        term_program = ENV["TERM_PROGRAM"].to_s.downcase
        terminal_emulator = ENV["TERMINAL_EMULATOR"].to_s.downcase
        color_term = ENV["COLORTERM"].to_s.downcase
        # pi hasTrueColorHint (:79) — the additive ENTRY-9 shape rides every
        # arm; the windows/jediterm arms' hardcoded trueColor nuance is that
        # entry's work, not this lane's.
        true_color = %w[truecolor 24bit].include?(color_term) || term.end_with?("-direct")

        hyperlinks =
          if ENV["TMUX"] || term.start_with?("tmux")
            # OSC-8 only when tmux confirms it forwards (:74-77). The
            # boolean coercion + the rescue keep ANY probe failure out of
            # the matrix — the consult answers false, never raises
            # (pi's catch is inside probeTmuxHyperlinks; the consult-side
            # belt covers the injected seam too).
            begin
              tmux_forwards.call ? true : false
            rescue StandardError
              false
            end
          elsif term.start_with?("screen")
            # screen strips OSC-8 (:81-83).
            false
          elsif term_program == "herdr"
            # herdr forwards; its panes leak the host terminal's vars, so
            # this arm runs BEFORE the leak-prone kitty/iterm checks (:86-89).
            true
          elsif ENV["KITTY_WINDOW_ID"] || term_program == "kitty"
            true
          elsif term_program == "ghostty" || term.include?("ghostty") || ENV["GHOSTTY_RESOURCES_DIR"]
            true
          elsif ENV["WEZTERM_PANE"] || term_program == "wezterm"
            true
          elsif term_program == "warpterminal" || ENV["WARP_SESSION_ID"] || ENV["WARP_TERMINAL_SESSION_UUID"]
            true
          elsif ENV["ITERM_SESSION_ID"] || term_program == "iterm.app"
            true
          elsif ENV["WT_SESSION"]
            true
          elsif %w[alacritty vscode zed].include?(term_program)
            true
          elsif terminal_emulator == "jetbrains-jediterm"
            false
          elsif windows_console?
            false
          else
            # Unknown terminal: conservative — a swallowing terminal renders
            # OSC-8 as visible junk (:134-139).
            false
          end

        # pi detectCapabilities' final spread (:160): the override beats
        # EVERY arm, not just the probe.
        { images: nil, true_color: true_color,
          hyperlinks: override.nil? ? hyperlinks : override }
      end

      # pi parseBooleanCapabilityOverride (:142-145).
      def parse_boolean(value)
        value == "1" ? true : value == "0" ? false : nil
      end

      def windows_console?
        RUBY_PLATFORM =~ /mingw|mswin/
      end

      # pi probeTmuxHyperlinks (:50-64): tmux re-emits OSC-8 only when its
      # client_termfeatures lists hyperlinks. ANY error → false (pi's
      # execSync timeout included). The 250 ms budget is an IO/wait idiom
      # (select + read_nonblock — no Thread, no Mutex).
      def tmux_hyperlinks_probe
        io = IO.popen(["tmux", "display-message", "-p", '#{client_termfeatures}'], err: File::NULL)
        features, exhausted = read_with_budget(io)
        if exhausted
          # pi's timeout arm raises into its catch → false. Kill first so
          # the ensure's close (which waits on the child) never hangs.
          Process.kill("KILL", io.pid)
          false
        else
          features_list_hyperlinks?(features)
        end
      rescue StandardError
        false
      ensure
        begin
          io&.close
        rescue StandardError
          nil
        end
      end

      # Reads until EOF or the budget expires; returns [text, exhausted?].
      def read_with_budget(io)
        out = +""
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + PROBE_BUDGET_S
        loop do
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          return [out, true] if remaining <= 0

          unless IO.select([io], nil, nil, remaining)
            return [out, true]
          end

          begin
            out << io.read_nonblock(4096)
          rescue IO::WaitReadable
            next
          rescue EOFError
            return [out, false]
          end
        end
      end
    end
  end
end
