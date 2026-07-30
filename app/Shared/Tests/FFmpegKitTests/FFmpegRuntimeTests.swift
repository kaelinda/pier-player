import Testing
@testable import FFmpegKit

@Test func bundledRuntimeIsPinnedAndLGPLCompatible() throws {
    #expect(try FFmpegRuntime.version() == "8.1.2")
    #expect(try FFmpegRuntime.license() == "LGPL version 2.1 or later")

    let configuration = try FFmpegRuntime.configuration()
    #expect(!configuration.contains("--enable-gpl"))
    #expect(!configuration.contains("--enable-nonfree"))
    #expect(!configuration.contains("--enable-libx264"))
    #expect(!configuration.contains("--enable-libx265"))
}
