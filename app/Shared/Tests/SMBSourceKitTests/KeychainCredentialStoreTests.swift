import Foundation
import Security
import Testing
@testable import SMBSourceKit

@Suite(.serialized) struct KeychainCredentialStoreTests {
    @Test func saveLoadUpdateDeleteAndMissingCredential() async throws {
        let service = "app.pier-player.tests.\(UUID().uuidString)"
        let sourceID = UUID()
        let store = KeychainCredentialStore(service: service, synchronizesCredentials: false)
        defer { deleteAllKeychainItems(service: service) }

        #expect(try await store.load(sourceID: sourceID) == nil)

        let first = try SMBCredential(username: "viewer", password: "first")
        try await store.save(sourceID: sourceID, credential: first, domain: "WORKGROUP")
        let loaded = try #require(try await store.load(sourceID: sourceID))
        #expect(loaded.credential.username == "viewer")
        #expect(loaded.credential.password == "first")
        #expect(loaded.domain == "WORKGROUP")

        let updated = try SMBCredential(username: "editor", password: "second")
        try await store.save(sourceID: sourceID, credential: updated, domain: nil)
        let reloaded = try #require(try await store.load(sourceID: sourceID))
        #expect(reloaded.credential.username == "editor")
        #expect(reloaded.credential.password == "second")
        #expect(reloaded.domain == nil)

        try await store.delete(sourceID: sourceID)
        #expect(try await store.load(sourceID: sourceID) == nil)
    }

    @Test func sourceIDsUseSeparateOpaqueAccounts() async throws {
        let service = "app.pier-player.tests.\(UUID().uuidString)"
        let firstID = UUID()
        let secondID = UUID()
        let store = KeychainCredentialStore(service: service, synchronizesCredentials: false)
        defer { deleteAllKeychainItems(service: service) }

        try await store.save(
            sourceID: firstID,
            credential: try SMBCredential(username: "one", password: "1"),
            domain: nil
        )
        try await store.save(
            sourceID: secondID,
            credential: try SMBCredential(username: "two", password: "2"),
            domain: nil
        )

        let accounts = try keychainItems(service: service).compactMap {
            $0[kSecAttrAccount as String] as? String
        }
        #expect(Set(accounts) == Set([firstID.uuidString, secondID.uuidString]))
    }

    @Test func secretPayloadContainsOnlyThePassword() async throws {
        let service = "app.pier-player.tests.\(UUID().uuidString)"
        let sourceID = UUID()
        let store = KeychainCredentialStore(service: service, synchronizesCredentials: false)
        defer { deleteAllKeychainItems(service: service) }

        let credential = try SMBCredential(
            username: "private-user",
            password: "exact-password"
        )
        try await store.save(sourceID: sourceID, credential: credential, domain: "PRIVATE-DOMAIN")

        let item = try #require(try keychainItem(service: service, sourceID: sourceID))
        let secretData = try #require(item[kSecValueData as String] as? Data)
        #expect(secretData == Data("exact-password".utf8))
        #expect(!String(decoding: secretData, as: UTF8.self).contains("nas.local"))
        #expect(!String(decoding: secretData, as: UTF8.self).contains("Media"))

        let metadataData = try #require(item[kSecAttrGeneric as String] as? Data)
        let metadata = try JSONDecoder().decode(KeychainCredentialMetadata.self, from: metadataData)
        #expect(metadata.username == "private-user")
        #expect(metadata.domain == "PRIVATE-DOMAIN")
    }

    @Test func productionQueriesRequestSynchronizableCredentials() {
        let store = KeychainCredentialStore(service: "app.pier-player.tests")
        let query = store.baseQuery(sourceID: UUID(), synchronizable: true)

        #expect(query[kSecAttrSynchronizable as String] as? Bool == true)
    }
}

private func keychainItems(service: String) throws -> [[String: Any]] {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecReturnAttributes as String: true,
        kSecMatchLimit as String: kSecMatchLimitAll,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return [] }
    guard status == errSecSuccess else {
        throw KeychainCredentialStoreError.unexpectedStatus(status)
    }
    return result as? [[String: Any]] ?? []
}

private func keychainItem(service: String, sourceID: UUID) throws -> [String: Any]? {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: sourceID.uuidString,
        kSecReturnAttributes as String: true,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else {
        throw KeychainCredentialStoreError.unexpectedStatus(status)
    }
    return result as? [String: Any]
}

private func deleteAllKeychainItems(service: String) {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
    ]
    SecItemDelete(query as CFDictionary)
}
