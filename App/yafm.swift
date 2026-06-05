import SwiftUI
import Core

@main
struct YafmApp: App {
    var body: some Scene {
        WindowGroup("yafm") {
            RootView()
                .frame(minWidth: 800, minHeight: 480)
        }
        .windowStyle(.titleBar)
    }
}

/// v0.1 scaffold: two panes side by side. Each pane lists a directory through
/// Core, rendering the honest loading state. Tabs / keyboard / file engine land next.
struct RootView: View {
    private let fs = LocalFileSystem()

    var body: some View {
        HSplitView {
            PaneView(model: PaneModel(fs: fs, directory: .homeDirectory))
            PaneView(model: PaneModel(fs: fs, directory: .homeDirectory))
        }
    }
}

@MainActor
@Observable
final class PaneModel {
    let fs: FileSystemProvider
    private(set) var directory: URL
    private(set) var state: ListingState = .idle
    private var task: Task<Void, Never>?

    init(fs: FileSystemProvider, directory: URL) {
        self.fs = fs
        self.directory = directory
    }

    func open(_ directory: URL) {
        self.directory = directory
        load()
    }

    func load() {
        task?.cancel()
        state = .loading(partial: [])
        let stream = fs.list(directory)
        task = Task { [weak self] in
            var partial: [FSEntry] = []
            for await event in stream {
                guard let self else { return }
                switch event {
                case .began:
                    break
                case .entries(let batch):
                    partial.append(contentsOf: batch)
                    self.state = .loading(partial: partial)
                case .finished:
                    partial.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                    self.state = .loaded(partial)
                case .failed(let message):
                    self.state = .failed(message)
                }
            }
        }
    }
}

struct PaneView: View {
    @State var model: PaneModel

    var body: some View {
        VStack(spacing: 0) {
            // Path bar (typed navigation comes later).
            Text(model.directory.path)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .background(.bar)

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { model.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle:
            Color.clear
        case .loading(let partial):
            VStack {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Reading… (\(partial.count))")
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 8)
                list(partial)
            }
        case .loaded(let entries):
            list(entries)
        case .failed(let message):
            ContentUnavailableView("Can't open folder", systemImage: "exclamationmark.triangle", description: Text(message))
        }
    }

    private func list(_ entries: [FSEntry]) -> some View {
        List(entries) { entry in
            Label(entry.name, systemImage: entry.isDirectory ? "folder" : "doc")
                .foregroundStyle(entry.isHidden ? .secondary : .primary)
        }
        .listStyle(.inset)
    }
}

private extension URL {
    static var homeDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }
}
