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
- [ ] Navigation: select row, Enter/→ into folder, Backspace/← up, arrow keys
- [ ] Tab = switch active pane; visible active-pane indicator
- [ ] Multi-select (Shift/⌘-click, Space-to-mark)
- [ ] Tabs per pane
- [ ] Path bar (type a path) + breadcrumbs
- [ ] Hidden files toggle (⌘⇧.)
- [ ] QuickLook on Space
- [ ] Own file engine: copy (F5) / move (F6) / delete (F8) / rename — visible queue, progress, cancel
- [ ] Tags: native xattr read/write + index + UI
- [ ] Internal extension points laid (columns / commands / context-menu) — first-party goes through them

## v0.2 — Differentiators

- [ ] Preview panel (toggle)
- [ ] Color coding by rules / type / tags
- [ ] Bulk rename with regex
- [ ] Bookmarks / favorites

## v0.3 — Platform

- [ ] JS plugin runtime (JavaScriptCore) + 2–3 extension points exposed
- [ ] First community plugin (git-status column) as proof
- [ ] Search (mdfind/Spotlight + own)
- [ ] AirDrop / Share from UI

## Later

- [ ] FTP / SMB / cloud as virtual filesystems (XPC)
- [ ] Plugin marketplace
- [ ] Archive mounting

## Next up

Navigation + keyboard (the rest of the spine sits on it): wire `PaneModel.open()` to the UI,
row selection, Enter/→/Backspace, arrow keys, Tab between panes, active-pane indicator.
