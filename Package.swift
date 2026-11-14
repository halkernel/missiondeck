// swift-tools-version:5.7
import PackageDescription

// MissionDeck uses only Apple's own frameworks: no third-party code, no network libraries.
let package = Package(
    name: "MissionDeck",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "MissionDeck",
            path: "Sources/MissionDeck",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
