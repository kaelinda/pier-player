import Foundation
import Testing
@testable import PierPlayerApp

@Suite struct ProgressivePlaybackSessionTests {
    @Test(arguments: ["movie.mp4", "MOVIE.M4V", "clip.mov"])
    func avFoundationPlaybackAcceptsSupportedContainers(fileName: String) throws {
        let mediaType = try #require(AVFoundationMediaType(fileName: fileName))

        #expect(!mediaType.contentType.isEmpty)
        #expect(mediaType.fileExtension == (fileName as NSString).pathExtension.lowercased())
    }

    @Test(arguments: ["movie.mkv", "movie.webm", "movie", "movie.mp4.exe"])
    func avFoundationPlaybackRejectsUnsupportedContainers(fileName: String) {
        #expect(AVFoundationMediaType(fileName: fileName) == nil)
    }

    @Test func privateAssetURLContainsNoRemotePath() throws {
        let mediaType = try #require(AVFoundationMediaType(fileName: "Private Movies/Family.mp4"))
        let identifier = UUID(uuidString: "3F2E1D0C-4B5A-6978-8796-A5B4C3D2E1F0")!

        let url = mediaType.makeAssetURL(identifier: identifier)

        #expect(url.scheme == "pier-player-media")
        #expect(url.host == "asset")
        #expect(url.pathExtension == "mp4")
        #expect(url.lastPathComponent == "3F2E1D0C-4B5A-6978-8796-A5B4C3D2E1F0.mp4")
        #expect(!url.absoluteString.contains("Private"))
        #expect(!url.absoluteString.contains("Family"))
    }

    @Test func finiteLoadingRangeStartsAtCurrentOffset() {
        let range = AVFoundationLoadingRange(
            requestedOffset: 100,
            currentOffset: 132,
            requestedLength: 80,
            requestsAllDataToEndOfResource: false
        )

        #expect(range == AVFoundationLoadingRange(offset: 132, length: 48))
    }

    @Test func allDataLoadingRangeHasNoFiniteLength() {
        let range = AVFoundationLoadingRange(
            requestedOffset: 100,
            currentOffset: 132,
            requestedLength: 80,
            requestsAllDataToEndOfResource: true
        )

        #expect(range == AVFoundationLoadingRange(offset: 132, length: nil))
    }

    @Test(arguments: [
        LoadingRangeInput(
            requestedOffset: -1,
            currentOffset: 0,
            requestedLength: 10,
            requestsAllDataToEndOfResource: false
        ),
        LoadingRangeInput(
            requestedOffset: 10,
            currentOffset: 10,
            requestedLength: 0,
            requestsAllDataToEndOfResource: false
        ),
        LoadingRangeInput(
            requestedOffset: 10,
            currentOffset: 21,
            requestedLength: 10,
            requestsAllDataToEndOfResource: false
        ),
        LoadingRangeInput(
            requestedOffset: Int64.max - 1,
            currentOffset: Int64.max - 1,
            requestedLength: 10,
            requestsAllDataToEndOfResource: false
        ),
    ])
    func invalidOrCompletedLoadingRangeIsRejected(input: LoadingRangeInput) {
        let range = AVFoundationLoadingRange(
            requestedOffset: input.requestedOffset,
            currentOffset: input.currentOffset,
            requestedLength: input.requestedLength,
            requestsAllDataToEndOfResource: input.requestsAllDataToEndOfResource
        )

        #expect(range == nil)
    }
}

struct LoadingRangeInput: Sendable, CustomTestStringConvertible {
    let requestedOffset: Int64
    let currentOffset: Int64
    let requestedLength: Int
    let requestsAllDataToEndOfResource: Bool

    var testDescription: String {
        "requested=\(requestedOffset), current=\(currentOffset), length=\(requestedLength), toEnd=\(requestsAllDataToEndOfResource)"
    }
}
