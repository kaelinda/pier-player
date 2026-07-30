import Foundation

public struct SubtitleCue: Equatable, Sendable, Identifiable {
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let text: String

    public var id: String {
        "\(startTime)-\(endTime)-\(text)"
    }

    public init(startTime: TimeInterval, endTime: TimeInterval, text: String) {
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
    }
}

public enum SubtitleFormat: String, Equatable, Sendable {
    case subRip
    case webVTT
    case ass
}

public struct SubtitleParseWarning: Equatable, Sendable {
    public let line: Int
    public let message: String

    public init(line: Int, message: String) {
        self.line = line
        self.message = message
    }
}

public struct SubtitleParseResult: Equatable, Sendable {
    public let cues: [SubtitleCue]
    public let warnings: [SubtitleParseWarning]

    public init(cues: [SubtitleCue], warnings: [SubtitleParseWarning]) {
        self.cues = cues
        self.warnings = warnings
    }
}

public enum SubtitleParserError: Error, Equatable, Sendable {
    case invalidUTF8
}
