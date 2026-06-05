import Foundation

// MARK: - Mounted volumes (drives, USB sticks, network shares)

/// A snapshot of one mounted volume. Value type, UI-free (the App layer maps it
/// to a sidebar row and owns mount/unmount observation via AppKit).
public struct Volume: Identifiable, Hashable, Sendable {
    public var id: URL { url }
    public let url: URL
    public let name: String
    public let isRemovable: Bool
    public let isEjectable: Bool
    public let isInternal: Bool
    public let isLocal: Bool
    public let totalCapacity: Int64?
    public let availableCapacity: Int64?

    public init(
        url: URL, name: String,
        isRemovable: Bool, isEjectable: Bool, isInternal: Bool, isLocal: Bool,
        totalCapacity: Int64?, availableCapacity: Int64?
    ) {
        self.url = url
        self.name = name
        self.isRemovable = isRemovable
        self.isEjectable = isEjectable
        self.isInternal = isInternal
        self.isLocal = isLocal
        self.totalCapacity = totalCapacity
        self.availableCapacity = availableCapacity
    }

    /// True for USB sticks / external disks / DMGs — anything we can eject.
    public var canEject: Bool { isEjectable || isRemovable }

    /// Network mount (SMB/AFP/NFS) — shown under "Network", not "Devices".
    public var isNetwork: Bool { !isLocal }

    /// Used fraction 0...1 for the capacity bar, nil if capacity is unknown.
    public var usedFraction: Double? {
        guard let total = totalCapacity, total > 0, let avail = availableCapacity else { return nil }
        return Double(total - avail) / Double(total)
    }
}

/// Reads the currently mounted volumes. Stateless and synchronous — the call is
/// a cheap local query; the App layer re-runs it on mount/unmount notifications.
public struct VolumeService: Sendable {
    private static let keys: [URLResourceKey] = [
        .volumeNameKey, .volumeIsRemovableKey, .volumeIsEjectableKey,
        .volumeIsInternalKey, .volumeIsLocalKey,
        .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
    ]

    public init() {}

    public func mountedVolumes() -> [Volume] {
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Self.keys,
            options: [.skipHiddenVolumes]
        ) ?? []
        return urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(Self.keys)) else { return nil }
            return Volume(
                url: url,
                name: v.volumeName ?? url.lastPathComponent,
                isRemovable: v.volumeIsRemovable ?? false,
                isEjectable: v.volumeIsEjectable ?? false,
                isInternal: v.volumeIsInternal ?? false,
                isLocal: v.volumeIsLocal ?? true,
                totalCapacity: v.volumeTotalCapacity.map(Int64.init),
                availableCapacity: v.volumeAvailableCapacity.map(Int64.init)
            )
        }
    }
}
