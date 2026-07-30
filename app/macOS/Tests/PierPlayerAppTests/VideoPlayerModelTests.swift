import AVFoundation
import DiagnosticsKit
import Foundation
import MediaSourceKit
import SMBSourceKit
import Testing
@testable import PierPlayerApp

@Suite @MainActor struct VideoPlayerModelTests {
    @Test func startTransfersTheOpenFileWithoutEagerReads() async throws {
        let file = ModelRecordingReadableFile(size: 8 * 1024 * 1024)
        let source = ModelFakeMediaSource(file: file)
        let session = FakeVideoPlaybackSession()
        let item = videoFixtureItem
        let model = VideoPlayerModel(
            item: item,
            source: source,
            sessionFactory: { openedFile, fileName in
                #expect(openedFile.identity == file.identity)
                #expect(fileName == item.name)
                return session
            }
        )

        await model.start()

        #expect(await source.openedPaths == [item.path])
        #expect(await file.readRequests.isEmpty)
        #expect(session.playCount == 1)
        let player = try #require(model.player)
        #expect(player === session.player)
        #expect(model.phase == .playing)
    }

    @Test func stopClearsPlayerAndStopsSessionOnce() async throws {
        let file = ModelRecordingReadableFile(size: 1024)
        let source = ModelFakeMediaSource(file: file)
        let session = FakeVideoPlaybackSession()
        let model = VideoPlayerModel(
            item: videoFixtureItem,
            source: source,
            sessionFactory: { _, _ in session }
        )
        await model.start()
        _ = try #require(model.player)

        await model.stop()
        await model.stop()

        #expect(model.player == nil)
        #expect(session.stopCount == 1)
    }

    @Test func sessionConstructionFailureClosesOpenedFile() async {
        let file = ModelRecordingReadableFile(size: 1024)
        let source = ModelFakeMediaSource(file: file)
        let model = VideoPlayerModel(
            item: videoFixtureItem,
            source: source,
            sessionFactory: { _, _ in throw ModelFixtureError.sessionConstructionFailed }
        )

        await model.start()

        #expect(await file.closeCount == 1)
        #expect(model.player == nil)
        #expect(model.phase == .failed("sessionConstructionFailed"))
    }

    @Test func playbackActivityRecordsOpenPreparePlayStopWithoutRawMediaIdentity() async throws {
        let file = ModelRecordingReadableFile(size: 1_024)
        let source = ModelFakeMediaSource(file: file)
        let session = FakeVideoPlaybackSession()
        let recorder = AppRecordingDiagnosticRecorder()
        let identityProvider = HMACDiagnosticIdentityProvider(keyData: Data(repeating: 4, count: 32))
        let model = VideoPlayerModel(
            item: videoFixtureItem,
            source: source,
            diagnosticRecorder: recorder,
            diagnosticContext: appDiagnosticContext,
            identityProvider: identityProvider,
            sessionFactory: { _, _ in session }
        )

        await model.start()
        await model.stop()

        let events = recorder.snapshot
        for name in [
            DiagnosticEventName.fileOpen,
            .playbackPrepare,
            .playbackPlay,
            .playbackStop,
        ] {
            #expect(events.contains { $0.name == name })
        }
        #expect(events.allSatisfy { $0.context.activityID == appDiagnosticContext.activityID })
        let expectedFileID = identityProvider.fileIdentity(
            sourceID: file.identity.sourceID,
            normalizedPath: file.identity.path,
            size: file.identity.size,
            modifiedAt: file.identity.modifiedAt
        ).value
        #expect(events.contains { $0.name == .fileOpen && $0.payload.fileID == expectedFileID })
        let encoded = try events.map(DiagnosticEventEncoder.encode)
            .map { String(decoding: $0, as: UTF8.self) }
            .joined()
            .lowercased()
        #expect(!encoded.contains("large fixture"))
        #expect(!encoded.contains("/movies"))
    }

    @Test func restoreUsesTypedDiagnosticsAndContainsNoLegacyLogWriter() async throws {
        let recorder = AppRecordingDiagnosticRecorder()
        let model = AppModel(
            sourceStore: SMBSourceStore(fallback: ()),
            diagnosticRecorder: recorder,
            diagnosticContext: appDiagnosticContext
        )

        await model.restore()

        let restore = try #require(recorder.snapshot.last { $0.name == .sourceRestore })
        #expect(restore.outcome == .failure)
        let encoded = String(
            decoding: try DiagnosticEventEncoder.encode(restore),
            as: UTF8.self
        ).lowercased()
        #expect(!encoded.contains("username"))
        #expect(!encoded.contains("displayname"))
        #expect(!encoded.contains("host"))
        #expect(!encoded.contains("share"))
        #expect(!encoded.contains("path"))

        let testFile = URL(fileURLWithPath: #filePath)
        let macOSRoot = testFile.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: macOSRoot.appendingPathComponent("Sources/PierPlayerApp/AppModel.swift"),
            encoding: .utf8
        )
        #expect(!source.contains("pier_restore.log"))
    }
}

private let videoFixtureItem = MediaSourceItem(
    name: "Large Fixture.mp4",
    path: "/Movies/Large Fixture.mp4",
    kind: .file,
    size: 8 * 1024 * 1024,
    modifiedAt: nil
)

private enum ModelFixtureError: Error {
    case sessionConstructionFailed
}

@MainActor
private final class FakeVideoPlaybackSession: VideoPlaybackSession {
    let player = AVPlayer()
    private(set) var playCount = 0
    private(set) var stopCount = 0

    func play() {
        playCount += 1
    }

    func stop() async {
        stopCount += 1
    }
}

private actor ModelFakeMediaSource: MediaSource {
    nonisolated let id = UUID()
    nonisolated let displayName = "Fixture Source"

    private let file: any MediaReadableFile
    private(set) var openedPaths: [String] = []

    init(file: any MediaReadableFile) {
        self.file = file
    }

    func connect() async throws {}
    func disconnect() async {}

    func list(directory path: String) async throws -> [MediaSourceItem] {
        []
    }

    func open(file path: String) async throws -> any MediaReadableFile {
        openedPaths.append(path)
        return file
    }
}

private actor ModelRecordingReadableFile: MediaReadableFile {
    nonisolated let identity: MediaFileIdentity

    private(set) var readRequests: [(offset: Int64, length: Int)] = []
    private(set) var closeCount = 0

    init(size: Int64) {
        self.identity = MediaFileIdentity(
            sourceID: UUID(),
            path: "/Movies/Large Fixture.mp4",
            size: size,
            modifiedAt: nil
        )
    }

    func read(at offset: Int64, length: Int) async throws -> Data {
        readRequests.append((offset, length))
        return Data(repeating: 0, count: length)
    }

    func close() async {
        closeCount += 1
    }
}
