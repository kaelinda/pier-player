import FFmpegKit
import Foundation

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
