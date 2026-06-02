// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "VoiceTyper",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "VoiceTyper", targets: ["VoiceTyper"])
    ],
    targets: [
        .executableTarget(
            name: "VoiceTyper",
            path: "Sources/VoiceTyper",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Carbon"),
                .linkedFramework("SwiftUI")
            ]
        )
    ],
    swiftLanguageVersions: [.v5]
)
