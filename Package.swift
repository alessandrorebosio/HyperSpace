// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HyperSpace",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "HyperSpace", targets: ["HyperSpaceApp"]),
        .executable(name: "hsctl", targets: ["hsctl"]),
    ],
    dependencies: [
        .package(url: "https://github.com/dduan/TOMLDecoder.git", exact: "0.4.5"),
    ],
    targets: [
        .target(name: "HyperSpaceCore", dependencies: ["TOMLDecoder"]),
        // Tiny on purpose: hsctl links only this.
        .target(name: "HyperSpaceIPC"),
        // Talks to macOS input APIs (event tap, HID event system).
        .target(name: "HyperSpaceInput", dependencies: ["HyperSpaceCore"]),
        // Talks to other apps' windows through the Accessibility API.
        .target(name: "HyperSpaceWM", dependencies: ["HyperSpaceCore"]),
        .executableTarget(name: "HyperSpaceApp", dependencies: ["HyperSpaceCore", "HyperSpaceIPC", "HyperSpaceInput", "HyperSpaceWM"]),
        .executableTarget(name: "hsctl", dependencies: ["HyperSpaceIPC"]),
        .testTarget(name: "HyperSpaceCoreTests", dependencies: ["HyperSpaceCore", "HyperSpaceIPC"]),
    ]
)
