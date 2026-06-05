import AppKit
import Quartz
import Core

/// Bridges Space-to-preview to the system QuickLook panel.
/// `@MainActor`-isolated: AppKit delivers the data-source callbacks on the main
/// thread, so the state (`urls`) is safe without `nonisolated(unsafe)`.
@MainActor
final class QuickLook: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLook()
    private var urls: [URL] = []

    static func toggle(urls: [URL]) {
        guard !urls.isEmpty else { return }
        shared.urls = urls
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.dataSource = shared
            panel.makeKeyAndOrderFront(nil)
            panel.reloadData()
        }
    }

    /// Live-follow the keyboard cursor: while the panel is open, swap its item
    /// to the newly-focused row so arrowing through the list updates the preview
    /// (Finder behaviour). No-op when the panel is closed.
    static func updateIfVisible(urls: [URL]) {
        guard !urls.isEmpty,
              QLPreviewPanel.sharedPreviewPanelExists(),
              let panel = QLPreviewPanel.shared(), panel.isVisible else { return }
        shared.urls = urls
        panel.reloadData()
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { urls.count }
    }
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated { () -> NSURL? in
            // Guard against a toggle/reload race shrinking `urls` mid-query (H-12).
            guard index >= 0, index < urls.count else { return nil }
            return urls[index] as NSURL
        }
    }
}
