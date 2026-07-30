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
        .library(name: "FFmpegKit", targets: ["FFmpegKit"]),
        .library(name: "RenderKit", targets: ["RenderKit"]),
        .library(name: "SubtitleKit", targets: ["SubtitleKit"]),
        .executable(name: "PierPlayerApp", targets: ["PierPlayerApp"]),
        .executable(name: "SMBProbe", targets: ["SMBProbe"]),
        .executable(name: "DiagnosticsReport", targets: ["DiagnosticsReport"]),
        .executable(name: "PlaybackProbe", targets: ["PlaybackProbe"]),
    ],
    targets: [
        .binaryTarget(
            name: "PierFFmpeg",
            path: "Vendor/FFmpeg/PierFFmpeg.xcframework"
        ),
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
            dependencies: ["DiagnosticsKit", "MediaSourceKit", "CLibSMB2"],
            path: "Shared/Sources/SMBSourceKit",
            linkerSettings: [
                .linkedFramework("Security"),
            ]
        ),
        .target(
            name: "StreamIOKit",
            dependencies: ["DiagnosticsKit", "MediaSourceKit"],
            path: "Shared/Sources/StreamIOKit"
        ),
        .target(
            name: "PlaybackCore",
            dependencies: [
                "DiagnosticsKit",
                "MediaSourceKit",
                "StreamIOKit",
                "FFmpegKit",
                "RenderKit",
                "SubtitleKit",
            ],
            path: "Shared/Sources/PlaybackCore"
        ),
        .target(
            name: "PlaybackTelemetry",
            dependencies: ["DiagnosticsKit"],
            path: "Shared/Sources/PlaybackTelemetry"
        ),
        .target(
            name: "FFmpegKit",
            dependencies: ["PierFFmpeg", "MediaSourceKit", "StreamIOKit"],
            path: "Shared/Sources/FFmpegKit"
        ),
        .target(
            name: "RenderKit",
            dependencies: ["FFmpegKit"],
            path: "Shared/Sources/RenderKit",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
            ]
        ),
        .target(
            name: "SubtitleKit",
            dependencies: ["MediaSourceKit"],
            path: "Shared/Sources/SubtitleKit"
        ),
        .executableTarget(
            name: "PierPlayerApp",
            dependencies: [
                "MediaSourceKit",
                "DiagnosticsKit",
                "StreamIOKit",
                "PlaybackCore",
                "PlaybackTelemetry",
                "FFmpegKit",
                "RenderKit",
                "SMBSourceKit",
                "SubtitleKit",
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
        .executableTarget(
            name: "DiagnosticsReport",
            dependencies: ["DiagnosticsKit"],
            path: "Tools/DiagnosticsReport"
        ),
        .testTarget(
            name: "DiagnosticsKitTests",
            dependencies: ["DiagnosticsKit"],
            path: "Shared/Tests/DiagnosticsKitTests"
        ),
        .executableTarget(
            name: "PlaybackProbe",
            dependencies: [
                "FFmpegKit",
                "MediaSourceKit",
            ],
            path: "Tools/PlaybackProbe"
        ),
        .testTarget(
            name: "MediaSourceKitTests",
            dependencies: ["MediaSourceKit"],
            path: "Shared/Tests/MediaSourceKitTests"
        ),
        .testTarget(
            name: "StreamIOKitTests",
            dependencies: ["DiagnosticsKit", "StreamIOKit", "MediaSourceKit"],
            path: "Shared/Tests/StreamIOKitTests"
        ),
        .testTarget(
            name: "SMBSourceKitTests",
            dependencies: ["DiagnosticsKit", "SMBSourceKit"],
            path: "Shared/Tests/SMBSourceKitTests"
        ),
        .testTarget(
            name: "PlaybackCoreTests",
            dependencies: [
                "DiagnosticsKit",
                "PlaybackCore",
                "MediaSourceKit",
                "RenderKit",
                "SubtitleKit",
            ],
            path: "Shared/Tests/PlaybackCoreTests"
        ),
        .testTarget(
            name: "PlaybackTelemetryTests",
            dependencies: ["DiagnosticsKit", "PlaybackTelemetry"],
            path: "Shared/Tests/PlaybackTelemetryTests"
        ),
        .testTarget(
            name: "FFmpegKitTests",
            dependencies: ["FFmpegKit", "MediaSourceKit", "StreamIOKit"],
            path: "Shared/Tests/FFmpegKitTests"
        ),
        .testTarget(
            name: "RenderKitTests",
            dependencies: ["RenderKit", "FFmpegKit"],
            path: "Shared/Tests/RenderKitTests"
        ),
        .testTarget(
            name: "SubtitleKitTests",
            dependencies: ["SubtitleKit", "MediaSourceKit"],
            path: "Shared/Tests/SubtitleKitTests"
        ),
        .testTarget(
            name: "PierPlayerAppTests",
            dependencies: [
                "DiagnosticsKit",
                "PierPlayerApp",
                "FFmpegKit",
                "MediaSourceKit",
                "PlaybackCore",
                "RenderKit",
                "SMBSourceKit",
            ],
            path: "macOS/Tests/PierPlayerAppTests"
        ),
    ]
)
