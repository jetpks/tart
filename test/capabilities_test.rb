# frozen_string_literal: true

require_relative "test_helper"

module Tart
  # The capability seam (I111 — pi terminal-image.ts:50-175, hyperlinks
  # arm): the detection matrix, the injected tmux probe, the override env,
  # the cache, the reset seam. Every pin drives the seam through
  # Capabilities.reset! + the probe/env inject — the ambient seat's
  # terminal never leaks (the helper's force-off is the default arm).
  class CapabilitiesTest < Test
    # The detection matrix's full ambient surface — scrubbed to a clean
    # unknown-terminal baseline for every arm, restored after.
    DETECTION_KEYS = %w[
      TERM TERM_PROGRAM TERMINAL_EMULATOR COLORTERM TMUX
      KITTY_WINDOW_ID GHOSTTY_RESOURCES_DIR WEZTERM_PANE
      WARP_SESSION_ID WARP_TERMINAL_SESSION_UUID ITERM_SESSION_ID
      WT_SESSION TART_HYPERLINKS
    ].freeze

    def with_detection_env(overrides, probe: nil)
      saved = DETECTION_KEYS.to_h { |key| [key, ENV[key]] }
      previous_probe = Capabilities.probe
      DETECTION_KEYS.each { |key| ENV.delete(key) }
      overrides.each { |key, value| ENV[key] = value }
      Capabilities.probe = probe if probe
      Capabilities.reset!
      yield
    ensure
      saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
      Capabilities.probe = previous_probe
      Capabilities.reset!
    end

    # pi terminal-image.ts:86-121 — the kitty family, herdr FIRST (before
    # the leak-prone vars), ghostty, wezterm, Warp, iterm, WT_SESSION,
    # alacritty/vscode/zed — every arm TRUE.
    def test_capability_env_matrix_kitty_family_iterm_vscode_herdr
      with_detection_env({"TERM_PROGRAM" => "herdr", "KITTY_WINDOW_ID" => "1"}) do
        assert_equal true, Capabilities.hyperlinks?,
          "herdr outranks the leaked kitty var (pi :86-89 runs first)"
      end
      arms = [
        [{"KITTY_WINDOW_ID" => "1"}], [{"TERM_PROGRAM" => "kitty"}],
        [{"TERM_PROGRAM" => "ghostty"}], [{"GHOSTTY_RESOURCES_DIR" => "/g"}],
        [{"WEZTERM_PANE" => "0"}], [{"TERM_PROGRAM" => "wezterm"}],
        [{"TERM_PROGRAM" => "warpterminal"}], [{"WARP_SESSION_ID" => "w"}],
        [{"WARP_TERMINAL_SESSION_UUID" => "w"}], [{"ITERM_SESSION_ID" => "i"}],
        [{"TERM_PROGRAM" => "iterm.app"}], [{"WT_SESSION" => "wt"}],
        [{"TERM_PROGRAM" => "alacritty"}], [{"TERM_PROGRAM" => "vscode"}],
        [{"TERM_PROGRAM" => "zed"}]
      ]
      arms.each do |(overrides)|
        with_detection_env(overrides) do
          assert_equal true, Capabilities.hyperlinks?, "arm #{overrides.inspect}"
        end
      end
    end

    # pi probeTmuxHyperlinks (:50-64) via the inject seam: the tmux arm
    # consults the probe, the features list splits/trim-matches, ANY
    # error → false, and TERM=tmux* counts without the TMUX env.
    def test_capability_tmux_probe_letter_via_injected_probe
      probes = {
        "extensions=clipboard,hyperlinks" => true,
        "extensions=clipboard" => false,
        " hyperlinks " => true
      }
      probes.each do |features, want|
        with_detection_env({"TMUX" => "1"},
          probe: -> { Capabilities.features_list_hyperlinks?(features) }) do
          assert_equal want, Capabilities.hyperlinks?, "features #{features.inspect}"
        end
      end
      with_detection_env({"TMUX" => "1"}, probe: -> { raise "tmux exploded" }) do
        assert_equal false, Capabilities.hyperlinks?, "ANY probe error → false (pi's catch)"
      end
      with_detection_env({"TERM" => "tmux-256color"},
        probe: -> { Capabilities.features_list_hyperlinks?("hyperlinks") }) do
        assert_equal true, Capabilities.hyperlinks?, "TERM tmux* consults the probe without the TMUX env"
      end
    end

    # pi :81-83/:127-139 — screen strips OSC-8; jediterm reports no
    # hyperlinks; an unknown terminal stays conservative.
    def test_capability_screen_and_unknown_terminals_stay_off
      with_detection_env({"TERM" => "screen-256color"}) do
        assert_equal false, Capabilities.hyperlinks?, "screen never forwards"
      end
      with_detection_env({"TERMINAL_EMULATOR" => "jetbrains-jediterm"}) do
        assert_equal false, Capabilities.hyperlinks?, "jediterm reports none"
      end
      with_detection_env({}) do
        assert_equal false, Capabilities.hyperlinks?, "unknown → conservative off"
      end
    end

    # pi parseBooleanCapabilityOverride + detectCapabilities' final spread
    # (:142-160): TART_HYPERLINKS=1|0 beats detection INCLUDING the probe.
    def test_capability_override_env_forces_on_and_off
      with_detection_env({"TART_HYPERLINKS" => "1"}) do
        assert_equal true, Capabilities.hyperlinks?, "override 1 forces ON on an unknown terminal"
      end
      with_detection_env({"KITTY_WINDOW_ID" => "1", "TART_HYPERLINKS" => "0"}) do
        assert_equal false, Capabilities.hyperlinks?, "override 0 beats a detecting arm"
      end
      with_detection_env({"TMUX" => "1", "TART_HYPERLINKS" => "1"}, probe: -> { raise "never consulted" }) do
        assert_equal true, Capabilities.hyperlinks?, "the override beats the probe wholesale"
      end
    end

    # pi getCapabilities (:163-175): the FIRST consult caches — the probe
    # (and the env) are never re-read.
    def test_capability_cached_after_first_read
      consults = 0
      with_detection_env({"TMUX" => "1"},
        probe: -> { consults += 1; Capabilities.features_list_hyperlinks?("hyperlinks") }) do
        assert_equal true, Capabilities.hyperlinks?
        assert_equal true, Capabilities.hyperlinks?
        assert_equal 1, consults, "the cache answers the second consult"
      end
    end

    # The test seam: reset! drops the cache so the next consult
    # re-detects under the CURRENT env/probe.
    def test_capability_reset_seam_restores_detection
      with_detection_env({"TMUX" => "1"},
        probe: -> { Capabilities.features_list_hyperlinks?("clipboard") }) do
        assert_equal false, Capabilities.hyperlinks?
      end
      with_detection_env({"TMUX" => "1"},
        probe: -> { Capabilities.features_list_hyperlinks?("hyperlinks") }) do
        assert_equal true, Capabilities.hyperlinks?, "reset! re-detects under the new probe"
      end
    end
  end
end
