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

    // Live section drag-reorder: the grabbed block follows the cursor while the
    // others animate to make space (heights drive the swap thresholds).
    @State private var dragKey: String?
    @State private var dragDY: CGFloat = 0
    @State private var dragStartVisible: [String] = []   // visible section order captured at grab
    @State private var dragStartIndex: Int = 0
    @State private var sectionHeights: [String: CGFloat] = [:]

    // Same live-reorder, but for items inside the Favorites section.
    @State private var favDragId: String?
    @State private var favDragDY: CGFloat = 0
    @State private var favStartOrder: [String] = []
    @State private var favStartIndex: Int = 0
    @State private var favHeights: [String: CGFloat] = [:]

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

    // MARK: Reorder model

    /// One Favorites entry — a system folder or a user bookmark — with a stable id
    /// for drag-reorder persistence.
    private enum FavItem: Identifiable {
        case system(SystemFavorite, URL)
        case bookmark(Bookmark)
        var id: String {
            switch self {
            case .system(let f, _): return "sys:\(f.rawValue)"
            case .bookmark(let b):  return "bm:\(b.id.uuidString)"
            }
        }
    }

    /// Favorites in the user's saved order; new items append in natural order.
    private var orderedFavorites: [FavItem] {
        var natural: [FavItem] = []
        for fav in SystemFavorite.allCases where app.settings.enabledFavorites.contains(fav) {
            if let url = Self.favURLs[fav] ?? nil { natural.append(.system(fav, url)) }
        }
        for bm in app.bookmarks { natural.append(.bookmark(bm)) }
        let order = app.settings.favoritesOrder
        guard !order.isEmpty else { return natural }
        let known = natural.filter { order.contains($0.id) }
            .sorted { (order.firstIndex(of: $0.id) ?? 0) < (order.firstIndex(of: $1.id) ?? 0) }
        return known + natural.filter { !order.contains($0.id) }
    }

    private static let allSectionKeys = ["favorites", "locations", "devices", "network", "tags"]
    private var orderedSectionKeys: [String] {
        let stored = app.settings.sidebarSectionOrder.filter { Self.allSectionKeys.contains($0) }
        return stored + Self.allSectionKeys.filter { !stored.contains($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toggle button — always visible regardless of collapse state
            HStack {
                if !sidebarCollapsed { Spacer() }
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        app.sidebarCollapsed.toggle()
                    }
                } label: {
                    Ph.sidebarSimple.bold
                        .renderingMode(.template).resizable().aspectRatio(contentMode: .fit)
                        .frame(width: 14, height: 14)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .frame(width: sidebarCollapsed ? 44 : 28, height: 28)
                .contentShape(Rectangle())
            }
            .padding(.top, 4)

            Divider().opacity(0.5)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(orderedSectionKeys, id: \.self) { key in
                        section(key)
                            .background(GeometryReader { g in
                                Color.clear
                                    .onAppear { sectionHeights[key] = g.size.height }
                                    .onChange(of: g.size.height) { _, h in sectionHeights[key] = h }
                            })
                            .offset(y: dragKey == key ? dragDY : 0)
                            .zIndex(dragKey == key ? 1 : 0)
                            .shadow(color: .black.opacity(dragKey == key ? 0.25 : 0),
                                    radius: dragKey == key ? 8 : 0, y: 2)
                            .transaction { if dragKey == key { $0.animation = nil } }
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .background(PanelBackground(kind: .sidebar))
        .frame(width: app.sidebarCollapsed ? 44 : 198)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: app.sidebarCollapsed)
        .clipped()
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

    // MARK: Section rendering (order is user-draggable)

    private var sidebarCollapsed: Bool { app.sidebarCollapsed }

    private func isSectionCollapsed(_ key: String) -> Bool {
        app.settings.collapsedSidebarSections.contains(key)
    }

    @ViewBuilder private func section(_ key: String) -> some View {
        switch key {
        case "favorites":
            if app.settings.sidebarShowFavorites {
                if !sidebarCollapsed { sectionHeader("Favorites", key: key) }
                if !isSectionCollapsed(key) || sidebarCollapsed {
                    ForEach(orderedFavorites) { item in
                        favoriteRow(item)
                            .background(GeometryReader { g in
                                Color.clear
                                    .onAppear { favHeights[item.id] = g.size.height }
                                    .onChange(of: g.size.height) { _, h in favHeights[item.id] = h }
                            })
                            .offset(y: favDragId == item.id ? favDragDY : 0)
                            .zIndex(favDragId == item.id ? 1 : 0)
                            .shadow(color: .black.opacity(favDragId == item.id ? 0.22 : 0),
                                    radius: favDragId == item.id ? 6 : 0, y: 2)
                            .transaction { if favDragId == item.id { $0.animation = nil } }
                            .gesture(sidebarCollapsed ? nil : favoriteDrag(item.id))
                    }
                }
            }
        case "locations":
            if app.settings.sidebarShowLocations {
                if !sidebarCollapsed { sectionHeader("Locations", key: key) }
                if !isSectionCollapsed(key) || sidebarCollapsed {
                    if app.settings.locShowComputer {
                        locationRow("Computer", Ph.desktop.bold, URL(fileURLWithPath: "/"))
                    }
                    if app.settings.locShowHome {
                        locationRow("Home", Ph.house.bold, FileManager.default.homeDirectoryForCurrentUser)
                    }
                    if app.settings.sidebarShowICloud, let url = iCloudDriveURL {
                        locationRow("iCloud Drive", Ph.cloud.bold, url)
                    }
                }
            }
        case "devices":
            if app.settings.sidebarShowDevices, !devices.isEmpty {
                if !sidebarCollapsed { sectionHeader("Devices", key: key) }
                if !isSectionCollapsed(key) || sidebarCollapsed {
                    ForEach(devices) { vol in volumeRow(vol) }
                }
            }
        case "network":
            if app.settings.sidebarShowNetwork, !networkVolumes.isEmpty {
                if !sidebarCollapsed { sectionHeader("Network", key: key) }
                if !isSectionCollapsed(key) || sidebarCollapsed {
                    ForEach(networkVolumes) { vol in volumeRow(vol) }
                }
            }
        case "tags":
            if app.settings.sidebarShowTags, !app.knownTags.isEmpty {
                if !sidebarCollapsed { sectionHeader("Tags", key: key) }
                if !isSectionCollapsed(key) || sidebarCollapsed {
                    ForEach(app.knownTags, id: \.name) { tag in
                        TagCloudRow(app: app, tag: tag, count: app.tagCounts[tag.name] ?? 0,
                                    collapsed: sidebarCollapsed)
                            .padding(.horizontal, sidebarCollapsed ? 0 : 6).frame(height: 30)
                    }
                }
            }
        default: EmptyView()
        }
    }

    /// Section header — tap toggles collapse (chevron rotates); grab-and-drag
    /// live-reorders the whole block (neighbors animate as the edge passes their
    /// midpoint). A tap moves <6 pt so it never starts a drag.
    private func sectionHeader(_ title: String, key: String) -> some View {
        let collapsed = isSectionCollapsed(key)
        return HStack(spacing: 4) {
            Ph.caretRight.bold
                .renderingMode(.template).resizable().aspectRatio(contentMode: .fit)
                .frame(width: 8, height: 8)
                .rotationEffect(.degrees(collapsed ? 0 : 90))
                .foregroundStyle(.secondary)
                .padding(.top, 8)
            SidebarSectionHeader(title)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                app.settings.toggleSectionCollapsed(key)
            }
        }
        .gesture(
            DragGesture(minimumDistance: 6, coordinateSpace: .global)
                .onChanged { v in
                    if dragKey == nil {
                        dragKey = key
                        dragStartVisible = orderedSectionKeys.filter { (sectionHeights[$0] ?? 0) > 4 }
                        dragStartIndex = dragStartVisible.firstIndex(of: key) ?? 0
                    }
                    updateSectionDrag(v.translation.height)
                }
                .onEnded { _ in
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { dragDY = 0 }
                    dragKey = nil
                }
        )
    }

    /// Position-based live reorder: each frame the target slot is recomputed from the
    /// order captured at grab time + the cursor's total travel, so it can't drift or
    /// "fly through" — the grabbed block crosses a neighbor only once the cursor passes
    /// that neighbor's midpoint, and the offset is compensated so the block stays under
    /// the cursor exactly. Other blocks spring into place.
    private func updateSectionDrag(_ t: CGFloat) {
        guard let key = dragKey, !dragStartVisible.isEmpty else { return }
        var target = dragStartIndex
        var crossed: CGFloat = 0
        if t > 0 {
            var i = dragStartIndex
            while i + 1 < dragStartVisible.count {
                let h = max(sectionHeights[dragStartVisible[i + 1]] ?? 44, 30)
                if t - crossed > h / 2 { crossed += h; i += 1 } else { break }
            }
            target = i
            dragDY = t - crossed
        } else {
            var i = dragStartIndex
            while i > 0 {
                let h = max(sectionHeights[dragStartVisible[i - 1]] ?? 44, 30)
                if -t - crossed > h / 2 { crossed += h; i -= 1 } else { break }
            }
            target = i
            dragDY = t + crossed
        }
        // Rebuild the full order: visible slots filled by the reordered visible list,
        // hidden sections left exactly where they are.
        var vis = dragStartVisible
        vis.removeAll { $0 == key }
        vis.insert(key, at: min(max(target, 0), vis.count))
        var it = vis.makeIterator()
        let result = orderedSectionKeys.map { dragStartVisible.contains($0) ? (it.next() ?? $0) : $0 }
        if result != app.settings.sidebarSectionOrder {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                app.settings.sidebarSectionOrder = result
            }
        }
    }

    @ViewBuilder private func favoriteRow(_ item: FavItem) -> some View {
        Group {
            switch item {
            case .system(let fav, let url):
                locationRow(fav.label, favImage(fav), url)
            case .bookmark(let bm):
                SidebarRow(icon: Ph.folder.bold, label: bm.name, isActive: app.activeTab.directory == bm.url,
                           collapsed: sidebarCollapsed)
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
    }

    /// Live drag-reorder for a Favorites item — same feel as section dragging.
    private func favoriteDrag(_ id: String) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { v in
                if favDragId == nil {
                    favDragId = id
                    favStartOrder = orderedFavorites.map(\.id)
                    favStartIndex = favStartOrder.firstIndex(of: id) ?? 0
                }
                updateFavoriteDrag(v.translation.height)
            }
            .onEnded { _ in
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { favDragDY = 0 }
                favDragId = nil
            }
    }

    private func updateFavoriteDrag(_ t: CGFloat) {
        guard let id = favDragId, !favStartOrder.isEmpty else { return }
        var target = favStartIndex
        var crossed: CGFloat = 0
        if t > 0 {
            var i = favStartIndex
            while i + 1 < favStartOrder.count {
                let h = max(favHeights[favStartOrder[i + 1]] ?? 30, 18)
                if t - crossed > h / 2 { crossed += h; i += 1 } else { break }
            }
            target = i; favDragDY = t - crossed
        } else {
            var i = favStartIndex
            while i > 0 {
                let h = max(favHeights[favStartOrder[i - 1]] ?? 30, 18)
                if -t - crossed > h / 2 { crossed += h; i -= 1 } else { break }
            }
            target = i; favDragDY = t + crossed
        }
        var arr = favStartOrder
        arr.removeAll { $0 == id }
        arr.insert(id, at: min(max(target, 0), arr.count))
        if arr != app.settings.favoritesOrder {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                app.settings.favoritesOrder = arr
            }
        }
    }

    private func volumeRow(_ vol: Volume) -> some View {
        VolumeRow(app: app, volume: vol, classification: app.volumeClassifications[vol.url],
                  collapsed: sidebarCollapsed,
                  onGetInfo: { infoItem = VolumeInfoItem(volume: vol, classification: app.volumeClassifications[vol.url]) },
                  onRename: { renameVolume = vol; renameText = vol.name })
            .padding(.horizontal, sidebarCollapsed ? 0 : 6)
    }

    private func locationRow(_ title: String, _ icon: Image, _ url: URL) -> some View {
        SidebarRow(icon: icon, label: title, isActive: app.activeTab.directory == url,
                   collapsed: sidebarCollapsed)
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
/// In collapsed sidebar shows icon only, centred.
struct SidebarRow: View {
    let icon: Image
    let label: String
    let isActive: Bool
    var collapsed: Bool = false

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
            if collapsed {
                icon
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 14, height: 14)
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
                    .frame(maxWidth: .infinity)
            } else {
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
            }
        }
        .frame(height: 30)
        .contentShape(Rectangle())
        .padding(.horizontal, 6)
    }
}

/// One tag in the sidebar: color dot · name · count.
/// In collapsed sidebar shows dot only, centred.
struct TagCloudRow: View {
    let app: AppState
    let tag: Tag
    let count: Int
    var collapsed: Bool = false

    private var isActive: Bool {
        app.activeTab.virtualName == "Tag: \(tag.name)"
    }

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
            if collapsed {
                Circle().fill(Color.named(tag.colorName) ?? .secondary)
                    .frame(width: Theme.Col.tagDot, height: Theme.Col.tagDot)
                    .frame(maxWidth: .infinity)
            } else {
                HStack(spacing: 6) {
                    Circle().fill(Color.named(tag.colorName) ?? .secondary)
                        .frame(width: Theme.Col.tagDot, height: Theme.Col.tagDot)
                    Text(tag.name).lineLimit(1)
                        .foregroundStyle(isActive ? Color.accentColor : .primary)
                    Spacer()
                    Text("\(count)").font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.leading, 10)
            }
        }
        .frame(height: 30)
        .contentShape(Rectangle())
        .onTapGesture { app.openTag(tag) }
        .contextMenu {
            Button("Show Tagged Files") { app.openTag(tag) }
        }
    }
}

/// One mounted volume: Phosphor icon, name, type/FS subtitle, capacity bar, eject.
/// In collapsed sidebar shows icon only, centred.
struct VolumeRow: View {
    let app: AppState
    let volume: Volume
    var classification: VolumeClassification?
    var collapsed: Bool = false
    var onGetInfo: (() -> Void)? = nil
    var onRename: (() -> Void)? = nil

    private var isActive: Bool {
        app.activeTab.directory == volume.url && app.activeTab.virtualName == nil
    }

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
            if collapsed {
                volumeIcon
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 14, height: 14)
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
                    .frame(maxWidth: .infinity)
            } else {
                HStack(spacing: 7) {
                    volumeIcon
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 14, height: 14)
                        .frame(width: 16, alignment: .center)
                        .foregroundStyle(isActive ? Color.accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(volume.name).font(IBMPlex.sans(13)).lineLimit(1)
                                .foregroundStyle(isActive ? Color.accentColor : .primary)
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
            }
        }
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
