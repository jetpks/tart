# frozen_string_literal: true

require_relative "test_helper"

module Tart
  # The free-form identity feature (I32 AC1, threaded since I33 AC5): the
  # face renders its own name in the tart-family header — every consumer
  # takes it explicitly ({Render::Motd#tart_header_lines} threads it from
  # Chat's @identity; no boot-recorded global remains). (The resolution
  # precedence table and the env-namespace unit pins live in
  # settings_test/models_test; the launcher-level wiring in
  # launcher_smoke_test.)
  class IdentityTest < Test
    # The recorded face renders its own wordmark, always with
    # Tart::VERSION (owner ruling 1: white-labelable out of the box).
    def test_threaded_faces_render_their_own_name_with_the_tart_version
      assert_includes wordmark_line("tart"), "tart v#{Tart::VERSION}"
      assert_includes wordmark_line("foo"), "foo v#{Tart::VERSION}"
      refute_includes wordmark_line("foo"), "tart v", "no tart wordmark leaks into the foo header"
    end

    # I69 new pin (owner ruling 2026-10-17): the RESOLVED DEFAULT face is
    # the tart family — the chat dispatch (render/chat.rb:829) sends the
    # default down the tart_header_lines branch, under Tart::VERSION,
    # never the oracle version.
    def test_the_resolved_default_face_is_the_tart_family
      id = Identity.resolve(settings: {}, env: {})
      assert_equal "tart", id, "the default identity (the flip)"
      rows = id == Identity::PI ? Render::Motd.pi_header_lines(expanded: false, width: 60)
                               : Render::Motd.tart_header_lines(60, id, expanded: false)
      joined = rows.map { |line| line.spans.map(&:content).join }.join("\n")
      assert_includes joined, "tart v#{Tart::VERSION}", "the default face's tart wordmark"
      refute_includes joined, "v#{Identity::ORACLE_VERSION}", "the oracle version never leaks into the default face"
    end

    # I69 new pin: the EXPLICIT pi-parity opt-in face stays byte-pi — the
    # oracle version line and pi's onboarding row, untouched by the flip.
    def test_the_explicit_pi_face_stays_byte_pi
      rows = Render::Motd.pi_header_lines(expanded: false, width: 120)
      joined = rows.map { |line| line.spans.map(&:content).join }.join("\n")
      assert_includes joined, "v#{Identity::ORACLE_VERSION}", "pi-mode's logo line renders the oracle version"
      assert_includes joined, Render::Motd::PI_ONBOARDING_LINE
    end

    private

    # The version row's span contents joined (RatatuiRuby::Text::Line#to_s
    # inspects, it does not concatenate; the name and version are separate
    # spans).
    def wordmark_line(name)
      line = Render::Motd.tart_header_lines(60, name, expanded: false)
                         .find { |row| row.spans.any? { |span| span.content.include?("v#{Tart::VERSION}") } }
      line.spans.map(&:content).join
    end
  end
end
