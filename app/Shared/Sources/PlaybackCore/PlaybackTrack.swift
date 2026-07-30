import FFmpegKit
import Foundation
import SubtitleKit

public struct ExternalPlaybackSubtitle: Equatable, Sendable {
    public let identifier: String
    public let codecName: String
    public let language: String?
    public let title: String?
    public let cues: [SubtitleCue]

    public init(
        identifier: String,
        codecName: String,
        language: String?,
        title: String?,
        cues: [SubtitleCue]
    ) {
        self.identifier = identifier
        self.codecName = codecName
        self.language = language
        self.title = title
        self.cues = cues
    }
}

public struct PlaybackTrack: Equatable, Sendable, Identifiable {
    public let index: Int
    public let kind: MediaTrackKind
    public let codecName: String
    public let language: String?
    public let title: String?
    public let isSelected: Bool

    public var id: String { "\(kind.rawValue)-\(index)" }

    public init(
        index: Int,
        kind: MediaTrackKind,
        codecName: String,
        language: String?,
        title: String?,
        isSelected: Bool
    ) {
        self.index = index
        self.kind = kind
        self.codecName = codecName
        self.language = language
        self.title = title
        self.isSelected = isSelected
    }
}
