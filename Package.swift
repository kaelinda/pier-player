// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PierPlayer",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "MediaSourceKit", targets: ["MediaSourceKit"]),
        .library(name: "StreamIOKit", targets: ["StreamIOKit"]),
        .library(name: "PlaybackCore", targets: ["PlaybackCore"]),
        .library(name: "PlaybackTelemetry", targets: ["PlaybackTelemetry"]),
        .executable(name: "PierPlayerApp", targets: ["PierPlayerApp"]),
    ],
    targets: [
        .target(name: "MediaSourceKit"),
        .target(
            name: "StreamIOKit",
            dependencies: ["MediaSourceKit"]
        ),
        .target(name: "PlaybackCore"),
        .target(name: "PlaybackTelemetry"),
        .executableTarget(
            name: "PierPlayerApp",
            dependencies: [
                "MediaSourceKit",
                "StreamIOKit",
                "PlaybackCore",
                "PlaybackTelemetry",
            ]
        ),
        .testTarget(
            name: "MediaSourceKitTests",
            dependencies: ["MediaSourceKit"]
        ),
        .testTarget(
            name: "StreamIOKitTests",
            dependencies: ["StreamIOKit", "MediaSourceKit"]
        ),
        .testTarget(
            name: "PlaybackCoreTests",
            dependencies: ["PlaybackCore"]
        ),
        .testTarget(
            name: "PlaybackTelemetryTests",
            dependencies: ["PlaybackTelemetry"]
        ),
    ]
)
