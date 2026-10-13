# frozen_string_literal: true

require "dry-struct"
require "dry-types"

module Tart
  module Shapes
    # The one shared dry-types container for the shapes family (I44): every
    # member file requires this module and references Types::… — never a
    # private container. Strict types where construction guarantees the
    # class, Nominal::Any where a value flows through verbatim (the
    # documented no-filter rule), coercing Constructor types only where
    # today's code already coerces (role symbolization, null content).
    module Types
      include Dry::Types()
    end
  end
end
