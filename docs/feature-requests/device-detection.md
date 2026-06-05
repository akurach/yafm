# Spec: Device Detection & Classification for yafm

> Status: **someday** (backlog). Don't start without an explicit priority decision.
> This file is the source of truth for the feature; the roadmap links here.

## Goal

When an external volume is mounted, yafm should automatically collect metadata, classify the
device, and surface useful information in the sidebar — without blocking the UI.

Today's sidebar shows mounted volumes with name + capacity bar + eject (`Sidebar.VolumeRow`,
backed by `Core/Volumes.swift`). This feature replaces Finder's thin volume presentation: at a
glance the user should understand **what** was connected, **whether it's writable**, **what
filesystem** it uses, **how full** it is, and **what kind of device** it looks like (camera card,
SSD, USB stick, backup disk, …).

This is **metadata collection + classification only**. No import/backup/workflow actions in MVP —
those reuse this engine later (see Future integration).

## Non-goals (MVP)

- No workflow actions (import, backup verify, format, repair).
- No write/unlock of read-only volumes (NTFS RW, SD lock).
- No per-file deep scan beyond the cheap classification probes below.
- No persistence of device history across launches (nice-to-have, later).

## Data collection

All collection is async and off the main actor. Mount/unmount already observed in
`AppState.observeVolumes()` via `NSWorkspace.didMount/didUnmount` — hang collection off that.

| Source | Used for |
|--------|----------|
| **NSWorkspace** | mount / unmount notifications (already wired) |
| **URLResourceValues / FileManager** | total + available capacity, volume name, writable state |
| **DiskArbitration** (`DADisk`, `DADiskCopyDescription`) | filesystem type, removable flag, ejectable flag, BSD/mount info |
| **IOKit** (`IORegistry` walk from the BSD node) | vendor, model, serial (if available), transport type, device hierarchy |

Capacity / writable extend the keys already read in `VolumeService` (add
`.volumeIsReadOnlyKey`, `.volumeLocalizedFormatDescriptionKey`). Filesystem + removable/ejectable
from DiskArbitration are more reliable than the URL resource flags (the v0.2.1 external-HDD eject
bug came from URL flags under-reporting — DA gives the truth). Vendor/model/transport need an
IOKit registry walk from the disk's BSD name.

## Volume metadata model

```swift
struct VolumeInfo {
    let id: UUID
    let name: String
    let filesystem: String        // "APFS", "exFAT", "NTFS", "SMB", …
    let totalCapacity: Int64
    let availableCapacity: Int64
    let isWritable: Bool
    let isRemovable: Bool
    let isEjectable: Bool
    let vendor: String?
    let model: String?
    let transport: TransportType
    let mountPath: URL
}
```

```swift
enum TransportType {
    case usb
    case thunderbolt
    case sdReader
    case network
    case virtual
    case internalBus
    case unknown
}
```

`VolumeInfo` is a richer sibling of the existing `Core.Volume`. Keep `Volume` as the cheap,
synchronous snapshot the sidebar already renders; layer `VolumeInfo` + `VolumeClassification` on
top, filled in asynchronously after mount so the row appears instantly and enriches in place.

## Classification

Classification must not rely on a single signal. Combine: hardware metadata, filesystem,
transport, removable status, top-level folder structure, file-extension patterns.

```swift
struct VolumeClassification {
    let kind: ExternalVolumeKind
    let confidence: Double   // 0.0 ... 1.0
    let reasons: [String]
}

enum ExternalVolumeKind {
    case internalDisk
    case externalSSD
    case externalHDD
    case usbFlashDrive
    case sdCard
    case cameraCard
    case cardReader
    case networkVolume
    case backupDisk
    case virtualVolume
    case unknown
}
```

Example:

```
Camera Card — confidence 0.92
Reasons:
- DCIM folder found
- exFAT filesystem
- removable media
- 420 RAW files detected
```

### Camera card

Indicators (folders): `DCIM`, `PRIVATE`, `AVCHD`, `M4ROOT`, `XDROOT`.
Files: `ARW CR2 CR3 RAF DNG NEF ORF RW2 JPG HEIC MOV MP4 MXF`.
Hints: exFAT / FAT32, removable. (Shares the detector with the Photo Ingest spec — build once,
both features consume it.)

### Backup disk

Indicators: Time Machine structures (`Backups.backupdb`, APFS TM snapshots), backup archives,
snapshot folders, large backup repositories. Surface the backup system when known, e.g.
`Backup Disk — Time Machine`, `Backup Disk — Veeam Repository`.

### SSD vs HDD vs flash

From IOKit (`Device Characteristics` → "Medium Type" Solid State / Rotational), transport
(Thunderbolt/USB), and removable flag. Small removable USB with FAT/exFAT and no rotational
hint → `usbFlashDrive`.

## Read-only detection

Read-only state must be **highly visible** (lock glyph + label). Three states:

- **Writable**
- **Read-only** (NTFS mounted RO, locked SD card, permission-restricted, damaged FS)
- **Access Unknown** (couldn't determine)

## UI requirements

The sidebar device row shows: device icon · volume name · device type · filesystem · capacity ·
free space · writable/read-only · transport type. Examples:

```
📸 Camera Card     SONY_A7IV     exFAT   128 GB  · 24 GB free   · Writable   · USB 3.2
💾 External SSD    Samsung T7     APFS    2 TB    · 1.4 TB free  · Writable   · Thunderbolt
🔒 External Drive  Archive        NTFS            · Read-only    · USB
```

Compact by default (name + icon + free-space bar, as today); the rest expands inline or in a
hover/disclosure so the sidebar stays narrow. Reuses the existing `VolumeRow` layout.

### Icon system

Icon changes with classification: Internal Disk · SSD · HDD · USB Flash · SD Card · Camera Card ·
Backup Disk · Network Storage · Virtual Volume · Generic External Drive. **Below the confidence
threshold → Generic External Drive.**

## Architecture

- **`VolumeInfoCollector`** (Core) — given a mounted `URL`/BSD node, gathers `VolumeInfo` via
  URLResourceValues + DiskArbitration + IOKit. Fully async / off-actor.
- **`VolumeClassifier`** (Core, UI-free) — pure function `VolumeInfo + cheap probes →
  VolumeClassification`. Folder/file probes go through the `FileSystemProvider` (never reach past
  it to FileManager) so it also works for virtual FS later.
- **App layer** — extends `AppState.refreshVolumes()`: emit the cheap `Volume` immediately, then
  spawn a `Task` per new mount to fill `VolumeInfo`+classification and update the row in place.
  Cancel on unmount. IOKit/DA handles must be released (CoreFoundation Create rule).
- Keep Core UI-free: classification returns `ExternalVolumeKind`; the App maps kind → SF Symbol +
  label, same pattern as `Color.named` / the existing `VolumeRow.icon`.

## Future integration

The classifier is reused by: Photo Ingest Extension (camera-card detection — share the detector),
Backup Verification, Media Import Workflows, and the Plugin API. **No workflow actions in MVP** —
metadata collection + classification only.

## Acceptance criteria

1. Device appears in the sidebar **immediately** after mount (cheap snapshot), enriches in place.
2. UI never blocks during scanning/classification.
3. Filesystem, capacity, and free space are displayed.
4. Read-only state is visible (lock glyph + label); Writable / Read-only / Access Unknown.
5. Device-type icon changes automatically with classification.
6. Classification carries a confidence value (0.0–1.0) and human-readable reasons.
7. Below-threshold / unknown devices fall back gracefully to the generic external-drive icon.
8. All metadata updates asynchronously; unmount cancels in-flight work and removes the row.
