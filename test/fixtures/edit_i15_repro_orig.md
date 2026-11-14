# ARCHITECT — knowledge-builder

> Cross-iteration table of contents for the Architect Loop. Per-iteration detail lives in
> architecture/I<NN>-<iteration>.md — this file only indexes the iterations and carries
> project-wide state. Keep it short (~150 lines): the next session must grok it
> in under a minute. Not in the committed architecture = didn't happen.
>
> Durable project contract: `architecture/BRIEF.md` (numbered §sections, cited as BRIEF §N).
> Edits to a §section are project-scope decisions — log them in the Decisions log below,
> never as silent per-iteration drift.

## TL;DR (keep current)

- Goal: hermetic, OS-contained knowledge-quest agents with auditable web access (BRIEF §1).
- Last iteration: I01-web-tools — **CONTINUE** (all 6 ACs PASS cold); merged to `project/knowledge-builder` a96e33a2, awaiting human PR push.
- Next action: human pushes the tart PR (block in `build/land/`), then `architect sync tart`, then `architect new hermit-kb` (ENTRY 2).

## Repos in scope

| Repo | Path |
|------|------|
| github.com/jetpks/tart | repos/tart |
| hermit-kb (local, no remote yet) | repos/hermit-kb |

## Verification gate (exact commands, per repo)

```
# repos/tart — NEVER bare rake: without the env prefix, 49 false theme failures at unpatched main.
TERM=xterm-256color COLORTERM=truecolor bundle exec rake     # ~225 s cold; base 1501 runs / 0F / 0E / 5S
# Loop shells also need: export SSH_AUTH_SOCK=/Users/eric/.ssh/agent/agent.sock (else architect commits hang)
```

## Iteration index

| I# | Iteration | Status | freeze_sha | Integration branch | Verdict | File |
|----|-----------|--------|-----------|--------------------|---------|------|
| 01 | web-tools | done | 4f16560a | project/knowledge-builder (a96e33a2) | continue | I01-web-tools.md |

## Backlog (ordered; no ordinal until `architect new`)

- hermit-kb (plan ENTRY 2): launcher + seatbelt profile + denial suite. Blocked on: I01 PR pushed to jetpks/tart main, then `architect sync tart`. First grounding step of its spec is the sync.
- quest-runner (plan ENTRY 3): quest skill + ledger/driver + model measurement. Blocked on ENTRY 2.

## Open items for the human / architect

- **Human**: push the tart PR — paste-and-run block + PR body in `build/land/`. After it lands on main: `architect sync tart`.
- **Architect (ENTRY 2 landing time)**: install launcher + seatbelt into space root; seed `.tart/settings.json` + `.tart/models.json` from repo templates (plan follow-up 2).
- Watch for the `exaApiBase` env-tier need at ENTRY 2 (judge ruling 2: add via new iteration, never amend I01).
- Keep `draft/web-tools-t01probe` until sync fast-forwards past the PR (provenance record); delete after.

## Decisions log (architect + human)

| Date | Decision | Why |
|------|----------|-----|
| 2026-11-10 | Plan kb-foundation: 3 ENTRYs (tart web tools → hermit-kb containment → quest runner) | BRIEF §1–§7 sequencing; containment before payload |
| 2026-11-11 | t01probe scratch recovered → `draft/web-tools-t01probe` (b03d567), prior art only | Uncommitted ignored-scratch work preserved before cleanup could lose it; spec froze AC independently |
| 2026-11-11 | Web tools enter NO default loadout; opt-in via `defaultTools`/profile `tools:` only | BRIEF §2.1 no-bash quest agent; `Tools::ALL` byte-stability |
| 2026-11-11 | `exaApiBase` rides settings tiers + DEFAULTS; NO env tier this iteration | Plan's "settings-level override" read as file+default; env tier deferred to a new iteration if ENTRY 2's launcher needs it |
| 2026-11-12 | I01 verdict CONTINUE; lane core integrated (a96e33a2), gates all PASS cold | Judge judgment `tmp/t01-judge/verdict.md` (transcribed to I01 Verdict section, commit fecf6a27) |
