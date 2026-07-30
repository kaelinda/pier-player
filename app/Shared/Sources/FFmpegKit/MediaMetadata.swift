import Foundation

public enum MediaTrackKind: String, Equatable, Codable, Sendable {
    case video
    case audio
    case subtitle
    case unknown
}

public struct MediaTrack: Equatable, Sendable, Identifiable {
    public let index: Int
    public let kind: MediaTrackKind
    public let codecID: Int
    public let codecName: String
    public let language: String?
    public let title: String?
    public let width: Int
    public let height: Int
    public let sampleRate: Int
    public let channelCount: Int
    public let isDefault: Bool

    public var id: Int { index }

    public init(
        index: Int,
        kind: MediaTrackKind,
        codecID: Int,
        codecName: String,
        language: String?,
        title: String?,
        width: Int,
        height: Int,
        sampleRate: Int,
        channelCount: Int,
        isDefault: Bool
    ) {
        self.index = index
        self.kind = kind
        self.codecID = codecID
        self.codecName = codecName
        self.language = language
        self.title = title
        self.width = width
        self.height = height
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.isDefault = isDefault
    }
}

public struct MediaMetadata: Equatable, Sendable {
    public let containerName: String
    public let duration: TimeInterval
    public let isSeekable: Bool
    public let tracks: [MediaTrack]

    public init(
        containerName: String,
        duration: TimeInterval,
        isSeekable: Bool,
        tracks: [MediaTrack]
    ) {
        self.containerName = containerName
        self.duration = duration
        self.isSeekable = isSeekable
        self.tracks = tracks
    }
}

public struct FFmpegProbeLimits: Equatable, Sendable {
    public let maximumBytes: Int64
    public let maximumDuration: TimeInterval

    public init(maximumBytes: Int64, maximumDuration: TimeInterval) {
        self.maximumBytes = maximumBytes
        self.maximumDuration = maximumDuration
    }

    public static let `default` = FFmpegProbeLimits(
        maximumBytes: 5 * 1024 * 1024,
        maximumDuration: 5
    )
}
