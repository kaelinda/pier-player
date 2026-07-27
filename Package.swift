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
        .library(name: "SMBSourceKit", targets: ["SMBSourceKit"]),
        .executable(name: "PierPlayerApp", targets: ["PierPlayerApp"]),
    ],
    targets: [
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
        .target(name: "MediaSourceKit"),
        .target(
            name: "SMBSourceKit",
            dependencies: ["MediaSourceKit", "CLibSMB2"],
            linkerSettings: [
                .linkedFramework("Security"),
            ]
        ),
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
                "SMBSourceKit",
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
            name: "SMBSourceKitTests",
            dependencies: ["SMBSourceKit"]
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
