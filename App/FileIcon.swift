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
        // A package (.app, .bundle…) is a directory WITH an extension and has its own
        // icon (the app's), so key by full path. Plain folders share one folder icon;
        // files key by extension.
        let isPackage = entry.isDirectory && !entry.url.pathExtension.isEmpty
        let key: String
        if isPackage { key = "pkg:" + entry.url.path }
        else if entry.isDirectory { key = "/dir" }
        else { key = entry.url.pathExtension.lowercased() }

        if let hit = cache[key] { return hit }
        let icon: NSImage
        if isPackage {
            icon = NSWorkspace.shared.icon(forFile: entry.url.path)   // real app icon
        } else if entry.isDirectory {
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

/// Leading file-type glyph. Hybrid per the redesign: when `tiles` is on, known
/// file extensions render as a drawn `FileTypeTile` (colored extension chip);
/// folders and unknown extensions keep their real macOS icon. `tiles` off →
/// every row uses the system icon (Settings ▸ Appearance ▸ Colored type tiles).
struct FileIconView: View {
    let entry: FSEntry
    var size: CGFloat = Theme.Col.icon
    /// Resolved tile (sRGB color + label), or nil to use the real macOS icon. The
    /// caller resolves this (honoring the toggle + user overrides) so this view
    /// stays a pure renderer.
    var tile: (rgb: (r: CGFloat, g: CGFloat, b: CGFloat), label: String)?
    var body: some View {
        if let tile {
            FileTypeTile(rgb: tile.rgb, label: tile.label, size: size)
        } else {
            Image(nsImage: FileIcon.image(for: entry))
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        }
    }
}
