import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import FFmpegKit
@testable import RenderKit

@MainActor
@Test func rendererUsesOneSynchronizerAndControlsTimeline() throws {
    let renderer = SampleBufferRenderer(maximumPendingDuration: 1)
    #expect(renderer.attachedRendererCount == 2)
    #expect(renderer.state.rate == 0)

    renderer.play(at: 0.5)
    #expect(renderer.state.rate == 1)
    renderer.pause()
    #expect(renderer.state.rate == 0)

    renderer.flush(at: 0.75)
    #expect(renderer.state.rate == 0)
    #expect(renderer.state.pendingVideoDuration == 0)
    #expect(renderer.state.pendingAudioDuration == 0)
}

@MainActor
@Test func rendererRejectsSamplesBeyondPendingDurationLimit() throws {
    let renderer = SampleBufferRenderer(maximumPendingDuration: 0.05)
    let first = try makeAudioSample(presentationTime: 0, duration: 0.04)
    let second = try makeAudioSample(presentationTime: 0.04, duration: 0.04)

    #expect(renderer.enqueueAudio(first))
    #expect(renderer.state.pendingAudioDuration >= 0.039)
    #expect(!renderer.enqueueAudio(second))
    renderer.flush(at: 0)
    #expect(renderer.enqueueAudio(second))
}

private func makeAudioSample(
    presentationTime: TimeInterval,
    duration: TimeInterval
) throws -> CMSampleBuffer {
    let sampleCount = Int(duration * 48_000)
    return try MediaSampleFactory.audioSample(
        from: DecodedAudioSample(
            data: Data(repeating: 0, count: sampleCount * 2 * MemoryLayout<Float>.size),
            presentationTime: presentationTime,
            duration: duration,
            sampleCount: sampleCount,
            sampleRate: 48_000,
            channelCount: 2,
            streamIndex: 1
        )
    )
}
