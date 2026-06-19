import SwiftUI
import AppKit

// MARK: - Typography

enum IBMPlex {
    static func sans(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        switch weight {
        case .medium:   return .custom("IBMPlexSans-Medium",   size: size)
        case .semibold: return .custom("IBMPlexSans-SemiBold", size: size)
        default:        return .custom("IBMPlexSans-Regular",  size: size)
        }
    }
    static func mono(_ size: CGFloat) -> Font {
        .custom("IBMPlexMono-Regular", size: size)
    }
}


// MARK: - Floating panel modifier (appearance-adaptive)

struct FloatingPanelModifier: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let isDark = scheme == .dark
        content
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .stroke(Color.primary.opacity(isDark ? 0.14 : 0.10), lineWidth: 1)
            }
            // Light shadow for depth — heavier in dark, lighter in light
            .shadow(color: .black.opacity(isDark ? 0.50 : 0.10), radius: 2,  x: 0, y: 1)
            .shadow(color: .black.opacity(isDark ? 0.35 : 0.12), radius: 28, x: 0, y: 10)
    }
}

extension View {
    func floatingPanel() -> some View {
        modifier(FloatingPanelModifier())
    }
}

// MARK: - Root chrome background (appearance-adaptive)

/// View that fills its frame with the window-chrome colour.
/// Uses @Environment so the colour is guaranteed to update on appearance change.
struct ChromeBackground: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View { Theme.Palette.chrome(scheme == .dark) }
}

/// Panel backgrounds — same pattern.
struct PanelBackground: View {
    enum Kind { case sidebar, panes }
    let kind: Kind
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        switch kind {
        case .sidebar: Theme.Palette.sidebarSurface(scheme == .dark)
        case .panes:   Theme.Palette.panesSurface(scheme == .dark)
        }
    }
}
