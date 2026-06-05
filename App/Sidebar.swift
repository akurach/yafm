import SwiftUI
import AppKit
import Core

// MARK: - Sidebar: Favorites · Locations · Devices · Network (v0.2.1 §2)

struct BookmarksSidebar: View {
    @Bindable var app: AppState

    private var devices: [Volume] { app.volumes.filter { !$0.isNetwork } }
    private var networkVolumes: [Volume] { app.volumes.filter { $0.isNetwork } }

    var body: some View {
        List {
            Section("Favorites") {
                ForEach(app.bookmarks) { bm in
                    Label(bm.name, systemImage: "folder")
                        .contentShape(Rectangle())
                        .onTapGesture { app.activeTab.open(bm.url) }
                        .contextMenu {
                            Button("Open") { app.activeTab.open(bm.url) }
                            Button("Open in New Tab") { app.openInNewTab(bm.url) }
                            Divider()
                            Button(role: .destructive) { app.removeBookmark(bm) } label: {
                                Label("Remove from Favorites", systemImage: "minus.circle")
                            }
                        }
                }
            }

            Section("Locations") {
                locationRow("Computer", "desktopcomputer", URL(fileURLWithPath: "/"))
                locationRow("Home", "house", FileManager.default.homeDirectoryForCurrentUser)
            }

            if !devices.isEmpty {
                Section("Devices") {
                    ForEach(devices) { vol in VolumeRow(app: app, volume: vol) }
                }
            }

            if !networkVolumes.isEmpty {
                Section("Network") {
                    ForEach(networkVolumes) { vol in VolumeRow(app: app, volume: vol) }
                }
            }

            if !app.knownTags.isEmpty {
                Section("Tags") {
                    ForEach(app.knownTags, id: \.name) { tag in
                        TagCloudRow(app: app, tag: tag, count: app.tagCounts[tag.name] ?? 0)
                    }
                }
            }
        }
        .frame(minWidth: 170, maxWidth: 220)
    }

    /// A Locations entry with open / new-tab / add-favorite context menu.
    private func locationRow(_ title: String, _ icon: String, _ url: URL) -> some View {
        Label(title, systemImage: icon)
            .contentShape(Rectangle())
            .onTapGesture { app.activeTab.open(url) }
            .contextMenu {
                Button("Open") { app.activeTab.open(url) }
                Button("Open in New Tab") { app.openInNewTab(url) }
                Divider()
                Button { app.addBookmark(url) } label: {
                    Label("Add to Favorites", systemImage: "star")
                }
            }
    }
}

/// One tag in the sidebar cloud: color dot · name · file count. Click filters.
struct TagCloudRow: View {
    let app: AppState
    let tag: Tag
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Color.named(tag.colorName) ?? .secondary)
                .frame(width: 9, height: 9)
            Text(tag.name).lineLimit(1)
            Spacer()
            Text("\(count)").font(.caption2).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { app.openTag(tag) }
        .contextMenu {
            Button("Show Tagged Files") { app.openTag(tag) }
        }
    }
}

/// One mounted volume: name, capacity bar, eject button for removables.
struct VolumeRow: View {
    let app: AppState
    let volume: Volume

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            VStack(alignment: .leading, spacing: 2) {
                Text(volume.name).lineLimit(1)
                if let frac = volume.usedFraction {
                    ProgressView(value: frac)
                        .controlSize(.mini)
                    if let total = volume.totalCapacity, let avail = volume.availableCapacity {
                        Text("\(byte(total - avail)) of \(byte(total))")
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            if volume.canEject {
                Button { app.eject(volume) } label: { Image(systemName: "eject.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { app.activeTab.open(volume.url) }
        .contextMenu {
            Button("Open") { app.activeTab.open(volume.url) }
            Button("Open in New Tab") { app.openInNewTab(volume.url) }
            Divider()
            Button { app.addBookmark(volume.url) } label: {
                Label("Add to Favorites", systemImage: "star")
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([volume.url])
            }
            if volume.canEject {
                Divider()
                Button { app.eject(volume) } label: {
                    Label("Eject", systemImage: "eject")
                }
            }
        }
    }

    private var icon: String {
        if volume.isNetwork { return "network" }
        if volume.canEject { return "externaldrive" }
        return "internaldrive"
    }

    private func byte(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}
