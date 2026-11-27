// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "DictationMac",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "DictationCore"),
        .executableTarget(name: "DictationMac", dependencies: ["DictationCore"]),
        .testTarget(name: "DictationCoreTests", dependencies: ["DictationCore"]),
        .testTarget(name: "DictationMacTests", dependencies: ["DictationMac", "DictationCore"]),
    ]
)
