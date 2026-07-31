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

@Test func corruptProgressFileIsIsolatedAsEmptyState() async throws {
    let fixture = try ProgressStoreFixture()
    defer { fixture.cleanup() }
    try Data("not-json".utf8).write(to: fixture.fileURL)

    #expect(try await fixture.store.load().isEmpty)
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
