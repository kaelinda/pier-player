import FFmpegKit
import Foundation
import MediaSourceKit
import PlaybackCore
import RenderKit
import Testing
@testable import PierPlayerApp

@MainActor
@Test func openingStreamsAnOpenHandleWithoutAggregatingTheFile() async throws {
    let item = testVideoItem()
    let file = ModelTestFile(size: 128 * 1024 * 1024)
    let source = ModelTestSource(file: file)
    let coordinator = ModelTestCoordinator()
    let model = VideoPlayerModel(
        item: item,
        source: source,
        renderer: SampleBufferRenderer(),
        coordinator: coordinator
    )

    await model.start()
    try await waitForModel(model) { $0.state == .playing }

    #expect(source.openedPaths == [item.path])
    #expect(file.readByteCount == 0)
    #expect(coordinator.startedIdentity == file.identity)

    await model.stop()
    #expect(coordinator.stopCount == 1)
}

@MainActor
@Test func modelFollowsSnapshotsAndSendsOneSeekAfterScrubbing() async throws {
    let item = testVideoItem()
    let source = ModelTestSource(file: ModelTestFile(size: 1_024))
    let coordinator = ModelTestCoordinator()
    let model = VideoPlayerModel(
        item: item,
        source: source,
        renderer: SampleBufferRenderer(),
        coordinator: coordinator
    )

    await model.start()
    coordinator.send(snapshot(state: .playing, position: 0.25))
    try await waitForModel(model) { $0.position == 0.25 }

    model.beginScrubbing()
    model.updateScrubPosition(0.5)
    model.updateScrubPosition(0.75)
    #expect(coordinator.seekPositions.isEmpty)
    await model.endScrubbing()
    #expect(coordinator.seekPositions == [0.75])
}

@MainActor
@Test func modelExposesTrackMenusAndSubtitleOff() async throws {
    let item = testVideoItem()
    let coordinator = ModelTestCoordinator()
    let model = VideoPlayerModel(
        item: item,
        source: ModelTestSource(file: ModelTestFile(size: 1_024)),
        renderer: SampleBufferRenderer(),
        coordinator: coordinator
    )
    let tracks = [
        PlaybackTrack(index: 0, kind: .video, codecName: "h264", language: nil, title: nil, isSelected: true),
        PlaybackTrack(index: 1, kind: .audio, codecName: "aac", language: "eng", title: "English 5.1", isSelected: true),
        PlaybackTrack(index: 2, kind: .subtitle, codecName: "subrip", language: "eng", title: "English", isSelected: true),
    ]

    await model.start()
    coordinator.send(snapshot(state: .playing, tracks: tracks))
    try await waitForModel(model) { $0.tracks.count == 3 }

    #expect(model.audioTracks.map(\.index) == [1])
    #expect(model.subtitleTracks.map(\.index) == [2])
    await model.selectSubtitleTrack(nil)
    #expect(coordinator.subtitleSelections == [nil])
}

@MainActor
@Test func closeWhileOpeningClosesLateHandleWithoutStartingPlayback() async throws {
    let file = ModelTestFile(size: 1_024)
    let source = DelayedModelTestSource(file: file)
    let coordinator = ModelTestCoordinator()
    let model = VideoPlayerModel(
        item: testVideoItem(),
        source: source,
        renderer: SampleBufferRenderer(),
        coordinator: coordinator
    )
    let openRequests = source.openRequests

    let startTask = Task { await model.start() }
    for await _ in openRequests { break }
    await model.stop()
    await source.releaseOpen()
    await startTask.value

    #expect(file.closeCount == 1)
    #expect(coordinator.startedIdentity == nil)
    #expect(coordinator.stopCount == 1)
}

@MainActor
func waitForModel(
    _ model: VideoPlayerModel,
    predicate: (PlaybackCoordinatorSnapshot) -> Bool
) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 2
    while ProcessInfo.processInfo.systemUptime < deadline {
        if predicate(model.snapshot) { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("timed out waiting for model state: \(model.snapshot)")
}

func testVideoItem() -> MediaSourceItem {
    MediaSourceItem(
        name: "A very long movie name for track and layout verification.mkv",
        path: "/Movies/test.mkv",
        kind: .file,
        size: 128 * 1024 * 1024,
        modifiedAt: nil
    )
}

func snapshot(
    state: PlaybackState,
    position: TimeInterval = 0,
    tracks: [PlaybackTrack] = []
) -> PlaybackCoordinatorSnapshot {
    PlaybackCoordinatorSnapshot(
        sessionID: UUID(),
        generation: 0,
        state: state,
        intendsToPlay: state == .playing,
        position: position,
        duration: 2,
        videoDecoderMode: .software,
        tracks: tracks,
        subtitleText: nil,
        failure: nil
    )
}

final class ModelTestCoordinator: PlaybackCoordinatorControlling, @unchecked Sendable {
    let snapshots: AsyncStream<PlaybackCoordinatorSnapshot>
    private let continuation: AsyncStream<PlaybackCoordinatorSnapshot>.Continuation
    private let lock = NSLock()
    private var state = State()

    private struct State {
        var startedIdentity: MediaFileIdentity?
        var stopCount = 0
        var seekPositions: [TimeInterval] = []
        var subtitleSelections: [Int?] = []
    }

    var startedIdentity: MediaFileIdentity? { lock.withLock { state.startedIdentity } }
    var stopCount: Int { lock.withLock { state.stopCount } }
    var seekPositions: [TimeInterval] { lock.withLock { state.seekPositions } }
    var subtitleSelections: [Int?] { lock.withLock { state.subtitleSelections } }

    init() {
        let stream = AsyncStream<PlaybackCoordinatorSnapshot>.makeStream()
        snapshots = stream.stream
        continuation = stream.continuation
    }

    func send(_ snapshot: PlaybackCoordinatorSnapshot) {
        continuation.yield(snapshot)
    }

    func start(file: any MediaReadableFile) async throws {
        lock.withLock { state.startedIdentity = file.identity }
        continuation.yield(snapshot(state: .playing))
    }

    func pause() async throws {}
    func resume() async throws {}

    func seek(to position: TimeInterval) async throws -> UInt64 {
        lock.withLock { state.seekPositions.append(position) }
        return 1
    }

    func selectAudioTrack(index: Int) async throws -> UInt64 { 1 }

    func selectSubtitleTrack(index: Int?) async throws {
        lock.withLock { state.subtitleSelections.append(index) }
    }

    func stop() async {
        lock.withLock { state.stopCount += 1 }
        continuation.yield(.idle)
    }
}

final class ModelTestSource: MediaSource, @unchecked Sendable {
    let id = UUID()
    let displayName = "Test Source"
    let file: ModelTestFile
    private let lock = NSLock()
    private var paths: [String] = []

    var openedPaths: [String] { lock.withLock { paths } }

    init(file: ModelTestFile) {
        self.file = file
    }

    func connect() async throws {}
    func disconnect() async {}
    func list(directory path: String) async throws -> [MediaSourceItem] { [] }

    func open(file path: String) async throws -> any MediaReadableFile {
        lock.withLock { paths.append(path) }
        return file
    }
}

final class ModelTestFile: MediaReadableFile, @unchecked Sendable {
    let identity: MediaFileIdentity
    private let lock = NSLock()
    private var bytesRead = 0
    private var closes = 0

    var readByteCount: Int { lock.withLock { bytesRead } }
    var closeCount: Int { lock.withLock { closes } }

    init(size: Int64) {
        identity = MediaFileIdentity(
            sourceID: UUID(),
            path: "/Movies/test.mkv",
            size: size,
            modifiedAt: nil
        )
    }

    func read(at offset: Int64, length: Int) async throws -> Data {
        lock.withLock { bytesRead += length }
        return Data(repeating: 0, count: length)
    }

    func close() async {
        lock.withLock { closes += 1 }
    }
}

actor DelayedModelTestSource: MediaSource {
    nonisolated let id = UUID()
    nonisolated let displayName = "Delayed Source"
    nonisolated let openRequests: AsyncStream<Void>

    private let file: ModelTestFile
    private let openRequestContinuation: AsyncStream<Void>.Continuation
    private var openContinuation: CheckedContinuation<any MediaReadableFile, Never>?

    init(file: ModelTestFile) {
        self.file = file
        let stream = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        openRequests = stream.stream
        openRequestContinuation = stream.continuation
    }

    func connect() async throws {}
    func disconnect() async {}
    func list(directory path: String) async throws -> [MediaSourceItem] { [] }

    func open(file path: String) async throws -> any MediaReadableFile {
        openRequestContinuation.yield()
        return await withCheckedContinuation { continuation in
            openContinuation = continuation
        }
    }

    func releaseOpen() {
        openContinuation?.resume(returning: file)
        openContinuation = nil
    }
}
