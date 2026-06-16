# Security

yafm ships as a **non-sandboxed**, notarized DMG with full disk access (sandbox was
deliberately rejected — it would break plugins, FTP/SMB, and full-disk access; see
`VISION.md`). There is no OS sandbox backstop, and v0.3 will run untrusted community
JavaScript plugins. Filesystem code is therefore held to a higher bar.

## Audit — 2026-06-05 (v0.1/v0.2 spine)

A security review + Swift-concurrency review were run by specialized agents against the
file engine, tag/xattr bridge, listing, keyboard monitor, and app state.

### Fixed

| Severity | Issue | Fix |
|----------|-------|-----|
| Critical | Recursive copy followed symlinks → arbitrary file read (copy-out-of-tree) | `Operations.swift`: copy symlinks as links via `copyItem`, never follow. Covered by `testCopyDoesNotFollowSymlinkOutOfTree`. |
| Critical | `../` in rename / bulk-rename → overwrite arbitrary path | `AppState.rename(entry:to:)`: reject names containing `/`, `.`, `..` |
| Critical | `cancelled` Set in `FileEngine` grew unbounded | `defer { cancelled.remove(id) }` in `execute` |
| High | Unbounded xattr read → memory exhaustion | `Tags.swift`: cap attribute at 128 KiB and ≤64 entries |
| High | Copy progress double-counted directory entry bytes (`fraction > 1`) | `totalBytes` sums file bytes only |
| High | Cancelled listing emitted `.finished` → shown as complete | `FileSystem.swift`: finish without `.finished` when cancelled |
| High | `NSWorkspace.open` ran scripts/executables with no prompt | `AppState.openFile`: confirm before opening loose code (`.sh/.command/.scpt/…`). Apps (`.app`) launch directly as of v0.9.5 — a deliberate double-click is normal and macOS Gatekeeper still gates untrusted/quarantined apps. |
| High | QuickLook `nonisolated(unsafe)` discarded Swift 6 isolation | `@MainActor` class + `assumeIsolated` callbacks |
| High | `fillTags` could overwrite the new directory's state after navigation | guard `directory == dir` across suspension points |
| Medium | Unsafe-pointer copy loop missing overshoot guard | bound `written <= read - offset` |
| Medium | Key monitor `assumeIsolated` unverified | `dispatchPrecondition(.onQueue(.main))` |
| Medium | Path bar accepted any string as a path | reject null bytes / non-absolute input |

### Deferred (tracked in `ROADMAP.md`)

- **TOCTOU on copy destination** — replace exists-check + truncating `OutputStream` with an
  `O_WRONLY|O_CREAT|O_EXCL` open. Current mitigation: unique-name planning + a pre-write
  existence guard (refuses to clobber, but not atomic).
- **Plugin capability boundary** — before any JS plugin API is exposed (v0.3), define a
  `PluginContext` that hands plugins only a vetted capability subset. Never pass `FileEngine`,
  `TagService`, or `LocalFileSystem` to plugin-facing code. Every path-traversal class above
  becomes plugin-reachable otherwise.

## macOS privacy gates (TCC)

yafm is non-sandboxed but still bound by TCC. Two gates surface in the UI:

- **Full Disk Access** — without it, protected folders (Desktop/Documents, other apps'
  data) read as empty. yafm shows the status and a one-click path to System Settings in
  **Settings ▸ General ▸ Full Disk Access** (and an onboarding banner), so it's always
  reachable, never silently required.
- **App Management** (macOS 13+) — writing extended attributes onto an app bundle (e.g.
  applying a Finder tag to a `.app`) counts as *modifying an app* and is blocked unless the
  user grants App Management. yafm does not request it; instead the **tag menu is hidden for
  packages** (v0.9.5) so the operation is never attempted and the user doesn't hit an opaque
  system denial.

## Reporting

Pre-release, single-developer project. File an issue (no public advisory process yet).
