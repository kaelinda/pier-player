import Foundation
import Testing
@testable import CloudSyncKit

@Test func progressStoreRoundTripsAndRemovesOneSource() async throws {
    let fixture = try ProgressStoreFixture()
    defer { fixture.cleanup() }
    let firstSource = UUID()
    let secondSource = UUID()
    let first = try progress(id: "a", sourceID: firstSource, position: 20)
    let second = try progress(id: "b", sourceID: secondSource, position: 30)

    try await fixture.store.upsert(first)
    try await fixture.store.upsert(second)
    #expect(try await fixture.store.progress(mediaID: first.mediaID) == first)

    try await fixture.store.removeAll(sourceID: firstSource)

    #expect(try await fixture.store.progress(mediaID: first.mediaID) == nil)
    #expect(try await fixture.store.progress(mediaID: second.mediaID) == second)
}

@Test func progressStoreRecordCarriesCompletionAcrossOpeningPosition() async throws {
    let fixture = try ProgressStoreFixture()
    defer { fixture.cleanup() }
    let sourceID = UUID()
    let completed = try progress(id: "e", sourceID: sourceID, position: 96)
    try await fixture.store.upsert(completed)

    let opening = try await fixture.store.record(
        mediaID: completed.mediaID,
        sourceID: sourceID,
        position: 4,
        duration: 100,
        modifiedAt: Date(timeIntervalSince1970: 100)
    )

    #expect(opening.isCompleted)
    #expect(try await fixture.store.progress(mediaID: completed.mediaID) == opening)
}

@Test func corruptProgressFileIsIsolatedAsEmptyState() async throws {
    let fixture = try ProgressStoreFixture()
    defer { fixture.cleanup() }
    try Data("not-json".utf8).write(to: fixture.fileURL)

    #expect(try await fixture.store.load().isEmpty)
}

@Test func scopedRestoreDoesNotLoseConcurrentProgressFromAnotherSource() async throws {
    let fixture = try ProgressStoreFixture()
    defer { fixture.cleanup() }
    let restoredSource = UUID()
    let concurrentSource = UUID()
    let restored = try progress(id: "c", sourceID: restoredSource, position: 40)
    let concurrent = try progress(id: "d", sourceID: concurrentSource, position: 50)

    async let restore: Void = fixture.store.restore([restored], sourceID: restoredSource)
    async let upsert: Void = fixture.store.upsert(concurrent)
    _ = try await (restore, upsert)

    #expect(try await fixture.store.progress(mediaID: restored.mediaID) == restored)
    #expect(try await fixture.store.progress(mediaID: concurrent.mediaID) == concurrent)
}

private struct ProgressStoreFixture {
    let directory: URL
    let fileURL: URL
    let store: PlaybackProgressStore

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        fileURL = directory.appendingPathComponent("progress.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = PlaybackProgressStore(fileURL: fileURL)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private func progress(id: Character, sourceID: UUID, position: Double) throws -> PlaybackProgress {
    try PlaybackProgress(
        mediaID: String(repeating: id, count: 64),
        sourceID: sourceID,
        position: position,
        duration: 100,
        modifiedAt: Date(timeIntervalSince1970: position)
    )
}
