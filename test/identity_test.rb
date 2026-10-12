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
