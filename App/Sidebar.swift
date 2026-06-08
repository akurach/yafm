import SwiftUI
import AppKit
import Core

// MARK: - Sidebar: Favorites · Locations · Devices · Network (v0.2.1 §2)

struct BookmarksSidebar: View {
    @Bindable var app: AppState

    private var devices: [Volume] { app.volumes.filter { !$0.isNetwork } }
    private var networkVolumes: [Volume] { app.volumes.filter { $0.isNetwork } }

    // Cached once at load — these paths are stable for the app lifetime (S-8).
    private static let favURLs: [SystemFavorite: URL?] = {
        let fm = FileManager.default
        func dir(_ d: FileManager.SearchPathDirectory) -> URL? { fm.urls(for: d, in: .userDomainMask).first }
        return [
            .desktop:      dir(.desktopDirectory),
            .documents:    dir(.documentDirectory),
            .downloads:    dir(.downloadsDirectory),
            .movies:       dir(.moviesDirectory),
            .music:        dir(.musicDirectory),
            .pictures:     dir(.picturesDirectory),
            .applications: URL(fileURLWithPath: "/Applications"),
        ]
    }()

    // Computed dynamically so iCloud enable/disable after launch is reflected (S-5).
    private var iCloudDriveURL: URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    @ViewBuilder
    private func sysFav(_ label: String, _ icon: String, _ url: URL?) -> some View {
        if let url { locationRow(label, icon, url) }
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {

                if app.settings.sidebarShowFavorites {
                    SidebarSectionHeader("Favorites").padding(.horizontal, 10)
                    ForEach(SystemFavorite.allCases) { fav in
                        if app.settings.enabledFavorites.contains(fav) {
                            sysFav(fav.label, fav.systemImage, Self.favURLs[fav] ?? nil)
                        }
                    }
                    ForEach(app.bookmarks) { bm in
                        SidebarRow(icon: "folder", label: bm.name, isActive: app.activeTab.directory == bm.url)
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

                if app.settings.sidebarShowLocations {
                    SidebarSectionHeader("Locations").padding(.horizontal, 10)
                    if app.settings.locShowComputer {
                        locationRow("Computer", "desktopcomputer", URL(fileURLWithPath: "/"))
                    }
                    if app.settings.locShowHome {
                        locationRow("Home", "house", FileManager.default.homeDirectoryForCurrentUser)
                    }
                    if app.settings.sidebarShowICloud, let url = iCloudDriveURL {
                        locationRow("iCloud Drive", "cloud", url)
                    }
                }

                if app.settings.sidebarShowDevices, !devices.isEmpty {
                    SidebarSectionHeader("Devices").padding(.horizontal, 10)
                    ForEach(devices) { vol in
                        VolumeRow(app: app, volume: vol,
                                  classification: app.volumeClassifications[vol.url])
                            .padding(.horizontal, 6)
                    }
                }

                if app.settings.sidebarShowNetwork, !networkVolumes.isEmpty {
                    SidebarSectionHeader("Network").padding(.horizontal, 10)
                    ForEach(networkVolumes) { vol in
                        VolumeRow(app: app, volume: vol,
                                  classification: app.volumeClassifications[vol.url])
                            .padding(.horizontal, 6)
                    }
                }

                if app.settings.sidebarShowTags, !app.knownTags.isEmpty {
                    SidebarSectionHeader("Tags").padding(.horizontal, 10)
                    ForEach(app.knownTags, id: \.name) { tag in
                        TagCloudRow(app: app, tag: tag, count: app.tagCounts[tag.name] ?? 0)
                            .padding(.horizontal, 6)
                            .frame(height: 30)
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .background(PanelBackground(kind: .sidebar))
        .frame(width: 198)
    }

    /// A Locations entry with open / new-tab / add-favorite context menu.
    private func locationRow(_ title: String, _ icon: String, _ url: URL) -> some View {
        SidebarRow(icon: icon, label: title, isActive: app.activeTab.directory == url)
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

// MARK: - Sidebar building blocks

struct SidebarSectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .tracking(0.4)
            .padding(.top, 8)
            .padding(.bottom, 1)
    }
}

/// Single sidebar item row: accent bar + fill when active, icon + label.
struct SidebarRow: View {
    let icon: String
    let label: String
    let isActive: Bool

    var body: some View {
        ZStack(alignment: .leading) {
            if isActive {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.accentColor.opacity(0.14))
                    .padding(.vertical, 1)
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 3)
                    .clipShape(RoundedRectangle(cornerRadius: 1.5, style: .continuous))
                    .padding(.vertical, 4)
            }
            Label(label, systemImage: icon)
                .font(.system(size: 14))
                .foregroundStyle(isActive ? Color.accentColor : .primary)
                .padding(.leading, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 30)
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 6)
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
                .frame(width: Theme.Col.tagDot, height: Theme.Col.tagDot)
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

/// One mounted volume: classification icon, name, filesystem/transport meta, capacity bar, eject.
struct VolumeRow: View {
    let app: AppState
    let volume: Volume
    var classification: VolumeClassification?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(volume.name).lineLimit(1)
                    if classification?.isReadOnly == true {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 8)).foregroundStyle(.secondary)
                    }
                }
                if let c = classification, c.confidence > 0 {
                    metaLine(c)
                }
                if let frac = volume.usedFraction {
                    ProgressView(value: frac).controlSize(.mini)
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
            if let c = classification, !c.reasons.isEmpty {
                Divider()
                Text(c.kind.label + " (\(Int(c.confidence * 100))% confidence)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if volume.canEject {
                Divider()
                Button { app.eject(volume) } label: { Label("Eject", systemImage: "eject") }
            }
        }
    }

    @ViewBuilder
    private func metaLine(_ c: VolumeClassification) -> some View {
        HStack(spacing: 3) {
            if let fs = c.filesystem {
                Text(fs.uppercased()).font(.system(size: 9)).foregroundStyle(.secondary)
            }
            if c.transport.label != "" && c.transport != .internalBus {
                Text("·").font(.system(size: 9)).foregroundStyle(.tertiary)
                Text(c.transport.label).font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
    }

    private var icon: String {
        if let c = classification, c.confidence >= 0.5 { return c.kind.icon }
        if volume.isNetwork { return "network" }
        if volume.canEject  { return "externaldrive" }
        return "internaldrive"
    }

    private func byte(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}
