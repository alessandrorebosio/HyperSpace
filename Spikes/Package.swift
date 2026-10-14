// swift-tools-version: 6.0
import PackageDescription

// Throwaway phase 0 spike: answers the open questions in docs/DESIGN.md §8.
// Swift 5 language mode on purpose, to keep C callbacks and globals simple.
let package = Package(
    name: "HelmSpike",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "helm-spike",
            path: "Sources/HelmSpike",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
