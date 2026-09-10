// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacDuo",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "LidAngleKit",
            path: "Sources/LidAngleKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "MacDuo",
            dependencies: ["LidAngleKit"],
            path: "Sources/MacDuo",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "lidprobe",
            dependencies: ["LidAngleKit"],
            path: "Sources/lidprobe",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
