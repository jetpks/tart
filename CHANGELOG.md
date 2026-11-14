# Changelog

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
