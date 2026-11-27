// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ezNTFS",
    defaultLocalization: "en",
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "ezNTFS", targets: ["EzNTFSApp"]),
        .executable(name: "ezntfs-tool", targets: ["EzNTFSCLI"]),
        .executable(name: "ezntfs-service", targets: ["EzNTFSService"]),
    ],
    targets: [
        .systemLibrary(name: "CRemoveFile"),
        .target(name: "EzNTFSCore", dependencies: ["CRemoveFile"]),
        .executableTarget(name: "EzNTFSApp", dependencies: ["EzNTFSCore"], resources: [.process("Resources")]),
        .executableTarget(name: "EzNTFSCLI", dependencies: ["EzNTFSCore"]),
        .executableTarget(name: "EzNTFSService", dependencies: ["EzNTFSCore"]),
        .testTarget(name: "EzNTFSCoreTests", dependencies: ["EzNTFSCore"]),
    ]
)
