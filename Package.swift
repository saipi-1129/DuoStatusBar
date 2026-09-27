// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DuoStatusBar",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "DuoStatusBar", targets: ["DuoStatusBar"])
    ],
    targets: [
        .executableTarget(
            name: "DuoStatusBar",
            path: "Sources/DuoStatusBar",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreWLAN"),
                .linkedFramework("IOKit"),
                .linkedFramework("Network"),
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration")
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
