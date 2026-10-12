# frozen_string_literal: true

require_relative "test_helper"

module Tart
  # The free-form identity feature (I32 AC1): any non-empty name resolves
  # and drives the branding — the tart-family MOTD wordmark follows the
  # boot-recorded face, always with Tart::VERSION. (The resolution
  # precedence table and the env-namespace unit pins live in
  # settings_test/models_test; the launcher-level wiring in
  # launcher_smoke_test.)
  class IdentityTest < Test
    def setup
      @saved_current = Identity.current
    end

    def teardown
      Identity.current = @saved_current == Identity::TART ? nil : @saved_current
    end

    # The recorded face defaults to the family mark: before any launcher
    # boot (and in every direct-construction test) the wordmark is tart.
    def test_current_defaults_to_the_tart_family_mark
      Identity.current = nil
      assert_equal Identity::TART, Identity.current
      assert_includes wordmark_line, "tart v#{Tart::VERSION}"
    end

    # A non-pi face renders its own name in the UI text, version stays
    # Tart::VERSION (owner ruling 1: white-labelable out of the box).
    def test_foo_renders_its_own_name_with_the_tart_version
      Identity.current = "foo"
      assert_includes wordmark_line, "foo v#{Tart::VERSION}"
      refute_includes wordmark_line, "tart v", "no tart wordmark leaks into the foo header"
    end

    private

    # The version row's span contents joined (RatatuiRuby::Text::Line#to_s
    # inspects, it does not concatenate; the name and version are separate
    # spans).
    def wordmark_line
      line = Render::Motd.tart_header_lines(60)
                         .find { |row| row.spans.any? { |span| span.content.include?("v#{Tart::VERSION}") } }
      line.spans.map(&:content).join
    end
  end
end
