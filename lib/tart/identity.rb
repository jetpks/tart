# frozen_string_literal: true

module Tart
  # The identity seam (I16, free-form since I32): which face the port
  # shows. One resolution point — the launcher passes the CLI flag (nil
  # when absent), the loaded settings and the environment; everything
  # user-visible (MOTD, exit resume hint, prompt preamble) reads the
  # resolved value, never the sources directly.
  #
  # Resolution order: CLI flag > TART_IDENTITY env > settings "identity" >
  # default "pi". The value is FREE-FORM (owner ruling 2026-10-12): any
  # non-empty string names a face — "pi" keeps pi's byte-exact rendering,
  # any other value renders the tart-family face under its own name, and
  # the env namespace follows it ({env_prefix}: pi → PI_, tart → TART_,
  # foo → FOO_). Empty/whitespace values abort the launch (the I16 clean-
  # abort seam).
  module Identity
    PI = "pi"
    TART = "tart"
    DEFAULT = PI
    # The bootstrap knob stays launcher-owned and literally spelled
    # TART_IDENTITY: the identity key cannot depend on its own output.
    ENV_KEY = "TART_IDENTITY"
    SETTINGS_KEY = "identity"

    # The oracle's user-visible version (coding-agent package.json:3) —
    # the pi-mode logo line renders it; tart-mode renders Tart::VERSION.
    # A tracked constant, bumped with the oracle parity target.
    ORACLE_VERSION = "1.1.0"

    # An invalid identity value — the launcher maps this to a clean abort.
    Error = Class.new(StandardError)

    class << self
      # The boot's resolved face, recorded by the launcher ({resolve} call
      # sites in bin/tart). The one render path that cannot take the
      # identity threaded — chat.rb's frozen Motd.tart_header_lines call —
      # reads this (the Theme[] precedent: boot-applied render state).
      attr_writer :current

      def current
        @current || TART
      end
    end

    module_function

    def resolve(cli: nil, settings: {}, env: ENV)
      value = cli || env[ENV_KEY] || settings[SETTINGS_KEY] || DEFAULT
      return value if value.is_a?(String) && !value.strip.empty?

      raise Error, "identity must be a non-empty string (got #{value.inspect})"
    end

    # The app env namespace: pi → "PI_", tart → "TART_", foo → "FOO_"
    # (owner ruling 3 — the PI_*/TART_* rule follows the identity).
    def env_prefix(identity)
      "#{identity.upcase}_"
    end

    # One namespaced env key: env_key("foo", "API_KEY") → "FOO_API_KEY".
    def env_key(identity, suffix)
      "#{env_prefix(identity)}#{suffix}"
    end
  end
end
