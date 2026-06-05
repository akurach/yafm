# Changelog

All notable changes to yafm are recorded here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
the project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.9.0] — 1.0 candidate

Stability + the last extension points. This release is mostly about making yafm
actually live up to its one promise — **it never freezes** — after real use
turned up big folders and drag-and-drop that did exactly that. Plus the final
VISION extension points and a data-loss fix, on the way to 1.0.

### Fixed — the never-freeze pillar, for real
- **Big folders no longer freeze on open.** Listing re-sorted the *entire growing
  partial* on every 128-file stream batch — O(n²) `localizedStandard` sorting on
  the main thread. A folder like Downloads churned for seconds. Now the stream
  shows arrival order and sorts **once** when complete: measured **1767 ms → 68 ms
  (26×)** for 8 000 files. Stream updates are also coalesced (a handful of
  re-renders, not one per batch). (`TabModel`.)
- **Tag dots no longer cost a syscall per row.** Opening a folder read
  `getxattr` for *every* file and then re-sorted — seconds on a big folder, even
  when nothing was tagged. Tags now come from the in-memory index in one batch,
  and the UI only updates when a file is actually tagged. (`TagService.cachedTags`.)
- **No more beachball on large folders / re-sort.** The tag-editor was a
  `.popover` attached to **every row**, which SwiftUI instantiates per row. It's
  now a single sheet for the whole table.
- **Drag between panes is smooth.** The drop highlight mutated table-level state
  on every hover, re-rendering the whole list. The targeted state now lives per
  row (and the pane drop has none), so an inter-pane drag no longer crawls.
- **Delete confirmation keeps focus.** Pressing Return on the delete prompt
  opened the file instead of confirming — the global key monitor swallowed the
  Return before the alert saw it. The monitor now stands down whenever a modal is
  up. (`Keyboard.swift`.)

### Added — last extension points
- **Transformers** — reusable bulk-rename rules / converters (`Transformer`):
  lowercase, sequential numbering, space-replace built in; registered in the
  extension registry for first-party features and (capability-bounded) plugins.
- **Custom previewers** — a `Previewer` extension point so file types QuickLook
  handles poorly (logs, CSV) can get a tailored preview; resolved by extension.
- **Plugin API frozen at 1.0** — within 1.x the contract is a compatibility
  promise (additive capabilities, deprecation window before removal); a breaking
  change bumps the major and is refused by the loader.

### Fixed — data safety
- **OPS-1 atomic replace.** A `.replace` copy deleted the destination *before*
  writing — a failed/cancelled copy lost both files. It now copies to a temp
  sibling and swaps with `replaceItemAt`; the original survives any failure. The
  output is also opened `O_CREAT|O_EXCL|O_NOFOLLOW`, closing the TOCTOU window and
  never following a planted symlink. (`FileEngine`.)

### Deferred (with reason)
- **Photo Ingest** + **device-detection sidebar icons** — Photo Ingest depends on
  device detection (auto-prompt on plugging a camera), which stays deferred; both
  are peripheral to the 1.0 stability focus and tracked in `docs/feature-requests/`.
- **Notarized DMG** — still gated on a paid Apple Developer ID.

### Docs
- User Guide now ships in **English and Russian** (`docs/USER_GUIDE.ru.md`).

_Tests: +8 Core (transformers, previewers, API freeze, atomic-replace + symlink
safety) → 79 total. Perf verified with listing/sort microbenchmarks._

## [0.8.0] — Make it yours

Extensibility re-opens — now safely. The public plugin surface, frozen since the
2026-06-05 re-sequencing, comes back with a capability model: a plugin declares
what it needs in a manifest, you grant it at enable-time in Settings, and the
host hands it nothing more.

### Added — plugin platform
- **Plugin manifests.** A sidecar `<plugin>.json` (`manifest: 1`, reverse-DNS
  `id`, `version`, `apiVersion`, `capabilities`, `contributes`) gives a plugin an
  identity and gates every surface beyond a column. A bare `.js` with no manifest
  still loads **compute-only** — the drop-a-file UX is intact. (`PluginManifest`.)
- **Per-plugin enable/disable** in Settings ▸ Plugins, with each plugin's
  capabilities and a **trust badge** (Signed / Author / Unsigned) shown honestly.
- **Re-opened command & context-menu surface.** Plugins can `registerCommand`
  (run from the pane menu) and `registerMenuItem` (row right-click) — but only
  when the manifest grants `contribute:command` / `contribute:menu`.
- **Scoped-FS read capability (`read:cwd`).** A granted plugin gets
  `yafm.readText(entry, "rel/path")`: the host resolves it **against the entry's
  folder only**, refuses any `..`/symlink escape (`PluginContext` + `O_NOFOLLOW`),
  caps the read at 256 KB, and hands JS an **opaque handle, never a path**. Consent
  is requested when you enable the plugin, never by the plugin.
- **Flagship git plugin.** A bundled "Branch" column reads `.git/HEAD` through
  `read:cwd` — proof the capability path works end to end. Ships **disabled** until
  you grant it.
- **Archive mounting.** Open a `.zip` to browse it read-only, like any folder:
  `ArchiveFileSystem` lists via `unzip` and rides the same `FileSystemRouter` seam
  as SMB (`archive://` scheme). Streamed off the main actor — a big archive loads,
  never freezes.

### Localization
- Russian coverage extended to the new v0.8 plugin UI.

### Deferred (with reason)
- **Remote plugin marketplace** (discovery/install/update) and **cryptographic
  plugin signing** — both need hosted infrastructure + a signing key/PKI (same
  class of blocker as DMG notarization). The manifest already carries the trust
  tier and `signature` field, so signing slots in without a format change; the
  marketplace builds on the same `capabilities` shown before install.

_Tests: +14 Core (manifest parse/validate, read:cwd grant + escape refusal +
capability gating, archive tree synthesis & streaming) → 70 total._

## [0.7.1] — Russian, in full

- **Fix: most of the UI stayed English when switching to Russian.** v0.7 shipped
  only a partial `ru.lproj`, so over half the interface didn't translate. This
  fills it out: every static UI literal across the app — sidebar sections, all
  settings tabs/sections, menus, the command palette, cheat sheet, onboarding,
  bulk rename, plugin & update panels, empty/loading states — is now translated,
  plus the common interpolated formats (`%lld items`, `%lld found`, "Reading…",
  "Searching…"). Resolution verified key-by-key against the bundled strings table.

## [0.7.0] — Remote disks, finally native

Reach + accessibility. yafm grows past the local disk: SMB shares mount natively
behind the v0.4 filesystem router and stream like any folder — a hung share shows
"loading…" or a clear error, never a frozen window. Plus VoiceOver, Dynamic Type,
and a Russian UI.

### Added — remote disks (SMB)
- **SMB as a virtual filesystem.** An `smb://` URL is a first-class location:
  `SMBFileSystem` mounts the share natively via **NetFS** (the system handles the
  SMB protocol and Keychain credentials), then streams the listing through the
  local provider. It's registered behind the `FileSystemRouter` under the `smb`
  scheme, so every call site that only knows `FileSystemProvider` is unchanged.
  Entries are re-keyed into `smb://` space so navigation stays in-provider, and a
  failed mount surfaces as a `.failed` listing — the never-freeze pillar at
  network latency. (`SMBFileSystem`, `NetFSShareMounter`; +6 Core tests.)
- **Connect to Server (⌘⇧K).** Type an `smb://server/share` address; it opens in
  the active pane like any folder. A failed connection reuses the v0.6 unified
  state-view (a connecting share is just `.loading`). (`ConnectServerSheet`.)

### Added — accessibility
- **VoiceOver** reads each file row as one coherent sentence — "name, kind, size,
  tagged X, git modified" — instead of spelling out every column; the cursor row
  carries the selected trait. Icon-only buttons (close/new tab, edit path, cancel
  operation) gained labels.
- **Dynamic Type** rides the `Theme` type tokens (`.body`/`.caption`), so the
  table scales with the system text-size setting.

### Added — localization
- **Russian UI + language picker** (Settings ▸ General ▸ Language: System /
  English / Русский). Localizations ship as `en.lproj` / `ru.lproj`; the picker
  writes `AppleLanguages` and applies on next launch. Coverage is the most
  user-facing surface (menus, settings, search, states) and grows each release.

_Tests: +6 Core (smb URL parsing, router dispatch, stub-mount listing & re-key,
failed-mount error) → 56 total._

## [0.6.0] — Never a dead end

The never-freeze pillar proves itself under load: content search that streams
and cancels instead of locking up, an inline find bar that keeps you in the
keyboard flow, and honest empty/idle states where there used to be a blank pane.

### Added — search that doesn't freeze
- **Content search (grep-in-files).** Toggle the find bar to **Contents** to
  search inside files, not just names. Streaming — hits appear as they're found,
  with a live "Searching… N" count — and cancellable (Esc, ⌘F again, or a new
  query stops the walk). Bounded for safety: an 8 MB/file cap and a binary-file
  skip so a giant log or blob can't stall it. (`SearchService.searchStream`.)
- **Results remember their origin.** A search listing knows which folder it came
  from (`TabModel.virtualOrigin`), shown in the empty/result states.

### Changed — interaction
- **Inline find bar replaces the modal.** ⌘F now opens a bar docked under the
  path bar of the active pane (name / contents toggle, live state, Esc to close)
  instead of a sheet that stole keyboard focus and broke the type-ahead flow.
  (`SearchBar`; the old `SearchSheet` modal is gone.)
- **Honest empty & idle states.** An idle tab, an empty folder, and a search
  with no matches each render an explicit `ContentUnavailableView` — the old
  build drew a blank pane (a quiet violation of the never-freeze pillar). Empty
  folder vs no-search-matches are now distinguished. (`Views.swift`.)

### Deferred (with reason)
- **Sparkle auto-update** — gated on a paid Apple Developer ID cert + a hosted,
  EdDSA-signed appcast (same blocker as DMG notarization). The GitHub-Releases
  update check (v0.2.3) covers the honest "newer version exists" notice until then.
- **Device detection** (DiskArbitration sidebar icons) — held to keep v0.6 on the
  search/states pillar; it primarily feeds photo-ingest in v0.9.

_Tests: +5 Core (content/name streaming, binary & size skip, cancellation) → 50 total._

## [0.5.0] — Looks as good as it runs

The visual & interaction-polish milestone. The keyboard wedge (v0.4) made yafm
fast; v0.5 makes it feel finished — density to your taste, real drag-and-drop,
motion that glides instead of snapping — plus one invisible seam (async plugin
values) landed before a virtual filesystem would force it as a breaking change.

### Added — polish
- **Density modes** (Settings ▸ Appearance ▸ Density): Compact / Cozy /
  Comfortable. Compact packs more rows on screen than Finder's single fixed
  height; Comfortable gives each row room. Drives row padding, font, and icon
  size off the `Density` tokens. (`Settings.swift`, `Views.swift`.)
- **Full drag-and-drop.** Drag a row to the other pane, onto a folder row, or
  out to Finder/any app to copy; hold **⌘** to move. Drop onto empty pane area
  lands in the current directory. Folder rows and the pane draw an accent ring
  while targeted. Dropping files *in* from Finder works too — the same path.
  (`AppState.dropEntries`, `FolderDrop` in `Views.swift`.)
- **Motion toggle** (Settings ▸ Appearance ▸ Motion): animate selection &
  navigation, or keep it instant. On by default.

### Changed — interaction
- **Scoped animation.** The global "disable all animations" kill-switch is gone.
  Selection / cursor / navigation now glide (token-timed, `Theme.Motion`), while
  streaming row inserts stay un-animated so a loading folder never tears.
  (`TabModel.isStreaming` gates it.)
- Cursor vs selection (redesigned in v0.4 — a leading accent bar for the cursor,
  a filled wash for selection) now scales cleanly across all three densities.

### Added — platform seam
- **Async plugin-value path.** `PluginColumn` gains an optional `asyncEvaluate`
  alongside the synchronous `evaluate`; a new main-actor `PluginValueCache`
  memoizes results per (column, URL), shows a placeholder while resolving, and
  de-dups concurrent reads of the same cell. A future VFS/remote column plugs in
  here without touching the table or any existing sync plugin. (`Commands.swift`;
  4 new Core tests — 45 total.)

## [0.4.0] — Fast as your editor

The keyboard-first milestone. The roadmap was re-sequenced (2026-06-05 review):
with no users yet, the public plugin surface stays **frozen** until v0.8 and
v0.4 instead targets the wedge — the keyboard-driven power user — with speed,
navigation, and visual polish. Two invisible "cheap-insurance" seams land now so
the hard later hooks (virtual filesystems, accessibility) don't force a rewrite.

### Added — keyboard-first
- **Command palette (⌘K).** Fuzzy "jump to anything": run any command, jump to a
  Favorite, or open a subfolder of the current directory. Type to filter, ↑↓ to
  move, Enter to run, Esc to close. The centerpiece of the keyboard-first pillar.
  (`App/CommandPalette.swift`, `CommandID.commandPalette`.)
- **Type-to-filter.** Start typing letters/numbers while a pane is focused to
  live-filter the current folder by name (Total Commander quick-search). Esc
  clears, Backspace edits; arrows/Enter still navigate the filtered list.
  (`TabModel.filter`, `App/Keyboard.swift`.)
- **Keyboard tab-switching.** ⌃Tab next / ⌃⇧Tab previous, ⌘1–⌘9 jump to tab N.
  (Tab alone still switches the active pane.)
- **Shortcut cheat sheet (⌘/).** A discoverability overlay listing every
  keyboard shortcut, grouped. (`CheatSheet`, Help ▸ Keyboard Shortcuts.)

### Added — visual
- **Real file-type icons.** Each entry shows its true macOS document/app icon
  (cached per type) instead of a generic glyph; color-coding rules now tint the
  name. (`App/FileIcon.swift`.)
- **Distinct cursor vs selection.** The keyboard cursor is a crisp accent ring;
  the selection is a filled wash — no longer a barely-visible ~15% opacity gap.

### Added — architecture seams (invisible now, load-bearing later)
- **`FileSystemRouter`** — routes filesystem calls by URL scheme to a provider.
  Today everything is local and unchanged; v0.7 SMB/FTP and v0.8 archives plug in
  by registering a scheme, with no call-site changes. (`Core/FileSystemRouter.swift`,
  + routing/fallback tests.)
- **UI tokens layer (`Theme`).** Spacing, type scale, semantic colors, and column
  widths in one place — the seam that makes later polish and accessibility a token
  edit instead of a hunt across `Views.swift`.

### Added — earlier (carried from Unreleased)
- **Tag manager (Settings ▸ Tags).** Every known tag with its color swatch and
  file count, editable in place — recolor (7 Finder colors / none), rename across
  every file that carries it, or delete from every file (files untouched). Backed
  by `TagService.renameTag/deleteTag/recolorTag` + a Core test.

### Notes
- New UI strings wrapped in `String(localized:)` (i18n hygiene) so the eventual
  Russian localization (v0.7) is a bounded extraction.
- Full v0.4 → v0.9 roadmap with the dependency spine lives in `ROADMAP.md`.

## [0.3.0] — Platform

The platform milestone: yafm grows a plugin runtime. Community plugins are
JavaScript run through JavaScriptCore (the Obsidian / Chrome model — drop a `.js`
file in the plugins folder and it works), sandboxed to a vetted host API. Plus a
native git-status column, find-within-folder search, and Share / AirDrop.

### Added — JS plugin runtime
- **JavaScriptCore plugin host** (`Core/Plugins.swift`, `JSPluginHost`). Each
  `*.js` in `~/Library/Application Support/yafm/plugins/` is evaluated in its own
  `JSContext` and may contribute table columns via `yafm.registerColumn({ id,
  title, value })`. Columns render in the file table after the native ones.
- **Sandbox by construction.** A plugin sees only a path-free, read-only snapshot
  of each entry — `{ name, ext, isDirectory, isHidden, size, modified, tags }` —
  never a `url`/absolute path. No filesystem, network, `Process`, `require`, or
  timers are exposed; the default JSC globals (`Math`/`JSON`/`Date`) are
  pure-compute. `JSPluginHost.snapshot(of:in:)` is the single place to widen the
  surface later. This is the boundary `PluginContext` was drafted for.
- **Robust loading.** A malformed or throwing plugin is recorded as a load error
  (surfaced in Settings ▸ Plugins) and skipped; a column function that throws at
  render degrades to an empty cell, never a crash.
- **Bundled example.** An editable `example-kind.js` (a "Type" column that
  classifies files by extension) is seeded into an empty plugins folder on first
  run, so the runtime has something to show and a template to copy.
- **Settings ▸ Plugins** — open the plugins folder, reload plugins, and see what
  loaded (with per-file errors).

### Added — git-status column (first-party native)
- **`GitStatusService`** (`Core/Git.swift`) shells out to `git status --porcelain`
  and maps each immediate child of the directory to a one-glyph marker — `M`
  modified · `A` added/staged · `?` untracked · `D` deleted · `•` a folder
  containing changes. Recomputed on each listing (never stale), empty outside a
  repo, and silently absent when `git` isn't installed. Rendered as a tinted
  "Git" column that appears only inside a work tree. Native by design: running
  `git` is exactly the capability the JS sandbox withholds, and VISION allows
  heavy first-party features to be native yet share the registry.

### Added — search
- **Find within folder (⌘F)** — `SearchService` (`Core/Search.swift`) queries
  Spotlight (`mdfind -onlyin`) and falls back to our own recursive,
  case-insensitive name-substring walk when Spotlight has nothing (unindexed
  disks, temp trees). Results stream into a virtual "Search: …" listing, like the
  tag cloud. Name-only by design for v0.3. Reachable from the Go menu, the pane
  background menu, and ⌘F.

### Added — Share / AirDrop
- **Share ▸** in the row context menu lists the system `NSSharingService`s
  (AirDrop, Mail, Messages, …) for the selection and performs the chosen one.

### Project
- **License: GPL-3.0 with a Plugin Exception** ([`LICENSE`](LICENSE)). yafm itself is copyleft (no
  closed-source forks); plugins using the published Plugin API may be proprietary/paid.
- GitHub repo polish: README badges + License section, CI workflow (`swift build` + `swift test`
  on macOS), issue templates (bug report / feature request), `icon.png` source untracked
  (shipped icon stays `App/Resources/AppIcon.icns`). VISION roadmap deduped to point at `ROADMAP.md`.
- New plugin API reference: [`docs/plugins.md`](docs/plugins.md).

## [0.2.3] — Settings & app shell

### Added
- **Settings window (⌘,)** backed by `UserDefaults` (`AppSettings` / `SettingsView`) with five
  tabs: General · Appearance · Operations · Tags · Updates. Settings change real behaviour.
- **"Right arrow opens files"** setting — default **off**: → enters folders only and ignores
  files (Enter always opens); opt in to also open files on →. Wired through
  `AppState.enterCursor` / `openCursor(allowFileOpen:)`.
- **"Show hidden files in new tabs"** — new tabs/panes inherit it (`TabModel`/`PaneModel` take a
  `showHidden` default).
- **Start folder** (General) — Home / Last used / a specific folder (with picker); new windows open
  there (`AppSettings.startDirectory`, last folder remembered on scene-phase change).
- **Operations tab** — confirm-before-delete (default **on**; delete is permanent, not Trash) and a
  default copy/move collision policy (keep both / skip / replace), plumbed through new
  `Core.CollisionPolicy` + `OperationTask.collision` + `FileEngine.plannedDestination`.
- **Tags tab** — rescan and clear the tag index (`TagService.clear`, `AppState.rescanTags` /
  `clearTags`).
- **Updates tab** — "Check for Updates" via the GitHub Releases API (`UpdateChecker`): honest
  status (checking / up to date / available → opens the release page / error), non-blocking. No
  auto-install (Sparkle deferred).
- **Theme Light / Dark / System** (Appearance) via `.preferredColorScheme`, persisted.
- **About yafm** — standard about panel (version from Info.plist), `CommandGroup(replacing: .appInfo)`.

### Fixed — v0.2.3
- Tag editor now closes when you click outside it: it was a modal `.sheet` (no outside-dismiss);
  reworked into a `.popover` anchored to the row.

### Fixed — v0.2.2 (post-0.2.1 UX bug report)
- **QuickLook follows the keyboard cursor.** With the Space preview open, arrowing through the
  list now swaps the previewed file in place (Finder behaviour) via `QuickLook.updateIfVisible`,
  driven from the cursor-change handler in `FileTableView`.
- **Mouse single-click no longer lags or drops.** The row had `onTapGesture(count: 2)` +
  `onTapGesture` together, so SwiftUI stalled every single tap ~0.3 s waiting to rule out a
  double-click (and dropped clicks under jitter). Single tap now selects instantly; double-click
  opens via an independent `simultaneousGesture(TapGesture(count: 2))`.
- **Table no longer janks while a folder loads.** The "Reading… (N)" indicator was stacked above
  the rows and shifted the whole table on every navigation; it's now a floating overlay badge.
  Implicit row animations are disabled (`transaction.disablesAnimations`) so streamed partial
  batches stop tearing the scroll.
- **External HDD eject now appears.** Many external disks report neither `isEjectable` nor
  `isRemovable`; `Volume.canEject` falls back to "not internal" (external or network), with the
  root volume always excluded.

### Added — v0.2.2
- **Custom tag editor** (`TagEditorSheet`) replaces the Finder-style nested checkbox submenu:
  large tappable color swatches, free-form tags as removable chips, an inline auto-focused "add
  tag" field, and a small `FlowLayout` for wrapping. Opened from the row context menu's "Tags…".
- **Sidebar context menus** across Favorites (Open / Open in New Tab / Remove), Locations and
  Devices (Open / New Tab / Add to Favorites / Reveal / **Eject** for removables), and Tags (Show
  Tagged Files). Plus "Add to Favorites" on folder rows and "Add Current Folder to Favorites" in
  the background menu (`AppState.addBookmark`/`removeBookmark`/`openInNewTab`).
- **Device Detection & Classification** spec parked in the backlog
  (`docs/feature-requests/device-detection.md`): async volume metadata (filesystem, capacity, free
  space, writable/read-only, vendor/model, transport via DiskArbitration + IOKit) and device-type
  classification with a confidence score. Metadata-only MVP; reused later by Photo Ingest.

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
