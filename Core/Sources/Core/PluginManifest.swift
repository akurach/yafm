import Foundation

// MARK: - Plugin manifests & capabilities (v0.8 "Make it yours")

/// What a plugin is allowed to do. Declared in its manifest, granted at
/// enable-time in Settings — never plugin-triggered. Absent capability = the
/// host never wires that surface, so an un-manifested `.js` is compute-only.
public enum PluginCapability: String, Codable, Sendable, CaseIterable {
    /// Contribute a computed table column from the path-free entry snapshot.
    /// The baseline since v0.3 — needs no grant (no host data leaves the snapshot).
    case computeColumn = "compute:column"
    /// Contribute commands (palette / menus).
    case command = "contribute:command"
    /// Contribute row context-menu items.
    case contextMenu = "contribute:menu"
    /// Read text files *relative to the listing root* (`yafm.readText`). The one
    /// capability that hands real bytes to JS — host-resolved, scoped, size-capped.
    case readCwd = "read:cwd"

    /// User-facing one-liner for the enable-time consent UI.
    public var consentSummary: String {
        switch self {
        case .computeColumn: return "Add a column computed from file info (name, size, type)."
        case .command: return "Add commands you can run from the palette and menus."
        case .contextMenu: return "Add items to the right-click menu."
        case .readCwd: return "Read text files inside the folder you're viewing (e.g. .git/HEAD)."
        }
    }

    /// Capabilities that hand real data/authority to the plugin and so require an
    /// explicit grant. `computeColumn` is implicit (snapshot-only).
    public var requiresConsent: Bool { self != .computeColumn }
}

/// What a plugin contributes, by id, for display before enabling.
public struct PluginContributions: Codable, Sendable, Equatable {
    public var columns: [String]
    public var commands: [String]
    public var menuItems: [String]

    public init(columns: [String] = [], commands: [String] = [], menuItems: [String] = []) {
        self.columns = columns
        self.commands = commands
        self.menuItems = menuItems
    }

    private enum CodingKeys: String, CodingKey { case columns, commands, menuItems }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        columns = try c.decodeIfPresent([String].self, forKey: .columns) ?? []
        commands = try c.decodeIfPresent([String].self, forKey: .commands) ?? []
        menuItems = try c.decodeIfPresent([String].self, forKey: .menuItems) ?? []
    }
}

/// A plugin's sidecar `<plugin>.json`. Optional: a bare `.js` with no manifest
/// loads compute-only (preserving the drop-a-file UX). Present, it gates every
/// surface beyond a column and carries the identity a marketplace needs.
public struct PluginManifest: Codable, Sendable, Equatable {
    /// Manifest format version — must be `1` for this host.
    public let manifest: Int
    /// Reverse-DNS identity, e.g. `com.example.git-status`.
    public let id: String
    public let name: String
    public let version: String
    /// Plugin API contract the plugin was written against (host advertises
    /// `PluginAPI.currentVersion`). Major-version mismatch = refuse to load.
    public let apiVersion: String
    public let capabilities: [PluginCapability]
    public let contributes: PluginContributions
    /// Optional provenance for the trust tier (v0.8 honest labeling; full
    /// cryptographic signing is a later, infra-gated step).
    public let author: String?
    public let signature: String?

    public init(manifest: Int = 1, id: String, name: String, version: String,
                apiVersion: String, capabilities: [PluginCapability] = [],
                contributes: PluginContributions = .init(),
                author: String? = nil, signature: String? = nil) {
        self.manifest = manifest
        self.id = id
        self.name = name
        self.version = version
        self.apiVersion = apiVersion
        self.capabilities = capabilities
        self.contributes = contributes
        self.author = author
        self.signature = signature
    }

    private enum CodingKeys: String, CodingKey {
        case manifest, id, name, version, apiVersion, capabilities, contributes, author, signature
    }

    /// Custom decode so optional sections (`capabilities`, `contributes`,
    /// provenance) may be omitted — only identity/version are required. An
    /// unknown capability string is ignored rather than failing the whole load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        manifest = try c.decodeIfPresent(Int.self, forKey: .manifest) ?? 0
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? "0"
        apiVersion = try c.decodeIfPresent(String.self, forKey: .apiVersion) ?? "0"
        let rawCaps = try c.decodeIfPresent([String].self, forKey: .capabilities) ?? []
        capabilities = rawCaps.compactMap(PluginCapability.init(rawValue:))
        contributes = try c.decodeIfPresent(PluginContributions.self, forKey: .contributes) ?? .init()
        author = try c.decodeIfPresent(String.self, forKey: .author)
        signature = try c.decodeIfPresent(String.self, forKey: .signature)
    }

    /// Trust tier shown honestly before install/enable. No remote PKI yet — a
    /// `signature` field is advisory until signing lands.
    public enum Trust: String, Sendable { case unsigned, declaredAuthor, signed }
    public var trust: Trust {
        if signature != nil { return .signed }
        if author != nil { return .declaredAuthor }
        return .unsigned
    }

    public func grants(_ capability: PluginCapability) -> Bool {
        capability == .computeColumn || capabilities.contains(capability)
    }
}

/// Manifest parsing + validation errors, surfaced in Settings ▸ Plugins.
public enum PluginManifestError: LocalizedError, Equatable {
    case malformed(String)
    case unsupportedManifestVersion(Int)
    case incompatibleAPI(plugin: String, host: String)
    case missingID

    public var errorDescription: String? {
        switch self {
        case .malformed(let why): return "Manifest isn't valid JSON: \(why)"
        case .unsupportedManifestVersion(let v): return "Unsupported manifest version \(v) (expected 1)."
        case .incompatibleAPI(let p, let h): return "Plugin targets API \(p); this host is \(h)."
        case .missingID: return "Manifest is missing a reverse-DNS id."
        }
    }
}

/// The plugin API contract version the host advertises. Frozen at 1.0 in v0.9.
public enum PluginAPI {
    public static let currentVersion = "1.0"

    /// Major component of a `major.minor` string (defaults to 0 on garbage).
    public static func major(_ version: String) -> Int {
        Int(version.split(separator: ".").first.map(String.init) ?? "") ?? 0
    }

    /// Compatible when the major versions match (1.x host runs 1.y plugins).
    public static func isCompatible(pluginAPI: String) -> Bool {
        major(pluginAPI) == major(currentVersion)
    }
}

extension PluginManifest {
    /// Parse + validate a sidecar manifest. Throws `PluginManifestError` so the
    /// reason reaches the user instead of a silent skip.
    public static func parse(_ data: Data) throws -> PluginManifest {
        let manifest: PluginManifest
        do {
            manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
        } catch {
            throw PluginManifestError.malformed(error.localizedDescription)
        }
        guard manifest.manifest == 1 else {
            throw PluginManifestError.unsupportedManifestVersion(manifest.manifest)
        }
        guard !manifest.id.isEmpty else { throw PluginManifestError.missingID }
        guard PluginAPI.isCompatible(pluginAPI: manifest.apiVersion) else {
            throw PluginManifestError.incompatibleAPI(plugin: manifest.apiVersion,
                                                      host: PluginAPI.currentVersion)
        }
        return manifest
    }
}
