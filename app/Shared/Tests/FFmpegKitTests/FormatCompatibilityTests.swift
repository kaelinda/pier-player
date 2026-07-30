import Foundation
import MediaSourceKit
import Testing
@testable import FFmpegKit

@Test func committedFormatsDecodeSeekAndReachCleanEOFThroughStreamingIO() async throws {
    struct ExpectedFormat {
        let fileName: String
        let containerFragment: String
        let videoCodec: String
        let audioCodec: String
    }

    let formats = [
        ExpectedFormat(fileName: "video-h264-aac.mkv", containerFragment: "matroska", videoCodec: "h264", audioCodec: "aac"),
        ExpectedFormat(fileName: "video-h264-aac.mp4", containerFragment: "mov", videoCodec: "h264", audioCodec: "aac"),
        ExpectedFormat(fileName: "video-vp9-opus.webm", containerFragment: "matroska", videoCodec: "vp9", audioCodec: "opus"),
        ExpectedFormat(fileName: "video-mpeg4-mp3.avi", containerFragment: "avi", videoCodec: "mpeg4", audioCodec: "mp3"),
        ExpectedFormat(fileName: "video-mpeg2-ac3.ts", containerFragment: "mpegts", videoCodec: "mpeg2video", audioCodec: "ac3"),
    ]

    for expected in formats {
        let file = try CompatibilityFixtureFile(url: compatibilityFixtureURL(expected.fileName))
        let result = try await PlaybackCompatibilityProbe.run(
            file: file,
            inputID: expected.fileName,
            options: PlaybackProbeOptions(seekTime: 1, videoFrameLimit: nil)
        )

        #expect(result.containerName.contains(expected.containerFragment))
        #expect(result.selectedVideoCodec == expected.videoCodec)
        #expect(result.selectedAudioCodec == expected.audioCodec)
        #expect(result.decoderMode != .none)
        #expect(result.videoSampleCount > 0)
        #expect(result.audioSampleCount > 0)
        #expect(result.videoTimestampsMonotonic)
        #expect(result.audioTimestampsMonotonic)
        #expect(result.firstVideoTime.map { $0 >= 1 } == true)
        #expect(result.seekCompleted)
        #expect(result.seekLatencyMilliseconds != nil)
        #expect(result.reachedEOF)
        #expect(result.errors.isEmpty)
        #expect(await file.closeCount == 1)
    }
}

private actor CompatibilityFixtureFile: MediaReadableFile {
    nonisolated let identity: MediaFileIdentity
    private let data: Data
    private(set) var closeCount = 0

    init(url: URL) throws {
        data = try Data(contentsOf: url)
        identity = MediaFileIdentity(
            sourceID: UUID(),
            path: "/redacted/fixture",
            size: Int64(data.count),
            modifiedAt: nil
        )
    }

    func read(at offset: Int64, length: Int) async throws -> Data {
        guard offset >= 0, length > 0, offset < identity.size else { return Data() }
        let start = Int(offset)
        let end = min(start + length, data.count)
        return data.subdata(in: start..<end)
    }

    func close() async {
        closeCount += 1
    }
}

private func compatibilityFixtureURL(_ fileName: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
        .appendingPathComponent(fileName)
}
