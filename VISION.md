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

- **Distribution:** **DMG**, no App Store, no sandbox (sandbox would break plugins, FTP/SMB, full disk access — not worth it). *Notarized* DMG is the target once an Apple Developer ID cert is set up; until then releases ship an **unnotarized DMG** with "Open Anyway" instructions (notarization needs the $99/yr Apple Developer Program).
- **Tags:** read/write **native macOS tags** (xattr `com.apple.metadata`) so they stay compatible with Finder, plus our own **index** for speed and a proper **UI**.
- **File operations:** our **own engine** — visible queue, progress, cancel. Finder hides this; we show it.
- **Plugins:** community plugins are **JavaScript** via **JavaScriptCore** (ships with macOS, zero deps). Model is Obsidian/Chrome: download a file → it loads → it works. Toggle on/off, marketplace later. No rebuild. Plugins can only do what the host API exposes. Heavy first-party features (SMB, archive mounting) may be native/XPC but appear in the same plugin registry for a uniform UX.
- **Preview panel:** toggleable.
- **License:** **GPL-3.0 + a Plugin Exception** (see [`LICENSE`](LICENSE)). The app is copyleft —
  no closed-source forks — but plugins talking to the published Plugin API (JS via JavaScriptCore,
  native/XPC via the registry) are exempt and may be proprietary/paid. Picked to protect the core
  from closed commercial forks while letting a paid-plugin ecosystem grow.

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

The detailed, status-tracked roadmap lives in **[`ROADMAP.md`](ROADMAP.md)** (kept current as
features land); parked feature specs are in [`docs/feature-requests/`](docs/feature-requests/).
The arc in brief:

- **v0.1 — Spine.** Dual pane + tabs, async listing with a visible "reading…" state, TC-style
  keyboard nav, own file engine (queue/progress/cancel), QuickLook, tags (native + index + UI).
  Async FS layer and internal extension points (columns/commands/context-menu) present but invisible.
- **v0.2 — Differentiators.** Preview panel, color coding, bulk rename, bookmarks.
- **v0.2.1–v0.2.3 — Daily-driver UX & shell.** Context menus, sidebar volumes/devices, function-key
  bar, columns + info inspector, tag cloud, access onboarding; UX bugfixes; Settings window (⌘,)
  with theme, start folder, operations, tags, and a GitHub-releases update check.
- **v0.3 — Platform. ✅ shipped.** JS plugin runtime (JavaScriptCore) — sandboxed column
  plugins via `yafm.registerColumn`, an editable example seeded on first run; native git-status
  column in the same registry; find-within-folder search (mdfind/Spotlight + own fallback);
  AirDrop/Share. Plugin API: [`docs/plugins.md`](docs/plugins.md).
- **v0.4 → v0.9 — ✅ shipped** (arc set in the 2026-06-05 review). Wedge = the keyboard-driven Mac
  power user who hates Finder's silent freezes; won with speed + polish + honest states + content
  search **first**, public plugin surface kept **frozen until v0.8** (no users yet = no ecosystem to
  widen for). Arc as delivered: v0.4 command palette (⌘K) + nav speed + seams (`FileSystemRouter`,
  UI tokens) · v0.5 visual polish + drag-and-drop · v0.6 content search + honest empty/error states
  + update check · v0.7 SMB virtual filesystem (XPC) + accessibility + **Russian i18n** · v0.8
  public plugins re-open (scoped-FS capability, manifests, archive mounting) · v0.9 API freeze
  (`apiVersion 1.0`) + 1.0 candidate, then point releases v0.9.1–0.9.4 (audit pass · plugin-API
  extensions · column resize + sidebar config · **float-layout visual redesign**). Currently
  **v0.9.4**; before 1.0: notarized DMG (paid cert) + polish. Photo-ingest + marketplace deferred
  post-1.0. Full status-tracked breakdown in [`ROADMAP.md`](ROADMAP.md).
