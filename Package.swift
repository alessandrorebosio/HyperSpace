// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "HyperSpace",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "HyperSpace",
            path: "Sources/HyperSpace"
        ),
        .testTarget(
            name: "HyperSpaceTests",
            dependencies: ["HyperSpace"]
        ),
    ]
)
