import SwiftUI
import AppKit
import Quartz
import Core

// MARK: - App delegate — reliable window chrome configuration

final class YafmAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        // Intentionally NOT setting isMovableByWindowBackground: it made the whole
        // window drag from any non-button view, so pressing-and-dragging a sidebar
        // row (which uses onTapGesture, not a Button — a tap fires, a drag doesn't,
        // so the window grabbed the drag) moved the window instead. The window is
        // still draggable from the top title-bar zone (hidden title bar).
    }
}

@main
struct YafmApp: App {
    @NSApplicationDelegateAdaptor(YafmAppDelegate.self) var appDelegate
    @State private var app = AppState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup("yafm") {
            RootView(app: app)
                .frame(minWidth: 900, minHeight: 520)
                .accentColor(app.settings.accent.color)
                .onAppear { app.start() }
                .background(KeyboardMonitor(app: app).frame(width: 0, height: 0))
        }
        .onChange(of: scenePhase) { _, phase in
            // Persist the last folder for the "Last used" start option.
            if phase != .active { app.settings.rememberLastFolder(app.activeTab.directory) }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandMenus(app: app)
            CommandGroup(replacing: .appInfo) {
                Button("About yafm") {
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .applicationName: "yafm",
                        .init(rawValue: "Copyright"): "Yet Another File Manager for macOS",
                    ])
                }
            }
            CommandGroup(replacing: .help) {
                Button("Keyboard Shortcuts") { app.run(CommandID.cheatSheet) }
                    .keyboardShortcut("/", modifiers: [.command])
            }
            // In-window Settings (Mole-style): replace the native Preferences
            // window so it can't be torn off outside the app.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { app.showSettings = true }
                    .keyboardShortcut(",", modifiers: [.command])
            }
        }
    }
}

/// Window chrome: floating sidebar card · floating panes card · status + fkeys on chrome.
struct RootView: View {
    @Bindable var app: AppState

    /// The active folder's name for the titlebar; "yafm" at the volume root or
    /// when the name is empty.
    private var titleText: String {
        let name = app.activeTab.directory.lastPathComponent
        return name.isEmpty || name == "/" ? "yafm" : name
    }

    var body: some View {
        ZStack {
            // Chrome fills the entire window including the title bar area
            ChromeBackground().ignoresSafeArea()

            // Current folder name centred in the hidden-titlebar zone (28 pt above
            // safe area) — orients you like a native window title. Capped + middle-
            // truncated so a deep folder name never collides with the traffic lights.
            VStack {
                Text(titleText)
                    .font(IBMPlex.sans(13, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.55))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 420)
                    .frame(maxWidth: .infinity)
                    .frame(height: 28)
                Spacer()
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                // Chrome body — 9 pt padding + gap between the two floating panels
                HStack(alignment: .top, spacing: 9) {

                    // ── Floating sidebar card ──────────────────────────────────
                    BookmarksSidebar(app: app)
                        .floatingPanel()

                    // ── Floating panes card ────────────────────────────────────
                    VStack(spacing: 0) {
                        if !app.hasFullDiskAccess && !app.bannerDismissed {
                            AccessBanner(app: app)
                            Divider()
                        }
                        HSplitView {
                            PaneView(pane: app.left,  isActive:  app.activePaneIsLeft, app: app)
                            PaneView(pane: app.right, isActive: !app.activePaneIsLeft, app: app)
                            if app.showPreview {
                                InspectorView(app: app).frame(minWidth: 240)
                            }
                        }
                        QueueView(app: app)
                    }
                    .background(PanelBackground(kind: .panes))
                    .floatingPanel()
                }
                .animation(Theme.Motion.layout, value: app.sidebarCollapsed)
                .padding(9)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // ── Bottom chrome — ONE band, one surface: a thin status line above
                // the full-width F-keys. Status and keys do NOT share a row (that was
                // the cramped right-squish); they stack, keys span the full width.
                Divider().opacity(0.5)
                VStack(spacing: 0) {
                    StatusBarView(tab: app.activeTab)
                        .padding(.horizontal, Theme.Space.rowLeading)
                        .frame(height: 18)
                    FunctionBarView(app: app)
                        .frame(height: 28)
                }
                .background(FunctionBarBackground())
            }
        }
        .sheet(isPresented: $app.renameSheet)    { RenameSheet(app: app) }
        .sheet(isPresented: $app.showOnboarding) { OnboardingSheet(app: app) }
        .sheet(isPresented: $app.connectSheet)   { ConnectServerSheet(app: app) }
        .sheet(isPresented: $app.commandPalette) { CommandPalette(app: app) }
        .sheet(isPresented: $app.cheatSheet)     { CheatSheet(app: app) }
        .overlay { SettingsOverlay(app: app) }
        .environment(\.font, IBMPlex.sans(13))
    }
}

/// Inline preview panel (v0.2) — toggled with ⌘⇧P, distinct from Space QuickLook.
struct PreviewPane: View {
    let tab: TabModel

    var body: some View {
        Group {
            if let url = tab.actionable.first?.url {
                QuickLookPreview(url: url)
            } else {
                ContentUnavailableView("No selection", systemImage: "eye.slash")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

/// QLPreviewView wrapper for the inline panel.
struct QuickLookPreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        let v = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        v.previewItem = url as NSURL
        return v
    }
    func updateNSView(_ nsView: QLPreviewView, context: Context) {
        nsView.previewItem = url as NSURL
    }
}

/// TC-style commands also surfaced in the menu bar (discoverability + ⌘ keys).
struct CommandMenus: Commands {
    let app: AppState

    var body: some Commands {
        CommandMenu("Go") {
            Button("Command Palette…") { app.run(CommandID.commandPalette) }
                .keyboardShortcut("k", modifiers: [.command])
            Button("Search…") { app.run(CommandID.search) }
                .keyboardShortcut("f", modifiers: [.command])
            Divider()
            Button("Next Tab") { app.run(CommandID.nextTab) }
            Button("Previous Tab") { app.run(CommandID.prevTab) }
            Divider()
            Button("Up") { app.run(CommandID.goUp) }
            Button("Toggle Hidden Files") { app.run(CommandID.toggleHidden) }
                .keyboardShortcut(".", modifiers: [.command, .shift])
            Button("Toggle Sidebar") { app.run(CommandID.toggleSidebar) }
                .keyboardShortcut("s", modifiers: [.command, .option])
            Button("Toggle Preview") { app.run(CommandID.togglePreview) }
                .keyboardShortcut("p", modifiers: [.command, .shift])
        }
        CommandMenu("File Ops") {
            Button("Copy → other pane") { app.run(CommandID.copy) }
            Button("Move → other pane") { app.run(CommandID.move) }
            Button("Delete") { app.run(CommandID.delete) }
            Button("Rename…") { app.run(CommandID.rename) }
            Divider()
            Button("Copy") { app.run(CommandID.clipCopy) }
            Button("Cut") { app.run(CommandID.clipCut) }
            Button("Paste") { app.run(CommandID.paste) }
            Button("New Folder…") { app.run(CommandID.newFolder) }
            Divider()
            Button("Reveal in Finder") { app.run(CommandID.reveal) }
            Button("Get Info") { app.run(CommandID.getInfo) }
            Button("Copy Path") { app.run(CommandID.copyPath) }
            Button("Refresh") { app.run(CommandID.refresh) }
        }
    }
}
