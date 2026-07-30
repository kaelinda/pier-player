import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import FFmpegKit
@testable import RenderKit

@Test func videoSampleRetainsPixelBufferAndExactTiming() throws {
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        16,
        9,
        kCVPixelFormatType_32BGRA,
        nil,
        &pixelBuffer
    )
    #expect(status == kCVReturnSuccess)
    let buffer = try #require(pixelBuffer)
    let decoded = DecodedVideoSample(
        pixelBuffer: buffer,
        presentationTime: 1.25,
        duration: 1.0 / 24,
        streamIndex: 0
    )

    let sample = try MediaSampleFactory.videoSample(from: decoded)

    #expect(CMSampleBufferGetImageBuffer(sample) === buffer)
    #expect(abs(CMSampleBufferGetPresentationTimeStamp(sample).seconds - 1.25) < 0.000_001)
    #expect(abs(CMSampleBufferGetDuration(sample).seconds - (1.0 / 24)) < 0.000_001)
}

@Test func audioSampleUsesFloat32StereoFramesAndRejectsMismatchedBytes() throws {
    let sampleCount = 480
    let bytes = Data(repeating: 0, count: sampleCount * 2 * MemoryLayout<Float>.size)
    let decoded = DecodedAudioSample(
        data: bytes,
        presentationTime: 0.5,
        duration: 0.01,
        sampleCount: sampleCount,
        sampleRate: 48_000,
        channelCount: 2,
        streamIndex: 1
    )

    let sample = try MediaSampleFactory.audioSample(from: decoded)

    #expect(CMSampleBufferGetNumSamples(sample) == sampleCount)
    #expect(abs(CMSampleBufferGetPresentationTimeStamp(sample).seconds - 0.5) < 0.000_001)
    #expect(abs(CMSampleBufferGetDuration(sample).seconds - 0.01) < 0.000_001)

    let malformed = DecodedAudioSample(
        data: Data(repeating: 0, count: 7),
        presentationTime: 0,
        duration: 0.01,
        sampleCount: 1,
        sampleRate: 48_000,
        channelCount: 2,
        streamIndex: 1
    )
    #expect(throws: MediaSampleFactoryError.invalidAudioByteCount) {
        _ = try MediaSampleFactory.audioSample(from: malformed)
    }
}
