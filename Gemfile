# frozen_string_literal: true

source "https://rubygems.org"

gemspec

# The fiber-native LLM wire (I52 — Grounds D8): published-gem pin. The
# pre-0.4.0 form was a relative path pin (lane worktrees escaped via a
# per-run, never-committed FAST_COMPLETIONS_PATH override) — retired with
# the rubygems pin.
gem "fast-completions", "0.10.0"

# The ratatui_ruby runtime dependency, temporarily a git pin (I109): the
# event-fd seam lives on the jetpks fork's local branch until it upstreams.
# Carve-out owner-ratified (same gem, git source — no new dependency). At
# upstreaming, restore `spec.add_dependency "ratatui_ruby"` in tart.gemspec
# and resolve this pin from the published gem (owner-side follow-up).
gem "ratatui_ruby", github: "jetpks/RatatuiRuby", branch: "event-fd-seam"

# Dev deps live here (not the gemspec): minitest 5.x is required — 6.x
# dropped minitest/mock, which ratatui_ruby's test tooling depends on.
gem "minitest", "~> 5.20"
gem "rake", "~> 13.0"
gem "irb"
