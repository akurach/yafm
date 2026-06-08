import SwiftUI
import AppKit
import Quartz
import Core

// MARK: - App delegate — reliable window chrome configuration

final class YafmAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            NSApp.windows
                .filter { !($0 is NSPanel) }
                .forEach { $0.isMovableByWindowBackground = true }
        }
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
                .preferredColorScheme(app.settings.theme.colorScheme)
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
        }

        Settings { SettingsView(app: app) }
    }
}

/// Window chrome: floating sidebar card · floating panes card · status + fkeys on chrome.
struct RootView: View {
    @Bindable var app: AppState

    var body: some View {
        ZStack {
            // Chrome fills the entire window including the title bar area
            ChromeBackground().ignoresSafeArea()

            // "yafm" title centred in the hidden-titlebar zone (28 pt above safe area)
            VStack {
                Text("yafm")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.55))
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
                .padding(9)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // ── Bottom chrome — not inside any card ───────────────────────
                Divider()
                StatusBarView(tab: app.activeTab)
                Divider()
                FunctionBarView(app: app)
            }
        }
        .sheet(isPresented: $app.renameSheet)    { RenameSheet(app: app) }
        .sheet(isPresented: $app.showOnboarding) { OnboardingSheet(app: app) }
        .sheet(isPresented: $app.connectSheet)   { ConnectServerSheet(app: app) }
        .sheet(isPresented: $app.commandPalette) { CommandPalette(app: app) }
        .sheet(isPresented: $app.cheatSheet)     { CheatSheet(app: app) }
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
