import Foundation

// MARK: - Dual-pane folder comparison (v0.9.8)

/// How an entry in one pane relates to the same-named entry in the other pane.
public enum CompareMark: String, Sendable, Equatable {
    case onlyHere    // no entry with this name on the other side
    case different   // present both sides but size/mtime differ (files); always `.same` for dirs
    case same        // present both sides and equal
}

/// Per-URL marks for each pane after a comparison. Empty maps mean "not compared".
public struct FolderComparison: Sendable, Equatable {
    public let left: [URL: CompareMark]
    public let right: [URL: CompareMark]
    public init(left: [URL: CompareMark], right: [URL: CompareMark]) {
        self.left = left; self.right = right
    }
}

/// Diff two directory listings by **name**, classifying each entry as only-on-this-side,
/// present-but-different, or identical. Files compare by size + modification time (within
/// `mtimeTolerance`, since filesystems differ in timestamp resolution). Directories can't be
/// cheaply deep-compared, so a folder present on both sides is treated as `.same`. Pure — the
/// UI tints rows from the result and selects the diffs for `F5`/`F6`.
public func compareFolders(left: [FSEntry], right: [FSEntry],
                           mtimeTolerance: TimeInterval = 1) -> FolderComparison {
    let lByName = Dictionary(left.map { ($0.name, $0) },  uniquingKeysWith: { a, _ in a })
    let rByName = Dictionary(right.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })

    func same(_ a: FSEntry, _ b: FSEntry) -> Bool {
        // A folder on both sides: treat as same (no cheap deep compare). A
        // dir-vs-file name clash counts as different.
        if a.isDirectory || b.isDirectory { return a.isDirectory && b.isDirectory }
        guard a.size == b.size else { return false }
        switch (a.modified, b.modified) {
        case let (ta?, tb?): return abs(ta.timeIntervalSince(tb)) <= mtimeTolerance
        case (nil, nil):     return true
        default:             return false
        }
    }

    func marks(_ side: [FSEntry], against other: [String: FSEntry]) -> [URL: CompareMark] {
        var out: [URL: CompareMark] = [:]
        out.reserveCapacity(side.count)
        for e in side {
            if let twin = other[e.name] { out[e.url] = same(e, twin) ? .same : .different }
            else { out[e.url] = .onlyHere }
        }
        return out
    }

    return FolderComparison(left: marks(left, against: rByName),
                            right: marks(right, against: lByName))
}
