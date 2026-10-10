# tart

A Ruby port of the [pi](https://github.com/earendil-works/pi) coding-agent harness — the parts we use — on the socketry async stack.

- **LLM layer:** [ruby_llm](https://rubyllm.com/) (harness-driven tool loop, model registry, MCP client)
- **TUI layer:** [ratatui_ruby](https://www.ratatui-ruby.dev/) (inline viewport chat, native Rust rendering)
- **Concurrency:** the [async](https://github.com/socketry/async) gem — one fiber-scheduler reactor for TTY input, LLM SSE streaming, and subprocess execution

## Usage

Interactive chat on an inline-viewport TUI, scoped to the working directory
(from a real terminal — the inline viewport's init query needs a tty reply):

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
| `TART_MCP_CONFIG` | `~/.tart/mcp.json` |

Keys: type + Enter to send (steers a running agent); y/n at approval prompts;
Ctrl+C interrupts a running turn / quits when idle.

### Sessions

Interactive runs are recorded by default — one JSONL session file per run
under `~/.tart/sessions`, holding the header and every user and
assistant message in order. Resume a previous session with `--resume`: with
no argument it continues the most recent session for the working directory;
with a session id or session-file path it continues that one (the resumed
run records into a new session file linked to the old one):

```sh
bundle exec ruby bin/tart --resume
bundle exec ruby bin/tart --resume <session-id>
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
from `TART_CONTEXT_WINDOW` (tokens), then the model registry's
`context_window`; unset/0 disables the threshold trigger only — the overflow
recovery always fires.

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

Print runs are not recorded (the session store is wired into the interactive
path only).

### Input-line editing

The input line is a single-line editor with a visible cursor (the grapheme at
the insertion point renders inverse-video; at end-of-input a highlighted
trailing space), mid-line editing, in-memory history, and word-wise
operations — the pi `editor.ts`/`input.ts`/`word-navigation.ts` subset
(single-line; no multi-line editing, undo/kill-ring, or autocomplete):

| Key | Action |
|---|---|
| printable characters | insert at the cursor |
| Left / Right | move the cursor one character (Ctrl+B / Ctrl+F too) |
| Backspace | delete before the cursor |
| Delete / Ctrl+D | delete after the cursor |
| Home / End (Ctrl+A / Ctrl+E) | jump to line start / end |
| Alt+Left or Alt+B (Ctrl+Left) | jump one word backward |
| Alt+Right or Alt+F (Ctrl+Right) | jump one word forward |
| Ctrl+W or Alt+Backspace | delete one word backward |
| Alt+D or Alt+Delete | delete one word forward |
| Up / Down | recall previous / next sent message |
| Enter | send (steers a running agent) |

History is in-memory for the session (most recent first, capped at 100,
no consecutive duplicates): Up walks older entries, Down returns toward the
draft you were typing, and a recalled entry is editable and sends as edited.
Word operations stop at whitespace, punctuation, and word boundaries (pi's
`word-navigation.ts` semantics — on `hello world|`, Ctrl+W deletes `world`
and keeps the separator space).

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
