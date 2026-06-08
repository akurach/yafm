import Foundation
import AppKit
import Core

// MARK: - Tag domain extracted from AppState (A-3)

@MainActor
@Observable
final class TagCoordinator {
    private let tags: TagServing
    private let fs: FileSystemProvider

    // AppState wires these after its own init so TabModel is reachable.
    var onReloadActiveTab: (() -> Void)?
    var activeTabGetter: (() -> TabModel)?

    // MARK: Observed state

    var knownTags: [Tag] = []
    var tagCounts: [String: Int] = [:]

    // MARK: Task handles (H-2: re-entry cancels prior run)

    private var openTagTask: Task<Void, Never>?
    private var refreshTagsTask: Task<Void, Never>?
    private var indexTask: Task<Void, Never>?

    init(tags: TagServing, fs: FileSystemProvider) {
        self.tags = tags
        self.fs = fs
    }

    // MARK: Tag cloud

    func refreshTags() {
        refreshTagsTask?.cancel()
        refreshTagsTask = Task { [weak self] in
            guard let self else { return }
            let all = await self.tags.allKnownTags()
            if Task.isCancelled { return }
            var counts: [String: Int] = [:]
            for t in all { counts[t.name] = await self.tags.entries(taggedWith: t).count }
            if Task.isCancelled { return }
            self.knownTags = all
            self.tagCounts = counts
        }
    }

    func indexTagsInBackground() {
        indexTask?.cancel()
        indexTask = Task { [weak self] in
            guard let self else { return }
            await self.tags.loadPersisted()
            self.refreshTags()
            await self.tags.index(roots: [FileManager.default.homeDirectoryForCurrentUser])
            if Task.isCancelled { return }
            self.refreshTags()
            await self.tags.persist()
        }
    }

    func rescanTags() {
        indexTask?.cancel()
        indexTask = Task { [weak self] in
            guard let self else { return }
            await self.tags.index(roots: [FileManager.default.homeDirectoryForCurrentUser])
            if Task.isCancelled { return }
            self.refreshTags()
            await self.tags.persist()
        }
    }

    func clearTags() {
        Task { [weak self] in
            guard let self else { return }
            await self.tags.clear()
            self.refreshTags()
        }
    }

    func renameTag(_ old: String, to new: String) {
        Task { [weak self] in
            guard let self else { return }
            _ = await self.tags.renameTag(old, to: new)
            await self.tags.persist()
            self.refreshTags()
            self.onReloadActiveTab?()
        }
    }

    func deleteTag(_ name: String) {
        Task { [weak self] in
            guard let self else { return }
            _ = await self.tags.deleteTag(name)
            await self.tags.persist()
            self.refreshTags()
            self.onReloadActiveTab?()
        }
    }

    func recolorTag(_ name: String, colorIndex: Int?) {
        Task { [weak self] in
            guard let self else { return }
            _ = await self.tags.recolorTag(name, colorIndex: colorIndex)
            await self.tags.persist()
            self.refreshTags()
            self.onReloadActiveTab?()
        }
    }

    func promptRenameTag(_ tag: Tag) {
        let alert = NSAlert()
        alert.messageText = "Rename Tag"
        alert.informativeText = "Rename \"\(tag.name)\" on every file that carries it."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = tag.name
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let new = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !new.isEmpty, new != tag.name else { return }
        renameTag(tag.name, to: new)
    }

    func promptDeleteTag(_ tag: Tag) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete tag \"\(tag.name)\"?"
        alert.informativeText = "Removes it from every file that carries it (\(tagCounts[tag.name] ?? 0)). The files themselves are untouched."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        deleteTag(tag.name)
    }

    /// Click a tag → stream every tagged file into a virtual listing progressively.
    func openTag(_ tag: Tag) {
        openTagTask?.cancel()
        guard let targetTab = activeTabGetter?() else { return }
        openTagTask = Task { [weak self] in
            guard let self else { return }
            let urls = await self.tags.entries(taggedWith: tag)
            targetTab.beginVirtual(title: "Tag: \(tag.name)")
            var entries: [FSEntry] = []
            for url in urls {
                if Task.isCancelled { return }
                guard var e = try? await self.fs.metadata(of: url) else { continue }
                e.tags = await self.tags.tags(of: url)
                entries.append(e)
                if entries.count % 64 == 0 { targetTab.appendVirtual(entries) }
            }
            if Task.isCancelled { return }
            targetTab.appendVirtual(entries)
        }
    }

    // MARK: Tag writing

    func toggleColorTag(name: String, colorIndex: Int, on entry: FSEntry) {
        Task { [weak self] in
            guard let self else { return }
            var current = await self.tags.tags(of: entry.url)
            if let i = current.firstIndex(where: { $0.name == name }) {
                current.remove(at: i)
            } else {
                current.append(Tag(name: name, colorIndex: colorIndex))
            }
            try? await self.tags.setTags(current, on: entry.url)
            self.onReloadActiveTab?()
            self.refreshTags()
        }
    }

    func addTag(_ name: String, on entry: FSEntry) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\n") else { return }
        Task { [weak self] in
            guard let self else { return }
            var current = await self.tags.tags(of: entry.url)
            guard !current.contains(where: { $0.name == trimmed }) else { return }
            current.append(Tag(name: trimmed))
            try? await self.tags.setTags(current, on: entry.url)
            self.onReloadActiveTab?()
            self.refreshTags()
        }
    }

    func writeTags(_ newTags: [Tag], on url: URL) {
        Task { [weak self] in
            guard let self else { return }
            try? await self.tags.setTags(newTags, on: url)
            self.onReloadActiveTab?()
            self.refreshTags()
        }
    }

    func currentTags(of url: URL) async -> [Tag] { await tags.tags(of: url) }

    func promptNewTag(on entry: FSEntry) {
        let alert = NSAlert()
        alert.messageText = "New Tag"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        addTag(field.stringValue, on: entry)
    }

    // MARK: Forget

    /// Drop moved/renamed/deleted URLs from the tag index so cloud counts and
    /// virtual tag listings don't point at paths that no longer exist.
    func forgetTagged(_ urls: [URL]) {
        Task { [weak self] in
            guard let self else { return }
            for url in urls { await self.tags.forget(url) }
            self.refreshTags()
        }
    }
}
