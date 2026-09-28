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

@Test func managerRemovesOneProgressAsATombstoneAndClearsThrottleState() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PlaybackProgressStore(fileURL: directory.appendingPathComponent("progress.json"))
    let sync = ProgressRecordingSyncCoordinator()
    let clock = ProgressTestClock(now: Date(timeIntervalSince1970: 200))
    let manager = PlaybackProgressManager(
        store: store,
        syncCoordinator: sync,
        minimumSaveInterval: 15,
        now: clock.current
    )
    let mediaID = String(repeating: "a", count: 64)
    let sourceID = UUID()

    await manager.record(
        mediaID: mediaID,
        sourceID: sourceID,
        position: 12,
        duration: 100,
        force: true
    )
    await manager.remove(mediaID: mediaID)

    #expect(await manager.progress(mediaID: mediaID) == nil)
    let stored = await manager.allProgress()
    #expect(stored.count == 1)
    #expect(stored.first?.isDeleted == true)
    #expect(
        await sync.mutations.last
            == stored.first.map(CloudSyncMutation.deleteProgress)
    )

    clock.advance(by: 1)
    await manager.record(
        mediaID: mediaID,
        sourceID: sourceID,
        position: 7,
        duration: 100,
        force: false
    )
    #expect(await manager.progress(mediaID: mediaID)?.position == 7)
}

@Test func managerClearsAllKnownProgressIdempotently() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PlaybackProgressStore(fileURL: directory.appendingPathComponent("progress.json"))
    let sync = ProgressRecordingSyncCoordinator()
    let manager = PlaybackProgressManager(
        store: store,
        syncCoordinator: sync,
        now: Date.init
    )
    let sourceID = UUID()

    for (index, character) in ["b", "c"].enumerated() {
        await manager.record(
            mediaID: String(repeating: Character(character), count: 64),
            sourceID: sourceID,
            position: Double(index + 1),
            duration: 100,
            force: true
        )
    }

    await manager.removeAll()
    await manager.removeAll()

    #expect(await manager.allProgress().filter { !$0.isDeleted }.isEmpty)
    #expect(await sync.mutations.filter {
        if case .deleteProgress = $0 { return true }
        return false
    }.count == 2)
}

private final class ProgressTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(now: Date) { value = now }

    func current() -> Date { lock.withLock { value } }

    func advance(by interval: TimeInterval) {
        lock.withLock { value = value.addingTimeInterval(interval) }
    }
}

private actor ProgressRecordingSyncCoordinator: CloudSyncCoordinating {
    private(set) var mutations: [CloudSyncMutation] = []

    func enqueue(_ mutation: CloudSyncMutation) {
        mutations.append(mutation)
    }

    func synchronize(local: CloudSyncSnapshot) -> CloudSyncSnapshot { local }
}
