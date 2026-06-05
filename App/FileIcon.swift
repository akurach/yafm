import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Core

/// Real macOS file-type icons for the listing, cached so a big folder doesn't
/// ask LaunchServices for an icon per row. Keyed by (directory?, extension) —
/// every `.swift` shares one icon, so the cache stays tiny regardless of count.
@MainActor
enum FileIcon {
    private static var cache: [String: NSImage] = [:]

    static func image(for entry: FSEntry) -> NSImage {
        let key = entry.isDirectory ? "/dir" : entry.url.pathExtension.lowercased()
        if let hit = cache[key] { return hit }
        let icon: NSImage
        if entry.isDirectory {
            icon = NSWorkspace.shared.icon(for: .folder)
        } else if !key.isEmpty, let type = UTType(filenameExtension: key) {
            icon = NSWorkspace.shared.icon(for: type)
        } else {
            icon = NSWorkspace.shared.icon(for: .data)
        }
        cache[key] = icon
        return icon
    }
}

/// SwiftUI wrapper that renders the cached file-type icon at a fixed box.
struct FileIconView: View {
    let entry: FSEntry
    var body: some View {
        Image(nsImage: FileIcon.image(for: entry))
            .resizable()
            .interpolation(.high)
            .frame(width: 16, height: 16)
    }
}
