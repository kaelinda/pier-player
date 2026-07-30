import Foundation

public enum PlaybackFailureBoundary: String, Equatable, Sendable {
    case sourceOpen
    case networkRead
    case probe
    case demux
    case videoDecode
    case audioDecode
    case subtitleDecode
    case render
    case fileChanged
}

public struct PlaybackFailure: Error, Equatable, Sendable {
    public let boundary: PlaybackFailureBoundary
    public let message: String
    public let diagnosticCode: Int?

    public init(
        boundary: PlaybackFailureBoundary,
        message: String,
        diagnosticCode: Int? = nil
    ) {
        self.boundary = boundary
        self.message = message
        self.diagnosticCode = diagnosticCode
    }
}
