import SwiftUI
import AppKit
import Core

/// A Sendable snapshot of a key event — extracted on the AppKit thread so no
/// non-Sendable `NSEvent` crosses into the main-actor handler.
struct KeyChord: Sendable {
    let keyCode: UInt16
    let command, shift, control, option: Bool
    let chars: String?
}

/// Installs a local key-down monitor that maps TC-style keys to commands.
/// A monitor is used (instead of SwiftUI `.keyboardShortcut`) because function
/// keys (F2/F5/F6/F8) and raw arrows aren't expressible as SwiftUI shortcuts.
/// Keys are ignored while a text field is being edited.
struct KeyboardMonitor: NSViewRepresentable {
    let app: AppState

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.install(app: app)
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var monitor: Any?

        func install(app: AppState) {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                let chord = KeyChord(
                    keyCode: event.keyCode,
                    command: event.modifierFlags.contains(.command),
                    shift: event.modifierFlags.contains(.shift),
                    control: event.modifierFlags.contains(.control),
                    option: event.modifierFlags.contains(.option),
                    chars: event.charactersIgnoringModifiers
                )
                // AppKit contract: local monitor callbacks arrive on the main
                // thread. Assert it so any regression fails loudly, not silently.
                dispatchPrecondition(condition: .onQueue(.main))
                let consumed = MainActor.assumeIsolated { KeyboardMonitor.handle(chord, app: app) }
                return consumed ? nil : event
            }
        }
        deinit { if let m = monitor { NSEvent.removeMonitor(m) } }
    }

    /// Returns true if the chord was consumed.
    @MainActor
    static func handle(_ c: KeyChord, app: AppState) -> Bool {
        // Don't steal keys from an active text field (path bar, rename sheet).
        if let responder = NSApp.keyWindow?.firstResponder,
           responder is NSText || responder.className.contains("NSTextView") {
            return false
        }

        let tab = app.activeTab

        switch c.keyCode {
        case 96: app.run(CommandID.copy); return true       // F5
        case 97: app.run(CommandID.move); return true       // F6
        case 100: app.run(CommandID.delete); return true    // F8
        case 120: app.run(CommandID.rename); return true    // F2
        case 48: app.run(CommandID.switchPane); return true // Tab
        case 49 where !c.command:                           // Space -> QuickLook
            QuickLook.toggle(urls: tab.actionable.map(\.url)); return true
        case 36, 76: app.run(CommandID.open); return true   // Return / Enter
        case 126: tab.moveCursor(by: -1, extend: c.shift); return true // Up
        case 125: tab.moveCursor(by: 1, extend: c.shift); return true  // Down
        case 123: app.run(CommandID.goUp); return true      // Left -> up
        case 124: app.run(CommandID.open); return true      // Right -> into
        default: break
        }

        switch (c.chars, c.command, c.shift) {
        case (".", true, true): app.run(CommandID.toggleHidden); return true
        case ("t", true, false): app.run(CommandID.newTab); return true
        case ("w", true, false): app.run(CommandID.closeTab); return true
        case ("p", true, true): app.run(CommandID.togglePreview); return true
        default: return false
        }
    }
}
