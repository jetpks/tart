# tart

A Ruby port of the [pi](https://github.com/earendil-works/pi) coding-agent harness — the parts we use — on the socketry async stack.

- **LLM layer:** [ruby_llm](https://rubyllm.com/) (harness-driven tool loop, model registry, MCP client)
- **TUI layer:** [ratatui_ruby](https://www.ratatui-ruby.dev/) (fullscreen chat surface, native Rust rendering)
- **Concurrency:** the [async](https://github.com/socketry/async) gem — one fiber-scheduler reactor for TTY input, LLM SSE streaming, and subprocess execution

## Usage

Interactive chat on a fullscreen TUI, scoped to the working directory
(from a real terminal — raw mode / the alt screen need a tty):

```sh
export TART_API_KEY=...   # provider API key (required)
bundle exec ruby bin/tart [workdir]   # default: the current directory
```

Configuration is environment-driven with documented defaults (see
`bin/tart --help`):

| Variable | Default |
|---|---|
| `TART_MODEL` | `accounts/fireworks/models/glm-5p3-flash` |
| `TART_PROVIDER` | `openai` (chat-completions protocol) |
| `TART_API_KEY` | — (required) |
| `TART_API_BASE` | `https://api.fireworks.ai/inference/v1` |
| `TART_CONTEXT_WINDOW` | the model's context window (tokens) |
| `TART_MCP_CONFIG` | `~/.tart/mcp.json` |

For model, provider, API base, and API key the resolution is environment →
settings → built-in default.

### Settings

JSON settings load from `~/.tart/settings.json` (user) and
`<workdir>/.tart/settings.json` (project, deep-merged over user). Missing
keys fall back to the built-in defaults; unknown keys warn and run continues;
a file that fails to parse counts as absent (defaults hold) with a warning.

| Key | Default |
|---|---|
| `defaultModel` | `accounts/fireworks/models/glm-5p3-flash` |
| `defaultProvider` | `openai` |
| `apiBase` | `https://api.fireworks.ai/inference/v1` |
| `apiKey` | — |
| `contextWindow` | the model's context window |
| `compaction.enabled` | `true` |
| `compaction.reserveTokens` | `16384` |
| `compaction.keepRecentTokens` | `20000` |
| `defaultTools` | `read bash edit write` (pi's default-4; `+find`-style modifiers append, plain lists replace) |
| `identity` | `pi` |
| `thinkingLevel` | `medium` (off/minimal/low/medium/high/xhigh/max) |
| `modelReasoning` | — (the model's registry capability) |

`identity` picks the face the port shows: `pi` (the default — the oracle's
header bytes) or `tart` (the owner's art collection, `tart v<version>`, the
port's hints line). The same choice reads from the `--identity` CLI flag and
the `TART_IDENTITY` env var — flag > env > settings, anything else errors
naming the valid values. Structural behavior (transcript padding, blank-line
spacers, footer format) is identity-independent. `modelReasoning` stages the
footer's reasoning capability (`model • <level>` only for
reasoning-capable models — the env form is `TART_MODEL_REASONING`; unset,
the fact resolves off the model's registry entry, RubyLLM's, then a
known-models table for assumed models — the daily-driver fireworks glm is
declared reasoning-capable). The footer's model segment never carries a
provider prefix: pi prefixes only when its available-model snapshot spans
>1 provider (footer.ts:246-258), and the port's snapshot is a single
provider.

`defaultTools` takes plain names (replacing the default loadout), `+name`
(adds), and `-name` (removes), in list order; a project list of only
modifiers composes onto the user's selection, a project list with a plain
name replaces it. The default is pi's four core tools (`read bash edit
write`) — `"defaultTools": ["+find"]` appends `find` to it, and
`["find", "grep", "ls"]` restores the pre-I41 search-tool superset.

### Models

The model catalog loads from `~/.tart/models.json` (pi's shape, JSON
comments tolerated): `{"providers": {"<provider>": {name, baseUrl,
apiKey, api, "models": [{id, name, reasoning, contextWindow, maxTokens,
thinkingLevelMap}]}}}` plus an optional `"default"` boot reference
(`"<provider/model-id>"`). The boot model resolves the
identity-namespaced MODEL/PROVIDER env (below) > the models.json default
> the settings `defaultModel`/`defaultProvider`.

`thinkingLevelMap` maps the thinking levels onto the model's native
`reasoning_effort` values (`{"off": "low", "low": "low", "medium":
"medium", ...}`; a `null` marks a level unsupported, and `xhigh`/`max`
need an explicit entry — without a map they are not offered). The
selected level reaches the wire as `reasoning_effort` through the map:
the map's value for the resolved level, else the level itself; a model
that cannot turn thinking off floors `off` to the map's String `off`
value (the default fireworks glm floors to `"low"`), and `off` sends
nothing on models with no such floor. Prior assistant thinking is kept
in the session and replayed on follow-up requests under
`reasoning_content` (the field the provider's deltas carried), so later
turns do not re-think from scratch.

A model entry may also carry `compat` — pi's per-model dialect subset,
which retargets the request shape for non-standard chat-completions
endpoints. The carried keys: `thinkingFormat` (pi's eleven-literal
vocabulary; `"zai"` switches the model to z.ai's dialect — a top-level
`thinking` object on every request, `reasoning_effort` when the entry
also sets `"supportsReasoningEffort": true`, `"tool_stream": true` when
`"zaiToolStream": true` and the request carries tools, `system`
instruction role unless `"supportsDeveloperRole": true`); and
`maxTokensField` (`"max_tokens"` renames the summarization request's
max-token field for endpoints that only accept the deprecated name).
Unknown compat keys are tolerated and ignored (pi's schema keeps them
`additionalProperties: true`), so a catalog copied from pi loads clean.
The fireworks default boot is unchanged: a model without `compat` (or
with a non-`zai` `thinkingFormat`) wires exactly as before. Note that
`apiKey` values are passed through verbatim — `$ENV` references are NOT
expanded; use a literal key or the `<IDENTITY>_API_KEY` environment
override. A zai provider block looks like:

```json
{"providers": {"zai": {"name": "Z.AI",
   "baseUrl": "https://api.z.ai/api/coding/paas/v4",
   "apiKey": "<key>",
   "models": [{"id": "glm-5.3", "reasoning": true,
     "contextWindow": 1000000, "maxTokens": 131072,
     "thinkingLevelMap": {"off": null, "minimal": null, "low": "low",
                          "medium": null, "high": "high", "xhigh": null, "max": "max"},
     "compat": {"supportsDeveloperRole": false, "supportsReasoningEffort": true,
                "maxTokensField": "max_tokens", "thinkingFormat": "zai",
                "zaiToolStream": true}}]}}}
```

### Skills

Skills load from `~/.tart/skills` (user) and `<workdir>/.tart/skills`
(project): each skill is a `SKILL.md` with YAML frontmatter — `name`
(defaults to the directory name), `description` (required), and optional
`disable-model-invocation` (still user-invocable, never offered to the
model). A directory holding a `SKILL.md` is a skill root and is not searched
below it; subdirectories recurse; bare `.md` files at the skills-dir root
load too. First-loaded wins on a name collision (user before project), with
a collision diagnostic; malformed frontmatter is a warning, not a crash.

Invoke a skill with `/skill:<name> [args]` — the skill file's body joins
your message as an expanded `<skill>` block (the model sees the expansion;
the session records it). `/skills` lists what loaded.

### Prompt templates

Prompt templates load from `~/.tart/prompts` (user) and
`<workdir>/.tart/prompts` (project): each is a top-level `.md` file (the
filename stem is the name) with optional YAML frontmatter — `description`
(falls back to the first body line) and `argument-hint`. Invoke one with
`/<name> [args]` — the body joins your message with the args substituted
(`$1..$N`, `$@`/`$ARGUMENTS`, `${N:-default}`, bash-style `${@:N}` slices).
First-loaded wins on a name collision (user before project). Loaded
templates appear in the startup `[Prompts]` section and the slash
autocomplete.

### Slash commands

| Command | Action |
|---|---|
| `/new` | start a fresh session (new session file, empty history, same settings/skills) |
| `/compact` | compact the session context now |
| `/resume` | open the session picker (arrows navigate, enter resumes, escape cancels) |
| `/skills` | list loaded skills |
| `/settings` | show the resolved settings |
| `/thinking` | set the thinking level (`/thinking <level>`; bare cycles) — the level drives the footer segment and the editor border color |
| `/help` | show the builtin commands |
| `/quit` | quit (when idle) |

Slash text matching no command — including an unknown `/skill:x` — goes to
the model as a plain message. While a turn is running, slash text steers
like any message.

Keys: type + Enter to send (steers a running agent); Escape interrupts a
running turn / cancels autocomplete / clears bash mode; Ctrl+C clears the
input, twice within half a second exits; Ctrl+D exits on an empty input.

### The surface

The fullscreen layout composes three areas (pi's chat viewport): the
transcript on top (completed turns render into a scrollback buffer;
assistant messages render as styled markdown — streaming shows the same
shape live, so nothing shifts at completion), a bordered editor area whose
top border carries the status line (spinner + working/tool while a turn
runs; the border color follows the thinking level — pi's
getThinkingBorderColor — and turns green in bash mode), and a two-line
footer: the ~-contracted working directory with the git branch, then token
counters (↑input ↓output R cache-read W cache-write CH cache-hit), context
usage against the resolved context window (warning above 70%, error above
90%, `(auto)` when compaction is enabled), and the model id with the
thinking level for reasoning-capable models.

Colors come from a theme token table (`Tart::Theme`) — pi's dark theme
tokens mapped onto the terminal's ANSI palette. All surface rendering —
chat roles, markdown styles, borders, the footer — resolves through it.

Editor keys: Ctrl+B/F step, Alt+B/F jump words, Ctrl+W deletes a word
backward, Ctrl+A/E home/end, ↑/↓ recall history.

### Sessions

Interactive and print runs are recorded by default — one JSONL session file
per run under the same root (`~/.tart/sessions`), holding the header and
every user and assistant message in order. Resume a previous session with
`--resume`: with no argument it continues the most recent session for the
working directory; with a session id or session-file path it continues that
one (the resumed run records into a new session file linked to the old one —
interactive or `-p` alike):

```sh
bundle exec ruby bin/tart --resume
bundle exec ruby bin/tart --resume <session-id>
bundle exec ruby bin/tart -p "keep going" --resume <session-id>
```

#### Compaction

Long sessions compact instead of overflowing: after a completed turn whose
provider-reported context usage exceeds the model's context window minus a
reserve, the agent summarizes the older turns with a standalone LLM call and
replaces the history with `[summary message, kept recent tail]`; a request
that fails with a context-length error omits the attempt, compacts, and
retries the turn once (a second consecutive overflow surfaces as the error).
A compaction is recorded as a `compaction` session entry, and `--resume`
replays it: the summary plus the kept tail — pre-compaction messages do not
come back.

Settings (defaults: enabled, `reserve_tokens` 16384, `keep_recent_tokens`
20000) are injectable on `Agent::Loop` via the `compaction:` kwarg;
`enabled: false` disables the threshold trigger. The context window resolves
from `TART_CONTEXT_WINDOW` (tokens), then the settings' `contextWindow`,
then the model registry's `context_window`, then the port's registry-default
table (the pinned ruby_llm registry misses the default fireworks model; its
catalog window is 1048573 — so the default chat compacts out of the box);
unset/0 disables the threshold trigger only — the overflow recovery always
fires.

### MCP servers

MCP stdio servers are loaded from `~/.tart/mcp.json` (override the
path with `TART_MCP_CONFIG`; a missing file means no servers):

```json
{"mcpServers": {"echo": {"command": "/path/to/echo-server", "args": [], "env": {}}}}
```

A configured server's tools join the loadout as `mcp__<server>__<tool>` and
are declared to the model like the built-in tools; a server that fails to
connect is skipped with a warning.

### Print mode

Single-shot headless runs — send one prompt, write the final response to
stdout, exit 0 (1 on error); no TUI anywhere on the path:

```sh
bundle exec ruby bin/tart -p "list the ruby files in this repo"
```

Print runs record like interactive ones: one session file per run under the
same root, and `--resume` works with `-p` — the continued run seeds the
recorded context and records into a new parent-linked file. The compaction
lever applies on print runs too: `<IDENTITY>_CONTEXT_WINDOW` (e.g.
`PI_CONTEXT_WINDOW`)/`TART_CONTEXT_WINDOW` arms the threshold, and the
`compaction` settings (`enabled`, `reserveTokens`, `keepRecentTokens`)
shape it — see Compaction above.

### Input-line editing

The input line is a multi-line editor with a visible cursor (the grapheme at
the insertion point renders inverse-video; at end-of-line a highlighted
trailing space): logical lines wrap into visual rows at the box width (pi's
visual-line model — `editor.ts` wordWrapLine/layoutText), the box grows with
the content up to pi's visible-window cap (`max(5, floor(rows * 0.3))`, with
` ↑ N more ` / ` ↓ N more ` borders), and the cursor navigates wrapped rows
with pi's sticky column. Mid-line editing, in-memory history, the emacs
kill/yank ring, and word-wise operations come from the pi
`editor.ts`/`input.ts`/`word-navigation.ts` subset (no undo, no paste-marker
compaction, autocomplete unchanged):

| Key | Action |
|---|---|
| printable characters | insert at the cursor |
| Left / Right | move one character, wrapping across lines (Ctrl+B / Ctrl+F too) |
| Up / Down | move one visual row (sticky column); recall previous / next sent message at the editor's top/bottom |
| Backspace | delete before the cursor (merges lines at a line start) |
| Delete / Ctrl+D | delete after the cursor (merges lines at a line end; exits when empty) |
| Home / End (Ctrl+A / Ctrl+E) | jump to the logical line's start / end |
| Alt+Left or Alt+B (Ctrl+Left) | jump one word backward (crosses line starts) |
| Alt+Right or Alt+F (Ctrl+Right) | jump one word forward (crosses line ends) |
| Ctrl+W or Alt+Backspace | delete one word backward (the newline at a line start) |
| Alt+D or Alt+Delete | delete one word forward (the newline at a line end) |
| Ctrl+U / Ctrl+K | kill to the logical line's start / end (the newline at a boundary merges the lines) |
| Ctrl+Y / Alt+Y | yank / yank-pop (multi-line ring text splices across lines) |
| Shift+Enter or Alt+Enter, Ctrl+J | insert a newline |
| Enter | send (a `\\` before the cursor becomes a newline instead; steers a running agent) |
| PageUp / PageDown | page the editor's visual rows (sticky column, clamped) |

History is in-memory for the session (most recent first, capped at 100,
no consecutive duplicates): Up walks older entries, Down returns toward the
draft you were typing, and a recalled entry is editable and sends as edited.
Word operations stop at whitespace, punctuation, and word boundaries (pi's
`word-navigation.ts` semantics — on `hello world|`, Ctrl+W deletes `world`
and keeps the separator space).

## Parity rig: tui-split-rig

`gems/tui-split-rig/bin/tui-split-rig` is the scripted side-by-side parity
instrument (BRIEF §1–§3, built in I02 from the I01 spike): it runs **pi**
(installed oracle) and
**tart** under identical scripted conditions — same mock LLM, same prompt,
same 120x40 tmux geometry — captures each app's settled screen, and diffs the
two captures with attribution.

```sh
gems/tui-split-rig/bin/tui-split-rig run gems/tui-split-rig/scenarios/s1_text_turn.yml   # full rig: pi + tart, diff, report
gems/tui-split-rig/bin/tui-split-rig run gems/tui-split-rig/scenarios/s2_tool_turn.yml --runs 3 --app pi
gems/tui-split-rig/bin/tui-split-rig diff a.capture b.capture --registry gems/tui-split-rig/registry.yml
```

`run` stages everything under the out dir (default `tmp/parity/<timestamp>`):
per-run mock server, staged HOME and agent dir per app, fresh sandbox per app,
the settled captures, `report.md` (human-readable classified unified diff)
and `summary.json` (per-app completion, mock request counts vs expected,
per-class diff counts, candidate lines, exit code).

**Exit semantics (frozen):** `0` — every difference line matched a registry
class (parity); `1` — at least one `unknown-candidate` line exists (parity not
yet achieved; the candidates ARE the work list); `2` — rig failure (staging,
boot, settle timeout, request-count mismatch, teardown survivor).

**The diff is sharp by design.** There are NO sanctioned MOTD/logo/version/
glyph classes. Today's known divergences (MOTD art, `❯` glyph, `⎿` tool
transcript, footer model string) surface as `unknown-candidate` lines — that
is correct behavior, not noise. The seed registry
(`gems/tui-split-rig/registry.yml`) contains only per-run path/sandbox
normalization.

**Pinning a new class** (when the owner rules a difference out of scope): add
a `classes:` entry to `gems/tui-split-rig/registry.yml` with a name and a regex
`pattern` — first match wins; keep the class as narrow as the finding.
Classes are data, never code, so a pin is reviewable in a one-line diff. The
exact-parity direction is one-way: candidates shrink, classes only ever get
more precise, and a class must never be widened to hide a rendering
regression — reproduce, fix in tart, keep the candidate list honest.

Isolation/teardown: every pane runs with a staged `HOME` (pi also gets a
staged `PI_CODING_AGENT_DIR`), pane commands are exec-wrapped so the pane pid
IS the app process, and teardown kills -9 the app and all descendants before
dropping the session (tmux kill-session alone does not kill tart — I01).
After any run: no surviving app process, no leftover `tui-split-rig-*` tmux
session, worktree clean.

**Per-app env overrides:** a scenario may carry an optional `env:` mapping
(app name → `{ENV_VAR => value}`, validated at load; unknown apps and
non-mapping shapes are rig errors). The runner layers the overrides over its
staged env for that app — the branding/staging seam (e.g. `s1_tart.yml` boots
tart with `TART_IDENTITY=tart`).

Live integration test (drives real pi + tart, tens of seconds):
`TUI_SPLIT_RIG_LIVE=1 bundle exec rake test`.

## Development

```sh
bundle install            # runtime deps: async, ratatui_ruby (pinned 1.5.0)
bundle exec rake          # minitest suite (headless, no tty required)
timeout 90 bundle exec ruby bench/seam_bench.rb   # seam bench, prints JSON + SEAM_BENCH_OK/FAIL
bundle exec ruby bin/tart --help          # launcher usage (non-tty-safe)
bundle exec ruby bin/tart -p "prompt"     # headless single-shot run
```

The bench runs itself inside a fresh 80x24 pty, self-asserts (hard internal
deadline < 60 s), and gates on: mean fps while animating ≥ 58, synthetic-event
dispatch p95 ≤ 30 ms, every delivered == expected, and a clean timeout-kill
probe.

## Project contract

`architecture/BRIEF.md` in the parent space. File contents are written
verbatim — no whitespace normalization at the write boundaries (read stays
verbatim).
