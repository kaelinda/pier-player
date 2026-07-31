import FFmpegKit
import Foundation
import MediaSourceKit

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

public enum PlaybackFailureReason: String, Equatable, Sendable {
    case corruptMedia
    case unsupportedMedia
    case network
    case sourceUnavailable
    case fileChanged
    case rendering
    case unknown
}

public struct PlaybackFailure: Error, Equatable, Sendable {
    public let boundary: PlaybackFailureBoundary
    public let reason: PlaybackFailureReason
    public let message: String
    public let diagnosticCode: Int?

    public init(
        boundary: PlaybackFailureBoundary,
        reason: PlaybackFailureReason = .unknown,
        message: String,
        diagnosticCode: Int? = nil
    ) {
        self.boundary = boundary
        self.reason = reason
        self.message = message
        self.diagnosticCode = diagnosticCode
    }

    public static func classify(
        _ error: Error,
        defaultBoundary: PlaybackFailureBoundary = .demux
    ) -> PlaybackFailure {
        if let ffmpegError = error as? FFmpegError {
            switch ffmpegError {
            case .corruptMedia:
                return PlaybackFailure(
                    boundary: .videoDecode,
                    reason: .corruptMedia,
                    message: "The video contains damaged or incomplete media data.",
                    diagnosticCode: ffmpegError.diagnosticCode
                )
            case .unsupportedCodec:
                return PlaybackFailure(
                    boundary: .videoDecode,
                    reason: .unsupportedMedia,
                    message: "The video's format or codec is not supported.",
                    diagnosticCode: ffmpegError.diagnosticCode
                )
            case let .native(code, message):
                if ffmpegError.isInputOutputFailure {
                    return networkFailure(diagnosticCode: code)
                }
                if message.localizedCaseInsensitiveContains("decoder not found") ||
                    message.localizedCaseInsensitiveContains("unsupported codec") {
                    return PlaybackFailure(
                        boundary: .videoDecode,
                        reason: .unsupportedMedia,
                        message: "The video's format or codec is not supported.",
                        diagnosticCode: code
                    )
                }
                return PlaybackFailure(
                    boundary: defaultBoundary,
                    reason: .unknown,
                    message: "Playback could not continue.",
                    diagnosticCode: code
                )
            default:
                return PlaybackFailure(
                    boundary: defaultBoundary,
                    reason: .unknown,
                    message: "Playback could not continue."
                )
            }
        }

        if error is BlockingMediaReaderError {
            return networkFailure()
        }
        if let sourceError = error as? MediaSourceError {
            switch sourceError {
            case .remoteFileChanged:
                return PlaybackFailure(
                    boundary: .fileChanged,
                    reason: .fileChanged,
                    message: "The video changed on the media source."
                )
            case .unsupported:
                return PlaybackFailure(
                    boundary: defaultBoundary,
                    reason: .unsupportedMedia,
                    message: "The video's format or codec is not supported."
                )
            case .notConnected, .authenticationFailed, .unreachable, .readFailed:
                return networkFailure()
            case .notFound, .invalidRead:
                return PlaybackFailure(
                    boundary: .sourceOpen,
                    reason: .sourceUnavailable,
                    message: "The video is no longer available at this location."
                )
            }
        }

        return PlaybackFailure(
            boundary: defaultBoundary,
            reason: .unknown,
            message: "Playback could not continue."
        )
    }

    private static func networkFailure(diagnosticCode: Int? = nil) -> PlaybackFailure {
        PlaybackFailure(
            boundary: .networkRead,
            reason: .network,
            message: "The connection to the media source was interrupted.",
            diagnosticCode: diagnosticCode
        )
    }
}
