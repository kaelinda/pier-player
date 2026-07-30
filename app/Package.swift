// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PierPlayer",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "DiagnosticsKit", targets: ["DiagnosticsKit"]),
        .library(name: "MediaSourceKit", targets: ["MediaSourceKit"]),
        .library(name: "StreamIOKit", targets: ["StreamIOKit"]),
        .library(name: "PlaybackCore", targets: ["PlaybackCore"]),
        .library(name: "PlaybackTelemetry", targets: ["PlaybackTelemetry"]),
        .library(name: "SMBSourceKit", targets: ["SMBSourceKit"]),
        .executable(name: "PierPlayerApp", targets: ["PierPlayerApp"]),
        .executable(name: "SMBProbe", targets: ["SMBProbe"]),
    ],
    targets: [
        .target(
            name: "DiagnosticsKit",
            path: "Shared/Sources/DiagnosticsKit",
            linkerSettings: [
                .linkedFramework("Security"),
            ]
        ),
        .target(
            name: "CLibSMB2",
            path: "Vendor/libsmb2",
            exclude: [
                "lib/CMakeLists.txt",
                "lib/libsmb2.syms",
                "lib/Makefile.am",
                "lib/Makefile.AMIGA",
                "lib/Makefile.AMIGA_AROS",
                "lib/Makefile.AMIGA_OS3",
                "lib/Makefile.PS3_PPU",
                "lib/ps2",
            ],
            sources: ["lib"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include"),
                .headerSearchPath("include/apple"),
                .headerSearchPath("include/smb2"),
                .headerSearchPath("lib"),
                .define("_U_", to: "__attribute__((unused))"),
                .define("HAVE_CONFIG_H", to: "1"),
            ]
        ),
        .target(
            name: "MediaSourceKit",
            path: "Shared/Sources/MediaSourceKit"
        ),
        .target(
            name: "SMBSourceKit",
            dependencies: ["MediaSourceKit", "CLibSMB2"],
            path: "Shared/Sources/SMBSourceKit",
            linkerSettings: [
                .linkedFramework("Security"),
            ]
        ),
        .target(
            name: "StreamIOKit",
            dependencies: ["MediaSourceKit"],
            path: "Shared/Sources/StreamIOKit"
        ),
        .target(
            name: "PlaybackCore",
            path: "Shared/Sources/PlaybackCore"
        ),
        .target(
            name: "PlaybackTelemetry",
            path: "Shared/Sources/PlaybackTelemetry"
        ),
        .executableTarget(
            name: "PierPlayerApp",
            dependencies: [
                "MediaSourceKit",
                "StreamIOKit",
                "PlaybackCore",
                "PlaybackTelemetry",
                "SMBSourceKit",
            ],
            path: "macOS/Sources/PierPlayerApp"
        ),
        .executableTarget(
            name: "SMBProbe",
            dependencies: [
                "MediaSourceKit",
                "SMBSourceKit",
                "StreamIOKit",
            ],
            path: "Tools/SMBProbe"
        ),
        .testTarget(
            name: "DiagnosticsKitTests",
            dependencies: ["DiagnosticsKit"],
            path: "Shared/Tests/DiagnosticsKitTests"
        ),
        .testTarget(
            name: "MediaSourceKitTests",
            dependencies: ["MediaSourceKit"],
            path: "Shared/Tests/MediaSourceKitTests"
        ),
        .testTarget(
            name: "StreamIOKitTests",
            dependencies: ["StreamIOKit", "MediaSourceKit"],
            path: "Shared/Tests/StreamIOKitTests"
        ),
        .testTarget(
            name: "SMBSourceKitTests",
            dependencies: ["SMBSourceKit"],
            path: "Shared/Tests/SMBSourceKitTests"
        ),
        .testTarget(
            name: "PlaybackCoreTests",
            dependencies: ["PlaybackCore"],
            path: "Shared/Tests/PlaybackCoreTests"
        ),
        .testTarget(
            name: "PlaybackTelemetryTests",
            dependencies: ["PlaybackTelemetry"],
            path: "Shared/Tests/PlaybackTelemetryTests"
        ),
        .testTarget(
            name: "PierPlayerAppTests",
            dependencies: ["PierPlayerApp"],
            path: "macOS/Tests/PierPlayerAppTests"
        ),
    ]
)
