import PlaybackCore
import Testing
@testable import PierPlayerApp

@Test func corruptMediaPresentationIsActionableWithoutRawDecoderText() {
    let failure = PlaybackFailure(
        boundary: .videoDecode,
        reason: .corruptMedia,
        message: "submit media packet: Invalid NAL unit size /Movies/private/video.mp4",
        diagnosticCode: -1_094_995_529
    )
    let presentation = PlayerFailurePresentation(failure: failure)

    #expect(presentation.title == "Video File Is Damaged")
    #expect(presentation.message.contains("incomplete"))
    #expect(!presentation.message.contains("NAL"))
    #expect(!presentation.technicalDetails.contains("/Movies"))
    #expect(!presentation.canRetry)
}

@Test func networkPresentationOffersRetryWithoutExposingSourceDetails() {
    let failure = PlaybackFailure(
        boundary: .networkRead,
        reason: .network,
        message: "smb://user:password@private-host/share/video.mkv",
        diagnosticCode: -5
    )
    let presentation = PlayerFailurePresentation(failure: failure)

    #expect(presentation.title == "Connection Interrupted")
    #expect(presentation.canRetry)
    #expect(!presentation.message.contains("private-host"))
    #expect(!presentation.technicalDetails.contains("password"))
}
