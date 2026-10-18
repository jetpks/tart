# Vendored pi model catalogue

This directory carries the provider model-catalogue data vendored from the
[pi](https://github.com/earendil-works/pi) repository
(`packages/ai/src/providers/data/`), used by tart as a local, offline
metadata baseline: gap-fill facts for model entries the user references but
does not fully declare, and enrichment for live `/v1/models` listings.

- **Source:** pi — `packages/ai/src/providers/data/*.json`
  (<https://github.com/earendil-works/pi/tree/main/packages/ai/src/providers/data>)
- **License:** MIT — `Copyright (c) 2025 Mario Zechner`
  (<https://github.com/earendil-works/pi/blob/main/LICENSE>). The data ships
  committed in-tree in the public pi repository, so the verbatim vendoring is
  license-clean; the licence text is reproduced at the link above.
- **Provenance:** `.manifest.json` is tart's OWN manifest over exactly the
  vendored `*.json` files (per-file sha256, the source clone's HEAD sha as
  the `revision`). pi's own `.manifest.json` is deliberately not copied.
  The data files themselves are byte-verbatim copies — never pruned or
  rewritten.

## Refresh

```sh
PI_REPO=/path/to/local/pi clone bundle exec rake models:vendor:refresh
# default PI_REPO is `../pi` beside the tart root
```

## The local-clone-only law

The refresh task reads a LOCAL pi checkout only and never touches the
network — no fetching from pi.dev at boot, on demand, or during the refresh.
The catalogue updates only when an operator re-runs the rake task against a
pinned local clone; the vendored tier itself reads these local files and
nothing else.
