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

    /// macOS virtual key codes for the keys that map to a `KeyBinding.Key`.
    /// Pure event-decoding — NOT a second list of bindings. The binding→command
    /// mapping itself lives once in `DefaultCommands.byBinding`.
    private static let keyByCode: [UInt16: KeyBinding.Key] = [
        96: .function(5), 97: .function(6), 98: .function(7), 99: .function(3),
        100: .function(8), 118: .function(4), 120: .function(2),
        48: .tab, 49: .space, 36: .enter, 76: .enter,
    ]

    /// Returns true if the chord was consumed.
    @MainActor
    static func handle(_ c: KeyChord, app: AppState) -> Bool {
        // A modal/alert is up (e.g. the delete confirmation): never intercept —
        // the local monitor would otherwise swallow Return and run "Open" before
        // the alert's default button saw it (the "Enter opens the file instead of
        // confirming delete" bug). Let the event reach the alert.
        if NSApp.modalWindow != nil { return false }

        // Don't steal keys from an active text field (path bar, rename sheet,
        // search/palette fields). The field editor is an NSText/NSTextView, and
        // NSTextField/NSSearchField conform to NSTextInputClient — covers them all
        // without the old stringly-typed className check (P2-9).
        if let responder = NSApp.keyWindow?.firstResponder,
           responder is NSText || responder is NSTextInputClient {
            return false
        }

        let tab = app.activeTab

        var mods: KeyBinding.Modifiers = []
        if c.command { mods.insert(.command) }
        if c.shift { mods.insert(.shift) }
        if c.control { mods.insert(.control) }
        if c.option { mods.insert(.option) }

        // ⌘1–⌘9: jump straight to tab N in the active pane.
        if c.command, !c.control, !c.option,
           let n = c.chars?.first?.wholeNumberValue, (1...9).contains(n) {
            app.activePane.selectIndex(n); return true
        }

        // Active type-to-filter session: Esc clears, Backspace edits, a plain
        // printable key extends the filter. Arrows/Enter fall through so the
        // filtered list is still navigable.
        if tab.filterActive {
            if c.keyCode == 53 { tab.clearFilter(); return true }      // Esc
            if c.keyCode == 51 { tab.backspaceFilter(); return true }  // Backspace
            if Self.isPlainTyping(c, mods), let s = c.chars, Self.isFilterChar(s) {
                tab.appendFilter(s); return true
            }
        }

        // Cursor movement and the Left/Right nav aliases aren't modeled as
        // commands (no binding), so they stay explicit.
        switch c.keyCode {
        case 126: tab.moveCursor(by: -1, extend: c.shift); return true // Up
        case 125: tab.moveCursor(by: 1, extend: c.shift); return true  // Down
        case 123: app.run(CommandID.goUp); return true      // Left -> up
        case 124: app.enterCursor(); return true            // Right -> into folder (files gated by setting)
        default: break
        }

        // Everything else: decode the chord into a KeyBinding and dispatch via
        // the single source of truth (DefaultCommands.byBinding).
        if let key = Self.keyByCode[c.keyCode],
           let id = DefaultCommands.byBinding[KeyBinding(key, mods)] {
            app.run(id); return true
        }
        if let ch = c.chars?.first,
           let id = DefaultCommands.byBinding[KeyBinding(.char(ch), mods)] {
            app.run(id); return true
        }

        // Total Commander-style quick search: the first bare alphanumeric
        // keystroke starts a type-to-filter session in the current folder.
        if Self.isPlainTyping(c, mods), let s = c.chars, let ch = s.first,
           ch.isLetter || ch.isNumber {
            tab.appendFilter(s); return true
        }
        return false
    }

    /// A single printable character typed with no command/control/option (Shift
    /// is fine for capitals) — i.e. plain typing, not a shortcut chord.
    private static func isPlainTyping(_ c: KeyChord, _ mods: KeyBinding.Modifiers) -> Bool {
        !c.command && !c.control && !c.option && (c.chars?.count == 1)
    }

    /// Characters allowed to extend an active filter (filename-ish). Kept to
    /// alphanumerics, space, and a small safe set so an active filter doesn't
    /// swallow punctuation/symbol command shortcuts (TC quick-search behaviour).
    private static func isFilterChar(_ s: String) -> Bool {
        guard let ch = s.first else { return false }
        return ch.isLetter || ch.isNumber || ch == " " || ch == "." || ch == "-" || ch == "_"
    }
}
