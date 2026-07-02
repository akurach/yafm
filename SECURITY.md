# Security

yafm ships as a **non-sandboxed** DMG with full disk access (sandbox was deliberately
rejected — it would break plugins, FTP/SMB, and full-disk access; see `VISION.md`).
Notarization is the target but pending a paid Apple Developer ID — current releases ship
**unnotarized** with "Open Anyway" steps. There is no OS sandbox backstop, and yafm runs
untrusted community **JavaScript** plugins, so filesystem code and the plugin host are held
to a higher bar (see *Plugin sandbox* below).

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

### Fixed since (v0.9)

- ✅ **TOCTOU on copy destination** — *done* (v0.9). The copy engine opens the output with
  `O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW`, so the kernel refuses if anything already exists at the
  path (closing the check-then-open window) and won't follow a planted symlink; overwrites route
  through a temp sibling + atomic `replaceItemAt`. See `Operations.swift` `copy(_:to:…)`.

### Deferred (tracked in `ROADMAP.md`)

- ✅ **Plugin capability boundary** — *done* (v0.3 → frozen `apiVersion 1.0`). Plugins get a
  vetted capability subset via `PluginContext`; `FileEngine`/`TagService`/`LocalFileSystem` are
  never handed to plugin-facing code. See *Plugin sandbox* below.

## Plugin sandbox (capability model + execution limit)

Community plugins are JavaScript run through JavaScriptCore. The boundary (`JSPluginHost`,
`Core/Plugins.swift`):

- **Per-plugin isolation** — each plugin file gets its own `JSContext` (own globals); no
  `require`, no network, no `Process`, no timers. The host injects only a `yafm` object.
- **Path-free snapshot** — a column/menu function receives a vetted entry snapshot
  (name/ext/size/tags…), never a raw path. `snapshot(of:in:)` is the single widening point.
- **Capability gating** — bridges are injected only when the sidecar manifest grants them:
  `read:cwd` / `read:exif` (scoped reads) and `contribute:action` (open-in-app, clipboard).
  Consent-requiring capabilities prompt at enable time, in Settings — never from the plugin.
- **Scoped reads** — `yafm.readText` resolves `rel` host-side against the entry's directory via
  `PluginContext.resolve` (refusing `..`/symlink escape), opens with `O_NOFOLLOW`, and caps the
  read (256 KB) with a per-context call budget (500).
- **Per-context handles** — opaque, scoped to the issuing context, so one plugin can't forge or
  enumerate another's handles.
- **Execution time limit (runaway/DoS guard)** — a plugin column/command runs synchronously, so
  an infinite loop (`while(true){}`) would freeze the UI and break the "never freezes" guarantee.
  Each context's VM is capped via `JSContextGroupSetExecutionTimeLimit`; past the cap the call is
  aborted and renders an empty cell. (The symbol is bound with `@_silgen_name`; acceptable as
  yafm is not sandboxed/App-Store-bound.)

Trust is honest: manifests declare an author but are **unsigned** — no fake "verified" badge.
Cryptographic plugin signing is deferred to the marketplace work.

## Hardened-runtime entitlements (notarized build)

The notarized build needs `com.apple.security.cs.allow-jit` (+ `allow-unsigned-executable-memory`)
because it embeds JavaScriptCore — without them JSC's JIT is killed under the hardened runtime and
the app crashes on first plugin run. These live in `App/Resources/yafm.entitlements` and are passed
to `codesign` in `Scripts/make-dmg.sh`. **No** App Sandbox entitlements (by design); Full Disk
Access is a runtime TCC grant, not an entitlement.

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

## Archive extract/compress (exec + path surface, v0.9.8)

**Extract Here** / **Compress** wrap the system binaries `bsdtar` (libarchive), `zip`, `unzip`,
`gzip`, `bzip2`, plus a **bundled 7-Zip CLI** (`7zz`, at `App/Resources/bin/7zz`) used for
`.7z` creation and RAR/7z extraction (`Core/ArchiveService.swift`). Notes on the surface:

- **Bundled binary.** `7zz` is invoked as a **separate process** (exec, not linked), located via
  `Bundle.main`; yafm isn't a derivative work of it (mere aggregation). It is the official 7-Zip
  build; its license sits beside it (`7zz-License.txt`). For the **notarized** build it must be
  codesigned with the same identity (the hardened runtime refuses an unsigned nested helper) —
  tracked in `ROADMAP.md`, gated on the paid cert. If `7zz` is absent, 7z-create and rar5 simply
  aren't offered; everything else still works on the stock tools.

- **No shell.** `Process` runs with an explicit executable path and an **argument array** — there
  is no `/bin/sh -c`, so archive names / paths / passwords are never interpreted by a shell (no
  command injection from a crafted filename or password).
- **No interactive hang.** Child `stdin` is wired to `/dev/null`, and `bsdtar` is *always* handed
  a `--passphrase` (the user's, or a non-guessable probe sentinel). Without this, libarchive
  spins forever re-prompting `Enter passphrase:` on an encrypted archive. The probe is ignored on
  unencrypted archives and rejected on encrypted ones, which we surface as "password required".
- **Passwords** are passed as process arguments, held only in memory for the call, never logged.
  ZIP creation uses the system `zip`'s legacy PKZip 2.0 cipher (weak) — the Compress dialog says
  so; stronger formats aren't available from the stock tools.
- **Extraction is contained.** Every archive unpacks into a freshly-created, collision-suffixed
  sibling folder, never into the current directory, so a malicious archive can't silently
  overwrite neighbours. Path-traversal (`../`, absolute paths) is left to libarchive's own
  protections; a second explicit traversal check is a tracked hardening follow-up.
- **No new privileges.** These run as the user, gated by the same TCC/Full-Disk-Access rules as
  any other file op. Read covers the broad libarchive format set; *creation* is limited to ZIP
  and the TAR family (no bundled `.7z`/`.rar` writer).

## Reporting

Pre-release, single-developer project. File an issue (no public advisory process yet).
