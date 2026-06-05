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

## v0.2.1 — Daily-driver UX (makes it actually usable) — see [TZ.md](TZ.md)

The v0.1/v0.2 skeleton works but isn't usable yet: right-click does nothing, drives aren't
shown, hotkeys are undiscoverable, no metadata is visible, tags can't be browsed. This milestone
closes that. Full spec in [TZ.md](TZ.md).

- [x] Context menu (right-click) on rows + empty pane area — Open/Open With/QuickLook, Copy/Cut/
  Paste, Copy→/Move→ pane, Rename/New Folder/Delete, Tags ▸, Reveal in Finder, Get Info, Copy Path
- [x] Mounted volumes/devices in the sidebar — Locations/Devices/Network sections, eject, live
  update on mount/unmount (`VolumeService` + NSWorkspace notifications)
- [x] Function-key bar (bottom, TC-style, clickable): F2 Rename · F3 View · F4 Edit · F5 Copy ·
  F6 Move · F7 New Folder · F8 Delete (+ new F3/F4/F7 commands)
- [x] Columns (Name/Size/Modified/Kind) with click-to-sort + right info inspector (size/dates/
  permissions/tags/preview), merged with the existing preview panel
- [x] Tag cloud in the sidebar (all known tags + counts + color, click to filter) + tag editor
  (7 Finder colors + new tag) in context menu & inspector
- [x] Access on launch: Info.plist usage strings + Full Disk Access onboarding + honest
  "limited access" banner (never silent empty folders); removable/network volume consent

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
