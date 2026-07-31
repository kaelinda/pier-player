import FFmpegKit
import MediaSourceKit
import Testing
@testable import PlaybackCore

@Test func corruptNativeDataMapsToTypedFriendlyPlaybackFailure() {
    let failure = PlaybackFailure.classify(FFmpegError.corruptMedia)

    #expect(failure.reason == .corruptMedia)
    #expect(failure.boundary == .videoDecode)
    #expect(!failure.message.contains("FFmpeg"))
    #expect(!failure.message.contains("NAL"))
}

@Test func unsupportedDecoderMapsSeparatelyFromCorruptMedia() {
    let failure = PlaybackFailure.classify(
        FFmpegError.unsupportedCodec
    )

    #expect(failure.reason == .unsupportedMedia)
    #expect(failure.boundary == .videoDecode)
}

@Test func networkAndChangedFileFailuresKeepTheirOwnCategories() {
    let network = PlaybackFailure.classify(
        FFmpegError.native(code: -5, message: "read media packet")
    )
    let changed = PlaybackFailure.classify(MediaSourceError.remoteFileChanged)

    #expect(network.reason == .network)
    #expect(network.boundary == .networkRead)
    #expect(changed.reason == .fileChanged)
    #expect(changed.boundary == .fileChanged)
}
