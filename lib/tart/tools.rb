# frozen_string_literal: true

require "fast/completions"

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
require_relative "tools/contact_supervisor"
require_relative "tools/registry"

module Tart
  module Tools
    # The built-in tools, verbatim-parity ports of pi's
    # packages/coding-agent/src/core/tools/ (BRIEF §3, §5-deferred).
    #
    # Each tool is a Fast::Completions::Tool subclass whose name, description, JSON
    # schema, execute behavior, and error strings match pi's observable
    # semantics. Model-facing text is pi's text byte-for-byte; renderer-only
    # metadata (details hashes) carries the pi-shaped fields.
    #
    # ALL is the MODEL-FACING loadout vocabulary (pi canonical order; the
    # settings selection + the child `--tools` flag speak it). The map
    # additionally carries `contact_supervisor` (I49) — a REGISTRY tool
    # that is validated through TOOL_CLASSES and activated only by the
    # child env, never entered here (in NO default loadout; the default
    # wire never changes).
    module_function

    # Tool names in pi's canonical order.
    ALL = %w[read edit write bash find grep ls].freeze
  end
end
