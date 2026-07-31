import PlaybackCore

struct PlayerFailurePresentation: Equatable {
    let title: String
    let message: String
    let systemImage: String
    let canRetry: Bool
    let technicalDetails: String

    init(failure: PlaybackFailure?) {
        let reason = failure?.reason ?? .unknown
        switch reason {
        case .corruptMedia:
            title = "Video File Is Damaged"
            message = "This video contains damaged or incomplete data and cannot continue playing. Try another copy of the file."
            systemImage = "doc.badge.ellipsis"
            canRetry = false
        case .unsupportedMedia:
            title = "Format Not Supported"
            message = "This video's container, video codec, or audio codec is not supported by this version of Pier Player."
            systemImage = "film.stack"
            canRetry = false
        case .network:
            title = "Connection Interrupted"
            message = "Pier Player lost access to the media source. Check the connection, then try again."
            systemImage = "network.slash"
            canRetry = true
        case .sourceUnavailable:
            title = "Video Unavailable"
            message = "The video could not be opened at its current location. Check the source, then try again."
            systemImage = "questionmark.folder"
            canRetry = true
        case .fileChanged:
            title = "Video Changed"
            message = "The video changed while it was playing. Start it again to use the latest version."
            systemImage = "arrow.triangle.2.circlepath.doc.on.clipboard"
            canRetry = true
        case .rendering:
            title = "Display Error"
            message = "The video was decoded but could not be displayed. Try playing it again."
            systemImage = "display.trianglebadge.exclamationmark"
            canRetry = true
        case .unknown:
            title = "Playback Failed"
            message = "Pier Player could not continue playing this video. Try again or use another copy."
            systemImage = "exclamationmark.triangle.fill"
            canRetry = true
        }

        var details = ["Stage: \(Self.stageName(for: failure?.boundary))"]
        if let code = failure?.diagnosticCode {
            details.append("Error code: \(code)")
        }
        technicalDetails = details.joined(separator: " | ")
    }

    private static func stageName(for boundary: PlaybackFailureBoundary?) -> String {
        switch boundary {
        case .sourceOpen: "Open"
        case .networkRead: "Network read"
        case .probe: "Media inspection"
        case .demux: "Container read"
        case .videoDecode: "Video decode"
        case .audioDecode: "Audio decode"
        case .subtitleDecode: "Subtitle decode"
        case .render: "Display"
        case .fileChanged: "Source validation"
        case nil: "Playback"
        }
    }
}
