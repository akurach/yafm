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
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
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
    var body: some View {
        scheme == .dark
            ? Color(red: 0.067, green: 0.067, blue: 0.075)   // #111113
            : Color(red: 0.878, green: 0.878, blue: 0.886)   // #e0e0e2 — light chrome per design spec
    }
}

/// Panel backgrounds — same pattern.
struct PanelBackground: View {
    enum Kind { case sidebar, panes }
    let kind: Kind
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        switch kind {
        case .sidebar:
            scheme == .dark
                ? Color(red: 0.129, green: 0.129, blue: 0.149)  // #212126
                : Color(red: 0.918, green: 0.918, blue: 0.925)  // #eaeaec — dusty light gray
        case .panes:
            scheme == .dark
                ? Color(red: 0.110, green: 0.110, blue: 0.118)  // #1c1c1e
                : Color(nsColor: .windowBackgroundColor)         // white
        }
    }
}
