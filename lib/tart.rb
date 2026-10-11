# frozen_string_literal: true

require_relative "tart/version"
require_relative "tart/identity"
require_relative "tart/tui"
require_relative "tart/core/loop"
require_relative "tart/tools"
require_relative "tart/skills"
require_relative "tart/prompts"
require_relative "tart/settings"
require_relative "tart/commands"
require_relative "tart/agent/loop"
require_relative "tart/theme"
require_relative "tart/render/chat"
require_relative "tart/render/markdown"
require_relative "tart/print"

module Tart
  # The version the MOTD renders — defined in version.rb (Tart::VERSION);
  # this file adds no second definition.
end
