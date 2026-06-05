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

---

# Forward plan: v0.4 → v0.9

> Planned with an architecture + product review (2026-06-05). The headline thesis: with **zero users**,
> the wedge is the **keyboard-driven Mac power user (skewed developer)** who hates Finder's silent
> freezes. Win them with *speed + keyboard fluency + visual polish + honest states + content search*
> **first**; the **public plugin surface is frozen** (internal `ExtensionRegistry` keeps absorbing
> first-party features) and **re-opens in v0.8** once an audience exists. Three "cheap-insurance"
> seams (`FileSystemRouter`, async plugin-value path, UI tokens layer) land **early** — invisible
> plumbing that makes the hard hooks (VFS, marketplace, a11y) cheap instead of a rewrite.
>
> **Validation rule:** every milestone must produce one thing a stranger would screenshot/link
> unprompted (Show HN / r/macapps / Mastodon). If you can't name that artifact before building it,
> the milestone is plumbing — re-scope it.

## The dependency spine (seams before features)

| Seam | Lands | Consumed by | Cost if deferred |
|------|-------|-------------|------------------|
| **`FileSystemRouter`** (scheme→provider) | v0.4 | SMB VFS (v0.7), archive mount (v0.8) | Rewrite every `TabModel`/`AppState` call site under deadline (`State.swift:200`,`:251`) |
| **Async plugin-value path** | v0.5 | VFS-backed columns (v0.7), marketplace plugins (v0.8) | Breaking change to `PluginColumn.evaluate` (`Commands.swift:150`) after plugins ship in the wild |
| **UI tokens / theme layer** | v0.4 | all UX polish (v0.6), accessibility (v0.7) | Dynamic Type + polish retrofit touches every literal across a much larger `Views.swift` |

## v0.4 — "Fast as your editor" (command & navigation speed + foundations) ✅ shipped

- [x] **Command palette (⌘K)** — fuzzy over `DefaultCommands.all` + Favorites + current-folder
  subfolders; ↑↓/Enter/Esc. The keyboard-first pillar made visible. (`App/CommandPalette.swift`.)
- [x] **Inline type-to-filter** in the current folder (bare-letter typing; Esc clears, Backspace edits).
  (`TabModel.filter`, `App/Keyboard.swift`.)
- [x] **Real file-type icons** (cached NSWorkspace icons) replacing the single `doc` glyph;
  color-coding now tints the name. (`App/FileIcon.swift`.)
- [x] Keyboard tab-switching (⌃Tab / ⌃⇧Tab / ⌘1–9) + a ⌘/ shortcut cheat-sheet overlay. (`CheatSheet`.)
- [x] **Seam — `FileSystemRouter`**: provider-by-URL-scheme, local default; wired at `State.swift`.
  SMB/FTP (v0.7) + archives (v0.8) register a scheme with no call-site change. (+ routing tests.)
- [x] **Seam — UI tokens layer** (`App/Theme.swift`): spacing/fonts/colors/widths in one place;
  migrated `Views.swift`; cursor-ring vs selection-fill now distinct.
- [x] **i18n hygiene**: new UI strings wrapped in `String(localized:)`.
- **Plugin API: frozen** (as planned) — internal registry unchanged, nothing new author-facing.

## v0.5 — "Looks as good as it runs" (visual & interaction polish) ✅ shipped

- [x] **Density modes** (Compact / Cozy / Comfortable) — `Density` tokens drive row
  padding/font/icon; Settings ▸ Appearance ▸ Density. (`Settings.swift`, `Views.swift`.)
- [x] **Redesigned cursor/selection** — distinct leading accent bar (cursor) vs filled wash
  (selection), landed in v0.4's `Theme.Palette`; v0.5 scales it across the three densities.
- [x] **Full drag-and-drop** — inter-pane + drop-onto-folder + drag in/out of app; copy by
  default, **⌘** to move; accent-ring drop highlight. (`AppState.dropEntries`, `FolderDrop`.)
- [x] **Scoped animation** — global `disablesAnimations` kill-switch removed; selection/cursor/
  nav glide (token-timed), streaming inserts stay suppressed via `TabModel.isStreaming`. Motion
  toggle in Settings.
- [x] **Seam — async plugin-value path**: `PluginColumn.asyncEvaluate` + `PluginValueCache`
  (placeholder → resolve, deduped, invalidatable) before VFS forces it. (+4 Core tests, 45 total.)

## v0.6 — "Never a dead end" (honest states + search that doesn't freeze) ✅ shipped

The never-freeze pillar proves itself under load. v0.6 ships the three pillar
items; the two infra-gated items are deferred with a reason (below) rather than
half-built.

- [x] **Content search** (grep-in-files) — streaming, cancellable, bounded (8 MB/file cap,
  binary-skip), visible "Searching… N" state; results listing remembers its origin
  (`TabModel.virtualOrigin`). `SearchService.searchStream` yields hits as found. (+5 Core tests, 50 total.)
- [x] **Inline (non-modal) search bar** (`SearchBar`) docked under the path bar of the active
  pane, name/contents toggle — replaces the focus-stealing `SearchSheet` modal.
- [x] **Unified empty/error/loading state-view** over the `ListingState` cases: `.idle` and empty
  folders/results now render an explicit `ContentUnavailableView` (was a blank pane) —
  distinguishing "empty folder" from "no search matches". (`Views.swift`.)
- [ ] **Sparkle seamless auto-update** — **deferred**: gated on a paid Apple Developer ID cert +
  a hosted, EdDSA-signed appcast (same blocker as DMG notarization). The GitHub-Releases checker
  (v0.2.3) already covers the honest "a newer version exists" notice until then.
- [ ] **Device detection** (DiskArbitration + IOKit → device-type sidebar icons) — **deferred** to
  keep v0.6 on the never-freeze pillar; peripheral here, primarily feeds photo-ingest (v0.9).
  Spec: [`device-detection.md`](docs/feature-requests/device-detection.md).

## v0.7 — "Remote disks, finally native" (reach + accessibility) ✅ shipped

- [x] **SMB as a virtual filesystem** — `SMBFileSystem` behind the v0.4 router (`smb` scheme),
  mounting natively via **NetFS** (system handles the protocol + Keychain) and streaming through
  the local provider; entries re-keyed into `smb://` space, failed mount → `.failed` listing.
  Chose NetFS mount over a hand-rolled XPC SMB stack: the OS already owns the protocol + auth, so
  the trust boundary is the system mount, not our code. (+6 Core tests, 56 total.)
- [x] VFS connection UX — **Connect to Server (⌘⇧K)** `ConnectServerSheet`; reuses the v0.6
  unified state-view (a connecting/failed share is `.loading`/`.failed`, never a freeze).
- [x] **Accessibility** — VoiceOver reads each row as one sentence (name/kind/size/tags/git) with a
  selected trait; icon-only buttons labelled; Dynamic Type via the `Theme` type tokens.
- [x] **i18n / Russian** — `en.lproj` / `ru.lproj` + language picker (Settings ▸ General), writing
  `AppleLanguages` (effective next launch). `make-app.sh` bundles the `.lproj`; resolution verified.
- **Done on:** router (v0.4) + async providers (v0.5) — a synchronous SMB provider would freeze.
- **Note:** picked the native NetFS mount over an XPC SMB service — same never-freeze guarantee
  (mount is async + the listing streams), far less attack surface than a custom non-sandboxed XPC
  daemon. FTP/cloud providers follow the same provider+router pattern.

## v0.8 — "Make it yours" (extensibility re-opens — now there's an audience) ✅ shipped

- [x] **Public plugin surface re-opened** — JS `registerCommand` (pane menu) + `registerMenuItem`
  (row menu), each gated by a manifest capability grant. (`JSPluginHost`, `Views.swift`.)
- [x] **Plugin manifests** (sidecar `<plugin>.json`: `manifest:1`, reverse-DNS `id`, `version`,
  `apiVersion`, `capabilities`, `contributes`) + per-plugin enable/disable in Settings ▸ Plugins with
  a trust badge. Bare `.js` → compute-only fallback. (`PluginManifest`, `PluginRow`.)
- [x] **Scoped-FS capability** (`read:cwd`) — `yafm.readText(entry, "rel")` resolves host-side against
  the entry's folder via `PluginContext`, **opaque handle not path**, refuses `..`/symlink escape,
  `O_NOFOLLOW`, 256 KB cap. Enable-time consent in Settings. Ships the **git-branch** flagship plugin.
- [x] **Plugin trust tier** — manifest `trust` (Signed / Author / Unsigned) surfaced honestly before
  enable; `signature` field reserved so cryptographic signing slots in without a format change.
- [ ] **Plugin marketplace** (remote discovery/install/update) — **deferred**: needs hosted infra +
  a signing key/PKI (same blocker class as notarization). Built on the manifest `capabilities` already
  shown at enable-time; slots in without an API change.
- [x] **Archive mounting** — `.zip` as a read-only `FileSystemProvider` (`ArchiveFileSystem`, `archive://`)
  behind the router, same shape as SMB; streamed, never freezes. (+14 Core tests, 70 total.)

## v0.9 — "1.0 candidate" ✅ shipped

- [x] **Freeze `apiVersion 1.0`** — `PluginAPI.frozen`; 1.x compatibility promise (additive caps,
  deprecation window before removal), major bump refused by the loader.
- [x] **Transformers** extension point + **custom previewers** — the last VISION extension points;
  `Transformer` (lowercase/sequence/space-replace) + `Previewer`, seeded in the registry.
- [x] **OPS-1 atomic replace + TOCTOU `O_EXCL`** — `.replace` copies to a temp sibling and swaps with
  `replaceItemAt` (original survives any failure); output opened `O_CREAT|O_EXCL|O_NOFOLLOW`.
- [x] **Stability hardening** (from real-use bug reports) — the never-freeze pillar made true on big
  folders: streaming sort O(n²)→one sort (26× on 8k), in-memory tag batch (no per-row `getxattr`),
  per-table tag sheet (was a per-row `.popover`), per-row drag highlight, delete-confirm focus fix.
- [ ] **Photo Ingest** (optional first-party plugin) — **deferred**: depends on device detection
  (auto-prompt on camera plug-in), itself deferred since v0.6. Tracked in `docs/feature-requests/`.
- [ ] **Notarized DMG** (paid Apple Developer ID) — **deferred**: still gated on the cert.

## Open questions to revisit

- **SMB in v0.7 for a solo dev** — XPC + a network filesystem is the heaviest single item; may need its own point release or a narrower first cut (read-only browse before write).
- **i18n timing** — v0.7 assumes the string surface stabilized; if community demand (esp. RU) shows up earlier, pull it forward — it's cheap *if* the v0.4 hygiene held.
- **Validation cadence** — confirm the per-milestone public-channel post + 5-user screen-share loop actually happens; it's the only signal in a no-telemetry product.

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

**v0.4 shipped** (command palette ⌘K, type-to-filter, real file-type icons, keyboard tab-switching,
⌘/ cheat sheet, `FileSystemRouter` + UI tokens seams). The public plugin surface stays **frozen**
until v0.8 per the re-sequenced plan. Next is **v0.5 — "Looks as good as it runs"**:

- Density modes (Compact / Cozy / Comfortable) + drag-and-drop (inter-pane + in/out of app).
- Scoped animation (replace the global `disablesAnimations` kill-switch with per-mutation glide).
- **Seam — async plugin-value path**: make `PluginColumn.evaluate` (`Commands.swift`) async-capable
  before VFS (v0.7) forces it as a breaking change.
