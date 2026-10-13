# frozen_string_literal: true

require "dry-schema"
require "dry-validation"

require_relative "schemas/settings"
require_relative "schemas/models"
require_relative "schemas/mcp"
require_relative "schemas/tools"

module Tart
  # The I43 parsing-boundary schema family (program ENTRY 1, the
  # pattern-setter): one member module per boundary — {Schemas::Settings}
  # (resolution contracts + the carried-key typed view), {Schemas::Models}
  # (models.json), {Schemas::Mcp} (mcp.json), {Schemas::Tools} (the seven
  # built-in tools' input contracts).
  #
  # The error discipline every later dry-rb iteration copies: contracts
  # validate SHAPE (semantic floors and precedence arithmetic stay in the
  # consuming module); pinned messages are produced byte-exactly — by a
  # contract rule's `key.failure` when the rule sees the values, else by
  # boundary mapping; unpinned failures speak pi's loop-level wrapper shape;
  # a boundary never raises where it did not raise before; unknown keys are
  # tolerated wherever today's code tolerates them; settings values are
  # never filtered (pi settings-manager.ts:126).
  module Schemas
  end
end
