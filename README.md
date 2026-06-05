# yafm

**Yet Another File Manager for macOS.** A fast, keyboard-driven, modern alternative to Finder — that never freezes silently.

> Status: early development (v0.1 in progress). Native Swift / SwiftUI.

## Why

Finder is a rudiment of old releases: weak tags, garbage color coding, and it freezes silently on external disks (empty folder for minutes, no "loading" signal). yafm fixes that — everything async with an honest "reading…" state, real tags, dual-pane keyboard-first navigation.

See **[VISION.md](VISION.md)** for the full vision, locked decisions, and roadmap.

## Highlights (target)

- Dual pane + tabs, keyboard-first (Total Commander–style)
- Async listing — always shows what it's loading, never a dead empty folder
- Own file-operation engine with a visible queue, progress, and cancel
- Real macOS tags (native + fast index + proper UI)
- QuickLook, toggleable preview panel, hidden-files toggle
- JavaScript plugins (JavaScriptCore) — download a plugin, it just works

## Distribution

Notarized DMG. No App Store, no sandbox.

## Development

Stack: Swift / SwiftUI. Build instructions land once the Xcode project is scaffolded.

## License

TBD
