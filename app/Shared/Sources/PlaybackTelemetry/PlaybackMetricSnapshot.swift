import Foundation

public struct PlaybackMetricSnapshot: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let networkBytesPerSecond: Double
    public let readLatencyMilliseconds: Double
    public let cacheHitRatio: Double
    public let bufferedDurationSeconds: Double
    public let compressedQueueDepth: Int
    public let videoQueueDepth: Int
    public let decodeLatencyMilliseconds: Double
    public let presentedFrames: UInt64
    public let droppedFrames: UInt64
    public let stallCount: UInt64
    public let residentBytes: UInt64

    public init(
        timestamp: Date,
        networkBytesPerSecond: Double,
        readLatencyMilliseconds: Double,
        cacheHitRatio: Double,
        bufferedDurationSeconds: Double,
        compressedQueueDepth: Int,
        videoQueueDepth: Int,
        decodeLatencyMilliseconds: Double,
        presentedFrames: UInt64,
        droppedFrames: UInt64,
        stallCount: UInt64,
        residentBytes: UInt64
    ) {
        self.timestamp = timestamp
        self.networkBytesPerSecond = networkBytesPerSecond
        self.readLatencyMilliseconds = readLatencyMilliseconds
        self.cacheHitRatio = cacheHitRatio
        self.bufferedDurationSeconds = bufferedDurationSeconds
        self.compressedQueueDepth = compressedQueueDepth
        self.videoQueueDepth = videoQueueDepth
        self.decodeLatencyMilliseconds = decodeLatencyMilliseconds
        self.presentedFrames = presentedFrames
        self.droppedFrames = droppedFrames
        self.stallCount = stallCount
        self.residentBytes = residentBytes
    }
}
