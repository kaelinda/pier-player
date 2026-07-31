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

private final class ProgressTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private let value: Date

    init(now: Date) { value = now }

    func current() -> Date { lock.withLock { value } }
}

private actor ProgressRecordingSyncCoordinator: CloudSyncCoordinating {
    private(set) var mutations: [CloudSyncMutation] = []

    func enqueue(_ mutation: CloudSyncMutation) {
        mutations.append(mutation)
    }

    func synchronize(local: CloudSyncSnapshot) -> CloudSyncSnapshot { local }
}
