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
        .testTarget(
            name: "CoreTests",
            dependencies: ["Core"],
            path: "Core/Tests/CoreTests"
        ),
        .executableTarget(
            name: "yafm",
            dependencies: ["Core"],
            path: "App",
            exclude: ["Resources/Info.plist", "Resources/AppIcon.icns"]
        ),
    ]
)
