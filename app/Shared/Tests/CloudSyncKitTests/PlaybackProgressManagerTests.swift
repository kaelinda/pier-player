import Foundation
import Testing
@testable import CloudSyncKit

@Test func managerThrottlesPeriodicWritesButForceFlushes() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PlaybackProgressStore(fileURL: directory.appendingPathComponent("progress.json"))
    let sync = ProgressRecordingSyncCoordinator()
    let clock = ProgressTestClock(now: Date(timeIntervalSince1970: 100))
    let manager = PlaybackProgressManager(
        store: store,
        syncCoordinator: sync,
        minimumSaveInterval: 15,
        now: clock.current
    )
    let mediaID = String(repeating: "d", count: 64)
    let sourceID = UUID()

    await manager.record(
        mediaID: mediaID,
        sourceID: sourceID,
        position: 10,
        duration: 100,
        force: false
    )
    await manager.record(
        mediaID: mediaID,
        sourceID: sourceID,
        position: 20,
        duration: 100,
        force: false
    )
    #expect(await sync.mutations.count == 1)

    await manager.record(
        mediaID: mediaID,
        sourceID: sourceID,
        position: 20,
        duration: 100,
        force: true
    )
    #expect(await sync.mutations.count == 2)
    #expect(await manager.progress(mediaID: mediaID)?.position == 20)
}

@Test func managerKeepsCompletionUntilRewatchPassesOpeningThreshold() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PlaybackProgressStore(fileURL: directory.appendingPathComponent("progress.json"))
    let manager = PlaybackProgressManager(store: store)
    let mediaID = String(repeating: "e", count: 64)
    let sourceID = UUID()

    await manager.record(
        mediaID: mediaID,
        sourceID: sourceID,
        position: 96,
        duration: 100,
        force: true
    )
    await manager.record(
        mediaID: mediaID,
        sourceID: sourceID,
        position: 4,
        duration: 100,
        force: true
    )
    #expect(await manager.progress(mediaID: mediaID)?.isCompleted == true)

    await manager.record(
        mediaID: mediaID,
        sourceID: sourceID,
        position: 5,
        duration: 100,
        force: true
    )
    #expect(await manager.progress(mediaID: mediaID)?.isCompleted == false)
}

@Test func managerSuspendedOpeningRecordDoesNotOverwriteNewerProgressOrSyncMutation() async throws {
    let mediaID = String(repeating: "f", count: 64)
    let sourceID = UUID()
    let completed = try PlaybackProgress(
        mediaID: mediaID,
        sourceID: sourceID,
        position: 96,
        duration: 100,
        modifiedAt: Date(timeIntervalSince1970: 99)
    )
    let store = ControlledProgressStore(initial: completed)
    let sync = ProgressRecordingSyncCoordinator()
    let clock = SequencedProgressTestClock(
        dates: [
            Date(timeIntervalSince1970: 100),
            Date(timeIntervalSince1970: 101),
        ]
    )
    let manager = PlaybackProgressManager(
        store: store,
        syncCoordinator: sync,
        now: clock.current
    )

    let openingRecord = Task {
        await manager.record(
            mediaID: mediaID,
            sourceID: sourceID,
            position: 4,
            duration: 100,
            force: true
        )
    }
    await store.waitUntilOpeningRecordReachedStore()

    await manager.record(
        mediaID: mediaID,
        sourceID: sourceID,
        position: 10,
        duration: 100,
        force: true
    )
    await store.releaseOpeningRead()
    await openingRecord.value

    #expect(await store.progressWithoutSuspending(mediaID: mediaID)?.position == 10)
    #expect(await sync.mutations.last?.progressPosition == 10)
}

@Test func managerRemovesOnlyProgressForRequestedSource() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PlaybackProgressStore(fileURL: directory.appendingPathComponent("progress.json"))
    let manager = PlaybackProgressManager(store: store)
    let removedSourceID = UUID()
    let retainedSourceID = UUID()
    let removedMediaID = String(repeating: "a", count: 64)
    let retainedMediaID = String(repeating: "b", count: 64)

    await manager.record(
        mediaID: removedMediaID,
        sourceID: removedSourceID,
        position: 20,
        duration: 100,
        force: true
    )
    await manager.record(
        mediaID: retainedMediaID,
        sourceID: retainedSourceID,
        position: 30,
        duration: 100,
        force: true
    )

    await manager.removeAll(sourceID: removedSourceID)

    #expect(await manager.progress(mediaID: removedMediaID) == nil)
    #expect(await manager.progress(mediaID: retainedMediaID)?.position == 30)
}

@Test func managerStrictCleanupSnapshotsRemovesAndRestoresOneSource() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PlaybackProgressStore(fileURL: directory.appendingPathComponent("progress.json"))
    let manager = PlaybackProgressManager(store: store)
    let removedSourceID = UUID()
    let retainedSourceID = UUID()
    let removed = try PlaybackProgress(
        mediaID: String(repeating: "e", count: 64),
        sourceID: removedSourceID,
        position: 20,
        duration: 100,
        modifiedAt: Date()
    )
    let retained = try PlaybackProgress(
        mediaID: String(repeating: "f", count: 64),
        sourceID: retainedSourceID,
        position: 30,
        duration: 100,
        modifiedAt: Date()
    )
    try await store.replaceAll([removed, retained])

    let snapshot = try await manager.snapshotPersistently(sourceID: removedSourceID)
    try await manager.removePersistently(sourceID: removedSourceID)
    #expect(try await store.load() == [retained])

    try await manager.restorePersistently(snapshot, sourceID: removedSourceID)
    #expect(try await store.load() == [removed, retained])
}

@Test func managerStrictCleanupPropagatesStoreFailure() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try Data("blocking-file".utf8).write(to: directory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PlaybackProgressStore(fileURL: directory.appendingPathComponent("progress.json"))
    let manager = PlaybackProgressManager(store: store)

    await #expect(throws: (any Error).self) {
        try await manager.removePersistently(sourceID: UUID())
    }
}

@Test func managerDoesNotThrottleSameMediaIDAcrossSources() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PlaybackProgressStore(fileURL: directory.appendingPathComponent("progress.json"))
    let clock = ProgressTestClock(now: Date(timeIntervalSince1970: 100))
    let manager = PlaybackProgressManager(
        store: store,
        minimumSaveInterval: 15,
        now: clock.current
    )
    let mediaID = String(repeating: "c", count: 64)
    let firstSourceID = UUID()
    let secondSourceID = UUID()

    await manager.record(
        mediaID: mediaID,
        sourceID: firstSourceID,
        position: 10,
        duration: 100,
        force: false
    )
    await manager.record(
        mediaID: mediaID,
        sourceID: secondSourceID,
        position: 20,
        duration: 100,
        force: false
    )

    #expect(await manager.progress(mediaID: mediaID)?.sourceID == secondSourceID)
    #expect(await manager.progress(mediaID: mediaID)?.position == 20)
}

private final class ProgressTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private let value: Date

    init(now: Date) { value = now }

    func current() -> Date { lock.withLock { value } }
}

private final class SequencedProgressTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var dates: [Date]

    init(dates: [Date]) { self.dates = dates }

    func current() -> Date {
        lock.withLock { dates.removeFirst() }
    }
}

private actor ControlledProgressStore: PlaybackProgressStoring {
    private var values: [String: PlaybackProgress]
    private let openingReadGate = ProgressReadGate()
    private let reachedStream: AsyncStream<Void>
    private let reachedContinuation: AsyncStream<Void>.Continuation

    init(initial: PlaybackProgress) {
        values = [initial.mediaID: initial]
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        reachedStream = pair.stream
        reachedContinuation = pair.continuation
    }

    func waitUntilOpeningRecordReachedStore() async {
        var iterator = reachedStream.makeAsyncIterator()
        _ = await iterator.next()
    }

    func releaseOpeningRead() async {
        await openingReadGate.release()
    }

    func progressWithoutSuspending(mediaID: String) -> PlaybackProgress? {
        values[mediaID]
    }

    func load() -> [PlaybackProgress] {
        Array(values.values)
    }

    func progress(mediaID: String) async -> PlaybackProgress? {
        let snapshot = values[mediaID]
        reachedContinuation.yield()
        await openingReadGate.waitForRelease()
        return snapshot
    }

    func record(
        mediaID: String,
        sourceID: UUID,
        position: TimeInterval,
        duration: TimeInterval,
        modifiedAt: Date
    ) async throws -> PlaybackProgress {
        let progress = try PlaybackProgress(
            mediaID: mediaID,
            sourceID: sourceID,
            position: position,
            duration: duration,
            modifiedAt: modifiedAt,
            isCompleted: position < 5 ? values[mediaID]?.isCompleted : nil
        )
        values[mediaID] = progress
        if position < 5 {
            reachedContinuation.yield()
            await openingReadGate.waitForRelease()
        }
        return progress
    }

    func upsert(_ progress: PlaybackProgress) {
        values[progress.mediaID] = progress
    }

    func removeAll(sourceID: UUID) {
        values = values.filter { $0.value.sourceID != sourceID }
    }

    func replaceAll(_ values: [PlaybackProgress]) {
        self.values = Dictionary(uniqueKeysWithValues: values.map { ($0.mediaID, $0) })
    }

    func restore(_ snapshot: [PlaybackProgress], sourceID: UUID) {
        removeAll(sourceID: sourceID)
        for progress in snapshot {
            values[progress.mediaID] = progress
        }
    }
}

private actor ProgressReadGate {
    private var isReleased = false
    private var continuation: CheckedContinuation<Void, Never>?

    func waitForRelease() async {
        guard !isReleased else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}

private actor ProgressRecordingSyncCoordinator: CloudSyncCoordinating {
    private(set) var mutations: [CloudSyncMutation] = []

    func enqueue(_ mutation: CloudSyncMutation) {
        mutations.append(mutation)
    }

    func synchronize(local: CloudSyncSnapshot) -> CloudSyncSnapshot { local }
}

private extension CloudSyncMutation {
    var progressPosition: TimeInterval? {
        guard case let .upsertProgress(progress) = self else { return nil }
        return progress.position
    }
}
