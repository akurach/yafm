// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "yafm",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "Core",
            path: "Core/Sources/Core"
        ),
        // NOTE: CoreTests target is disabled until full Xcode is installed —
        // neither swift-testing nor XCTest ships with Command Line Tools alone.
        // The test sources live in Core/Tests/CoreTests/ ready to re-enable:
        // .testTarget(name: "CoreTests", dependencies: ["Core"], path: "Core/Tests/CoreTests"),
        .executableTarget(
            name: "yafm",
            dependencies: ["Core"],
            path: "App"
        ),
    ]
)
