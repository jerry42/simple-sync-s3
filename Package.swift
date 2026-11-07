// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SimpleSyncS3",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "S5Core",
            path: "Sources/S5Core"
        ),
        .executableTarget(
            name: "SimpleSyncS3",
            dependencies: ["S5Core"],
            path: "Sources/SimpleSyncS3"
        ),
        .executableTarget(
            name: "s5-sync",
            dependencies: ["S5Core"],
            path: "Sources/s5-sync"
        ),
        .testTarget(
            name: "S5Tests",
            dependencies: ["S5Core"],
            path: "Tests/S5Tests"
        ),
    ]
)
