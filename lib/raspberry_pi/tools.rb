# frozen_string_literal: true

require "ruby_llm"

require_relative "tools/support/truncate"
require_relative "tools/support/path_utils"
require_relative "tools/support/file_mutation_queue"
require_relative "tools/support/edit_diff"
require_relative "tools/support/mime"
require_relative "tools/output_accumulator"
require_relative "tools/read"
require_relative "tools/write"
require_relative "tools/edit"
require_relative "tools/bash"
require_relative "tools/find"
require_relative "tools/grep"
require_relative "tools/ls"
require_relative "tools/registry"

module RaspberryPi
  module Tools
    # The seven built-in tools, verbatim-parity ports of pi's
    # packages/coding-agent/src/core/tools/ (BRIEF §3, §5-deferred).
    #
    # Each tool is a RubyLLM::Tool subclass whose name, description, JSON
    # schema, execute behavior, and error strings match pi's observable
    # semantics. Model-facing text is pi's text byte-for-byte; renderer-only
    # metadata (details hashes) carries the pi-shaped fields.
    module_function

    # Tool names in pi's canonical order.
    ALL = %w[read edit write bash find grep ls].freeze

    # Classes that mutate their target and gate behind approval.
    DESTRUCTIVE = %w[edit write bash].freeze
  end
end
