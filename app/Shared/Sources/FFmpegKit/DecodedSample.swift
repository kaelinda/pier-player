import CoreVideo
import Foundation

public enum VideoDecoderMode: String, Equatable, Sendable {
    case none
    case videoToolbox
    case software
}

public struct FFmpegDecodeConfiguration: Equatable, Sendable {
    public let preferHardware: Bool
    public let forceHardwareOpenFailure: Bool

    public init(
        preferHardware: Bool = true,
        forceHardwareOpenFailure: Bool = false
    ) {
        self.preferHardware = preferHardware
        self.forceHardwareOpenFailure = forceHardwareOpenFailure
    }

    public static let `default` = FFmpegDecodeConfiguration()
}

public struct VideoDecoderStatus: Equatable, Sendable {
    public let mode: VideoDecoderMode
    public let hardwareAttempted: Bool
    public let softwareFallbackCount: Int

    public init(
        mode: VideoDecoderMode,
        hardwareAttempted: Bool,
        softwareFallbackCount: Int
    ) {
        self.mode = mode
        self.hardwareAttempted = hardwareAttempted
        self.softwareFallbackCount = softwareFallbackCount
    }
}

public struct DecodedVideoSample: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    public let presentationTime: TimeInterval
    public let duration: TimeInterval
    public let streamIndex: Int

    public init(
        pixelBuffer: CVPixelBuffer,
        presentationTime: TimeInterval,
        duration: TimeInterval,
        streamIndex: Int
    ) {
        self.pixelBuffer = pixelBuffer
        self.presentationTime = presentationTime
        self.duration = duration
        self.streamIndex = streamIndex
    }
}

public struct DecodedAudioSample: Equatable, Sendable {
    public let data: Data
    public let presentationTime: TimeInterval
    public let duration: TimeInterval
    public let sampleCount: Int
    public let sampleRate: Int
    public let channelCount: Int
    public let streamIndex: Int

    public init(
        data: Data,
        presentationTime: TimeInterval,
        duration: TimeInterval,
        sampleCount: Int,
        sampleRate: Int,
        channelCount: Int,
        streamIndex: Int
    ) {
        self.data = data
        self.presentationTime = presentationTime
        self.duration = duration
        self.sampleCount = sampleCount
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.streamIndex = streamIndex
    }
}

public struct DecodedSubtitleSample: Equatable, Sendable {
    public let text: String
    public let presentationTime: TimeInterval
    public let duration: TimeInterval
    public let streamIndex: Int

    public init(
        text: String,
        presentationTime: TimeInterval,
        duration: TimeInterval,
        streamIndex: Int
    ) {
        self.text = text
        self.presentationTime = presentationTime
        self.duration = duration
        self.streamIndex = streamIndex
    }
}

public enum DecodedSample: @unchecked Sendable {
    case video(DecodedVideoSample)
    case audio(DecodedAudioSample)
    case subtitle(DecodedSubtitleSample)
}
