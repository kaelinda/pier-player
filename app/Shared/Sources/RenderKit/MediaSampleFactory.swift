import CoreMedia
import FFmpegKit
import Foundation

public enum MediaSampleFactoryError: Error, Equatable, Sendable {
    case invalidVideoTiming
    case invalidAudioFormat
    case invalidAudioByteCount
    case coreMedia(OSStatus)
}

public enum MediaSampleFactory {
    public static func videoSample(
        from sample: DecodedVideoSample
    ) throws -> CMSampleBuffer {
        guard sample.presentationTime.isFinite,
              sample.presentationTime >= 0,
              sample.duration.isFinite,
              sample.duration > 0 else {
            throw MediaSampleFactoryError.invalidVideoTiming
        }

        var formatDescription: CMVideoFormatDescription?
        var status = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: sample.pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        guard status == noErr, let formatDescription else {
            throw MediaSampleFactoryError.coreMedia(status)
        }

        var timing = CMSampleTimingInfo(
            duration: mediaTime(sample.duration),
            presentationTimeStamp: mediaTime(sample.presentationTime),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: sample.pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            throw MediaSampleFactoryError.coreMedia(status)
        }
        return sampleBuffer
    }

    public static func audioSample(
        from sample: DecodedAudioSample
    ) throws -> CMSampleBuffer {
        guard sample.sampleCount > 0,
              sample.sampleRate > 0,
              sample.channelCount > 0,
              sample.presentationTime.isFinite,
              sample.presentationTime >= 0 else {
            throw MediaSampleFactoryError.invalidAudioFormat
        }

        let bytesPerFrame = sample.channelCount * MemoryLayout<Float>.size
        let expectedByteCount = sample.sampleCount * bytesPerFrame
        guard sample.data.count == expectedByteCount else {
            throw MediaSampleFactoryError.invalidAudioByteCount
        }

        var streamDescription = AudioStreamBasicDescription(
            mSampleRate: Double(sample.sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(bytesPerFrame),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(bytesPerFrame),
            mChannelsPerFrame: UInt32(sample.channelCount),
            mBitsPerChannel: UInt32(MemoryLayout<Float>.size * 8),
            mReserved: 0
        )
        var formatDescription: CMAudioFormatDescription?
        var status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &streamDescription,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        guard status == noErr, let formatDescription else {
            throw MediaSampleFactoryError.coreMedia(status)
        }

        var blockBuffer: CMBlockBuffer?
        status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: sample.data.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: sample.data.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let blockBuffer else {
            throw MediaSampleFactoryError.coreMedia(status)
        }
        status = sample.data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: sample.data.count
            )
        }
        guard status == noErr else {
            throw MediaSampleFactoryError.coreMedia(status)
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sample.sampleRate)),
            presentationTimeStamp: mediaTime(sample.presentationTime),
            decodeTimeStamp: .invalid
        )
        var sampleSize = bytesPerFrame
        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: sample.sampleCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            throw MediaSampleFactoryError.coreMedia(status)
        }
        return sampleBuffer
    }

    private static func mediaTime(_ seconds: TimeInterval) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 1_000_000)
    }
}
