import Foundation
import PierFFmpeg
import Testing
@testable import FFmpegKit

@Test func representativeContainersProbeThroughCustomAVIO() throws {
    struct ExpectedMedia {
        let fileName: String
        let containerFragment: String
        let videoCodec: String
        let audioCodec: String
    }

    let fixtures = [
        ExpectedMedia(
            fileName: "video-h264-aac.mkv",
            containerFragment: "matroska",
            videoCodec: "h264",
            audioCodec: "aac"
        ),
        ExpectedMedia(
            fileName: "video-h264-aac.mp4",
            containerFragment: "mov",
            videoCodec: "h264",
            audioCodec: "aac"
        ),
        ExpectedMedia(
            fileName: "video-vp9-opus.webm",
            containerFragment: "matroska",
            videoCodec: "vp9",
            audioCodec: "opus"
        ),
        ExpectedMedia(
            fileName: "video-mpeg4-mp3.avi",
            containerFragment: "avi",
            videoCodec: "mpeg4",
            audioCodec: "mp3"
        ),
        ExpectedMedia(
            fileName: "video-mpeg2-ac3.ts",
            containerFragment: "mpegts",
            videoCodec: "mpeg2video",
            audioCodec: "ac3"
        ),
    ]

    for expected in fixtures {
        let data = try Data(contentsOf: fixtureURL(expected.fileName))
        let session = try FFmpegSession(data: data)
        let metadata = try session.metadata()

        #expect(metadata.containerName.contains(expected.containerFragment))
        #expect(metadata.duration >= 1 && metadata.duration <= 3)
        #expect(metadata.isSeekable)

        let video = try #require(metadata.tracks.first { $0.kind == .video })
        #expect(video.codecName == expected.videoCodec)
        #expect(video.width == 320)
        #expect(video.height == 180)
        #expect(video.isDefault)

        let audio = try #require(metadata.tracks.first { $0.kind == .audio })
        #expect(audio.codecName == expected.audioCodec)
        #expect(audio.sampleRate == 48_000)
        #expect(audio.channelCount == 1)
        #expect(audio.isDefault)

        session.close()
        session.close()
    }
}

@Test func malformedInputFailsWithTypedError() {
    #expect(throws: FFmpegError.self) {
        _ = try FFmpegSession(data: Data("not media".utf8))
    }
}

@Test func exhaustedProbeBudgetFailsWithoutReadingPastLimit() throws {
    let data = try Data(contentsOf: fixtureURL("video-h264-aac.mkv"))
    let source = CountingByteSource(data: data)

    #expect(throws: FFmpegError.self) {
        _ = try FFmpegSession(
            source: source,
            limits: FFmpegProbeLimits(
                maximumBytes: 64,
                maximumDuration: 1
            )
        )
    }
    #expect(source.totalBytesRead <= 64)
}

@Test func elapsedProbeBudgetInterruptsSlowInput() throws {
    let data = try Data(contentsOf: fixtureURL("video-h264-aac.mkv"))
    let source = SlowByteSource(data: data, delay: 0.02)

    #expect(throws: FFmpegError.self) {
        _ = try FFmpegSession(
            source: source,
            limits: FFmpegProbeLimits(
                maximumBytes: Int64(data.count),
                maximumDuration: 0.001
            )
        )
    }
}

@Test func invalidSeekIsRejectedWithoutMovingPosition() throws {
    let source = CountingByteSource(data: Data(repeating: 0, count: 16))
    let bridge = FFmpegIOBridge(source: source, limits: .default)
    let callbacks = bridge.callbacks
    let seek = try #require(callbacks.seek)

    let invalidResult = seek(callbacks.opaque, 17, SEEK_SET)
    #expect(invalidResult == Int64(PPFF_ERROR_INVALID_ARGUMENT))
    #expect(seek(callbacks.opaque, 0, SEEK_CUR) == 0)
}

private func fixtureURL(_ fileName: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
        .appendingPathComponent(fileName)
}

private final class CountingByteSource: FFmpegByteSource, @unchecked Sendable {
    let size: Int64
    private let data: Data
    private let lock = NSLock()
    private var byteCount = 0

    var totalBytesRead: Int {
        lock.withLock { byteCount }
    }

    init(data: Data) {
        self.data = data
        self.size = Int64(data.count)
    }

    func read(at offset: Int64, length: Int) throws -> Data {
        let lowerBound = Int(offset)
        let upperBound = min(lowerBound + length, data.count)
        guard lowerBound >= 0, lowerBound < upperBound else { return Data() }
        let result = data.subdata(in: lowerBound..<upperBound)
        lock.withLock {
            byteCount += result.count
        }
        return result
    }
}

private final class SlowByteSource: FFmpegByteSource, @unchecked Sendable {
    let size: Int64
    private let data: Data
    private let delay: TimeInterval

    init(data: Data, delay: TimeInterval) {
        self.data = data
        self.delay = delay
        self.size = Int64(data.count)
    }

    func read(at offset: Int64, length: Int) throws -> Data {
        Thread.sleep(forTimeInterval: delay)
        let lowerBound = Int(offset)
        let upperBound = min(lowerBound + length, data.count)
        guard lowerBound >= 0, lowerBound < upperBound else { return Data() }
        return data.subdata(in: lowerBound..<upperBound)
    }
}
