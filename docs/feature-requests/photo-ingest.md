# Spec: Photo Ingest Extension for yafm

> Status: **someday** (backlog). Don't start without an explicit priority decision.
> This file is the source of truth for the feature; the roadmap links here.

## Goal

Add an import mode for photos/videos from camera cards: SD, microSD, CFexpress, USB drives.

Core value: safely copy material off the card, verify integrity, lay it out into a sane
structure, and never let the user accidentally lose originals.

## Scenario

When the user connects an external volume, yafm should:

1. Detect that it's potentially a camera card.
2. Find folders like DCIM, PRIVATE, MISC, MP_ROOT, AVCHD, XDROOT.
3. Show an unobtrusive prompt:

   Detected camera media
   - Copy photos/videos
   - Open in yafm
   - Ignore this device

## MVP features

### 1. Card detection

Listen for external volume mounts via macOS APIs.

A volume counts as a camera card if:
- it has a DCIM folder, **or**
- it has camera video structures: PRIVATE, AVCHD, XDROOT, **or**
- many files of these formats are found: RAW, ARW, CR3, CR2, RAF, NEF, DNG, ORF, RW2, JPG, HEIC, MOV, MP4, MXF.

### 2. Import wizard

Choosing "Copy photos/videos" opens the import wizard.

Fields:
- Destination folder
- Project/Shoot name
- Date source:
  - today
  - file creation date
  - EXIF date if available
- Folder template:
  - `YYYY-MM-DD Shoot Name`
  - `YYYY/YYYY-MM-DD Shoot Name`
  - custom template later
- File handling:
  - copy only
  - copy + verify
  - copy + verify + eject

Deleting from the card is **not** in the MVP — too risky to ship early.

### 3. Preview before import

Before copying, show:
- file count
- total size
- breakdown: RAW / JPEG / Video / Other
- the planned destination folder
- a warning if there isn't enough free disk space

### 4. Copy engine

Use yafm's own file-operation engine.

Requirements:
- operation queue
- per-file progress
- overall progress
- copy speed
- ETA
- cancel
- pause/resume desirable, but can come after MVP

### 5. Verification

For copy + verify mode, after copying compare:
- file size
- checksum, e.g. SHA-256 or xxHash

Result per file:
- imported
- verified
- failed
- skipped
- duplicate

If verify fails — don't hide the error; show a proper report.

### 6. Duplicate handling

If a file already exists:
- Skip
- Keep both
- Replace
- Compare size/checksum and skip if identical

Default: skip identical, keep both if different.

### 7. Import report

After import, show a report:
- copied files count
- failed files count
- skipped duplicates
- destination path
- verification status

Save an `import-report.json` next to the import containing:
- source volume name
- source volume UUID if available
- started_at
- completed_at
- files list, each with: original path, destination path, size, checksum (if calculated), status

### 8. Safe eject

After a successful, verified import, offer:
- Eject card
- Open destination
- Close

No auto-formatting of the card.

## Not in the MVP

- Lightroom/Capture One integration
- AI culling
- face detection
- auto-delete from card
- cloud backup
- complex metadata editor
- DAM/catalog system

All later. For now: a fast, reliable ingest.

## UI principle

Don't build a kitchen sink. The window stays simple:

1. Source card
2. Destination
3. Naming/folder template
4. Safety options
5. Start Import

Key rule: the user must always understand what's happening right now — reading, copying,
verifying, completed, failed.

## Naming

In the UI: **Photo Ingest**
In code: **PhotoIngestExtension**

## Architecture

Core entities:
- ExternalVolumeMonitor
- CameraMediaDetector
- PhotoIngestWizardView
- IngestPlan
- IngestJob
- IngestFile
- ChecksumVerifier
- ImportReportWriter

`IngestPlan` is built before copying and holds the full list of files and target paths.
`IngestJob` runs through yafm's shared operation queue.

## Acceptance criteria

The feature is done when:

1. Connecting an SD card with DCIM makes yafm offer import.
2. The user can pick a destination folder and a shoot name.
3. yafm shows file count and total size before starting.
4. Files copy with visible progress.
5. In verify mode, yafm verifies files after copying.
6. Copy errors are never lost — they show up in the report.
7. An `import-report.json` is written on completion.
8. The user can open the import folder or eject the card.

## Implementation notes (from a codebase review)

- `ExternalVolumeMonitor` maps onto the existing `VolumeService` + the
  `NSWorkspace.didMount/didUnmount` observers already in `AppState.observeVolumes()`.
- `IngestJob` must go through the existing `FileEngine` (`Core/Operations.swift`) — it already
  has streamed progress and a working cancel (after the B-2 fix). Speed/ETA can be derived from
  the `OperationProgress` stream (completedBytes + elapsed time).
- Put `ChecksumVerifier` in Core (CryptoKit SHA-256) and hash **in the background**
  (`Task.detached`), off the actor — same pattern as `TagService.index` moving xattr reads off-actor.
- `PhotoIngestExtension` registers through `ExtensionRegistry` as the first "heavy" native feature
  in the plugin registry (see VISION: SMB/archives live there too).
