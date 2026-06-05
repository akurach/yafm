# yafm — Architecture (v0.1 spine)

This describes the v0.1 skeleton. Everything here serves the two non-negotiables from `VISION.md`:
**never freeze silently** (everything async, always a visible loading state) and **native/fast/beautiful** (Swift Concurrency + SwiftUI, thin testable core).

## Layers

```
┌─────────────────────────────────────────────────────────┐
│  yafmApp        @main, window wiring, dependency setup    │
├─────────────────────────────────────────────────────────┤
│  UI (SwiftUI)   Panes · Tabs · PathBar · FileTable ·      │
│                 StatusBar · QuickLook · OperationQueue UI │
│   @MainActor, @Observable view models                     │
├─────────────────────────────────────────────────────────┤
│  Core (Swift package, no UI — unit-testable)              │
│   • FileSystemProvider (async, streaming, cancellable)    │
│   • Domain model: FSEntry, ListingState                   │
│   • FileEngine: copy/move/delete/rename + progress queue  │
│   • TagService: native xattr tags + index                 │
│   • ExtensionRegistry: columns/commands/context-menu      │
│   • CommandSystem: id → keybinding → handler              │
└─────────────────────────────────────────────────────────┘
```

**Rule:** Core never imports SwiftUI/AppKit UI. UI never touches the filesystem directly — only through Core. This keeps Core testable and lets virtual filesystems (FTP/SMB) drop in later behind the same protocol.

## Module layout

```
yafm/
├── yafm.xcodeproj              # app target (SwiftUI macOS app)
├── Core/                       # local Swift package
│   ├── Package.swift
│   └── Sources/Core/
│       ├── FileSystem/         # FileSystemProvider, LocalFileSystem, FSEntry, ListingState
│       ├── Operations/         # FileEngine, Operation, OperationQueue
│       ├── Tags/               # TagService, TagIndex, xattr bridge
│       ├── Extensions/         # ExtensionRegistry + provider protocols
│       └── Commands/           # Command, CommandRegistry, keybindings
│       └── Tests/CoreTests/
└── App/                        # SwiftUI app target sources
    ├── yafmApp.swift           # @main
    ├── State/                  # AppState, PaneModel, TabModel (@Observable, @MainActor)
    ├── Views/                  # Pane, TabBar, PathBar, FileTable, StatusBar, QueueView
    └── Integrations/           # QuickLook (QLPreviewPanel) bridge
```

Core as a real package (not just folders) enforces the no-UI boundary at compile time and makes it independently testable.

## Concurrency model

- **Swift Concurrency** throughout. No callbacks-as-API.
- `FileSystemProvider` and `FileEngine` are **actors** (or have actor-isolated internals) — filesystem work never runs on the main thread.
- View models are **`@MainActor @Observable`**. They `await` Core and publish state.
- Directory listing is a **stream**, not a single return — entries arrive incrementally so a slow/external disk shows a growing list + spinner instead of a dead empty folder.

## Core protocols (sketch)

```swift
// One entry. Value type, cheap to diff for SwiftUI.
struct FSEntry: Identifiable, Hashable, Sendable {
    let id: FileID            // stable identity (inode/URL) for selection across reloads
    let url: URL
    let name: String
    let isDirectory: Bool
    let isHidden: Bool
    let size: Int64?
    let modified: Date?
    var tags: [Tag]          // populated lazily by TagService
}

// The honest-loading contract. UI renders each case explicitly.
enum ListingState: Sendable {
    case idle
    case loading(partial: [FSEntry])   // <-- spinner + already-known entries
    case loaded([FSEntry])
    case failed(Error)
}

// Pluggable filesystem. Local now; FTP/SMB/cloud later behind the SAME protocol.
protocol FileSystemProvider: Sendable {
    func list(_ directory: URL) -> AsyncStream<ListingEvent>   // streamed + cancellable
    func metadata(of url: URL) async throws -> FSEntry
}

enum ListingEvent: Sendable {
    case began
    case entries([FSEntry])      // a batch — append to partial
    case finished
    case failed(Error)
}
```

### File operations

```swift
enum FileOperation: Sendable { case copy, move, delete, rename(to: String) }

struct OperationTask: Identifiable, Sendable {
    let id: UUID
    let kind: FileOperation
    let sources: [URL]
    let destination: URL?
    // progress is observed via the queue, not polled
}

actor FileEngine {
    func enqueue(_ task: OperationTask) -> AsyncStream<OperationProgress>
    func cancel(_ id: UUID)
}

struct OperationProgress: Sendable {
    let id: UUID
    let completedBytes: Int64
    let totalBytes: Int64
    let currentFile: URL?
    let state: State   // running / paused / done / failed / cancelled
}
```

Copy/move stream bytes in a loop (or `copyfile` with a callback) so progress is real, not faked. The queue is always visible in the UI.

### Tags

```swift
protocol TagService: Sendable {
    func tags(of url: URL) async -> [Tag]           // reads xattr com.apple.metadata:_kMDItemUserTags
    func setTags(_ tags: [Tag], on url: URL) async throws
    func allKnownTags() async -> [Tag]              // from the index
    func entries(taggedWith tag: Tag) async -> [URL]
}
```

Write-through to native xattr (Finder-compatible) + maintain an index (in-memory for v0.1, persisted later) so "show everything tagged X" is instant.

### Extension points (invisible in v0.1, but real)

First-party features register through these now; the JS loader plugs into the same registry in v0.3.

```swift
protocol ColumnProvider { var id: String { get }; func value(for entry: FSEntry) -> ColumnValue }
protocol CommandProvider { var commands: [Command] { get } }
protocol ContextMenuProvider { func items(for selection: [FSEntry]) -> [MenuItem] }

final class ExtensionRegistry {
    func register(column: ColumnProvider)
    func register(commands: CommandProvider)
    func register(contextMenu: ContextMenuProvider)
}
```

### Commands & keybindings

```swift
struct Command: Identifiable { let id: String; let title: String; let defaultKey: KeyBinding?; let run: () -> Void }
```

One registry drives both keybindings (TC-style: F5/F6/F8, Tab) and, later, the command palette (⌘K). Adding a feature = registering a command, not wiring keys ad hoc.

## Key data flow — "open a directory" (the differentiator)

1. User navigates. `TabModel` sets `state = .loading(partial: [])` **immediately** → UI shows spinner + path.
2. `TabModel` starts consuming `fileSystem.list(url)`.
3. Each `.entries(batch)` appends to the partial list → UI grows live. Slow external disk = visible progress, never a dead empty folder.
4. `.finished` → `state = .loaded(...)`. `.failed` → `state = .failed` with a real message.
5. Navigating away cancels the stream (structured concurrency / task cancellation).
6. Tags fill in lazily per visible row (don't block the listing on xattr reads).

This single flow is the whole thesis: **the app is honest about what it's doing.**

## What v0.1 deliberately omits

Preview panel, color-coding, bulk rename, bookmarks (v0.2); JS plugin loader, search, AirDrop (v0.3); virtual filesystems, marketplace, archives (later). The protocols above leave room for all of it without a rewrite.
