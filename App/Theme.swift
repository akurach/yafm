import SwiftUI

/// The single source of UI tokens — spacing, type scale, semantic colors, column
/// widths, motion. Views read `Theme.*` instead of scattering literals, so a
/// visual change happens in one place and Dynamic Type / a light-dark audit are
/// a token edit rather than a hunt across `Views.swift`.
///
/// Introduced in v0.4 while the view layer is still small (the cheap-insurance
/// seam): every later UX milestone (polish, accessibility) consumes it.
enum Theme {

    // MARK: Spacing

    enum Space {
        static let row: CGFloat = 8        // horizontal gap inside a row
        static let rowV: CGFloat = 2       // vertical row padding
        static let pane: CGFloat = 6
        static let tight: CGFloat = 4
    }

    // MARK: Column widths (Name flexes; the rest are fixed and header-aligned)

    enum Col {
        static let size: CGFloat = 78
        static let modified: CGFloat = 124
        static let kind: CGFloat = 92
        static let git: CGFloat = 34
        static let plugin: CGFloat = 104
        static let icon: CGFloat = 16      // row icon box; matches the header spacer

        static let tagDot: CGFloat = 8
    }

    // MARK: Type scale

    enum Font {
        static let row = SwiftUI.Font.body
        static let mono = SwiftUI.Font.caption.monospaced()
        static let meta = SwiftUI.Font.caption
        static let header = SwiftUI.Font.caption.bold()
        static let badge = SwiftUI.Font.caption
        static let chevron = SwiftUI.Font.system(size: 7)
    }

    // MARK: Semantic colors

    enum Palette {
        /// Selection and the keyboard cursor must read as *distinct* states.
        /// Selection is a filled accent wash; the cursor is a crisp accent ring
        /// (see `Theme.cursorStroke`) so "where focus is" is unmistakable even on
        /// an unselected row — the v0.3 build made them differ by ~15% opacity.
        static let selectionFill = Color.accentColor.opacity(0.22)
        static let cursorFill = Color.accentColor.opacity(0.08)
        static let cursorStroke = Color.accentColor
        static let activePaneTint = Color.accentColor.opacity(0.06)
        static let tabActive = Color.accentColor.opacity(0.20)

        // Git markers: untracked/added green, modified orange, deleted red.
        static let gitAdded = Color.green
        static let gitModified = Color.orange
        static let gitDeleted = Color.red

        static func git(_ marker: String?) -> Color {
            switch marker {
            case "?", "A": return gitAdded
            case "D": return gitDeleted
            case "M", "•": return gitModified
            default: return .secondary
            }
        }
    }

    // MARK: Motion

    enum Motion {
        /// Selection / cursor / navigation glide. Streaming row inserts stay
        /// un-animated (handled at the call site) to avoid load-time jank.
        static let selection: Animation = .easeOut(duration: 0.12)
    }

    // MARK: Geometry

    static let cornerRadius: CGFloat = 5
    static let cursorBarWidth: CGFloat = 3   // leading accent bar marking the cursor row
}
