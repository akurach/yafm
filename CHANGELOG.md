# Changelog

All notable changes to yafm are recorded here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added — v0.1 spine
- SwiftPM scaffold: `Core` (async filesystem provider, streamed cancellable listing) and
  `App` (SwiftUI dual-pane entry).
- Honest loading state: panes render "Reading… (N)" while a directory streams in.
- `App/Resources/Info.plist` (bundle id `com.yafm.app`) and `Scripts/make-app.sh` to wrap the
  SwiftPM binary into a real `.app` bundle.
- TC-style keyboard navigation: ↑↓ cursor, Enter/→ open, Backspace/← up, Tab switches pane,
  ⇧+arrows multi-select, F5 copy / F6 move / F8 delete / F2 rename, Space QuickLook, ⌘⇧. hidden.
- Tabs per pane, active-pane indicator, path bar (typed + validated) with breadcrumbs.
- Own file engine (`FileEngine`): streamed copy/move/delete/rename with real byte progress,
  a visible operation queue, and cancel.
- Native macOS tags (xattr `com.apple.metadata:_kMDItemUserTags`) read/write + in-memory index,
  shown as color dots.
- Extension points (`ExtensionRegistry`: columns / commands / context-menu) — the plugin contract.
- `ROADMAP.md`, `SECURITY.md`, and this changelog. 10 Core unit tests.

### Added — v0.2 differentiators
- Inline preview panel (⌘⇧P) via `QLPreviewView`.
- Color coding by extension / directory / tag / name regex (`ColorCoder`).
- Bulk rename with regex + `#` sequence counter and a live preview (`RenameSheet`).
- Bookmarks sidebar (Home / Documents / Downloads / Desktop).

### Added — v0.2.1 daily-driver UX (see `TZ.md`)
- Context menu (right-click) on rows and empty pane area: Open / Open With (LaunchServices) /
  Quick Look, Copy→/Move→ other pane, internal Copy (⌘C) / Cut (⌘X) / Paste (⌘V),
  Rename / New Folder (F7) / Delete, Tags ▸, Reveal in Finder, Get Info, Copy Path; background
  menu adds Sort By / Show Hidden / Refresh.
- Mounted volumes in the sidebar — Favorites · Locations · Devices · Network sections with a
  capacity bar and eject for removables, live-updated on mount/unmount (`Core/Volumes.swift`
  `VolumeService` + `NSWorkspace` notifications).
- TC-style function-key bar (F2…F8, clickable, compact when narrow) with new F3 View / F4 Edit /
  F7 New Folder commands.
- Table columns Name / Size / Modified / Kind with click-to-sort (▲/▼, reverse on repeat) and a
  right inspector with Info / Preview modes — kind, background-computed folder size, created/
  modified dates, POSIX permissions, path, and a color + free-text tag editor.
- Tag cloud in the sidebar (color dot + name + file count, click → virtual "everything tagged X"
  listing), backed by a bounded background index of Home so the cloud isn't empty on cold start
  (`TagService.index(roots:)`).
- Access onboarding: Info.plist usage strings (Desktop/Documents/Downloads/Removable/Network),
  first-run Full Disk Access sheet with a deep link into System Settings, and an honest
  "limited access" banner instead of silently-empty protected folders.
- 1 new Core unit test (`testIndexPopulatesTagCloudFromRoot`) — 11 total.

### Fixed
- App launched faceless (no window) with `linkd.autoShortcut` / "missing main bundle
  identifier" warnings — caused by a bare SPM executable having no `CFBundleIdentifier`.
  Running from the generated `.app` bundle fixes it.

### Security
- Hardened after a security + Swift-concurrency audit: symlink-safe copy, rename
  path-traversal guard, xattr size/count caps, executable-open confirmation, listing-cancel
  correctness, copy-progress accuracy, QuickLook actor isolation, key-monitor assertion,
  `cancelled`-set leak. Full table in `SECURITY.md`.

### Fixed — audit 2026-06-05 follow-up
- **Cancel now interrupts a running operation (B-2).** `FileEngine` keeps its cancel set in an
  `OSAllocatedUnfairLock` and runs the blocking copy loop `nonisolated`, so a cancel is observed
  mid-copy instead of queueing behind the in-flight `execute`.
- **`TagService.index` no longer starves the actor (B-1).** xattr reads run in a background
  detached task and merge back in one actor hop.
- **Single source of truth for key dispatch.** The keyboard layer decodes events into a
  `KeyBinding` and looks them up in `DefaultCommands.byBinding`, instead of duplicating F-key codes.
- **`TagService`** gains a reverse `url→tags` map (O(tags-on-url) reindex), on-disk persistence
  (`persist`/`loadPersisted`), and `forget(_:)` invalidation wired into delete/move/rename/cut-paste.
- **Inspector reads go through the provider** (`detail(of:)`, `directorySize(of:)`) instead of
  reaching past it to `FileManager`, so a virtual FS returns correct values.
- Precompiled `ColorRule` regex + ReDoS length caps; cached `TabModel.displayed`; delete progress
  recurses into folders and sizes before removing; `newFolder` routes through the engine; tag-cloud
  open streams entries; deferred context-menu focus out of the render pass; volume-observer cleanup
  in `deinit`; double-paste guard; QuickLook index bounds check; assorted N-level cleanups.
- +13 Core tests (cancel-mid-copy, move, rename, recursive copy, n≥3 collision, delete progress,
  missing source, listing cancellation, regex edges, literal rename, tag forget/persistence) — 24 total.
- `Views.swift` (840 lines) split into `Sidebar.swift`, `Inspector.swift`, `FunctionBar.swift`,
  `RenameSheet.swift`.

### Fixed — post-icon bug report
- Keyboard nav dead / selection jumping to the last row: SwiftUI builds each row's
  context menu eagerly, and focusing the row inside the menu *builder* fired for every
  row and snapped selection to the last one. Focus now happens inside each menu action.
- File list pinned to the bottom of the pane with the header floating mid-pane: the
  `List` wouldn't fill a `VStack`; rebuilt as a `List` with a pinned `Section(header:)`,
  which fills natively and aligns header columns with the rows.
- Tag cloud empty: indexing walked Home with `.skipsHiddenFiles`, missing tags under
  `~/Library/Mobile Documents` (iCloud). Now indexes via Spotlight (`mdfind`) across the
  whole system, plus a direct walk of explicit roots for un-indexed locations.
- Context menu restyled with SF Symbols + grouping; destructive Delete role.
- App icon had a white border (source PNG was a dark squircle on white, no alpha) —
  trimmed and flood-filled corners to transparent.

### Added
- App icon (`App/Resources/AppIcon.icns`, wired via `Info.plist` + `make-app.sh`).
- `docs/feature-requests/` backlog with full specs: Photo Ingest and the app shell
  (Settings / About / auto-updater / theme).
- `PluginContext` capability-boundary type drafted for the v0.3 JS plugin host.
