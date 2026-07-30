import Foundation
import Testing
@testable import DiagnosticsKit

@Test func storeAppendsRollsAndSnapshotsActiveRun() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let runID = UUID()
    let store = FileDiagnosticStore(
        rootDirectory: root,
        configuration: DiagnosticStoreConfiguration(
            maximumSegmentBytes: 60,
            maximumBatchBytes: 1,
            maximumAge: 7 * 24 * 60 * 60,
            maximumStorageBytes: 1_000_000
        )
    )
    try await store.startRun(manifest(runID: runID, startedAt: Date(timeIntervalSince1970: 0)))

    try await store.appendEvents([
        Data("{\"event\":\"first-record-with-padding\"}".utf8),
        Data("{\"event\":\"second-record-with-padding\"}".utf8),
    ])
    try await store.flush()

    let snapshot = try await store.snapshot(runID: runID)
    let rootMode = try posixMode(at: root)
    let segmentModes = try snapshot.eventSegmentURLs.map(posixMode(at:))

    #expect(snapshot.eventSegments.count == 2)
    #expect(snapshot.eventSegments.allSatisfy { $0.last == 0x0A })
    #expect(snapshot.manifest.endedAt == nil)
    #expect(rootMode == 0o700)
    #expect(segmentModes.allSatisfy { $0 == 0o600 })
}

@Test func retentionDeletesExpiredRunsBeforeCapacityVictims() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let oldRunID = UUID()
    let newerRunID = UUID()
    let now = Date(timeIntervalSince1970: 20 * 24 * 60 * 60)
    let configuration = DiagnosticStoreConfiguration(
        maximumSegmentBytes: 1_000,
        maximumBatchBytes: 1,
        maximumAge: 7 * 24 * 60 * 60,
        maximumStorageBytes: 1_000_000
    )
    let store = FileDiagnosticStore(rootDirectory: root, configuration: configuration)

    try await store.startRun(manifest(
        runID: oldRunID,
        startedAt: now.addingTimeInterval(-10 * 24 * 60 * 60)
    ))
    try await store.appendEvents([Data("{\"old\":1}".utf8)])
    try await store.closeRun(endedAt: now.addingTimeInterval(-9 * 24 * 60 * 60))

    try await store.startRun(manifest(
        runID: newerRunID,
        startedAt: now.addingTimeInterval(-60)
    ))
    try await store.appendEvents([Data("{\"new\":1}".utf8)])
    try await store.closeRun(endedAt: now.addingTimeInterval(-30))

    let result = try await store.enforceRetention(now: now)
    let summaries = try await store.summaries()

    #expect(result.deletedRunIDs == [oldRunID])
    #expect(!result.storageLimitReached)
    #expect(summaries.map(\.runID) == [newerRunID])
}

@Test func retentionDeletesOldestClosedRunToReachCapacity() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let firstRunID = UUID()
    let secondRunID = UUID()
    let broadConfiguration = DiagnosticStoreConfiguration(
        maximumSegmentBytes: 2_000,
        maximumBatchBytes: 1,
        maximumAge: 100_000,
        maximumStorageBytes: 1_000_000
    )
    let writer = FileDiagnosticStore(rootDirectory: root, configuration: broadConfiguration)

    try await writer.startRun(manifest(runID: firstRunID, startedAt: Date(timeIntervalSince1970: 1)))
    try await writer.appendEvents([Data(repeating: 0x31, count: 500)])
    try await writer.closeRun(endedAt: Date(timeIntervalSince1970: 2))
    try await writer.startRun(manifest(runID: secondRunID, startedAt: Date(timeIntervalSince1970: 3)))
    try await writer.appendEvents([Data(repeating: 0x32, count: 500)])
    try await writer.closeRun(endedAt: Date(timeIntervalSince1970: 4))

    let usage = try await writer.currentUsageBytes()
    let constrained = FileDiagnosticStore(
        rootDirectory: root,
        configuration: DiagnosticStoreConfiguration(
            maximumSegmentBytes: 2_000,
            maximumBatchBytes: 1,
            maximumAge: 100_000,
            maximumStorageBytes: usage - 1
        )
    )
    let result = try await constrained.enforceRetention(now: Date(timeIntervalSince1970: 10))

    #expect(result.deletedRunIDs == [firstRunID])
    #expect(!result.storageLimitReached)
    #expect(try await constrained.summaries().map(\.runID) == [secondRunID])
}

@Test func retentionNeverDeletesActiveRun() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let runID = UUID()
    let store = FileDiagnosticStore(
        rootDirectory: root,
        configuration: DiagnosticStoreConfiguration(
            maximumSegmentBytes: 1_000,
            maximumBatchBytes: 1,
            maximumAge: 1,
            maximumStorageBytes: 1
        )
    )
    try await store.startRun(manifest(runID: runID, startedAt: Date(timeIntervalSince1970: 0)))
    try await store.appendEvents([Data(repeating: 0x33, count: 100)])

    let result = try await store.enforceRetention(now: Date(timeIntervalSince1970: 100))

    #expect(result.deletedRunIDs.isEmpty)
    #expect(result.storageLimitReached)
    #expect(try await store.snapshot(runID: runID).manifest.runID == runID)
}

private func manifest(runID: UUID, startedAt: Date) -> DiagnosticRunManifest {
    DiagnosticRunManifest(
        runID: runID,
        startedAt: startedAt,
        policy: .standard,
        environment: DiagnosticRunEnvironment(
            appVersion: "1.0",
            appBuild: "1",
            osVersion: "macOS",
            architecture: .arm64,
            hardwareClass: .mac,
            networkAvailability: .available,
            networkInterface: .ethernet
        )
    )
}

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("pier-diagnostics-tests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
}

private func posixMode(at url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
}
