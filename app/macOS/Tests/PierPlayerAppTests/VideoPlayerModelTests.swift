import AVFoundation
import Foundation
import MediaSourceKit
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
