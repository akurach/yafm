import Foundation
import DiskArbitration
import IOKit

// MARK: - Transport type

public enum TransportType: String, Sendable {
    case usb, thunderbolt, sdReader, network, internalBus, unknown

    public var label: String {
        switch self {
        case .usb:         return "USB"
        case .thunderbolt: return "Thunderbolt"
        case .sdReader:    return "SD Reader"
        case .network:     return "Network"
        case .internalBus: return "Internal"
        case .unknown:     return ""
        }
    }
}

// MARK: - Volume kind

public enum ExternalVolumeKind: String, Sendable {
    case internalDisk, externalSSD, externalHDD, usbFlashDrive
    case sdCard, cameraCard, networkVolume, backupDisk, virtualVolume, unknown

    public var icon: String {
        switch self {
        case .internalDisk:  return "internaldrive"
        case .externalSSD:   return "externaldrive"
        case .externalHDD:   return "externaldrive"
        case .usbFlashDrive: return "memorystick"
        case .sdCard:        return "sdcard"
        case .cameraCard:    return "camera"
        case .networkVolume: return "network"
        case .backupDisk:    return "externaldrive.badge.timemachine"
        case .virtualVolume: return "opticaldiscdrive"
        case .unknown:       return "externaldrive.fill"
        }
    }

    public var label: String {
        switch self {
        case .internalDisk:  return "Internal"
        case .externalSSD:   return "External SSD"
        case .externalHDD:   return "External HDD"
        case .usbFlashDrive: return "USB Flash"
        case .sdCard:        return "SD Card"
        case .cameraCard:    return "Camera Card"
        case .networkVolume: return "Network"
        case .backupDisk:    return "Backup Disk"
        case .virtualVolume: return "Virtual"
        case .unknown:       return "External Drive"
        }
    }
}

// MARK: - Classification

public struct VolumeClassification: Sendable {
    public let kind: ExternalVolumeKind
    public let confidence: Double
    public let filesystem: String?
    public let transport: TransportType
    public let isReadOnly: Bool
    public let reasons: [String]

    public init(kind: ExternalVolumeKind, confidence: Double, filesystem: String?,
                transport: TransportType, isReadOnly: Bool, reasons: [String]) {
        self.kind = kind; self.confidence = confidence; self.filesystem = filesystem
        self.transport = transport; self.isReadOnly = isReadOnly; self.reasons = reasons
    }
}

// MARK: - Collector (off-actor, all calls are synchronous system queries)

public struct VolumeInfoCollector: Sendable {
    public init() {}

    public func collect(volume: Volume) -> VolumeClassification {
        let (filesystem, bsdName) = daInfo(mountURL: volume.url)
        let transport = resolveTransport(bsdName: bsdName, filesystem: filesystem, volume: volume)
        let isReadOnly = readOnly(mountURL: volume.url)
        let cameraFolders = probeCameraFolders(mountURL: volume.url)
        let hasTM = probeTimeMachine(mountURL: volume.url)
        return VolumeClassifier.classify(
            volume: volume, filesystem: filesystem, transport: transport,
            isReadOnly: isReadOnly, cameraFolders: cameraFolders, hasTimeMachine: hasTM
        )
    }

    // MARK: DiskArbitration

    private func daInfo(mountURL: URL) -> (filesystem: String?, bsdName: String?) {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, mountURL as CFURL),
              let desc = DADiskCopyDescription(disk) else { return (nil, nil) }
        let d = desc as NSDictionary
        let fs  = d[kDADiskDescriptionVolumeKindKey]  as? String
        let bsd = d[kDADiskDescriptionMediaBSDNameKey] as? String
        return (fs, bsd)
    }

    // MARK: Transport

    private func resolveTransport(bsdName: String?, filesystem: String?, volume: Volume) -> TransportType {
        if !volume.isLocal  { return .network }
        if volume.isInternal { return .internalBus }
        if let bsd = bsdName, let t = ioTransport(bsdName: bsd), t != .unknown { return t }
        // Heuristic fallback
        let fs = filesystem?.lowercased() ?? ""
        if fs == "exfat" || fs == "msdos" { return .usb }
        if volume.isRemovable { return .usb }
        return .unknown
    }

    private func ioTransport(bsdName: String) -> TransportType? {
        guard let matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsdName) else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }

        let key = "Physical Interconnect Type" as CFString
        let opts = IOOptionBits(kIORegistryIterateParents | kIORegistryIterateRecursively)
        guard let raw = IORegistryEntrySearchCFProperty(
            service, kIOServicePlane, key, kCFAllocatorDefault, opts
        ) else { return nil }
        let value = (raw as? NSString as? String) ?? ""
        switch value {
        case "USB":                        return .usb
        case "Thunderbolt":                return .thunderbolt
        case "Secure Digital (SD Card)":   return .sdReader
        case "SATA", "ATA", "PCI-Express": return .internalBus
        default:                           return .unknown
        }
    }

    // MARK: Read-only

    private func readOnly(mountURL: URL) -> Bool {
        (try? mountURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
    }

    // MARK: Folder probes

    private func probeCameraFolders(mountURL: URL) -> [String] {
        let indicators = ["DCIM", "PRIVATE", "AVCHD", "M4ROOT", "XDROOT", "MP_ROOT"]
        return indicators.filter { folder in
            var isDir: ObjCBool = false
            let url = mountURL.appendingPathComponent(folder)
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        }
    }

    private func probeTimeMachine(mountURL: URL) -> Bool {
        let indicators = ["Backups.backupdb", ".com.apple.timemachine.donotpresent"]
        return indicators.contains { FileManager.default.fileExists(atPath: mountURL.appendingPathComponent($0).path) }
    }
}

// MARK: - Classifier (pure, no I/O)

public struct VolumeClassifier: Sendable {
    public static func classify(
        volume: Volume, filesystem: String?, transport: TransportType,
        isReadOnly: Bool, cameraFolders: [String], hasTimeMachine: Bool
    ) -> VolumeClassification {
        func result(_ kind: ExternalVolumeKind, _ confidence: Double, _ reasons: [String]) -> VolumeClassification {
            VolumeClassification(kind: kind, confidence: confidence, filesystem: filesystem,
                                 transport: transport, isReadOnly: isReadOnly, reasons: reasons)
        }

        // Internal
        if volume.isInternal {
            return result(.internalDisk, 1.0, ["Internal volume"])
        }

        // Network
        if !volume.isLocal {
            return result(.networkVolume, 1.0, ["Network volume"])
        }

        let fs = filesystem?.lowercased() ?? ""

        // Camera card: folder indicators dominate
        if !cameraFolders.isEmpty {
            var conf = 0.7; var reasons = ["Found: \(cameraFolders.joined(separator: ", "))"]
            if fs == "exfat" || fs == "msdos" { conf += 0.10; reasons.append("Camera FS (\(filesystem ?? ""))") }
            if volume.isRemovable              { conf += 0.05; reasons.append("Removable") }
            if transport == .sdReader          { conf += 0.15; reasons.append("SD reader transport") }
            return result(.cameraCard, min(1.0, conf), reasons)
        }

        // Time Machine
        if hasTimeMachine {
            return result(.backupDisk, 0.95, ["Time Machine structure found"])
        }

        // SD reader without camera folders
        if transport == .sdReader {
            return result(.sdCard, 0.80, ["SD reader transport"])
        }

        // USB flash: small, removable, FAT/exFAT
        if (fs == "exfat" || fs == "msdos") && volume.isRemovable {
            let gb = Double(volume.totalCapacity ?? 0) / 1_000_000_000
            if gb < 512 {
                return result(.usbFlashDrive, 0.75, ["Removable \(filesystem ?? "FAT") < 512 GB"])
            }
        }

        // External drives
        if volume.canEject {
            let kind: ExternalVolumeKind = fs == "apfs" ? .externalSSD : .externalHDD
            let conf: Double = fs == "apfs" ? 0.60 : 0.50
            var reasons: [String] = ["\(filesystem ?? "Unknown") external volume"]
            if volume.isRemovable { reasons.append("Removable") }
            return result(kind, conf, reasons)
        }

        return result(.unknown, 0, [])
    }
}
