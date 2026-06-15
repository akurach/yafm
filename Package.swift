// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "yafm",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Fork of phosphor-icons/swift: upstream's Package.swift omits the
        // `resources:` declaration for Assets.xcassets, so `Bundle.module` isn't
        // generated and PhosphorSwift fails to compile on a clean checkout (CI).
        // The fork adds that one line; otherwise identical. See akurach/phosphor-swift.
        .package(url: "https://github.com/akurach/phosphor-swift", branch: "main"),
    ],
    targets: [
        .target(
            name: "Core",
            path: "Core/Sources/Core",
            // NetFS: native SMB/AFP share mounting for the v0.7 virtual filesystem.
            linkerSettings: [
                .linkedFramework("NetFS"),
                .linkedFramework("DiskArbitration"),
                .linkedFramework("IOKit"),
            ]
        ),
        .testTarget(
            name: "CoreTests",
            dependencies: ["Core"],
            path: "Core/Tests/CoreTests"
        ),
        .executableTarget(
            name: "yafm",
            dependencies: [
                "Core",
                .product(name: "PhosphorSwift", package: "phosphor-swift"),
            ],
            path: "App",
            // .lproj are copied into the .app bundle by Scripts/make-app.sh so
            // Bundle.main (the app) resolves them; SwiftPM must not treat them as
            // module resources (that would need defaultLocalization + land them in
            // Bundle.module, where LocalizedStringKey wouldn't look).
            exclude: ["Resources/Info.plist", "Resources/AppIcon.icns",
                      "Resources/en.lproj", "Resources/ru.lproj"],
            resources: [.copy("Resources/Fonts")],
            linkerSettings: [
                .linkedFramework("ImageIO"),
            ]
        ),
    ]
)
