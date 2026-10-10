# raspberry-pi

A Ruby port of the [pi](https://github.com/earendil-works/pi) coding-agent harness — the parts we use — on the socketry async stack.

- **LLM layer:** [ruby_llm](https://rubyllm.com/) (harness-driven tool loop, model registry, MCP client)
- **TUI layer:** [ratatui_ruby](https://www.ratatui-ruby.dev/) (inline viewport chat, native Rust rendering)
- **Concurrency:** the [async](https://github.com/socketry/async) gem — one fiber-scheduler reactor for TTY input, LLM SSE streaming, and subprocess execution

## Usage

Interactive chat on an inline-viewport TUI, scoped to the working directory
(from a real terminal — the inline viewport's init query needs a tty reply):

```sh
export RASPBERRY_PI_API_KEY=...   # provider API key (required)
bundle exec ruby bin/raspberry-pi [workdir]   # default: the current directory
```

Configuration is environment-driven with documented defaults (see
`bin/raspberry-pi --help`):

| Variable | Default |
|---|---|
| `RASPBERRY_PI_MODEL` | `accounts/fireworks/models/glm-5p3-flash` |
| `RASPBERRY_PI_PROVIDER` | `openai` (chat-completions protocol) |
| `RASPBERRY_PI_API_KEY` | — (required) |
| `RASPBERRY_PI_API_BASE` | `https://api.fireworks.ai/inference/v1` |

Keys: type + Enter to send (steers a running agent); y/n at approval prompts;
Ctrl+C interrupts a running turn / quits when idle.

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
bundle exec ruby bin/raspberry-pi --help          # launcher usage (non-tty-safe)
```

The bench runs itself inside a fresh 80x24 pty, self-asserts (hard internal
deadline < 60 s), and gates on: mean fps while animating ≥ 58, synthetic-event
dispatch p95 ≤ 30 ms, every delivered == expected, and a clean timeout-kill
probe.

## Project contract

`architecture/BRIEF.md` in the parent space. File contents are written
verbatim — no whitespace normalization at the write boundaries (read stays
verbatim).
