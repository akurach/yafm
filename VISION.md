# yafm — Vision

**Yet Another File Manager for macOS.**

Name is a wink at `yarn` — the tool that once made a boring job feel good. yafm wants to do that for files on macOS.

## Why

Finder annoys. It's a rudiment of very old releases, kept alive in roughly the same shape, and it shows:

- **Tags are garbage.** Clunky, weak. We want real, fast, visible tags.
- **Color coding is garbage.** We want flexible coloring (by type / rules / tags).
- **It freezes silently.** On external disks it shows an empty folder, then 3 minutes later — without touching anything — the files appear. No "I'm loading" signal, just a dead empty folder.
- **Illogical in places.** Legacy decisions, not deliberate ones.

yafm is the daily driver Finder should have been: fast, keyboard-driven, modern, honest about what it's doing.

## Pillars

- **Never lies, never freezes silently.** Everything async. Always a visible "reading…/loading…" state. This is the core differentiator.
- **Native + fast + beautiful.** Swift / SwiftUI. All three are non-negotiable.
- **Keyboard-first.** Total Commander usability as the base (F5 copy, F6 move, F8 delete, Tab to switch pane, multi-select).
- **Dual-pane + real tabs.** Each pane has its own tabs.
- **For everyone.** Normal users and power users. Power features exist but don't get in the way.
- **Extensible.** Thin core, plugins for the rest.

## Decisions (locked)

- **Distribution:** notarized **DMG**. No App Store, no sandbox (sandbox would break plugins, FTP/SMB, full disk access — not worth it).
- **Tags:** read/write **native macOS tags** (xattr `com.apple.metadata`) so they stay compatible with Finder, plus our own **index** for speed and a proper **UI**.
- **File operations:** our **own engine** — visible queue, progress, cancel. Finder hides this; we show it.
- **Plugins:** community plugins are **JavaScript** via **JavaScriptCore** (ships with macOS, zero deps). Model is Obsidian/Chrome: download a file → it loads → it works. Toggle on/off, marketplace later. No rebuild. Plugins can only do what the host API exposes. Heavy first-party features (SMB, archive mounting) may be native/XPC but appear in the same plugin registry for a uniform UX.
- **Preview panel:** toggleable.

## Plugin extension points (the long-term API contract)

Design the registry/loader correctly from day one; ship points incrementally.

- Columns (e.g. git status, custom metadata)
- Commands (command palette, ⌘K)
- Context-menu actions
- Toolbar buttons
- Custom previewers
- Virtual filesystems (FTP/SMB/cloud as a "disk" — the heaviest hook, needs streaming)
- Transformers (bulk rename rules, converters)

## Roadmap

### v0.1 — Spine (already better than Finder for daily use)
- Dual pane + tabs per pane
- **Async listing + visible "reading…" state** (the foundation everything sits on)
- Keyboard TC-style: arrows/Enter, Tab=switch pane, F5/F6/F8, multi-select
- Own file engine: copy/move/delete/rename + visible queue, progress, cancel
- QuickLook on Space
- Hidden files toggle (⌘⇧.)
- Path bar (type a path) + breadcrumbs
- **Tags: native + index + UI**

Architecturally present in v0.1 but invisible: async FS layer, and internal extension points (columns / commands / context-menu) — first-party features go through them. No JS loader/marketplace yet, but the contract is laid.

### v0.2 — Differentiators
- Preview panel (toggle)
- Color coding by rules / type / tags
- Bulk rename with regex
- Bookmarks / favorites

### v0.3 — Platform
- JS plugin runtime (JavaScriptCore) + 2–3 extension points exposed
- First community plugin (e.g. git-status column) as proof
- Search (mdfind/Spotlight + our own)
- AirDrop / Share from the UI

### Later
- FTP / SMB / cloud as virtual filesystems (XPC)
- Plugin marketplace
- Archive mounting
