# frozen_string_literal: true

require_relative "test_helper"

module Tart
  # The I114 repin's hard-literal pins: the parity oracle moved
  # v1.1.0 → v1.6.0 (the tracked Identity::ORACLE_VERSION constant +
  # the rig's default-oracle promotion). Every def name carries the
  # `repin` token — the suite gate's membership family (want = the base
  # membership + these defs). D4 law: every pin injects through the
  # seams, deterministic, no ambient detection, no wall-clock.
  class OracleRepinTest < Test
    # (a) The tracked constant IS the literal "1.6.0" — expected side a
    # literal, never an interpolation: a silent constant drift must fail
    # this pin.
    def test_oracle_version_repin_is_the_hard_literal
      assert_equal "1.6.0", Identity::ORACLE_VERSION
    end

    # (b) The pi-mode MOTD logo row renders " ▀▀█  v1.6.0" as a hard
    # literal through the same render seam test/render/motd_test.rb uses
    # (mirrored harness; that file is byte-held by the scope gate — the
    # banner moves BY DESIGN with the constant, never by an edit there).
    def test_pi_mode_motd_logo_row_repin_renders_the_hard_literal
      rows = Render::Motd.pi_header_lines(expanded: false, width: 120)
                         .map { |row| row.spans.map(&:content).join }
      assert_equal " ▀▀█  v1.6.0", rows[0], "the pi-mode logo row carries the promoted version"
    end

    # (c) The tart-mode default face never carries the oracle version —
    # the identity seam's other arm (the identity_test:33 property),
    # pinned here as a hard literal against the NEW constant.
    def test_tart_mode_default_face_repin_never_carries_the_oracle_version
      id = Identity.resolve(settings: {}, env: {})
      assert_equal "tart", id, "the default identity (the flip)"
      rows = Render::Motd.tart_header_lines(60, id, expanded: false)
      joined = rows.map { |line| line.spans.map(&:content).join }.join("\n")
      assert_includes joined, "tart v#{Tart::VERSION}", "the default face's tart wordmark"
      refute_includes joined, "v1.6.0", "the oracle version never leaks into the default face"
    end
  end
end
