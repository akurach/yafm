# yafm

**Yet Another File Manager for macOS.** A fast, keyboard-driven, modern alternative to Finder — that never freezes silently.

> Status: early development. v0.1 + v0.2 + v0.2.1 (daily-driver UX) + v0.2.2 (UX bugfixes) done. Native Swift / SwiftUI.

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
- JavaScript plugins (JavaScriptCore) — download a plugin, it just works *(planned, v0.3)*

## Distribution

Notarized DMG. No App Store, no sandbox.

## Development

Stack: Swift / SwiftUI, SwiftPM (no Xcode project). The app must run from a real `.app` bundle:

```
swift build                    # compile Core + yafm
swift test                     # Core unit tests
Scripts/make-app.sh            # wrap .build/debug/yafm into .build/debug/yafm.app
open .build/debug/yafm.app     # run
```

See [ARCHITECTURE.md](ARCHITECTURE.md) for the module layout and [ROADMAP.md](ROADMAP.md) for status.
Parked feature specs (Photo Ingest, app shell) live in [docs/feature-requests/](docs/feature-requests/).

## License

TBD
