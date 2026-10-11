# frozen_string_literal: true

# The pty-tester parity rig library (BRIEF §1–§3): a scripted side-by-side
# parity instrument that runs pi (installed oracle) and tart under identical
# scripted conditions and diffs their settled screen captures with
# attribution.
#
# Stdlib only — bin/pty-tester runs without Bundler. The app-side mock LLM
# server it drives lives in test/support/mock_llm_server.rb (top-level
# MockLLMServer, minitest-free since I02).
module Tart
  module Parity
    # Any rig failure (staging, launch, settle timeout, teardown, survivor,
    # bad scenario/registry): the CLI maps this to exit code 2.
    class Error < StandardError; end
  end
end

require_relative "parity/scenario"
require_relative "parity/registry"
require_relative "parity/differ"
require_relative "parity/runner"
require_relative "parity/report"
