# yafm — Roadmap (status tracker)

The **why** and locked decisions live in [`VISION.md`](VISION.md). This file tracks
**what is actually done** vs planned. Update it whenever a feature lands, and add a matching
entry to [`CHANGELOG.md`](CHANGELOG.md).

Legend: `[x]` done · `[~]` in progress · `[ ]` not started

## v0.1 — Spine

- [x] SwiftPM scaffold (`Core` + `App`) builds & runs as a real `.app` bundle
- [x] Async FS listing layer (`Core/FileSystem`) — streamed entries, cancellable
- [x] Visible "reading…/loading…" state in the UI (the core differentiator)
- [x] Dual pane (side-by-side)
- [x] Navigation: Enter/→ into folder, Backspace/← up, ↑↓ cursor (`Keyboard.swift`)
- [x] Tab = switch active pane; visible active-pane indicator
- [x] Multi-select (⇧+arrows, click; cursor + selection model in `TabModel`)
- [x] Tabs per pane (`PaneModel`, `TabBarView`)
- [x] Path bar (type a path, validated) + breadcrumbs (`PathBarView`)
- [x] Hidden files toggle (⌘⇧.)
- [x] QuickLook on Space (`QuickLook.swift`)
- [x] Own file engine: copy (F5) / move (F6) / delete (F8) / rename (F2) — visible queue, progress, cancel
- [x] Tags: native xattr read/write + in-memory index + UI dots (`Tags.swift`)
- [x] Internal extension points laid (columns / commands / context-menu) — `Commands.swift` `ExtensionRegistry`

## v0.2 — Differentiators

- [x] Preview panel (toggle, ⌘⇧P) — `PreviewPane` / `QLPreviewView`
- [x] Color coding by rules / type / tags (`ColorCoder`, `ColorRule`)
- [x] Bulk rename with regex + live preview (`RenameRule`, `RenameSheet`)
- [x] Bookmarks / favorites (`BookmarksSidebar`)

## v0.3 — Platform

- [ ] JS plugin runtime (JavaScriptCore) + 2–3 extension points exposed
- [ ] First community plugin (git-status column) as proof
- [ ] Search (mdfind/Spotlight + own)
- [ ] AirDrop / Share from UI

## Later

- [ ] FTP / SMB / cloud as virtual filesystems (XPC)
- [ ] Plugin marketplace
- [ ] Archive mounting

## Hardening backlog (from the security + Swift audit — see `SECURITY.md`)

Done: symlink-safe copy, rename path-traversal guard, xattr size/count caps, copy-progress
fix, cancellation no longer looks "complete", `cancelled`-set leak, QuickLook actor isolation,
executable-open confirmation, path-bar input validation.

Deferred (tracked, not yet done):
- [ ] TOCTOU: open copy output with `O_EXCL` instead of exists-check + truncate
- [ ] Perf: cache `displayed` (sorts on every SwiftUI body); precompile `ColorRule` regex;
  reverse-index in `TagService.reindex`
- [ ] Plugin capability boundary (`PluginContext`) before any JS API is exposed (v0.3)

## Next up

v0.3 platform work: JS plugin runtime (JavaScriptCore) behind the `ExtensionRegistry` contract,
starting with the deferred `PluginContext` capability boundary, then a git-status column plugin.
