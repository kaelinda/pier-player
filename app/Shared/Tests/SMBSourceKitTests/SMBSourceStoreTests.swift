import Foundation
import Testing
@testable import SMBSourceKit

@Test func updateReplacesOneStoredSourceWithoutChangingOrder() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let fileURL = directory.appendingPathComponent("sources.json")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let first = SMBStorageSource(
        id: UUID(),
        displayName: "First",
        host: "first.local",
        share: "Media",
        username: "viewer",
        password: "old"
    )
    let second = SMBStorageSource(
        id: UUID(),
        displayName: "Second",
        host: "second.local",
        share: "Archive",
        username: "viewer",
        password: "secret"
    )
    let updated = SMBStorageSource(
        id: first.id,
        displayName: "Living Room",
        host: "nas.local",
        share: "Movies",
        username: "editor",
        password: "new",
        domain: "WORKGROUP",
        requiresEncryption: true
    )
    let store = SMBSourceStore(fileURL: fileURL)
    try await store.save([first, second])

    try await store.update(updated)

    let loaded = try await store.load()
    #expect(loaded.map(\.id) == [first.id, second.id])
    #expect(loaded[0] == updated)
    #expect(loaded[1] == second)
}

@Test func updateRejectsAnUnknownStoredSource() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let fileURL = directory.appendingPathComponent("sources.json")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let missing = SMBStorageSource(
        id: UUID(),
        displayName: "Missing",
        host: "nas.local",
        share: "Media",
        username: "viewer",
        password: "secret"
    )
    let store = SMBSourceStore(fileURL: fileURL)
    try await store.save([])

    await #expect(throws: SMBSourceStoreError.sourceNotFound(missing.id)) {
        try await store.update(missing)
    }
}
