# frozen_string_literal: true

source "https://rubygems.org"

gemspec

# The fiber-native LLM wire (I52 — Grounds D8): published-gem pin. The
# pre-0.4.0 form was a relative path pin (lane worktrees escaped via a
# per-run, never-committed FAST_COMPLETIONS_PATH override) — retired with
# the rubygems pin.
gem "fast-completions", "0.5.0"

# Dev deps live here (not the gemspec): minitest 5.x is required — 6.x
# dropped minitest/mock, which ratatui_ruby's test tooling depends on.
gem "minitest", "~> 5.20"
gem "rake", "~> 13.0"
gem "irb"
