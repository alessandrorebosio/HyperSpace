// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Helm",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Helm", targets: ["HelmApp"]),
        .executable(name: "helmctl", targets: ["helmctl"]),
    ],
    dependencies: [
        .package(url: "https://github.com/dduan/TOMLDecoder.git", exact: "0.4.5"),
    ],
    targets: [
        .target(name: "HelmCore", dependencies: ["TOMLDecoder"]),
        // Tiny on purpose: helmctl links only this.
        .target(name: "HelmIPC"),
        .executableTarget(name: "HelmApp", dependencies: ["HelmCore", "HelmIPC"]),
        .executableTarget(name: "helmctl", dependencies: ["HelmIPC"]),
        .testTarget(name: "HelmCoreTests", dependencies: ["HelmCore", "HelmIPC"]),
    ]
)
