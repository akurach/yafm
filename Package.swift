// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "yafm",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "Core",
            path: "Core/Sources/Core",
            // NetFS: native SMB/AFP share mounting for the v0.7 virtual filesystem.
            linkerSettings: [.linkedFramework("NetFS")]
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
            // .lproj are copied into the .app bundle by Scripts/make-app.sh so
            // Bundle.main (the app) resolves them; SwiftPM must not treat them as
            // module resources (that would need defaultLocalization + land them in
            // Bundle.module, where LocalizedStringKey wouldn't look).
            exclude: ["Resources/Info.plist", "Resources/AppIcon.icns",
                      "Resources/en.lproj", "Resources/ru.lproj"]
        ),
    ]
)
