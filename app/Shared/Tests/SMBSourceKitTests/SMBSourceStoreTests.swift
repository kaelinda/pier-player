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
        share: "Media"
    )
    let second = SMBStorageSource(
        id: UUID(),
        displayName: "Second",
        host: "second.local",
        share: "Archive"
    )
    let updated = SMBStorageSource(
        id: first.id,
        displayName: "Living Room",
        host: "nas.local",
        share: "Movies",
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
        share: "Media"
    )
    let store = SMBSourceStore(fileURL: fileURL)
    try await store.save([])

    await #expect(throws: SMBSourceStoreError.sourceNotFound(missing.id)) {
        try await store.update(missing)
    }
}

@Test func migratesLegacyCredentialsBeforeRemovingPlaintextFields() async throws {
    let fixture = try SourceStoreFixture()
    defer { fixture.cleanup() }
    let sourceID = UUID()
    try legacySourceJSON(id: sourceID).write(to: fixture.fileURL, options: .atomic)
    let credentialStore = MigrationCredentialStore()

    try await fixture.store.migrateCredentials(to: credentialStore)

    let credential = try #require(await credentialStore.load(sourceID: sourceID))
    #expect(credential.credential.username == "viewer")
    #expect(credential.credential.password == "plain-secret")
    let rewritten = try String(contentsOf: fixture.fileURL, encoding: .utf8)
    #expect(!rewritten.contains("username"))
    #expect(!rewritten.contains("password"))
    #expect(!rewritten.contains("plain-secret"))
    let stored = try #require(try await fixture.store.load().first)
    #expect(stored.id == sourceID)
}

@Test func failedCredentialMigrationPreservesLegacySourceBytes() async throws {
    let fixture = try SourceStoreFixture()
    defer { fixture.cleanup() }
    let original = legacySourceJSON(id: UUID())
    try original.write(to: fixture.fileURL, options: .atomic)
    let credentialStore = MigrationCredentialStore(shouldFailSave: true)

    await #expect(throws: MigrationCredentialError.saveFailed) {
        try await fixture.store.migrateCredentials(to: credentialStore)
    }

    #expect(try Data(contentsOf: fixture.fileURL) == original)
}

private struct SourceStoreFixture {
    let directory: URL
    let fileURL: URL
    let store: SMBSourceStore

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        fileURL = directory.appendingPathComponent("sources.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = SMBSourceStore(fileURL: fileURL)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private enum MigrationCredentialError: Error {
    case saveFailed
}

private actor MigrationCredentialStore: SMBCredentialStore {
    private var values: [UUID: StoredSMBCredential] = [:]
    private let shouldFailSave: Bool

    init(shouldFailSave: Bool = false) {
        self.shouldFailSave = shouldFailSave
    }

    func save(sourceID: UUID, credential: SMBCredential, domain: String?) throws {
        if shouldFailSave { throw MigrationCredentialError.saveFailed }
        values[sourceID] = StoredSMBCredential(credential: credential, domain: domain)
    }

    func load(sourceID: UUID) -> StoredSMBCredential? {
        values[sourceID]
    }

    func delete(sourceID: UUID) {
        values[sourceID] = nil
    }
}

private func legacySourceJSON(id: UUID) -> Data {
    Data(
        """
        [{
          "id":"\(id.uuidString)",
          "displayName":"Home NAS",
          "host":"nas.local",
          "share":"Media",
          "username":"viewer",
          "password":"plain-secret",
          "requiresEncryption":false
        }]
        """.utf8
    )
}
