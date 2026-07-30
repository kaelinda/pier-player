import FFmpegKit
import Foundation
import MediaSourceKit
import RenderKit
import SubtitleKit
import Testing
@testable import PlaybackCore

@MainActor
@Test func coordinatorPlaysSeeksWithPausedIntentAndExposesTracks() async throws {
    let file = try PlaybackTestFile(fixture: "video-h264-aac-srt.mkv")
    let renderer = SampleBufferRenderer(maximumPendingDuration: 3)
    let coordinator = PlaybackCoordinator(
        renderer: renderer,
        configuration: .test
    )

    try await coordinator.start(file: file)
    try await waitForCoordinator(coordinator) {
        $0.state == .playing
    }
    let opened = await coordinator.snapshot
    #expect(opened.duration >= 1)
    #expect(opened.tracks.contains { $0.kind == .audio })
    #expect(opened.tracks.contains { $0.kind == .subtitle })
    #expect(opened.videoDecoderMode != .none)

    try await coordinator.pause()
    #expect(await coordinator.snapshot.state == .paused)
    let generation = try await coordinator.seek(to: 1)
    try await waitForCoordinator(coordinator) {
        $0.generation == generation && $0.state == .paused
    }
    #expect(await coordinator.snapshot.position >= 1)

    try await coordinator.resume()
    #expect(await coordinator.snapshot.intendsToPlay)
    await coordinator.stop()
    #expect(await coordinator.snapshot.state == .idle)
    #expect(file.closeCount == 1)
}

@MainActor
@Test func coordinatorDrainsEOFAndRejectsStaleRapidSeekWork() async throws {
    let file = try PlaybackTestFile(fixture: "video-h264-aac.mkv")
    let renderer = SampleBufferRenderer(maximumPendingDuration: 3)
    let coordinator = PlaybackCoordinator(
        renderer: renderer,
        configuration: .test
    )

    try await coordinator.start(file: file)
    try await waitForCoordinator(coordinator) { $0.state == .playing }
    let generationBeforeSeek = await coordinator.snapshot.generation
    let first = Task { try await coordinator.seek(to: 0.25) }
    try await waitForCoordinator(coordinator) {
        $0.generation > generationBeforeSeek
    }
    let second = Task { try await coordinator.seek(to: 1) }
    _ = try? await first.value
    let latestGeneration = try await second.value
    try await waitForCoordinator(coordinator, timeout: 4) {
        $0.state == .ended
    }
    let ended = await coordinator.snapshot
    #expect(ended.generation >= latestGeneration)
    #expect(ended.state == .ended)
    await coordinator.stop()
    #expect(file.closeCount == 1)
}

@MainActor
@Test func coordinatorDrainsAsymmetricAudioEOFWithoutUnderrun() async throws {
    let file = try PlaybackTestFile(fixture: "video-longer-than-audio.mkv")
    let renderer = SampleBufferRenderer(maximumPendingDuration: 0.1)
    let coordinator = PlaybackCoordinator(
        renderer: renderer,
        configuration: .test
    )

    try await coordinator.start(file: file)
    try await waitForCoordinator(coordinator) { $0.state == .playing }
    try await waitForCoordinator(coordinator, timeout: 4) { $0.state == .ended }

    #expect(await coordinator.snapshot.state == .ended)
    await coordinator.stop()
    #expect(file.closeCount == 1)
}

@MainActor
@Test func coordinatorPublishesEmbeddedSubtitleAsTimelineAdvances() async throws {
    let file = try PlaybackTestFile(fixture: "video-h264-aac-srt.mkv")
    let renderer = SampleBufferRenderer(maximumPendingDuration: 3)
    let coordinator = PlaybackCoordinator(
        renderer: renderer,
        configuration: .test
    )

    try await coordinator.start(file: file)
    try await waitForCoordinator(coordinator) { $0.state == .playing }
    try await Task.sleep(for: .milliseconds(100))
    renderer.play(at: 0.25)
    try await waitForCoordinator(coordinator) {
        $0.subtitleText?.contains("Pier Player subtitle fixture") == true
    }

    await coordinator.stop()
    #expect(file.closeCount == 1)
}

@MainActor
@Test func coordinatorRegistersAndSelectsExternalSubtitleTrack() async throws {
    let file = try PlaybackTestFile(fixture: "video-h264-aac.mkv")
    let renderer = SampleBufferRenderer(maximumPendingDuration: 3)
    let coordinator = PlaybackCoordinator(
        renderer: renderer,
        configuration: .test
    )
    let external = ExternalPlaybackSubtitle(
        identifier: "/Movies/video-h264-aac.en.srt",
        codecName: "subRip",
        language: "en",
        title: "video-h264-aac.en.srt",
        cues: [SubtitleCue(startTime: 0.2, endTime: 1.2, text: "External subtitle")]
    )

    try await coordinator.start(file: file)
    await coordinator.registerExternalSubtitles([external])
    let externalTrack = try #require(
        await coordinator.snapshot.tracks.first { $0.index < 0 }
    )
    try await coordinator.selectSubtitleTrack(index: externalTrack.index)
    renderer.play(at: 0.25)
    try await waitForCoordinator(coordinator) {
        $0.subtitleText == "External subtitle" &&
            $0.tracks.first(where: { $0.index == externalTrack.index })?.isSelected == true
    }

    await coordinator.stop()
    #expect(file.closeCount == 1)
}

@MainActor
@Test func coordinatorReopensAndResumesAfterPlaybackReadFailure() async throws {
    let data = try playbackFixtureData("video-h264-aac.mkv")
    let identity = MediaFileIdentity(
        sourceID: UUID(),
        path: "/video-h264-aac.mkv",
        size: Int64(data.count),
        modifiedAt: Date(timeIntervalSince1970: 1)
    )
    let interrupted = RecoveryTestFile(
        data: data,
        identity: identity,
        failStartingAtRead: 7
    )
    let recovered = RecoveryTestFile(data: data, identity: identity)
    let reopener = RecoveryTestReopener(file: recovered)
    let renderer = SampleBufferRenderer(maximumPendingDuration: 3)
    let coordinator = PlaybackCoordinator(
        renderer: renderer,
        configuration: .test
    )

    try await coordinator.start(
        file: interrupted,
        reopenFile: { try reopener.open() }
    )
    try await waitForCoordinator(coordinator, timeout: 3) {
        let openCount = reopener.openCount
        return openCount == 1 && $0.generation >= 1 && $0.state == .playing
    }

    #expect(interrupted.closeCount == 1)
    #expect(await coordinator.snapshot.state != .failed("The media source stopped responding"))
    await coordinator.stop()
    #expect(recovered.closeCount == 1)
}

@MainActor
@Test func coordinatorRejectsChangedFileDuringRecovery() async throws {
    let data = try playbackFixtureData("video-h264-aac.mkv")
    let identity = recoveryIdentity(size: data.count)
    let changedIdentity = MediaFileIdentity(
        sourceID: identity.sourceID,
        path: identity.path,
        size: identity.size + 1,
        modifiedAt: identity.modifiedAt
    )
    let interrupted = RecoveryTestFile(
        data: data,
        identity: identity,
        failStartingAtRead: 7
    )
    let changed = RecoveryTestFile(data: data, identity: changedIdentity)
    let reopener = RecoveryTestReopener(file: changed)
    let coordinator = PlaybackCoordinator(
        renderer: SampleBufferRenderer(maximumPendingDuration: 3),
        configuration: .test
    )

    try await coordinator.start(
        file: interrupted,
        reopenFile: { try reopener.open() }
    )
    try await waitForCoordinator(coordinator, timeout: 3) {
        $0.failure?.boundary == .fileChanged
    }

    #expect(reopener.openCount == 1)
    #expect(changed.closeCount == 1)
    await coordinator.stop()
}

@MainActor
@Test func coordinatorStopsAfterBoundedRecoveryAttempts() async throws {
    let data = try playbackFixtureData("video-h264-aac.mkv")
    let identity = recoveryIdentity(size: data.count)
    let interrupted = RecoveryTestFile(
        data: data,
        identity: identity,
        failStartingAtRead: 7
    )
    let reopener = FailingRecoveryTestReopener()
    let coordinator = PlaybackCoordinator(
        renderer: SampleBufferRenderer(maximumPendingDuration: 3),
        configuration: .test
    )

    try await coordinator.start(
        file: interrupted,
        reopenFile: { try reopener.open() }
    )
    try await waitForCoordinator(coordinator, timeout: 3) {
        $0.failure?.boundary == .networkRead
    }

    #expect(reopener.openCount == 1)
    await coordinator.stop()
}

@MainActor
@Test func coordinatorClosesLateRecoveryHandleAfterStop() async throws {
    let data = try playbackFixtureData("video-h264-aac.mkv")
    let identity = recoveryIdentity(size: data.count)
    let interrupted = RecoveryTestFile(
        data: data,
        identity: identity,
        failStartingAtRead: 7
    )
    let recovered = RecoveryTestFile(data: data, identity: identity)
    let reopener = DelayedRecoveryTestReopener()
    let requests = reopener.requests
    let coordinator = PlaybackCoordinator(
        renderer: SampleBufferRenderer(maximumPendingDuration: 3),
        configuration: .test
    )

    try await coordinator.start(
        file: interrupted,
        reopenFile: { try await reopener.open() }
    )
    for await _ in requests { break }
    await coordinator.stop()
    await reopener.release(recovered)
    try await Task.sleep(for: .milliseconds(100))

    #expect(await coordinator.snapshot.state == .idle)
    #expect(recovered.closeCount == 1)
}

@MainActor
@Test func coordinatorSeekInterruptsBlockedPreviousGenerationRead() async throws {
    let data = try playbackFixtureData("video-h264-aac.mkv")
    let file = DelayedReadTestFile(
        data: data,
        identity: recoveryIdentity(size: data.count),
        blockAtRead: 7
    )
    let blockedReads = file.blockedReads
    let coordinator = PlaybackCoordinator(
        renderer: SampleBufferRenderer(maximumPendingDuration: 3),
        configuration: recoveryTestConfiguration(
            maximumRetryDuration: 1,
            ioTimeout: 3
        )
    )

    try await coordinator.start(file: file)
    for await _ in blockedReads { break }
    let startedAt = ProcessInfo.processInfo.systemUptime
    _ = try await coordinator.seek(to: 1)
    let elapsed = ProcessInfo.processInfo.systemUptime - startedAt

    #expect(elapsed < 1.5)
    await file.releaseBlockedRead()
    await coordinator.stop()
}

@MainActor
@Test func coordinatorEnforcesRecoveryElapsedDeadlineAndClosesLateHandle() async throws {
    let data = try playbackFixtureData("video-h264-aac.mkv")
    let identity = recoveryIdentity(size: data.count)
    let interrupted = RecoveryTestFile(
        data: data,
        identity: identity,
        failStartingAtRead: 7
    )
    let recovered = RecoveryTestFile(data: data, identity: identity)
    let reopener = DelayedRecoveryTestReopener()
    let requests = reopener.requests
    let coordinator = PlaybackCoordinator(
        renderer: SampleBufferRenderer(maximumPendingDuration: 3),
        configuration: recoveryTestConfiguration(maximumRetryDuration: 0.05)
    )

    try await coordinator.start(
        file: interrupted,
        reopenFile: { try await reopener.open() }
    )
    for await _ in requests { break }
    try await waitForCoordinator(coordinator, timeout: 0.5) {
        $0.failure?.boundary == .networkRead
    }
    #expect(await coordinator.snapshot.failure?.boundary == .networkRead)

    await reopener.release(recovered)
    try await Task.sleep(for: .milliseconds(100))
    #expect(recovered.closeCount == 1)
    await coordinator.stop()
}

@MainActor
@Test func coordinatorClosesResourcesAfterTerminalPlaybackFailure() async throws {
    let data = try playbackFixtureData("video-h264-aac.mkv")
    let interrupted = RecoveryTestFile(
        data: data,
        identity: recoveryIdentity(size: data.count),
        failStartingAtRead: 7
    )
    let coordinator = PlaybackCoordinator(
        renderer: SampleBufferRenderer(maximumPendingDuration: 3),
        configuration: .test
    )

    try await coordinator.start(file: interrupted)
    try await waitForCoordinator(coordinator, timeout: 3) {
        if case .failed = $0.state { return true }
        return false
    }

    #expect(interrupted.closeCount == 1)
    await coordinator.stop()
    #expect(interrupted.closeCount == 1)
}

@MainActor
@Test func coordinatorPublishesRuntimeSoftwareDecoderFallback() async throws {
    let file = try PlaybackTestFile(fixture: "video-h264-aac.mkv")
    let coordinator = PlaybackCoordinator(
        renderer: SampleBufferRenderer(maximumPendingDuration: 3),
        configuration: recoveryTestConfiguration(
            maximumRetryDuration: 1,
            decodeConfiguration: FFmpegDecodeConfiguration(
                preferHardware: true,
                forceHardwareDecodeFailure: true
            )
        )
    )

    try await coordinator.start(file: file)
    try await waitForCoordinator(coordinator) {
        $0.videoDecoderMode == .software
    }

    await coordinator.stop()
    #expect(file.closeCount == 1)
}

@MainActor
@Test func coordinatorFreezesAndRefillsAfterRendererUnderrun() async throws {
    let data = try playbackFixtureData("video-h264-aac.mkv")
    let file = DelayedReadTestFile(
        data: data,
        identity: recoveryIdentity(size: data.count),
        blockAtRead: 7
    )
    let blockedReads = file.blockedReads
    let renderer = SampleBufferRenderer(maximumPendingDuration: 3)
    let coordinator = PlaybackCoordinator(
        renderer: renderer,
        configuration: recoveryTestConfiguration(
            maximumRetryDuration: 1,
            ioTimeout: 3
        )
    )

    try await coordinator.start(file: file)
    for await _ in blockedReads { break }
    try await waitForCoordinator(coordinator, timeout: 2.5) {
        $0.state == .buffering(.underrun)
    }
    #expect(renderer.state.rate == 0)

    await file.releaseBlockedRead()
    try await waitForCoordinator(coordinator) { $0.state == .playing }
    await coordinator.stop()
}

@MainActor
private func waitForCoordinator(
    _ coordinator: PlaybackCoordinator,
    timeout: TimeInterval = 2,
    predicate: (PlaybackCoordinatorSnapshot) -> Bool
) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while ProcessInfo.processInfo.systemUptime < deadline {
        if predicate(await coordinator.snapshot) { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("timed out waiting for coordinator state: \(await coordinator.snapshot)")
}

private final class PlaybackTestFile: MediaReadableFile, @unchecked Sendable {
    let identity: MediaFileIdentity
    private let data: Data
    private let lock = NSLock()
    private var closes = 0
    private var reads = 0

    var closeCount: Int { lock.withLock { closes } }
    var readCount: Int { lock.withLock { reads } }

    init(fixture: String) throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(fixture)
        self.data = try Data(contentsOf: url)
        self.identity = MediaFileIdentity(
            sourceID: UUID(),
            path: "/\(fixture)",
            size: Int64(data.count),
            modifiedAt: nil
        )
    }

    func read(at offset: Int64, length: Int) async throws -> Data {
        lock.withLock { reads += 1 }
        guard offset >= 0, length > 0, offset < identity.size else { return Data() }
        let start = Int(offset)
        let end = min(start + length, data.count)
        return data.subdata(in: start..<end)
    }

    func close() async {
        lock.withLock { closes += 1 }
    }
}

private enum RecoveryTestError: Error {
    case interrupted
}

private final class RecoveryTestFile: MediaReadableFile, @unchecked Sendable {
    let identity: MediaFileIdentity

    private let data: Data
    private let failStartingAtRead: Int?
    private let lock = NSLock()
    private var reads = 0
    private var closes = 0

    var closeCount: Int { lock.withLock { closes } }

    init(
        data: Data,
        identity: MediaFileIdentity,
        failStartingAtRead: Int? = nil
    ) {
        self.data = data
        self.identity = identity
        self.failStartingAtRead = failStartingAtRead
    }

    func read(at offset: Int64, length: Int) async throws -> Data {
        let shouldFail = lock.withLock {
            reads += 1
            return failStartingAtRead.map { reads >= $0 } ?? false
        }
        if shouldFail { throw RecoveryTestError.interrupted }
        guard offset >= 0, length > 0, offset < identity.size else { return Data() }
        let start = Int(offset)
        let end = min(start + length, data.count)
        return data.subdata(in: start..<end)
    }

    func close() async {
        lock.withLock { closes += 1 }
    }
}

private final class RecoveryTestReopener: @unchecked Sendable {
    private let file: RecoveryTestFile
    private let lock = NSLock()
    private var opens = 0

    var openCount: Int { lock.withLock { opens } }

    init(file: RecoveryTestFile) {
        self.file = file
    }

    func open() throws -> any MediaReadableFile {
        lock.withLock { opens += 1 }
        return file
    }
}

private final class FailingRecoveryTestReopener: @unchecked Sendable {
    private let lock = NSLock()
    private var opens = 0

    var openCount: Int { lock.withLock { opens } }

    func open() throws -> any MediaReadableFile {
        lock.withLock { opens += 1 }
        throw RecoveryTestError.interrupted
    }
}

private actor DelayedRecoveryTestReopener {
    nonisolated let requests: AsyncStream<Void>

    private let requestContinuation: AsyncStream<Void>.Continuation
    private var continuation: CheckedContinuation<any MediaReadableFile, Never>?

    init() {
        let stream = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        requests = stream.stream
        requestContinuation = stream.continuation
    }

    func open() async throws -> any MediaReadableFile {
        requestContinuation.yield(())
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release(_ file: any MediaReadableFile) {
        continuation?.resume(returning: file)
        continuation = nil
    }
}

private actor DelayedReadTestFile: MediaReadableFile {
    nonisolated let identity: MediaFileIdentity
    nonisolated let blockedReads: AsyncStream<Void>

    private let data: Data
    private let blockAtRead: Int
    private let blockedReadContinuation: AsyncStream<Void>.Continuation
    private var readCount = 0
    private var didBlock = false
    private var continuation: CheckedContinuation<Data, Never>?
    private var blockedOffset: Int64 = 0
    private var blockedLength = 0

    init(data: Data, identity: MediaFileIdentity, blockAtRead: Int) {
        self.data = data
        self.identity = identity
        self.blockAtRead = blockAtRead
        let stream = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        blockedReads = stream.stream
        blockedReadContinuation = stream.continuation
    }

    func read(at offset: Int64, length: Int) async throws -> Data {
        readCount += 1
        if readCount == blockAtRead, !didBlock {
            didBlock = true
            blockedOffset = offset
            blockedLength = length
            blockedReadContinuation.yield(())
            return await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }
        return bytes(at: offset, length: length)
    }

    func releaseBlockedRead() {
        continuation?.resume(returning: bytes(at: blockedOffset, length: blockedLength))
        continuation = nil
    }

    func close() {
        releaseBlockedRead()
    }

    private func bytes(at offset: Int64, length: Int) -> Data {
        guard offset >= 0, length > 0, offset < identity.size else { return Data() }
        let start = Int(offset)
        let end = min(start + length, data.count)
        return data.subdata(in: start..<end)
    }
}

private func recoveryIdentity(size: Int) -> MediaFileIdentity {
    MediaFileIdentity(
        sourceID: UUID(),
        path: "/video-h264-aac.mkv",
        size: Int64(size),
        modifiedAt: Date(timeIntervalSince1970: 1)
    )
}

private func recoveryTestConfiguration(
    maximumRetryDuration: TimeInterval,
    ioTimeout: TimeInterval? = nil,
    decodeConfiguration: FFmpegDecodeConfiguration = .default
) -> PlaybackCoordinatorConfiguration {
    let base = PlaybackCoordinatorConfiguration.test
    return PlaybackCoordinatorConfiguration(
        pageSize: base.pageSize,
        cacheCapacityBytes: base.cacheCapacityBytes,
        ioTimeout: ioTimeout ?? base.ioTimeout,
        videoQueueLimits: base.videoQueueLimits,
        audioQueueLimits: base.audioQueueLimits,
        startupVideoDuration: base.startupVideoDuration,
        startupAudioDuration: base.startupAudioDuration,
        maximumRetryAttempts: base.maximumRetryAttempts,
        maximumRetryDuration: maximumRetryDuration,
        decodeConfiguration: decodeConfiguration
    )
}

private func playbackFixtureData(_ fileName: String) throws -> Data {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
        .appendingPathComponent(fileName)
    return try Data(contentsOf: url)
}
