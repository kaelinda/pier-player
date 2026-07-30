import FFmpegKit
import Foundation

public struct PlaybackCoordinatorSnapshot: Equatable, Sendable {
    public let sessionID: UUID?
    public let generation: UInt64
    public let state: PlaybackState
    public let intendsToPlay: Bool
    public let position: TimeInterval
    public let duration: TimeInterval
    public let videoDecoderMode: VideoDecoderMode
    public let tracks: [PlaybackTrack]
    public let subtitleText: String?
    public let failure: PlaybackFailure?

    public init(
        sessionID: UUID?,
        generation: UInt64,
        state: PlaybackState,
        intendsToPlay: Bool,
        position: TimeInterval,
        duration: TimeInterval,
        videoDecoderMode: VideoDecoderMode,
        tracks: [PlaybackTrack],
        subtitleText: String?,
        failure: PlaybackFailure?
    ) {
        self.sessionID = sessionID
        self.generation = generation
        self.state = state
        self.intendsToPlay = intendsToPlay
        self.position = position
        self.duration = duration
        self.videoDecoderMode = videoDecoderMode
        self.tracks = tracks
        self.subtitleText = subtitleText
        self.failure = failure
    }

    public static let idle = PlaybackCoordinatorSnapshot(
        sessionID: nil,
        generation: 0,
        state: .idle,
        intendsToPlay: false,
        position: 0,
        duration: 0,
        videoDecoderMode: .none,
        tracks: [],
        subtitleText: nil,
        failure: nil
    )
}

public struct PlaybackCoordinatorConfiguration: Sendable {
    public let pageSize: Int
    public let cacheCapacityBytes: Int
    public let ioTimeout: TimeInterval
    public let videoQueueLimits: BoundedMediaQueueLimits
    public let audioQueueLimits: BoundedMediaQueueLimits
    public let startupVideoDuration: TimeInterval
    public let startupAudioDuration: TimeInterval
    public let maximumRetryAttempts: Int
    public let maximumRetryDuration: TimeInterval

    public init(
        pageSize: Int,
        cacheCapacityBytes: Int,
        ioTimeout: TimeInterval,
        videoQueueLimits: BoundedMediaQueueLimits,
        audioQueueLimits: BoundedMediaQueueLimits,
        startupVideoDuration: TimeInterval,
        startupAudioDuration: TimeInterval,
        maximumRetryAttempts: Int,
        maximumRetryDuration: TimeInterval
    ) {
        self.pageSize = pageSize
        self.cacheCapacityBytes = cacheCapacityBytes
        self.ioTimeout = ioTimeout
        self.videoQueueLimits = videoQueueLimits
        self.audioQueueLimits = audioQueueLimits
        self.startupVideoDuration = startupVideoDuration
        self.startupAudioDuration = startupAudioDuration
        self.maximumRetryAttempts = maximumRetryAttempts
        self.maximumRetryDuration = maximumRetryDuration
    }

    public static let `default` = PlaybackCoordinatorConfiguration(
        pageSize: 256 * 1024,
        cacheCapacityBytes: 32 * 1024 * 1024,
        ioTimeout: 10,
        videoQueueLimits: BoundedMediaQueueLimits(
            high: MediaQueueWatermark(itemCount: 48, byteCount: 128 * 1024 * 1024, duration: 3),
            low: MediaQueueWatermark(itemCount: 12, byteCount: 32 * 1024 * 1024, duration: 0.75)
        ),
        audioQueueLimits: BoundedMediaQueueLimits(
            high: MediaQueueWatermark(itemCount: 128, byteCount: 16 * 1024 * 1024, duration: 3),
            low: MediaQueueWatermark(itemCount: 32, byteCount: 4 * 1024 * 1024, duration: 0.75)
        ),
        startupVideoDuration: 0.25,
        startupAudioDuration: 0.25,
        maximumRetryAttempts: 3,
        maximumRetryDuration: 15
    )

    public static let test = PlaybackCoordinatorConfiguration(
        pageSize: 16 * 1024,
        cacheCapacityBytes: 1024 * 1024,
        ioTimeout: 1,
        videoQueueLimits: BoundedMediaQueueLimits(
            high: MediaQueueWatermark(itemCount: 48, byteCount: 32 * 1024 * 1024, duration: 3),
            low: MediaQueueWatermark(itemCount: 4, byteCount: 1024 * 1024, duration: 0.05)
        ),
        audioQueueLimits: BoundedMediaQueueLimits(
            high: MediaQueueWatermark(itemCount: 128, byteCount: 4 * 1024 * 1024, duration: 3),
            low: MediaQueueWatermark(itemCount: 8, byteCount: 256 * 1024, duration: 0.05)
        ),
        startupVideoDuration: 0.02,
        startupAudioDuration: 0.02,
        maximumRetryAttempts: 1,
        maximumRetryDuration: 1
    )
}
