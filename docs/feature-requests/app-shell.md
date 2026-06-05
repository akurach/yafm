# Spec: App shell — Settings · About · Auto-update · Theme

> Status: ✅ **SHIPPED in v0.2.3** (closed 2026-06-05). Settings window (⌘,) with
> General/Appearance/Operations/Tags/Plugins/Updates tabs, About panel, theme
> (Light/Dark/System), start folder, collision policy, confirm-delete, and the
> GitHub-Releases update check all landed. Sparkle seamless auto-install remains
> deferred (needs a paid Developer ID + a signed appcast). Kept here as the
> historical source of truth.

## Goal

Bring yafm up to the standard of a real desktop app: settings, an About window, an update
mechanism, and theme switching. None of this exists today — there's only the main window.

## 1. Settings

Standard macOS settings window (`Settings { ... }` scene, ⌘,), organized into tabs.

Minimum tab set:

- **General**
  - start folder (Home / last used / specified)
  - show hidden files by default (currently lives only in `TabModel.showHidden`)
  - double-click behavior (open / select)
- **Appearance**
  - theme: Light / Dark / System (see §3)
  - row density, table font size (optional)
- **Operations**
  - confirm before delete
  - default name-collision behavior (skip / keep both / replace) — reuse the future ingest
    duplicate-handling logic
- **Tags**
  - manage the tag index: rescan, clear, path to the persisted index
    (`TagService` already does `persist()` / `loadPersisted()` / `index(roots:)`)
- **Updates**
  - update channel, "check automatically", "check now" (see §2)

Principle: settings actually change behavior, not decorative toggles. Store in `UserDefaults`
(same as the existing `didOnboard` flag).

## 2. About

About window: app icon (`AppIcon`), name, version (`CFBundleShortVersionString` +
`CFBundleVersion`), short description, link to the repo/site, license.

Wire into the standard app menu via `CommandGroup(replacing: .appInfo)`.

## 3. Auto-update

**Open question: how to do this properly.** Options, simplest to most involved:

1. **Sparkle** (the de-facto standard for non-App-Store macOS apps) — appcast XML + signed
   DMG/ZIP, EdDSA signatures. Downside: external dependency, must host the appcast and artifacts.
2. **Hand-rolled check**: hit the GitHub Releases API, compare versions, and on a newer release
   open the release page / download the DMG. Simpler, no auto-install.
3. Nothing yet, just "check for updates" → open the releases page.

For an MVP, probably option 2 (check + redirect to release); Sparkle later if seamless
auto-install is needed. Decide before implementing.

Requirements regardless of option:
- yafm ships as a **notarized DMG, no App Store / no sandbox** (see VISION) — the updater must
  account for this (a sandbox would break Sparkle's mechanism).
- The update check must not block the UI and must not fail silently — honest status:
  "checking / update available / up to date / error".

## 4. Theme (light / dark / system)

- Switch in Settings → Appearance: Light / Dark / System.
- System (default) follows the system theme.
- Implementation: `.preferredColorScheme(...)` on the root scene, value from `UserDefaults`,
  `nil` for System.
- Verify custom colors (`Color.named`, pane accents, `.bar` backgrounds) read correctly in
  both themes.

## Not now

- A full theming engine / user-defined palettes.
- iCloud settings sync.
- Telemetry.

## Acceptance criteria

1. ⌘, opens a settings window with working General / Appearance / Updates tabs (minimum).
2. Changing "show hidden files" in settings affects new tabs.
3. About shows the correct version and icon.
4. Theme switches between Light / Dark / System and persists across launches.
5. "Check for updates" runs with honest status, without blocking the UI.
