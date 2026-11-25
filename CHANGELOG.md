# Changelog

## Unreleased

### Changed

- **grep context lines come from ripgrep's own events, and a resumed session restores its
  recorded tool loadout (I117 — the last two pi v1.6.0 parity ports, the REPIN plan's ENTRY 4;
  closes the eleven-item mapped-surface ledger).** grep (#9276, pi `grep.ts:168` + `:231`):
  `--context` rides the rg invocation and the surrounding lines come from rg's `context`
  events — NO matched file is ever read for context (the pre-fix `File.read` OOM-on-large-files
  exposure is dead, pinned with a hostile-large-file probe); rows past the 50KB byte cap are
  counted but never stored; at the match limit the notice waits for proof of one more match
  and the last allowed match's trailing context window is shown. Resume (#10785, pi
  `agent-session.ts:284` + `:1600-1640`): interactive sessions record their active tool
  loadout as a system-message entry (pi's toolsAdded/toolsRemoved declaration deltas), and
  a resumed session RESTORES exactly that loadout — `--tools +name/-name` composes on top
  (both directions), plain `--tools` names still select exactly, and a session that records
  no loadout keeps the current tools. The restored loadout drives both the wire
  declarations and the `<tools>` prompt section (pi `_setActiveTools` rebuilds the system
  prompt). Print mode is unchanged end to end (its `--tools` stays the exact-allowlist
  harness flag).

- **The compat-nil default-arm instruction role changes developer → system (I115 — the
  fast-completions 0.10.0 re-pin; the wire-parity half of the REPIN).** The gem absorbs the
  three pi v1.6.0 wire fixes (the vocabulary default #10741, the cross-model thinking drop
  #10995, the `tools: []` fallback gate #11843); the VISIBLE echo on tart's default arm is
  the instruction role: pi `openai-completions.js:890` instructionRole + `:1259-1265`
  `supportsDeveloperRole = isOpenAI` — the default dialect arm is non-OpenAI, so its
  reasoning-model instruction message rides `system` now (`test/agent_loop_test.rb` Pins 8/9
  re-seated in place; the zai explicit-true arm still opts in to `developer`). The rig wire
  goldens are byte-held (the mock models are `reasoning: false`); nothing renders — zero
  screen movement.
- **The parity oracle repins v1.1.0 → v1.6.0 (I114 — the ratified REPIN, plan ENTRY 1).**
  `Identity::ORACLE_VERSION` bumps to `"1.6.0"` (the tracked constant — the pi-mode
  version-banner pair moves BY DESIGN with the oracle pin) and the rig's DEFAULT oracle
  resolution is PROMOTED to the standing git worktree
  `build/pi-oracle-v1.6.0/packages/coding-agent/dist/bundle/cli.js` (derived off the canonical
  tart checkout via the existing git-common-dir mechanism, so every lane-worktree seat resolves
  the same worktree). The retired repos/pi v1.1.0 clone is byte-stable, never deleted, and
  demoted to flag/env-only (`--pi-bin` / `TUI_SPLIT_RIG_PI_BIN`) — never a default again.
  Owner ruling recorded: LaTeX rendering (present in pi v1.6.0, absent in tart) is GATED as a
  sanctioned deviation — reopened on owner pain, never a work item here. No gem/fork/upstream
  change; the constant's consumers interpolate it and never move.
- **Inline terminal images land in the transcript (I112 — kitty/iterm2, the I111 post-flush overlay's sibling).**
  `Tart::Capabilities` gains the `images` arm in the SAME cached hash (pi terminal-image.ts:70-139 —
  kitty/ghostty/wezterm/Warp → `"kitty"`, iterm → `"iterm2"`, every other arm nil; the family +
  jediterm + Windows-console arms hardcode `true_color: true` while tmux/screen/herdr/unknown keep the
  `COLORTERM` hint), forced by the `TART_IMAGE_PROTOCOL` override (`kitty`/`iterm2`/`none`/`0`,
  case-insensitive, composing independently of `TART_HYPERLINKS`). The new `Tart::TerminalImages`
  module ports pi's protocol letter: the kitty transmission (`a=T,f=100,q=2,C=1` + 4096-char `m=1`/`m=0`
  chunking), the three erase commands, the placement-only re-emit over registered metadata, the iterm2
  1337 letter (`inline=1,size=,width=,height=auto`, BEL), the four bounded dimension sniffers (64 KiB
  header reads; bmp → nil), the 9×18-default injectable cell geometry with the aspect-optimizing pass,
  the bottom-clip crop arithmetic, and the `[Image: …]` fallback row. The read tool block reserves
  blank panel rows for a transmittable image (dimensions-derived, ≤ 60 cells wide, gated on an 8 MiB
  inline cap) with the first row registered as the overlay anchor, or renders the fallback row
  otherwise; the markdown converter passes image-escape lines through as zero-width carrier rows
  (capability-gated — OFF parses byte-identically). `Session#draw` emits the image escapes to the
  session's writer AFTER the frame flushes: per the owner's erase/redraw ruling (2026-11-21) images
  NEVER live in the scrollback buffer — kitty frames emit `delete_all_kitty_placements` then re-place
  every visible anchor (transmitting once per content generation `[path, bytes, mime]`, cached and
  bounded at 16 entries / 32 MiB / 64 MiB with offscreen eviction deleting image data; static frames
  emit ZERO bytes), iterm2 re-emits the cached sequence, and the exit path best-effort emits
  `delete_all_kitty_images`. Recorded deviations: kitty transmits PNG only (no transcoder — no new
  deps), the live cell-size query is cut (the 9×18 default is injectable), the fallback renders only
  when images are capable but the image is not transmittable (the OFF arm is today's bytes), and
  sniffer reads are 64 KiB-bounded. No gem/fork/upstream change; the wire shapes and the read tool's
  schema are untouched.
- **The tree's remaining Thread/Mutex/ConditionVariable concurrency is migrated to async/fiber primitives per the owner's concurrency law (2026-11-21, PR-#28 review).** Every long-lived worker (the sink flusher, the herdr sender, the manager watcher, the supervisor channel poller, the MCP stdio readers/writer, the print deadline) now runs as a task on the host reactor; one-shot bounded work self-gates through `Kernel#Sync`; cross-thread wakes use the dual-path queue ping (direct push + scheduler-ready rider); the kernel's per-signal disposable thread, the test belt's ConditionVariable park, and all guard Mutexes whose funnels became same-reactor are deleted — zero behavior change beyond synchronization mechanics. Two sites survive as named, owner-ratified exemptions: the TUI poller thread (ratatui's FFI poll has no unblock function, so a fiber cannot stand in) and `FileMutationQueue`'s two Mutexes (same-file mutation serialization across the bare off-reactor call seats, where every async wait primitive would crash).

### Fixed

- **The intercom reply-consumption leg no longer flakes on the atomic-write temp window (the ~625 s CI walls).** `test_child_tool_consumes_the_reply_and_unlinks_the_request`'s answerer thread listed `supervisor-requests` with a raw `Dir.children` (dotfile filter only) — but `atomic_write_json` stages its temp as `<id>.json.<pid>.<uuid>.tmp` INSIDE that directory, so the answerer's unsynchronized first poll could see the temp mid-`File.write`, parse the partial JSON, die silently (`report_on_exception = false`), and leave the ask to burn its full 600 s bound — exactly the deterministic-looking ~625 s worker walls on CI (600 s burn + shard remainder). The leg now lists with the `*.json` glob — the same idiom as the interview leg and the channel's own production sweep (which was verified safe: the glob's extension filter never matches temps). A regression pin stages a sort-first truncated temp and fails fast (500 ms bound) against the old idiom.

- **The e2e session legs' scratch dirs no longer collide across parallel-runner workers.** The i42 legs keyed their `tmp/i42-e2e-*` scratch on `object_id` — deterministic per fresh process — and the runner shards BY TEST, so legs landing in different worker processes could allocate the same id and share one scratch path: one leg's teardown `rm_rf` deleted another's live fixtures mid-run (bit CI twice on the 1838-test shard map; the I111 D3 precedent, second application). The scratch now keys on the leg's own test name + the worker pid — unique on both axes.

- **Print-mode truncation warns and exits 1; the summarize one-shot rides the model's output cap (I116 — the pi v1.6.0 semantics ports #10799/#9512).** In print mode, a final assistant message whose stop reason is `length` still lands its text on stdout, then writes the exact v1.6.0 warning — `Response was truncated: the model reached its output token limit.` — to stderr and exits 1 (pi `modes/print-mode.ts:163-166`, the warn AFTER the text; the error/aborted arms keep their precedence, pi `:154-156`). The compaction summarize call sets NO per-call output cap any more: the `min(floor(0.8 × reserve_tokens), model max)` floor dies with its method — the summary rides the wire model's own `max_tokens`, clamped by the gem's `clamp_max_tokens` (pi `core/compaction/compaction.ts:603-605` sets no maxTokens; `:647`/`:699` reserveTokens is unused for the cap — it keeps only its start-time-trigger job). The s7 `max_completion_tokens` wire field converges to the oracle's same-run shape (measured: base `0` → delivered `1`).

- **`grep`'s process management is now async/fiber native per the concurrency law.** The deadline, the stderr drain, and the reap all run as reactor fibers: `Kernel#Sync` gates the call (the live tool task runs inline; bare callers get a fresh reactor on their own fiber), pipe reads and `Process.waitpid2` park evented in the scheduler, the deadline is a `with_timeout` fiber timer with time-based TERM→KILL escalation, and the match limit TERMs the whole process group — no threads anywhere. Behavior is unchanged: the `TOOL_TIMEOUT_S` deadline (default 120 s), the teaching-refusal bytes, limit-hit results, and normal greps.

- **Reading a zero-byte file is empty content, not a crash.** `read` on an empty file now returns empty content (`""`, with the usual truncation details) instead of an `{error:}` envelope: the image MIME sniff used to raise `NoMethodError` on the zero-byte read (`File.binread` returns `nil`), which surfaced as a tool error. A nil buffer and a zero-byte file both sniff as "no image" now; one-byte and normal files are byte-identical.

- **A stuck `rg` child can no longer wedge a `grep` call.** `grep` now spawns ripgrep in its own process group with stdin closed, and a watchdog enforces a deadline: `TOOL_TIMEOUT_S` env (positive integer, read at call time) or 120 s by default; junk/zero/negative values fall back to 120. At the deadline the whole process group is TERMed, probed after a 2 s grace and KILLed if it ignored TERM (the escalation is time-based), every wait is bounded (WNOHANG reap budget, drained stderr, retired watchdog), and the call returns a teaching refusal — `TOOL_TIMEOUT: grep exceeded <N>s and was killed (pattern=… path=… glob=-). Narrow the search: a smaller path, a tighter glob, or a more specific pattern.` — instead of hanging the session. Normal greps are unchanged.

- **The edit tool accepts the legacy single-edit shape under both key spellings.** A call with top-level `oldText`/`newText` beside `path` — string keys (the executor's wire form) or symbol keys — now folds into a one-element `edits[]` equivalent and executes instead of refusing with `edits: is missing`; the four legacy keys are consumed, never forwarded. The `edit` description now declares the canonical shape (`edit(path, edits: [{oldText, newText}, …])`) explicitly.

### Added

- **models.json `apiKey` and mcp.json server `env` values expand pi's `$ENV` template
  grammar (I119 env-templates — closes I46 OQ-3).** A catalog copied from pi
  (`"apiKey": "$FIREWORKS_API_KEY"`) now works: `"$VAR"` and `"${VAR}"` resolve
  when the key is USED (the chat wire, print mode, the `/model` live listing,
  subagent children, the compaction summary chat) and when an MCP server
  connects — never at load, so the catalog stays byte-untouched. An unset or
  empty variable fails the request by name with pi's exact string instead of
  sending the template or falling back to another key (print: exit 1 + stderr;
  interactive: the error-transcript row; MCP: the connect-failure warning);
  `"!command"` values are not supported (neither run nor sent). Precedence is
  otherwise unchanged (`<IDENTITY>_API_KEY` still wins; `baseUrl`,
  `settings.json`, names and ids never expand).

- **Markdown links and tool file paths render as OSC-8 hyperlinks when the terminal supports them (I111); today's printed-URL fallback is byte-intact otherwise.** The mechanism is the supervisor-ruled post-flush overlay (pi-shaped, Grounds §1 ruling A): the buffer renders link rows PLAIN — no OSC-8 byte ever enters a buffer cell — and after `RatatuiRuby.draw` returns, `TUI::Session#draw` writes each visible link's wrap (`CUP` + the span's SGR (the same color vocabulary the gem's flush presents, modifier-first) + `\e]8;;{url}\e\\` + the clipped visible text + close + reset) to stdout, the `osc52_copy` direct-write idiom, injectable writer. The delta is keyed on (row-object identity, y) at a geometry epoch (the session viewport's size): static frames emit ZERO escapes, sweep-rebuilt rows re-emit at the new width's positions, any terminal-size change re-bases the emitted set, and departing links leave silently (a recorded residual stale-fragment bound). A new `Tart::Capabilities` seam ports pi `terminal-image.ts:50-175`'s hyperlinks detection verbatim (tmux `client_termfeatures` probe with a 250 ms IO/wait budget, the env matrix with herdr checked before the leak-prone kitty/iterm vars, unknown→false, `TART_HYPERLINKS=1|0` override beating everything, cached once, a `reset!`/inject seam); the module's shape takes ENTRY 9's image arms additively. `Markdown::Span` gains `href` — when capable the ` (href)` fallback span is not appended, href survives the wrap regrouping, and the tool-path spans (read/write call rows, the edit header) carry the `file://` URL per pi `linkPath` (raw path resolved against the cwd, WHATWG percent-encoding; the ~ contraction stays display-only). Because the gem's span objects are frozen `Data` (no ivar channel) and the frozen transcript converter rebuild drops the href field, the carrier rides tart-only identity registries the Rust render never reads (converter link-modifiers arrays → href; produced span objects → href), compacted synchronously at every overlay evaluation. The chat surface submits its final transcript window rows to the session's overlay only when capable (capability-off: zero cost, zero bytes); test_helper pins `TART_HYPERLINKS=0` so every existing golden stays seat-independent, with the reset/inject seam forcing the ON arm in pins. No new runtime dependencies (stdlib only, `weakref` included); no gem/fork/upstream change.

- **Markdown gains GFM tables, setext headings, angle autolinks, and titled links (I110 — the last markdown-scope gap of the owner's revisal).** `Render::Markdown` recognizes tables under marked 18.0.11's letter (header + `[:|]`-guarded delimiter row, equal cell counts, `\|` escapes, pipeless headers, body rows to the blank/block boundary, paragraph interruption, in-quote/list recursion) and renders them per pi v1.1.0's `renderTable`: bordered `┌─┬─┐/├─┼─┤/└─┴─┘` rows in the Span vocabulary sized against the content width (natural/min-word ≤ 30/proportional-shrink arithmetic, bold nil-fg header cells, cell wrapping via `Text.wrap_row`, the too-narrow raw-source fallback; alignment is recognized but rendered left — pi v1.1.0 never reads `token.align`). Setext underlines (`===`/`---` immediately after a paragraph) convert to the ATX-identical h1/h2 shapes. Angle autolinks (`<scheme:…>`, `<user@host.tld>` → mailto) render through the existing link letter with the URL suffix suppressed; titled links (`[a](url "title")`, all three title shapes + whitespace-tolerant parens + angle-wrapped destinations) parse with the title discarded. Task-list markers hold byte-for-byte (I68 R8). All of it lands inside the pure converter — zero per-site work for messages, reasoning, and panels; bare URLs stay plain text (deferred to the origin/main-era entry).

- **CLI-style flags get a teaching line.** An unknown keyword that starts with `-` (the observed class: `grep` called with `"-i": "true"`) gains exactly one appended line on the validation error: "CLI-style flag; tools take named parameters — e.g. `ignoreCase` for case-insensitive search". The flag key itself is still never accepted — the hint is pedagogy, not a new parameter form.

- **`param: null` behaves identically to omitting the key for optional parameters.** An explicit `null` on a declared-optional parameter is dropped before binding and validation (schema-derived via the new `optional_properties`), so a model that fills optionals with nulls no longer fails the call. Required parameters keep their refusals byte-exact, off-schema keys pass through untouched, and wrong-typed non-null values refuse exactly as before — the ruling here is fewer failed tool calls.

## 0.2.2 (2026-11-14)

Patch release off main since 0.2.1.

### Fixed

- **A tool call omitting a required argument no longer kills the session (#19, #20).** The `ArgumentError: missing keyword:` raised at the `SafeExecute#call` binding — before the in-body rescue could run — is now caught at the boundary and returned to the model as the canonical validation `{error:}` (`…: is missing`, the I43 seam's wrapper): the session continues and the model self-corrects. Unknown keywords and contract-less tool names get one minted wrapper in the same vocabulary; the rescue never re-raises. The green path and the present-invalid path are byte-unchanged.

### Added

- **Native architect-loop driver mode (#18, default-off).** `Tart::ArchitectLoop` + the `architect_loop` / `architect_compact` tools and the `/loop` command, ported from pi's `architect-loop.ts` onto the I47 Hooks seam: a tart session can drive a space-architect loop itself (spawn role children woken through the real KernelBridge path, ground from `architect looplog`). `architect dispatch` stays as the fallback. Includes the builder guard on the `tool_call` channel and compaction playbook carry.

### Internal

- Test suite 1547 → 1580 runs, 0 failures / 0 errors.

## 0.2.1 (2026-11-14)

Patch release off main since 0.2.0.

### Fixed

- **Edit tool no longer reports failure after a successful write (#15).** Display metadata (diff string + unified patch) now generates *before* `File.binwrite`; a metadata crash degrades to nil details with a warning instead of flipping the completed mutation into an error result. The diff-lcs `Hunk` recipe is gone — one `line_diff_parts` engine now serves both display and patch — and `safe_execute` errors carry class + site.
- **Interactive wake restored (#14).** `bin/tart` now wires the wake ferry through `Subagents.wake_bridge(session)` to the real `Session#push_event` (the old wiring called `TUI.push_event`, which never existed). The supervisor `surface` rescue warns on wake failure instead of silently swallowing it.

### Added

- Web tools: `web_search` + `web_fetch` against Exa (stdlib-only client, x-api-key, capped), `exaApiBase` settings tier (#13).
- Interrupt-delivery belt (tick seam) for subagent runs (#16).

### Internal

- Test suite 1535 → 1547 runs, 0 failures / 0 errors.

## 0.2.0 (2026-10-30)

Drop Ruby 3.3, first CI (#12).
