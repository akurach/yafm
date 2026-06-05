# yafm

[![CI](https://github.com/akurach/yafm/actions/workflows/ci.yml/badge.svg)](https://github.com/akurach/yafm/actions/workflows/ci.yml)
[![License: GPL-3.0 + plugin exception](https://img.shields.io/badge/license-GPL--3.0%20%2B%20plugin%20exception-blue.svg)](LICENSE)
![Platform: macOS 14+](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey.svg)
![Swift 6](https://img.shields.io/badge/swift-6-orange.svg)
[![Latest release](https://img.shields.io/github/v/release/akurach/yafm?include_prereleases&sort=semver)](https://github.com/akurach/yafm/releases)

**Yet Another File Manager for macOS.** A fast, keyboard-driven, modern alternative to Finder — that never freezes silently.

> Status: early development. v0.1 + v0.2 + v0.2.1 (daily-driver UX) + v0.2.2 (UX bugfixes) + v0.2.3 (Settings) + v0.3 (Platform: JS plugins, git column, search, Share) done. Native Swift / SwiftUI.

## Why

Finder is a rudiment of old releases: weak tags, garbage color coding, and it freezes silently on external disks (empty folder for minutes, no "loading" signal). yafm fixes that — everything async with an honest "reading…" state, real tags, dual-pane keyboard-first navigation.

See **[VISION.md](VISION.md)** for the full vision, locked decisions, and roadmap.

## Highlights (target)

- Dual pane + tabs, keyboard-first (Total Commander–style)
- Async listing — always shows what it's loading, never a dead empty folder
- Own file-operation engine with a visible queue, progress, and cancel
- Real macOS tags (native + fast index + proper UI) — sidebar tag cloud, click to filter
- Right-click context menus, TC-style function-key bar, sortable columns + info inspector
- Mounted drives / USB / network volumes in the sidebar (live, with eject)
- QuickLook, toggleable preview panel, hidden-files toggle
- Honest access onboarding — explains Full Disk Access instead of silently-empty folders
- Find within a folder (⌘F) — Spotlight with our own name-scan fallback
- Git-status column + Share / AirDrop from the row menu
- JavaScript plugins (JavaScriptCore) — drop a `.js` file, it just works. See [docs/plugins.md](docs/plugins.md)

## Distribution

Notarized DMG. No App Store, no sandbox.

## Development

Stack: Swift / SwiftUI, SwiftPM (no Xcode project). The app must run from a real `.app` bundle:

```
swift build                    # compile Core + yafm
swift test                     # Core unit tests
Scripts/make-app.sh            # wrap .build/debug/yafm into .build/debug/yafm.app
open .build/debug/yafm.app     # run
Scripts/make-dmg.sh            # release build → notarized .dmg (set CODESIGN_IDENTITY + AC_NOTARY_PROFILE)
```

See [ARCHITECTURE.md](ARCHITECTURE.md) for the module layout and [ROADMAP.md](ROADMAP.md) for status.
Parked feature specs (Photo Ingest, app shell) live in [docs/feature-requests/](docs/feature-requests/).

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
