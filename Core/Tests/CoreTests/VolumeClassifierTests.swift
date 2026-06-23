import XCTest
@testable import Core

final class VolumeClassifierTests: XCTestCase {

    private func volume(
        internal isInternal: Bool = false, local: Bool = true,
        removable: Bool = false, ejectable: Bool = false,
        capacity: Int64? = nil
    ) -> Volume {
        Volume(
            url: URL(fileURLWithPath: "/Volumes/Test"), name: "Test",
            isRemovable: removable, isEjectable: ejectable,
            isInternal: isInternal, isLocal: local,
            totalCapacity: capacity, availableCapacity: capacity
        )
    }

    private func classify(_ v: Volume, fs: String?, transport: TransportType = .unknown,
                          camera: [String] = [], tm: Bool = false,
                          diskImage: Bool = false) -> VolumeClassification {
        VolumeClassifier.classify(
            volume: v, filesystem: fs, transport: transport,
            isReadOnly: false, cameraFolders: camera, hasTimeMachine: tm,
            isDiskImage: diskImage
        )
    }

    // Regression: a mounted .dmg is a local ejectable APFS volume; without the
    // disk-image flag it was misclassified as an External SSD.
    func testMountedDiskImageIsVirtual() {
        let v = volume(ejectable: true, capacity: 100_000_000)
        let c = classify(v, fs: "apfs", diskImage: true)
        XCTAssertEqual(c.kind, .virtualVolume)
        XCTAssertEqual(c.kind.label, "Virtual")
    }

    // Same APFS ejectable volume, but NOT a disk image -> real external SSD.
    func testEjectableAPFSIsExternalSSD() {
        let v = volume(ejectable: true)
        let c = classify(v, fs: "apfs", diskImage: false)
        XCTAssertEqual(c.kind, .externalSSD)
    }

    // Internal wins over everything, even if the disk-image flag is set.
    func testInternalDominatesDiskImage() {
        let v = volume(internal: true)
        let c = classify(v, fs: "apfs", diskImage: true)
        XCTAssertEqual(c.kind, .internalDisk)
    }
}
