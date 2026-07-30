import CoreVideo
import Foundation
import Testing
@testable import FFmpegKit

@Test func representativeFormatsDecodeVideoAndNormalizedAudio() throws {
    for fileName in [
        "video-h264-aac.mkv",
        "video-h264-aac.mp4",
        "video-vp9-opus.webm",
        "video-mpeg4-mp3.avi",
        "video-mpeg2-ac3.ts",
    ] {
        let data = try Data(contentsOf: decodeFixtureURL(fileName))
        let session = try FFmpegSession(data: data)
        try session.prepareForDecoding()

        var videoSamples: [DecodedVideoSample] = []
        var audioSamples: [DecodedAudioSample] = []
        while let sample = try session.readNextSample() {
            switch sample {
            case let .video(video):
                videoSamples.append(video)
            case let .audio(audio):
                audioSamples.append(audio)
            case .subtitle:
                break
            }
        }

        #expect(!videoSamples.isEmpty)
        #expect(!audioSamples.isEmpty)
        #expect(videoSamples.allSatisfy { $0.duration > 0 })
        #expect(zip(videoSamples, videoSamples.dropFirst()).allSatisfy {
            $0.presentationTime <= $1.presentationTime
        })
        #expect(videoSamples.allSatisfy {
            CVPixelBufferGetWidth($0.pixelBuffer) == 320 &&
                CVPixelBufferGetHeight($0.pixelBuffer) == 180
        })

        #expect(audioSamples.allSatisfy { $0.sampleRate == 48_000 })
        #expect(audioSamples.allSatisfy { $0.channelCount == 2 })
        #expect(audioSamples.allSatisfy { $0.sampleCount > 0 })
        #expect(audioSamples.allSatisfy {
            $0.data.count == $0.sampleCount * $0.channelCount * MemoryLayout<Float>.size
        })
        #expect(zip(audioSamples, audioSamples.dropFirst()).allSatisfy {
            abs(($0.presentationTime + $0.duration) - $1.presentationTime) < 0.000_1
        })
        #expect(try session.readNextSample() == nil)
    }
}

@Test func h264AttemptsHardwareAndInjectedFailureFallsBackOnce() throws {
    let data = try Data(contentsOf: decodeFixtureURL("video-h264-aac.mkv"))

    let preferredSession = try FFmpegSession(data: data)
    try preferredSession.prepareForDecoding()
    let preferredStatus = try preferredSession.videoDecoderStatus()
    #expect(preferredStatus.hardwareAttempted)
    #expect([.videoToolbox, .software].contains(preferredStatus.mode))

    let fallbackSession = try FFmpegSession(data: data)
    try fallbackSession.prepareForDecoding(
        configuration: FFmpegDecodeConfiguration(forceHardwareOpenFailure: true)
    )
    let fallbackStatus = try fallbackSession.videoDecoderStatus()
    #expect(fallbackStatus.hardwareAttempted)
    #expect(fallbackStatus.mode == .software)
    #expect(fallbackStatus.softwareFallbackCount == 1)
    #expect(try firstVideoSample(from: fallbackSession) != nil)
}

@Test func cancellationAndClosePreventFurtherDecodeOutput() throws {
    let data = try Data(contentsOf: decodeFixtureURL("video-h264-aac.mkv"))

    let cancelledSession = try FFmpegSession(data: data)
    try cancelledSession.prepareForDecoding()
    cancelledSession.cancel()
    #expect(throws: FFmpegError.self) {
        _ = try cancelledSession.readNextSample()
    }

    let closedSession = try FFmpegSession(data: data)
    try closedSession.prepareForDecoding()
    closedSession.close()
    #expect(throws: FFmpegError.sessionClosed) {
        _ = try closedSession.readNextSample()
    }
}

@Test func embeddedTextSubtitleProducesTimedDecodeEvent() throws {
    let data = try Data(contentsOf: decodeFixtureURL("video-h264-aac-srt.mkv"))
    let session = try FFmpegSession(data: data)
    let metadata = try session.metadata()
    let subtitleTrack = try #require(metadata.tracks.first { $0.kind == .subtitle })
    #expect(subtitleTrack.codecName == "subrip")

    try session.prepareForDecoding()
    var subtitle: DecodedSubtitleSample?
    while let sample = try session.readNextSample() {
        if case let .subtitle(value) = sample {
            subtitle = value
            break
        }
    }

    let decoded = try #require(subtitle)
    #expect(decoded.text.contains("Pier Player subtitle fixture"))
    #expect(decoded.presentationTime >= 0.2)
    #expect(decoded.duration > 0)

    let offSession = try FFmpegSession(data: data)
    try offSession.prepareForDecoding()
    try offSession.selectSubtitleTrack(index: nil)
    var emittedSubtitle = false
    while let sample = try offSession.readNextSample() {
        if case .subtitle = sample {
            emittedSubtitle = true
        }
    }
    #expect(!emittedSubtitle)
}

private func firstVideoSample(from session: FFmpegSession) throws -> DecodedVideoSample? {
    while let sample = try session.readNextSample() {
        if case let .video(video) = sample {
            return video
        }
    }
    return nil
}

private func decodeFixtureURL(_ fileName: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
        .appendingPathComponent(fileName)
}
