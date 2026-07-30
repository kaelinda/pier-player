import Foundation
import Testing
@testable import FFmpegKit

@Test func seekAdvancesGenerationAndDropsPrerollSamples() throws {
    let session = try seekFixtureSession()
    let originalCandidate = try firstSeekVideoSample(from: session)
    let original = try #require(originalCandidate)
    #expect(original.generation == 0)

    let generation = try session.seek(to: 1)
    let soughtCandidate = try firstSeekVideoSample(from: session)
    let sought = try #require(soughtCandidate)
    #expect(generation == 1)
    #expect(sought.generation == generation)
    #expect(sought.presentationTime >= 1)
    #expect(session.currentGeneration == generation)
}

@Test func repeatedSeekAndAudioSelectionInvalidateOlderGenerations() throws {
    let session = try seekFixtureSession()
    let metadata = try session.metadata()
    let audioTrack = try #require(metadata.tracks.first { $0.kind == .audio })

    _ = try session.seek(to: 0.25)
    let secondSeek = try session.seek(to: 1)
    #expect(secondSeek == 2)

    let selected = try session.selectAudioTrack(index: audioTrack.index, at: 1)
    #expect(selected == 3)
    let audioCandidate = try firstSeekAudioSample(from: session)
    let audio = try #require(audioCandidate)
    #expect(audio.generation == selected)
    #expect(audio.presentationTime >= 1)

    #expect(throws: FFmpegError.self) {
        _ = try session.selectAudioTrack(index: 999, at: 1)
    }
    #expect(session.currentGeneration == selected)
}

private func seekFixtureSession() throws -> FFmpegSession {
    let data = try Data(contentsOf: seekFixtureURL("video-h264-aac.mkv"))
    let session = try FFmpegSession(data: data)
    try session.prepareForDecoding()
    return session
}

private func firstSeekVideoSample(from session: FFmpegSession) throws -> DecodedVideoSample? {
    while let sample = try session.readNextSample() {
        if case let .video(video) = sample { return video }
    }
    return nil
}

private func firstSeekAudioSample(from session: FFmpegSession) throws -> DecodedAudioSample? {
    while let sample = try session.readNextSample() {
        if case let .audio(audio) = sample { return audio }
    }
    return nil
}

private func seekFixtureURL(_ fileName: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
        .appendingPathComponent(fileName)
}
