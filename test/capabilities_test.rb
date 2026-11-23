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
      WT_SESSION TART_HYPERLINKS TART_IMAGE_PROTOCOL
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

    # --- I112 — the capability seam's images arm (ENTRY 9) ------------

    # pi terminal-image.ts:91-139 — the images values ride the SAME arm
    # order: tmux/screen/herdr/WT_SESSION/alacritty-vscode-zed/jediterm/
    # Windows-console/unknown → nil (byte-held); kitty/ghostty/wezterm/
    # Warp → "kitty"; iterm → "iterm2".
    def test_termimg_capability_matrix_images_kitty_family_iterm2_null
      with_detection_env({"TMUX" => "1"}, probe: -> { true }) do
        assert_nil Capabilities.images?, "tmux → nil (image protocols unreliable, pi :74-77)"
      end
      nil_arms = [
        [{"TERM" => "screen-256color"}], [{"TERM_PROGRAM" => "herdr"}],
        [{"WT_SESSION" => "wt"}], [{"TERM_PROGRAM" => "alacritty"}],
        [{"TERM_PROGRAM" => "vscode"}], [{"TERM_PROGRAM" => "zed"}],
        [{"TERMINAL_EMULATOR" => "jetbrains-jediterm"}], [{}]
      ]
      nil_arms.each do |(overrides)|
        with_detection_env(overrides) do
          assert_nil Capabilities.images?, "arm #{overrides.inspect} stays nil"
        end
      end
      kitty_arms = [
        [{"KITTY_WINDOW_ID" => "1"}], [{"TERM_PROGRAM" => "kitty"}],
        [{"TERM_PROGRAM" => "ghostty"}], [{"GHOSTTY_RESOURCES_DIR" => "/g"}],
        [{"WEZTERM_PANE" => "0"}], [{"TERM_PROGRAM" => "wezterm"}],
        [{"TERM_PROGRAM" => "warpterminal"}], [{"WARP_SESSION_ID" => "w"}],
        [{"WARP_TERMINAL_SESSION_UUID" => "w"}]
      ]
      kitty_arms.each do |(overrides)|
        with_detection_env(overrides) do
          assert_equal "kitty", Capabilities.images?, "arm #{overrides.inspect} → kitty"
        end
      end
      [{"ITERM_SESSION_ID" => "i"}, {"TERM_PROGRAM" => "iterm.app"}].each do |overrides|
        with_detection_env(overrides) do
          assert_equal "iterm2", Capabilities.images?, "arm #{overrides.inspect} → iterm2"
        end
      end
    end

    # pi PI_IMAGE_PROTOCOL (:151-156): "kitty"/"iterm2" (case-insensitive)
    # force the protocol; "none"/"0" force nil; anything else falls through
    # to detection — and it composes independently of TART_HYPERLINKS.
    def test_termimg_capability_override_env_forces_protocol_and_none
      [%w[kitty kitty], ["KITTY", "kitty"], ["iTerm2", "iterm2"], ["ITERM2", "iterm2"]].each do |value, want|
        with_detection_env({"TART_IMAGE_PROTOCOL" => value}) do
          assert_equal want, Capabilities.images?, "override #{value.inspect} forces #{want}"
        end
      end
      %w[none NONE 0].each do |value|
        with_detection_env({"KITTY_WINDOW_ID" => "1", "TART_IMAGE_PROTOCOL" => value}) do
          assert_nil Capabilities.images?, "override #{value.inspect} beats the detecting arm"
        end
      end
      with_detection_env({"KITTY_WINDOW_ID" => "1", "TART_IMAGE_PROTOCOL" => "junk"}) do
        assert_equal "kitty", Capabilities.images?, "a junk value falls through to detection"
      end
      # Composition: the image override rides alone; hyperlinks stay off.
      with_detection_env({"TART_IMAGE_PROTOCOL" => "kitty", "TART_HYPERLINKS" => "0"}) do
        assert_equal "kitty", Capabilities.images?
        assert_equal false, Capabilities.hyperlinks?, "the rails compose independently"
      end
    end

    # The ONE cached hash answers both arms (the ENTRY-9 contract, now
    # discharged): the images consult never re-detects, and reset! drops
    # the whole table so both arms re-read.
    def test_termimg_capability_images_share_cached_hash_and_reset
      consults = 0
      with_detection_env({"TMUX" => "1"},
        probe: -> { consults += 1; true }) do
        table = Capabilities.capabilities
        assert_same table, Capabilities.capabilities, "the cache answers the second read"
        assert_same table, Capabilities.capabilities, "the images arm reads the same hash"
        assert_nil Capabilities.images?
        assert_equal 1, consults, "the probe ran once for BOTH arms"
      end
      with_detection_env({"KITTY_WINDOW_ID" => "1"}) do
        assert_equal "kitty", Capabilities.images?, "reset! re-detects the images arm"
        assert_equal true, Capabilities.hyperlinks?, "reset! re-detects the hyperlink arm too"
      end
    end

    # pi :92-:130 — the family/jediterm/Windows arms hardcode trueColor
    # true; the tmux/screen/herdr/unknown arms keep hasTrueColorHint.
    def test_termimg_capability_true_color_family_hardcodes
      [{"KITTY_WINDOW_ID" => "1"}, {"TERM_PROGRAM" => "kitty"}, {"TERM_PROGRAM" => "ghostty"},
       {"GHOSTTY_RESOURCES_DIR" => "/g"}, {"WEZTERM_PANE" => "0"}, {"TERM_PROGRAM" => "warpterminal"},
       {"ITERM_SESSION_ID" => "i"}, {"WT_SESSION" => "wt"}, {"TERM_PROGRAM" => "alacritty"},
       {"TERM_PROGRAM" => "vscode"}, {"TERM_PROGRAM" => "zed"},
       {"TERMINAL_EMULATOR" => "jetbrains-jediterm"}].each do |overrides|
        # COLORTERM stays deleted (the hint's false value) — a hardcoded
        # true must not depend on it.
        with_detection_env(overrides) do
          assert_equal true, Capabilities.capabilities[:true_color],
            "arm #{overrides.inspect} hardcodes true (pi :92-:130)"
        end
      end
      [{"TMUX" => "1"}, {"TERM" => "screen-256color"}, {"TERM_PROGRAM" => "herdr"}, {}].each do |overrides|
        with_detection_env(overrides) do
          assert_equal false, Capabilities.capabilities[:true_color],
            "arm #{overrides.inspect} keeps the hint (unset COLORTERM → false, pi :79)"
        end
        with_detection_env(overrides.merge("COLORTERM" => "truecolor")) do
          assert_equal true, Capabilities.capabilities[:true_color],
            "arm #{overrides.inspect} keeps the hint (truecolor → true)"
        end
      end
    end
  end
end
