# frozen_string_literal: true

source "https://rubygems.org"

gemspec

# The fiber-native LLM wire (I52 — Grounds D8): the PATH pin resolves the
# GEMSPEC'S directory, not the monorepo root. The relative default is the
# canonical, landing-relevant form (repos/tart checkout); a lane worktree
# resolves it through the FAST_COMPLETIONS_PATH override (exported per
# run, never committed).
gem "fast-completions", "0.2.0", path: ENV.fetch("FAST_COMPLETIONS_PATH", "../fast-llm/gems/completions")

# Dev deps live here (not the gemspec): minitest 5.x is required — 6.x
# dropped minitest/mock, which ratatui_ruby's test tooling depends on.
gem "minitest", "~> 5.20"
gem "rake", "~> 13.0"
gem "irb"
