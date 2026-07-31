import Foundation
import Testing
@testable import CloudSyncKit

@Test func synchronizationUploadsNewLocalSourceAndConverges() async throws {
    let fixture = try SyncFixture()
    defer { fixture.cleanup() }
    let local = source(name: "Living Room", modifiedAt: 10)

    let result = await fixture.coordinator.synchronize(
        local: CloudSyncSnapshot(sources: [local], progress: [])
    )

    #expect(result.sources == [local])
    #expect(await fixture.transport.savedMutations == [.upsertSource(local)])
    #expect(await fixture.coordinator.status == .upToDate)
    #expect(try await fixture.stateStore.pendingMutations().isEmpty)
}

@Test func failedUploadSurvivesCoordinatorRestartAndRetries() async throws {
    let fixture = try SyncFixture()
    defer { fixture.cleanup() }
    let local = source(name: "Offline NAS", modifiedAt: 20)
    await fixture.coordinator.enqueue(.upsertSource(local))
    await fixture.transport.setFailure(.temporarilyUnavailable)

    _ = await fixture.coordinator.synchronize(
        local: CloudSyncSnapshot(sources: [local], progress: [])
    )

    #expect(await fixture.coordinator.status == .temporarilyUnavailable)
    #expect(try await fixture.stateStore.pendingMutations() == [.upsertSource(local)])

    await fixture.transport.setFailure(nil)
    let restarted = SyncCoordinator(
        transport: fixture.transport,
        stateStore: SyncStateStore(fileURL: fixture.fileURL)
    )
    _ = await restarted.synchronize(local: .empty)

    #expect(await fixture.transport.savedMutations == [.upsertSource(local)])
    #expect(try await fixture.stateStore.pendingMutations().isEmpty)
}

@Test func pendingLocalEditWinsFetchedServerRecord() async throws {
    let fixture = try SyncFixture()
    defer { fixture.cleanup() }
    let id = UUID()
    let remote = source(id: id, name: "Remote", modifiedAt: 30)
    let local = source(id: id, name: "Local Pending", modifiedAt: 31)
    await fixture.transport.setSnapshot(CloudSyncSnapshot(sources: [remote], progress: []))
    try await fixture.stateStore.enqueue(.upsertSource(local))

    let result = await fixture.coordinator.synchronize(
        local: CloudSyncSnapshot(sources: [local], progress: [])
    )

    #expect(result.sources == [local])
    #expect(await fixture.transport.savedMutations == [.upsertSource(local)])
}

@Test func unavailableAccountLeavesLocalStateUsable() async throws {
    let fixture = try SyncFixture(accountAvailable: false)
    defer { fixture.cleanup() }
    let local = source(name: "Local Only", modifiedAt: 40)

    let result = await fixture.coordinator.synchronize(
        local: CloudSyncSnapshot(sources: [local], progress: [])
    )

    #expect(result.sources == [local])
    #expect(await fixture.coordinator.status == .accountUnavailable)
    #expect(await fixture.transport.fetchCount == 0)
}

private struct SyncFixture {
    let directory: URL
    let fileURL: URL
    let stateStore: SyncStateStore
    let transport: TestSyncTransport
    let coordinator: SyncCoordinator

    init(accountAvailable: Bool = true) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        fileURL = directory.appendingPathComponent("sync-state.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        stateStore = SyncStateStore(fileURL: fileURL)
        transport = TestSyncTransport(accountAvailable: accountAvailable)
        coordinator = SyncCoordinator(transport: transport, stateStore: stateStore)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private actor TestSyncTransport: CloudSyncTransport {
    private let isAccountAvailable: Bool
    private var snapshot: CloudSyncSnapshot = .empty
    private var failure: CloudSyncError?
    private(set) var savedMutations: [CloudSyncMutation] = []
    private(set) var fetchCount = 0

    init(accountAvailable: Bool) {
        self.isAccountAvailable = accountAvailable
    }

    func accountAvailable() async -> Bool { isAccountAvailable }

    func fetchSnapshot() async throws -> CloudSyncSnapshot {
        fetchCount += 1
        if let failure { throw failure }
        return snapshot
    }

    func save(_ mutations: [CloudSyncMutation]) async throws {
        if let failure { throw failure }
        savedMutations.append(contentsOf: mutations)
    }

    func setSnapshot(_ snapshot: CloudSyncSnapshot) {
        self.snapshot = snapshot
    }

    func setFailure(_ failure: CloudSyncError?) {
        self.failure = failure
    }
}

private func source(
    id: UUID = UUID(),
    name: String,
    modifiedAt: TimeInterval
) -> SyncedSMBSource {
    SyncedSMBSource(
        id: id,
        displayName: name,
        host: "nas.local",
        share: "Media",
        domain: nil,
        requiresEncryption: false,
        modifiedAt: Date(timeIntervalSince1970: modifiedAt)
    )
}
