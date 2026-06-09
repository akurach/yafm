import SwiftUI
import AppKit
import Core
import PhosphorSwift

// MARK: - Sidebar: Favorites · Locations · Devices · Network (v0.2.1 §2)

struct BookmarksSidebar: View {
    @Bindable var app: AppState

    @State private var infoItem: VolumeInfoItem?
    @State private var renameVolume: Volume?
    @State private var renameText: String = ""

    private var devices: [Volume] { app.volumes.filter { !$0.isNetwork } }
    private var networkVolumes: [Volume] { app.volumes.filter { $0.isNetwork } }

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

    private var iCloudDriveURL: URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    @ViewBuilder
    private func sysFav(_ label: String, _ icon: Image, _ url: URL?) -> some View {
        if let url { locationRow(label, icon, url) }
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {

                if app.settings.sidebarShowFavorites {
                    SidebarSectionHeader("Favorites").padding(.horizontal, 10)
                    ForEach(SystemFavorite.allCases) { fav in
                        if app.settings.enabledFavorites.contains(fav) {
                            sysFav(fav.label, favImage(fav), Self.favURLs[fav] ?? nil)
                        }
                    }
                    ForEach(app.bookmarks) { bm in
                        SidebarRow(icon: Ph.folder.bold, label: bm.name,
                                   isActive: app.activeTab.directory == bm.url)
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
                        locationRow("Computer", Ph.desktop.bold, URL(fileURLWithPath: "/"))
                    }
                    if app.settings.locShowHome {
                        locationRow("Home", Ph.house.bold,
                                    FileManager.default.homeDirectoryForCurrentUser)
                    }
                    if app.settings.sidebarShowICloud, let url = iCloudDriveURL {
                        locationRow("iCloud Drive", Ph.cloud.bold, url)
                    }
                }

                if app.settings.sidebarShowDevices, !devices.isEmpty {
                    SidebarSectionHeader("Devices").padding(.horizontal, 10)
                    ForEach(devices) { vol in
                        VolumeRow(
                            app: app, volume: vol,
                            classification: app.volumeClassifications[vol.url],
                            onGetInfo: {
                                infoItem = VolumeInfoItem(
                                    volume: vol,
                                    classification: app.volumeClassifications[vol.url])
                            },
                            onRename: { renameVolume = vol; renameText = vol.name }
                        )
                        .padding(.horizontal, 6)
                    }
                }

                if app.settings.sidebarShowNetwork, !networkVolumes.isEmpty {
                    SidebarSectionHeader("Network").padding(.horizontal, 10)
                    ForEach(networkVolumes) { vol in
                        VolumeRow(
                            app: app, volume: vol,
                            classification: app.volumeClassifications[vol.url],
                            onGetInfo: {
                                infoItem = VolumeInfoItem(
                                    volume: vol,
                                    classification: app.volumeClassifications[vol.url])
                            },
                            onRename: { renameVolume = vol; renameText = vol.name }
                        )
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
        .sheet(item: $infoItem) { item in
            VolumeInfoSheet(item: item)
        }
        .alert("Rename Volume", isPresented: Binding(
            get: { renameVolume != nil },
            set: { if !$0 { renameVolume = nil } }
        )) {
            TextField("New name", text: $renameText)
            Button("Rename") {
                if let vol = renameVolume { performRename(vol, renameText) }
                renameVolume = nil
            }
            Button("Cancel", role: .cancel) { renameVolume = nil }
        } message: {
            if let vol = renameVolume { Text("Current name: \(vol.name)") }
        }
    }

    private func locationRow(_ title: String, _ icon: Image, _ url: URL) -> some View {
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

    private func performRename(_ volume: Volume, _ newName: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        task.arguments = ["rename", volume.url.path, newName]
        try? task.run()
    }

    private func favImage(_ fav: SystemFavorite) -> Image {
        switch fav {
        case .desktop:      Ph.desktop.bold
        case .documents:    Ph.file.bold
        case .downloads:    Ph.arrowLineDown.bold
        case .movies:       Ph.filmStrip.bold
        case .music:        Ph.musicNote.bold
        case .pictures:     Ph.image.bold
        case .applications: Ph.squaresFour.bold
        }
    }
}

// MARK: - Volume Info sheet

struct VolumeInfoItem: Identifiable {
    let id = UUID()
    let volume: Volume
    let classification: VolumeClassification?
}

struct VolumeInfoSheet: View {
    let item: VolumeInfoItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(item.volume.name).font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(.bottom, 12)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                row("Kind",      item.classification?.kind.label ?? "Volume")
                row("Format",    item.classification?.filesystem?.uppercased() ?? "—")
                if let t = item.classification?.transport, t != .internalBus, !t.label.isEmpty {
                    row("Connection", t.label)
                }
                row("Read Only", item.classification?.isReadOnly == true ? "Yes" : "No")
                row("Location",  item.volume.url.path)
                if let total = item.volume.totalCapacity {
                    row("Capacity",  fmt(total))
                }
                if let avail = item.volume.availableCapacity {
                    row("Available", fmt(avail))
                }
                if let total = item.volume.totalCapacity,
                   let avail = item.volume.availableCapacity {
                    row("Used", fmt(total - avail))
                }
            }
            .padding(.top, 12)
        }
        .padding(20)
        .frame(width: 340)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
            Text(value).textSelection(.enabled)
        }
        .font(.system(size: 13))
    }

    private func fmt(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - Sidebar building blocks

struct SidebarSectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title.uppercased())
            .font(IBMPlex.sans(10, weight: .semibold))
            .foregroundStyle(.secondary)
            .tracking(0.4)
            .padding(.top, 8)
            .padding(.bottom, 1)
    }
}

/// Single sidebar item row: accent bar + fill when active, Phosphor icon + label.
struct SidebarRow: View {
    let icon: Image
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
            HStack(spacing: 7) {
                icon
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 14, height: 14)
                    .frame(width: 16, alignment: .center)
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
                Text(label)
                    .font(IBMPlex.sans(13))
                    .foregroundStyle(isActive ? Color.accentColor : .primary)
                Spacer()
            }
            .padding(.leading, 10)
            .frame(height: 30)
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 6)
    }
}

/// One tag in the sidebar: color dot · name · count.
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

/// One mounted volume: Phosphor icon, name, type/FS subtitle, capacity bar, eject.
struct VolumeRow: View {
    let app: AppState
    let volume: Volume
    var classification: VolumeClassification?
    var onGetInfo: (() -> Void)? = nil
    var onRename: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 7) {
            volumeIcon
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 14, height: 14)
                .frame(width: 16, alignment: .center)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(volume.name).font(IBMPlex.sans(13)).lineLimit(1)
                    if classification?.isReadOnly == true {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 8)).foregroundStyle(.secondary)
                    }
                }
                Text(subtitleText)
                    .font(IBMPlex.sans(10)).foregroundStyle(.secondary)
                if let frac = volume.usedFraction {
                    ProgressView(value: frac).controlSize(.mini).padding(.top, 1)
                }
            }
            Spacer()
            if volume.canEject {
                Button { app.eject(volume) } label: { Image(systemName: "eject") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .font(.system(size: 11))
            }
        }
        .padding(.leading, 10)
        .frame(minHeight: 36)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Open")            { app.activeTab.open(volume.url) }
            Button("Open in New Tab") { app.openInNewTab(volume.url) }
            Divider()
            Button("Get Info")        { onGetInfo?() }
            Button("Rename…")         { onRename?() }
            Divider()
            Button { app.addBookmark(volume.url) } label: {
                Label("Add to Favorites", systemImage: "star")
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([volume.url])
            }
            if volume.canEject {
                Divider()
                Button { app.eject(volume) } label: { Label("Eject", systemImage: "eject") }
            }
        }
        .onTapGesture { app.activeTab.open(volume.url) }
    }

    private var volumeIcon: Image {
        guard let c = classification, c.confidence >= 0.5 else {
            if volume.isNetwork { return Ph.globe.bold }
            return volume.canEject ? Ph.hardDrive.bold : Ph.hardDrive.fill
        }
        switch c.kind {
        case .internalDisk:  return Ph.hardDrive.fill
        case .externalSSD:   return Ph.hardDrive.bold
        case .externalHDD:   return Ph.hardDrives.bold
        case .usbFlashDrive: return Ph.usb.bold
        case .sdCard:        return Ph.simCard.bold
        case .cameraCard:    return Ph.camera.bold
        case .networkVolume: return Ph.globe.bold
        case .backupDisk:    return Ph.clockCounterClockwise.bold
        case .virtualVolume: return Ph.disc.bold
        case .unknown:       return Ph.hardDrive.bold
        }
    }

    private var subtitleText: String {
        var parts: [String] = []
        if let c = classification, c.confidence >= 0.5 { parts.append(c.kind.label) }
        if let fs = classification?.filesystem { parts.append(fs.uppercased()) }
        return parts.isEmpty ? "Volume" : parts.joined(separator: " · ")
    }
}
