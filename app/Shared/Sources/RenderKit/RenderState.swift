import Foundation

public struct RenderState: Equatable, Sendable {
    public let rate: Float
    public let currentTime: TimeInterval
    public let pendingVideoDuration: TimeInterval
    public let pendingAudioDuration: TimeInterval

    public init(
        rate: Float,
        currentTime: TimeInterval,
        pendingVideoDuration: TimeInterval,
        pendingAudioDuration: TimeInterval
    ) {
        self.rate = rate
        self.currentTime = currentTime
        self.pendingVideoDuration = pendingVideoDuration
        self.pendingAudioDuration = pendingAudioDuration
    }
}

public enum RenderLane: Hashable, Sendable {
    case video
    case audio
}
