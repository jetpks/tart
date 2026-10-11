# frozen_string_literal: true

# The tui-split-rig parity rig library (BRIEF §1–§3): a scripted side-by-side
# parity instrument that runs pi (installed oracle) and tart under identical
# scripted conditions and diffs their settled screen captures with
# attribution.
#
# Stdlib only — bin/tui-split-rig runs without Bundler. The app-side mock LLM
# server it drives lives in the tart repo's test/support/mock_llm_server.rb
# (top-level MockLLMServer, minitest-free since I02; dev-only cross-tree
# require — see runner.rb).
module TuiSplitRig
# Any rig failure (staging, launch, settle timeout, teardown, survivor,
# bad scenario/registry): the CLI maps this to exit code 2.
class Error < StandardError; end
end

require_relative "tui_split_rig/scenario"
require_relative "tui_split_rig/registry"
require_relative "tui_split_rig/differ"
require_relative "tui_split_rig/runner"
require_relative "tui_split_rig/report"
