import DiagnosticsKit
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

    @Test @MainActor func stateAdapterRecordsReadyLongWaitBurstStallsAndTerminalStates() throws {
        let recorder = AppRecordingDiagnosticRecorder()
        let clock = MonotonicTestClock()
        let longWait = PlaybackStateDiagnosticAdapter(
            diagnosticRecorder: recorder,
            diagnosticContext: appDiagnosticContext,
            monotonicNow: { clock.now }
        )

        longWait.observe(.ready)
        longWait.observe(.waiting)
        clock.advance(by: 4)
        longWait.poll()
        longWait.observe(.playing)
        longWait.observe(.ended)

        let burst = PlaybackStateDiagnosticAdapter(
            diagnosticRecorder: recorder,
            diagnosticContext: appDiagnosticContext,
            monotonicNow: { clock.now }
        )
        for _ in 0..<3 {
            burst.observe(.waiting)
            clock.advance(by: 1)
            burst.observe(.playing)
        }

        let failed = PlaybackStateDiagnosticAdapter(
            diagnosticRecorder: recorder,
            diagnosticContext: appDiagnosticContext,
            monotonicNow: { clock.now }
        )
        failed.observe(.failed)

        let events = recorder.snapshot
        #expect(events.filter { $0.name == .playbackReady }.count == 1)
        #expect(events.filter { $0.name == .playbackStall }.count == 2)
        #expect(events.filter { $0.name == .playbackRecover }.count == 4)
        #expect(events.filter { $0.name == .playbackEnded }.count == 1)
        let failure = try #require(events.last { $0.name == .playbackFailed })
        #expect(failure.outcome == .failure)
        #expect(failure.payload.error?.code == .playerFailed)
    }

    @Test func loadingCompletionGateAllowsOneTerminalAction() {
        let gate = LoadingRequestCompletionGate()

        #expect(gate.claim(.finished))
        #expect(!gate.claim(.cancelled))
        #expect(!gate.claim(.failed))
    }
}

private final class MonotonicTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0

    var now: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        value += interval
        lock.unlock()
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
