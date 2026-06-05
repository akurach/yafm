import SwiftUI
import AppKit
import Quartz
import Core

@main
struct YafmApp: App {
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
        .windowStyle(.titleBar)
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
        }

        Settings { SettingsView(app: app) }
    }
}

/// Window chrome: bookmarks sidebar · dual pane (+ optional preview) · queue · status.
struct RootView: View {
    @Bindable var app: AppState

    var body: some View {
        NavigationSplitView {
            BookmarksSidebar(app: app)
        } detail: {
            VStack(spacing: 0) {
                if !app.hasFullDiskAccess && !app.bannerDismissed {
                    AccessBanner(app: app)
                    Divider()
                }
                HSplitView {
                    PaneView(pane: app.left, isActive: app.activePaneIsLeft, app: app)
                    PaneView(pane: app.right, isActive: !app.activePaneIsLeft, app: app)
                    if app.showPreview {
                        InspectorView(app: app).frame(minWidth: 240)
                    }
                }
                QueueView(app: app)
                Divider()
                StatusBarView(tab: app.activeTab)
                Divider()
                FunctionBarView(app: app)
            }
        }
        .sheet(isPresented: $app.renameSheet) { RenameSheet(app: app) }
        .sheet(isPresented: $app.showOnboarding) { OnboardingSheet(app: app) }
        .sheet(isPresented: $app.searchSheet) { SearchSheet(app: app) }
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
            Button("Search…") { app.run(CommandID.search) }
                .keyboardShortcut("f", modifiers: [.command])
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
