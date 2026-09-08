// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DiskReclaim",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "ReclaimCore", resources: [.process("Resources")]),
        .executableTarget(name: "reclaim", dependencies: ["ReclaimCore"]),
        .executableTarget(name: "ReclaimTests", dependencies: ["ReclaimCore"]),
    ]
)
