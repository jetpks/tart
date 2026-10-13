# frozen_string_literal: true

require_relative "shapes/types"
require_relative "shapes/model"
require_relative "shapes/settings"
require_relative "shapes/session"

module Tart
  # The I44 typed-shapes family (program ENTRY 2, composing on ENTRY 1's
  # Schemas): one member file per shape domain — shapes/model.rb (the
  # Model-catalog values + the boot reference + the thinking facts),
  # shapes/settings.rb (ResolvedSettings + CompactionSettings — the
  # resolved-settings consumer view), shapes/session.rb (the session-entry
  # read-path envelopes + the chat-ready projection) — with Shapes::Types
  # the one shared dry-types container.
  #
  # The value-side discipline the Schemas family's error discipline
  # becomes for values: structs never construct where today's code does
  # not branch (the session envelopes' tolerant `.of` wrap reproduces the
  # guard-chain nil-skips); no struct to_h output crosses a byte-frozen
  # surface (the JSONL write path stays Hash literals; the gem seam gets
  # the projection hash); strict types only where construction guarantees
  # the class, Nominal::Any where pi flows values through; no validation
  # and no filtering rides construction (shape typing ≠ boundary
  # validation — the I43 rule).
  module Shapes
  end
end
