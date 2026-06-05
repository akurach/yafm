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

## v0.2.2 — UX bugfixes & polish

Post-0.2.1 bug report fixes. Full notes in [`CHANGELOG.md`](CHANGELOG.md).

- [x] QuickLook follows the keyboard cursor (Space → preview, arrows update it in place)
- [x] Instant mouse single-click (no double-click disambiguation stall / dropped clicks)
- [x] No table jank while loading — floating "Reading…" badge + disabled implicit row animations
- [x] External-HDD eject button appears (eject fallback for any non-internal volume)
- [x] Custom tag editor UI (swatches + chips + inline add) replacing the Finder-style submenu
- [x] Context menus across all sidebar sections (Favorites / Locations / Devices / Tags)

## v0.2.3 — Settings & app shell

App-shell milestone pulled out of the backlog. Full spec: [`app-shell.md`](docs/feature-requests/app-shell.md).

- [x] Settings window (⌘,) backed by `UserDefaults` (`AppSettings`, `SettingsView`)
- [x] **General → "Right arrow opens files"** — default off (→ enters folders only; Enter always
  opens), opt-in to also open files on →
- [x] General → "Show hidden files in new tabs" (applies to newly opened tabs/panes)
- [x] Appearance → theme Light / Dark / System (`.preferredColorScheme`, persisted)
- [x] About yafm (standard panel, version from Info.plist)
- [x] General → start folder (Home / last used / specified, with folder picker)
- [x] Operations tab — confirm-before-delete (default on; permanent delete) + default
  collision behavior (keep both / skip / replace) plumbed through `OperationTask.collision`
- [x] Tags tab — rescan / clear the tag index (`TagService.clear`, `AppState.rescanTags/clearTags`)
- [x] Auto-update MVP — "Check for Updates" via GitHub Releases API, honest status, opens the
  release page (option 2 from the spec; Sparkle auto-install still deferred)

## v0.3 — Platform

- [x] JS plugin runtime (JavaScriptCore) behind `ExtensionRegistry` — plugins
  contribute table columns via `yafm.registerColumn`, each file its own sandboxed
  `JSContext` (no FS / network / process; only a path-free entry snapshot).
  Seeds an editable `example-kind.js` on first run. Settings ▸ Plugins manages it.
- [x] git-status column as proof — first-party **native** `GitStatusService`
  (per VISION: heavy first-party features may be native yet appear in the same
  registry). Per-file markers (M/A/?/D, `•` rolled-up folders), tinted in the table.
  A JS-reachable git/exec capability is intentionally still withheld (see below).
- [x] Search (mdfind/Spotlight + own) — ⌘F find-within-folder, Spotlight with a
  recursive name-substring fallback, results shown as a virtual listing.
- [x] AirDrop / Share from UI — `NSSharingService` "Share ▸" in the row menu.

## Later

- [ ] **Russian interface (localization / i18n)** — move all UI strings to
  `Localizable.strings`, add a `ru` localization, and a language picker in
  Settings ▸ General (System / English / Русский). Today every label is a
  hard-coded English literal across `App/*.swift`; first pass is extracting them.
- [ ] Seamless auto-install updates (Sparkle) — v0.2.3 shipped the GitHub-releases *check*; this is
  the remaining app-shell piece (signed appcast + EdDSA, accounts for the notarized-DMG/no-sandbox model)
- [ ] FTP / SMB / cloud as virtual filesystems (XPC)
- [ ] Plugin marketplace
- [ ] Archive mounting

## Someday / backlog (full specs in [`docs/feature-requests/`](docs/feature-requests/))

Parked feature requests with complete specs. Not scheduled; pull into a milestone when prioritized.

- [ ] **Device Detection & Classification** — on mount, async-collect volume metadata (filesystem,
  capacity, free space, writable/read-only, vendor/model, transport) via DiskArbitration + IOKit and
  classify the device (SSD/HDD/USB/SD/camera card/backup/network) with a confidence score; device-type
  icons in the sidebar. Reused later by Photo Ingest. Spec: [`device-detection.md`](docs/feature-requests/device-detection.md)
- [ ] **Photo Ingest** — import from camera cards (SD/CFexpress/USB): detect camera media, import
  wizard, preview, copy+verify (checksum), duplicate handling, `import-report.json`, safe eject.
  Spec: [`photo-ingest.md`](docs/feature-requests/photo-ingest.md)
- ✅ **App shell** — delivered in v0.2.3 (Settings ⌘, with General/Appearance/Operations/Tags/Updates,
  About, theme, GitHub-releases update check). Spec: [`app-shell.md`](docs/feature-requests/app-shell.md).
  Residual (Sparkle seamless auto-install) tracked under **Later**.

## Hardening backlog (from the security + Swift audit — see `SECURITY.md`)

Done: symlink-safe copy, rename path-traversal guard, xattr size/count caps, copy-progress
fix, cancellation no longer looks "complete", `cancelled`-set leak, QuickLook actor isolation,
executable-open confirmation, path-bar input validation.

Done (audit 2026-06-05 follow-up): cancel actually interrupts a running op (B-2); `TagService.index`
reads xattrs off-actor (B-1); commands derive from a single `DefaultCommands.byBinding` source;
precompiled `ColorRule` regex + ReDoS length caps; cached `TabModel.displayed`; reverse-index in
`TagService.reindex` + persistence + invalidation; FS-detail reads moved into the provider; delete
progress recurses; +13 tests (cancel/move/rename/recursive/collision/regex/persistence).

Deferred (tracked, not yet done):
- [ ] **OPS-1** (audit 2026-06-05): `.replace` collision removes the destination *before* writing —
  a failed/cancelled copy loses both files. Copy to a temp sibling + `replaceItemAt` (atomic swap).
- [ ] TOCTOU: open copy output with `O_EXCL` instead of exists-check + truncate
- [x] Plugin capability boundary enforced (v0.3): JS plugins get only a path-free entry
  snapshot — no `url`/path, FS, network, or process — and each runs in its own `JSContext`.
  `JSPluginHost.snapshot(of:in:)` is the single widening point. `PluginContext.resolve`
  remains the chokepoint for the day a scoped-FS capability is added.

## Next up

v0.3 platform shipped (JS runtime, native git-status column, search, Share). Next:
- Widen the plugin surface beyond columns — context-menu items and commands from JS,
  then a vetted scoped-FS capability (`PluginContext.resolve`) so a plugin can read files
  it's granted, opening the door to a real JS git plugin and community plugins.
- Plugin metadata/manifests + enable/disable per plugin in Settings.
- Content search (beyond name) and a results pane that remembers its origin.
- Then the **Later** items: Sparkle seamless auto-install, FTP/SMB virtual filesystems.
