# Changelog

## Unreleased

### Changed

- **The last Thread in `lib/` is gone: the TUI input path is now fiber-native end to end (I109).** The dedicated poller thread (the I107 concurrency-law exemption) is deleted — `Poller`/`PollerLingerError` and the poller-lifecycle linger machinery with it. In its place the kernel runs an fd-driven input seam on the reactor: per-fd tasks park on the session's exposed input-wait fds via `IO#wait_readable` (io-event under the Async scheduler) and push onto the same event queue — the wake fd drains its byte(s) and pushes the `:wake` sentinel when synthetic events are pending; the tty fd runs the non-blocking ready-read (`poll_event(timeout: 0)`, the GVL-free call, invoked only on reported readiness). No polling timer replaces the thread: a session with no fds (headless/test mode) leaves the idle loop parked on the queue. The kernel exposes the producer (`Loop#input_seam`, `stopped?` observable); teardown stops it with the reactor's own `Task#stop` — no join, no linger class. The I103 boot/teardown `signal_state_change` broadcasts keep their exact seats, re-seated on the seam's lifecycle. `TUI::Session` gains `input_wait_fds` (empty when no real terminal — non-exposing doubles keep working unchanged); the `ratatui_ruby` dependency moves to a Gemfile git pin (`jetpks/RatatuiRuby`, branch `event-fd-seam` — the owner-ratified same-gem/git-source carve-out; the gemspec carries a restore-at-upstreaming note). Input latency and SIGWINCH delivery are at parity with the poller shape (measured: medians ~8 ms both arms — the Builder Report's table).

- **The tree's remaining Thread/Mutex/ConditionVariable concurrency is migrated to async/fiber primitives per the owner's concurrency law (2026-11-21, PR-#28 review).** Every long-lived worker (the sink flusher, the herdr sender, the manager watcher, the supervisor channel poller, the MCP stdio readers/writer, the print deadline) now runs as a task on the host reactor; one-shot bounded work self-gates through `Kernel#Sync`; cross-thread wakes use the dual-path queue ping (direct push + scheduler-ready rider); the kernel's per-signal disposable thread, the test belt's ConditionVariable park, and all guard Mutexes whose funnels became same-reactor are deleted — zero behavior change beyond synchronization mechanics. Two sites survive as named, owner-ratified exemptions: the TUI poller thread (ratatui's FFI poll has no unblock function, so a fiber cannot stand in) and `FileMutationQueue`'s two Mutexes (same-file mutation serialization across the bare off-reactor call seats, where every async wait primitive would crash).

### Removed

- **`lib/tart/core/poller.rb` (the `Tart::Core::Poller` thread + `PollerLingerError`).** The class, the I02 missed-join guard, and the I107 named-exemption comment die with the file: the fd seam does the waiting on the reactor, and crossterm's read runs GVL-free only when a selector reports readiness. Suite membership moves 1664 → 1662 (seven superseded poller pins retired/re-derived per the I109 spec §e).

### Fixed

- **`grep`'s process management is now async/fiber native per the concurrency law.** The deadline, the stderr drain, and the reap all run as reactor fibers: `Kernel#Sync` gates the call (the live tool task runs inline; bare callers get a fresh reactor on their own fiber), pipe reads and `Process.waitpid2` park evented in the scheduler, the deadline is a `with_timeout` fiber timer with time-based TERM→KILL escalation, and the match limit TERMs the whole process group — no threads anywhere. Behavior is unchanged: the `TOOL_TIMEOUT_S` deadline (default 120 s), the teaching-refusal bytes, limit-hit results, and normal greps.

- **Reading a zero-byte file is empty content, not a crash.** `read` on an empty file now returns empty content (`""`, with the usual truncation details) instead of an `{error:}` envelope: the image MIME sniff used to raise `NoMethodError` on the zero-byte read (`File.binread` returns `nil`), which surfaced as a tool error. A nil buffer and a zero-byte file both sniff as "no image" now; one-byte and normal files are byte-identical.

- **A stuck `rg` child can no longer wedge a `grep` call.** `grep` now spawns ripgrep in its own process group with stdin closed, and a watchdog enforces a deadline: `TOOL_TIMEOUT_S` env (positive integer, read at call time) or 120 s by default; junk/zero/negative values fall back to 120. At the deadline the whole process group is TERMed, probed after a 2 s grace and KILLed if it ignored TERM (the escalation is time-based), every wait is bounded (WNOHANG reap budget, drained stderr, retired watchdog), and the call returns a teaching refusal — `TOOL_TIMEOUT: grep exceeded <N>s and was killed (pattern=… path=… glob=-). Narrow the search: a smaller path, a tighter glob, or a more specific pattern.` — instead of hanging the session. Normal greps are unchanged.

- **The edit tool accepts the legacy single-edit shape under both key spellings.** A call with top-level `oldText`/`newText` beside `path` — string keys (the executor's wire form) or symbol keys — now folds into a one-element `edits[]` equivalent and executes instead of refusing with `edits: is missing`; the four legacy keys are consumed, never forwarded. The `edit` description now declares the canonical shape (`edit(path, edits: [{oldText, newText}, …])`) explicitly.

### Added

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
