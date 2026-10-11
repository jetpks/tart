# frozen_string_literal: true

module Tart
  # The identity seam (I16): which face the port shows. One resolution
  # point — the launcher passes the CLI flag (nil when absent), the loaded
  # settings and the environment; everything user-visible (MOTD, exit
  # resume hint) reads the resolved value, never the sources directly.
  #
  # Resolution order: CLI flag > TART_IDENTITY env > settings "identity" >
  # default "pi". Values are pi | tart; anything else is an error naming
  # the valid values.
  module Identity
    VALUES = %w[pi tart].freeze
    PI = "pi"
    TART = "tart"
    DEFAULT = PI
    ENV_KEY = "TART_IDENTITY"
    SETTINGS_KEY = "identity"

    # The oracle's user-visible version (coding-agent package.json:3) —
    # the pi-mode logo line renders it; tart-mode renders Tart::VERSION.
    # A tracked constant, bumped with the oracle parity target.
    ORACLE_VERSION = "1.1.0"

    # An invalid identity value — the launcher maps this to a clean abort.
    Error = Class.new(StandardError)

    module_function

    def resolve(cli: nil, settings: {}, env: ENV)
      value = cli || env[ENV_KEY] || settings[SETTINGS_KEY] || DEFAULT
      return value if VALUES.include?(value)

      raise Error, "unknown identity: #{value} (valid values: #{VALUES.join(", ")})"
    end
  end
end
