# yafm

[![CI](https://github.com/akurach/yafm/actions/workflows/ci.yml/badge.svg)](https://github.com/akurach/yafm/actions/workflows/ci.yml)
[![License: GPL-3.0 + plugin exception](https://img.shields.io/badge/license-GPL--3.0%20%2B%20plugin%20exception-blue.svg)](LICENSE)
![Platform: macOS 14+](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey.svg)
![Swift 6](https://img.shields.io/badge/swift-6-orange.svg)
[![Latest release](https://img.shields.io/github/v/release/akurach/yafm?include_prereleases&sort=semver)](https://github.com/akurach/yafm/releases)

**Yet Another File Manager for macOS.** A fast, keyboard-driven, modern alternative to Finder — that never freezes silently.

> Status: **v0.9.1 — 1.0 candidate.** Native Swift / SwiftUI. The spine (v0.1–0.3:
> dual-pane + tabs, async listing, own file engine, tags, JS plugins, git, search) is
> done; v0.4–0.9 added the keyboard-first speed layer, visual polish, content search,
> SMB, the plugin capability model, archives, accessibility, and a Russian UI — then a
> five-dimension audit pass (perf · security · UX · design). See [ROADMAP.md](ROADMAP.md)
> and [CHANGELOG.md](CHANGELOG.md). **New here? Read the [User Guide](docs/USER_GUIDE.md)
> ([RU](docs/USER_GUIDE.ru.md)).**

## Why

Finder is a rudiment of old releases: weak tags, garbage color coding, and it freezes silently on external disks (empty folder for minutes, no "loading" signal). yafm fixes that — everything async with an honest "reading…" state, real tags, dual-pane keyboard-first navigation.

See **[VISION.md](VISION.md)** for the full vision, locked decisions, and roadmap.

## Highlights

**Core**
- Dual pane + tabs, keyboard-first (Total Commander–style) — F-key bar, arrows, multi-select (⇧/Insert/⌘-click), Home/End/PageUp-Down
- Async listing — always shows what it's loading, never a dead empty folder; honest empty/error/limited states
- Own file-operation engine with a visible queue, progress, cancel — **atomic replace** (no data loss on a failed copy)
- **Move to Trash** (F8) or permanent delete (⇧F8); real macOS tags + fast index + sidebar tag cloud
- Right-click menus, sortable columns + info inspector, live volumes/USB/network in the sidebar (with eject), QuickLook + preview panel

**Speed & polish (v0.4–0.5)**
- **⌘K command palette** (fuzzy jump to commands / favorites / subfolders), type-to-filter, real file-type icons
- **Density modes**, full drag-and-drop (⌘ to move), scoped animation, keyboard tab-switching (⌃Tab / ⌘1–9), ⌘/ cheat sheet

**Reach (v0.6–0.7)**
- **Content search** (grep-in-files) — streaming, cancellable, bounded; inline find bar (⌘F, name or contents)
- **SMB shares** mount natively behind a filesystem router (⌘⇧K) — a slow share loads, never freezes
- **VoiceOver + Dynamic Type**; **Russian UI** + language picker

**Extensibility (v0.8–0.9)**
- **JavaScript plugins** with a capability model — manifests, per-plugin enable/disable, scoped file reads (`read:cwd`), commands & menu items. See [docs/plugins.md](docs/plugins.md)
- **Browse `.zip` archives** read-only like any folder; bulk-rename transformers + custom previewers; plugin API frozen at 1.0

## Distribution

DMG, no App Store, no sandbox. A *notarized* DMG is the goal once an Apple Developer ID is in place; for now releases ship an **unnotarized DMG**.

### Installing an unnotarized DMG

Until the app is notarized (needs a paid Apple Developer account), Gatekeeper will warn on first launch. Open it once with any of:

- **Right-click** `yafm.app` → **Open** → **Open**, or
- System Settings → **Privacy & Security** → scroll down → **Open Anyway**, or
- Terminal: `xattr -dr com.apple.quarantine /Applications/yafm.app`

After the first launch it opens normally. Or just build from source (below) — locally built apps aren't quarantined.

## Development

Stack: Swift / SwiftUI, SwiftPM (no Xcode project). The app must run from a real `.app` bundle:

```
swift build                    # compile Core + yafm
swift test                     # Core unit tests
Scripts/make-app.sh            # wrap .build/debug/yafm into .build/debug/yafm.app
open .build/debug/yafm.app     # run
Scripts/make-dmg.sh            # release build → .dmg (unnotarized; set CODESIGN_IDENTITY + AC_NOTARY_PROFILE to notarize)
```

See [ARCHITECTURE.md](ARCHITECTURE.md) for the module layout and [ROADMAP.md](ROADMAP.md) for status.
Triaged feature specs (all closed — shipped or deferred post-1.0) live in [docs/feature-requests/](docs/feature-requests/).

## License

**GNU GPL v3.0 with a Plugin Exception** — see [LICENSE](LICENSE).

What this means in practice:

- yafm itself is copyleft: any fork or modified version of the app **must also be open source
  under the GPL**. You can't take this code and ship a closed-source / proprietary fork.
- **Plugins are exempt.** Anything that talks to yafm only through its published Plugin API
  (JavaScript plugins via JavaScriptCore, or native/XPC extensions through the extension registry)
  is **not** a derivative work and may be licensed however you like — including **proprietary and
  paid** plugins.

Contributions are accepted under the same license.
