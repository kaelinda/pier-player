import CloudSyncKit
import DiagnosticsKit
import FFmpegKit
import Foundation
import MediaSourceKit
import PlaybackCore
import RenderKit
import SMBSourceKit
import Testing
@testable import PierPlayerApp

@MainActor
@Test func modelRestoresSyncedProgressAndFlushesOnStop() async throws {
    let item = testVideoItem()
    let file = ModelTestFile(size: 1_024)
    let source = ModelTestSource(file: file)
    let coordinator = ModelTestCoordinator()
    let progress = ModelProgressManager()
    let mediaID = MediaSyncIdentity.make(from: file.identity)
    await progress.set(try PlaybackProgress(
        mediaID: mediaID,
        sourceID: source.id,
        position: 30,
        duration: 100
    ))
    let model = VideoPlayerModel(
        item: item,
        source: source,
        renderer: SampleBufferRenderer(),
        coordinator: coordinator,
        progressManager: progress
    )

    await model.start()
    try await waitForModel(model) { $0.state == .playing }
    #expect(coordinator.seekPositions == [30])

    coordinator.send(snapshot(state: .playing, position: 40, duration: 100))
    try await waitForModel(model) { $0.position == 40 }
    await model.togglePlayback()
    let pauseRecords = await progress.records
    #expect(pauseRecords.contains { $0.force && $0.position == 40 })
    let pauseFlushCount = pauseRecords.count(where: \.force)
    await model.stop()

    let stopRecords = await progress.records
    #expect(stopRecords.count(where: \.force) == pauseFlushCount + 1)
    #expect(stopRecords.last(where: \.force)?.position == 40)
}

@MainActor
@Test func modelDoesNotOverwriteProgressBeforeRestoringIt() async throws {
    let file = ModelTestFile(size: 1_024)
    let source = ModelTestSource(file: file)
    let coordinator = ModelTestCoordinator(startDelay: .milliseconds(300))
    let progress = ModelProgressManager()
    let mediaID = MediaSyncIdentity.make(from: file.identity)
    await progress.set(try PlaybackProgress(
        mediaID: mediaID,
        sourceID: source.id,
        position: 30,
        duration: 100
    ))
    let model = VideoPlayerModel(
        item: testVideoItem(),
        source: source,
        renderer: SampleBufferRenderer(),
        coordinator: coordinator,
        progressManager: progress
    )

    await model.start()

    #expect(coordinator.seekPositions == [30])
    await model.stop()
}

@MainActor
@Test func modelSkipsNonResumableAndDifferentMediaProgress() async throws {
    for (position, storedSize) in [(4.9, 1_024), (95.0, 1_024), (30.0, 2_048)] {
        let file = ModelTestFile(size: 1_024)
        let source = ModelTestSource(file: file)
        let coordinator = ModelTestCoordinator()
        let progress = ModelProgressManager()
        let storedIdentity = MediaFileIdentity(
            sourceID: file.identity.sourceID,
            path: file.identity.path,
            size: Int64(storedSize),
            modifiedAt: file.identity.modifiedAt
        )
        await progress.set(try PlaybackProgress(
            mediaID: MediaSyncIdentity.make(from: storedIdentity),
            sourceID: source.id,
            position: position,
            duration: 100
        ))
        let model = VideoPlayerModel(
            item: testVideoItem(),
            source: source,
            renderer: SampleBufferRenderer(),
            coordinator: coordinator,
            progressManager: progress
        )

        await model.start()
        #expect(coordinator.seekPositions.isEmpty)
        await model.stop()
    }
}

@MainActor
@Test func modelForceFlushesWhenPlaybackEnds() async throws {
    let source = ModelTestSource(file: ModelTestFile(size: 1_024))
    let coordinator = ModelTestCoordinator()
    let progress = ModelProgressManager()
    let model = VideoPlayerModel(
        item: testVideoItem(),
        source: source,
        renderer: SampleBufferRenderer(),
        coordinator: coordinator,
        progressManager: progress
    )

    await model.start()
    coordinator.send(snapshot(state: .ended, position: 100, duration: 100))
    try await waitForProgress(progress) { records in
        records.contains { $0.force && $0.position == 100 }
    }
    await model.stop()
}

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

    let reopened = try await coordinator.reopen()
    #expect(reopened.identity == file.identity)
    #expect(source.openedPaths == [item.path, item.path])

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
@Test func retryReopensTheVideoAfterARecoverableFailure() async throws {
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
    coordinator.send(snapshot(
        state: .failed("raw network failure"),
        failure: PlaybackFailure(
            boundary: .networkRead,
            reason: .network,
            message: "The connection was interrupted."
        )
    ))
    try await waitForModel(model) { $0.failure?.reason == .network }

    await model.retry()
    try await waitForModel(model) { $0.state == .playing }

    #expect(source.openedPaths == [item.path, item.path])
    #expect(coordinator.startCount == 2)
    #expect(coordinator.stopCount == 1)
}

@MainActor
@Test func sourceOpenFailureDoesNotExposeThePrivatePath() async {
    let privatePath = "/Private Share/Family/video.mp4"
    let source = ModelTestSource(
        file: ModelTestFile(size: 1_024),
        openError: MediaSourceError.notFound(path: privatePath)
    )
    let model = VideoPlayerModel(
        item: testVideoItem(),
        source: source,
        renderer: SampleBufferRenderer(),
        coordinator: ModelTestCoordinator()
    )

    await model.start()

    #expect(model.snapshot.failure?.reason == .sourceUnavailable)
    #expect(model.snapshot.failure?.message.contains(privatePath) == false)
    if case let .failed(message) = model.snapshot.state {
        #expect(!message.contains(privatePath))
    } else {
        Issue.record("Expected a failed playback state")
    }
}

@MainActor
@Test func modelRecordsCorrelatedHashedFileOpenDiagnostics() async throws {
    let item = testVideoItem()
    let file = ModelTestFile(size: 1_024)
    let recorder = AppRecordingDiagnosticRecorder()
    let identityProvider = HMACDiagnosticIdentityProvider(
        keyData: Data(repeating: 4, count: 32)
    )
    let model = VideoPlayerModel(
        item: item,
        source: ModelTestSource(file: file),
        renderer: SampleBufferRenderer(),
        coordinator: ModelTestCoordinator(),
        diagnosticRecorder: recorder,
        diagnosticContext: appDiagnosticContext,
        identityProvider: identityProvider
    )

    await model.start()
    try await waitForModel(model) { $0.state == .playing }
    await model.stop()

    let events = recorder.snapshot.filter { $0.name == .fileOpen }
    #expect(events.map(\.phase) == [.begin, .end])
    #expect(events.allSatisfy {
        $0.context.activityID == appDiagnosticContext.activityID
    })
    let expectedFileID = identityProvider.fileIdentity(
        sourceID: file.identity.sourceID,
        normalizedPath: file.identity.path,
        size: file.identity.size,
        modifiedAt: file.identity.modifiedAt
    ).value
    #expect(events.last?.payload.fileID == expectedFileID)
    let encoded = try events.map(DiagnosticEventEncoder.encode)
        .map { String(decoding: $0, as: UTF8.self) }
        .joined()
        .lowercased()
    #expect(!encoded.contains("movies"))
    #expect(!encoded.contains("very long movie"))
}

@MainActor
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
@Test func modelDiscoversAndLoadsSameBasenameExternalSubtitles() async throws {
    let subtitleBytes = Data(
        "1\n00:00:00,200 --> 00:00:01,200\nExternal subtitle\n".utf8
    )
    let subtitleItem = MediaSourceItem(
        name: "test.en.srt",
        path: "/Movies/test.en.srt",
        kind: .file,
        size: Int64(subtitleBytes.count),
        modifiedAt: nil
    )
    let mediaFile = ModelTestFile(size: 1_024)
    let subtitleFile = ModelTestFile(
        bytes: subtitleBytes,
        path: subtitleItem.path
    )
    let source = ModelTestSource(
        file: mediaFile,
        directoryItems: [subtitleItem],
        additionalFiles: [subtitleItem.path: subtitleFile]
    )
    let coordinator = ModelTestCoordinator()
    let model = VideoPlayerModel(
        item: testVideoItem(),
        source: source,
        renderer: SampleBufferRenderer(),
        coordinator: coordinator
    )

    await model.start()

    #expect(source.listedPaths == ["/Movies"])
    #expect(source.openedPaths == ["/Movies/test.mkv", subtitleItem.path])
    #expect(subtitleFile.closeCount == 1)
    await model.stop()
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
    duration: TimeInterval = 2,
    tracks: [PlaybackTrack] = [],
    failure: PlaybackFailure? = nil
) -> PlaybackCoordinatorSnapshot {
    PlaybackCoordinatorSnapshot(
        sessionID: UUID(),
        generation: 0,
        state: state,
        intendsToPlay: state == .playing,
        position: position,
        duration: duration,
        videoDecoderMode: .software,
        tracks: tracks,
        subtitleText: nil,
        failure: failure
    )
}

final class ModelTestCoordinator: PlaybackCoordinatorControlling, @unchecked Sendable {
    let snapshots: AsyncStream<PlaybackCoordinatorSnapshot>
    private let continuation: AsyncStream<PlaybackCoordinatorSnapshot>.Continuation
    private let startDelay: Duration?
    private let lock = NSLock()
    private var state = State()

    private struct State {
        var startedIdentity: MediaFileIdentity?
        var reopenFile: MediaFileReopener?
        var startCount = 0
        var stopCount = 0
        var seekPositions: [TimeInterval] = []
        var subtitleSelections: [Int?] = []
    }

    var startedIdentity: MediaFileIdentity? { lock.withLock { state.startedIdentity } }
    var startCount: Int { lock.withLock { state.startCount } }
    var stopCount: Int { lock.withLock { state.stopCount } }
    var seekPositions: [TimeInterval] { lock.withLock { state.seekPositions } }
    var subtitleSelections: [Int?] { lock.withLock { state.subtitleSelections } }

    init(startDelay: Duration? = nil) {
        let stream = AsyncStream<PlaybackCoordinatorSnapshot>.makeStream()
        snapshots = stream.stream
        continuation = stream.continuation
        self.startDelay = startDelay
    }

    func send(_ snapshot: PlaybackCoordinatorSnapshot) {
        continuation.yield(snapshot)
    }

    func start(
        file: any MediaReadableFile,
        reopenFile: @escaping MediaFileReopener
    ) async throws {
        lock.withLock {
            state.startedIdentity = file.identity
            state.reopenFile = reopenFile
            state.startCount += 1
        }
        continuation.yield(snapshot(state: .playing, duration: 100))
        if let startDelay {
            try await Task.sleep(for: startDelay)
        }
    }

    func reopen() async throws -> any MediaReadableFile {
        let reopenFile = try #require(lock.withLock { state.reopenFile })
        return try await reopenFile()
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

    func registerExternalSubtitles(_ subtitles: [ExternalPlaybackSubtitle]) async {}

    func stop() async {
        lock.withLock { state.stopCount += 1 }
        continuation.yield(.idle)
    }
}

private actor ModelProgressManager: PlaybackProgressManaging {
    struct Record: Sendable {
        let position: TimeInterval
        let force: Bool
    }

    private var storedProgress: PlaybackProgress?
    private(set) var records: [Record] = []

    func set(_ progress: PlaybackProgress) {
        storedProgress = progress
    }

    func progress(mediaID: String) -> PlaybackProgress? {
        storedProgress?.mediaID == mediaID ? storedProgress : nil
    }

    func record(
        mediaID: String,
        sourceID: UUID,
        position: TimeInterval,
        duration: TimeInterval,
        force: Bool
    ) {
        records.append(Record(position: position, force: force))
        storedProgress = try? PlaybackProgress(
            mediaID: mediaID,
            sourceID: sourceID,
            position: position,
            duration: duration
        )
    }

    func allProgress() -> [PlaybackProgress] {
        storedProgress.map { [$0] } ?? []
    }

    func replaceAll(_ progress: [PlaybackProgress]) {
        storedProgress = progress.first
    }

    func removeAll(sourceID: UUID) {
        if storedProgress?.sourceID == sourceID {
            storedProgress = nil
        }
    }
}

@MainActor
private func waitForProgress(
    _ manager: ModelProgressManager,
    timeout: Duration = .seconds(1),
    predicate: @escaping ([ModelProgressManager.Record]) -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if predicate(await manager.records) { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("timed out waiting for persisted playback progress")
}

final class ModelTestSource: MediaSource, @unchecked Sendable {
    let id = UUID()
    let displayName = "Test Source"
    let file: ModelTestFile
    let directoryItems: [MediaSourceItem]
    let additionalFiles: [String: ModelTestFile]
    let openError: Error?
    private let lock = NSLock()
    private var paths: [String] = []
    private var directories: [String] = []

    var openedPaths: [String] { lock.withLock { paths } }
    var listedPaths: [String] { lock.withLock { directories } }

    init(
        file: ModelTestFile,
        directoryItems: [MediaSourceItem] = [],
        additionalFiles: [String: ModelTestFile] = [:],
        openError: Error? = nil
    ) {
        self.file = file
        self.directoryItems = directoryItems
        self.additionalFiles = additionalFiles
        self.openError = openError
    }

    func connect() async throws {}
    func disconnect() async {}
    func list(directory path: String) async throws -> [MediaSourceItem] {
        lock.withLock { directories.append(path) }
        return directoryItems
    }

    func open(file path: String) async throws -> any MediaReadableFile {
        lock.withLock { paths.append(path) }
        if let openError { throw openError }
        return additionalFiles[path] ?? file
    }
}

final class ModelTestFile: MediaReadableFile, @unchecked Sendable {
    let identity: MediaFileIdentity
    private let bytes: Data?
    private let lock = NSLock()
    private var bytesRead = 0
    private var closes = 0

    var readByteCount: Int { lock.withLock { bytesRead } }
    var closeCount: Int { lock.withLock { closes } }

    init(size: Int64, path: String = "/Movies/test.mkv") {
        bytes = nil
        identity = MediaFileIdentity(
            sourceID: UUID(),
            path: path,
            size: size,
            modifiedAt: nil
        )
    }

    init(bytes: Data, path: String) {
        self.bytes = bytes
        identity = MediaFileIdentity(
            sourceID: UUID(),
            path: path,
            size: Int64(bytes.count),
            modifiedAt: nil
        )
    }

    func read(at offset: Int64, length: Int) async throws -> Data {
        lock.withLock { bytesRead += length }
        if let bytes {
            let start = Int(offset)
            let end = min(start + length, bytes.count)
            guard start >= 0, start < end else { return Data() }
            return bytes.subdata(in: start..<end)
        }
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
