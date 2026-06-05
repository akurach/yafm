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
                }
            }

            Section("Locations") {
                Label("Computer", systemImage: "desktopcomputer")
                    .contentShape(Rectangle())
                    .onTapGesture { app.activeTab.open(URL(fileURLWithPath: "/")) }
                Label("Home", systemImage: "house")
                    .contentShape(Rectangle())
                    .onTapGesture { app.activeTab.open(FileManager.default.homeDirectoryForCurrentUser) }
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
