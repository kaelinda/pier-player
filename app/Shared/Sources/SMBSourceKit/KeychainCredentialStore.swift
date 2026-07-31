import Foundation
import Security

public enum KeychainCredentialStoreError: Error, Equatable, Sendable {
    case invalidService
    case corruptItem
    case unexpectedStatus(OSStatus)
}

struct KeychainCredentialMetadata: Codable, Equatable, Sendable {
    let username: String
    let domain: String?
}

public actor KeychainCredentialStore: SMBCredentialStore {
    private let service: String
    private let synchronizesCredentials: Bool
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        service: String = "app.pier-player.smb-credentials",
        synchronizesCredentials: Bool = true
    ) {
        self.service = service
        self.synchronizesCredentials = synchronizesCredentials
    }

    public func save(
        sourceID: UUID,
        credential: SMBCredential,
        domain: String?
    ) throws {
        try validateService()
        let metadata = KeychainCredentialMetadata(
            username: credential.username,
            domain: domain?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        )
        let metadataData = try encoder.encode(metadata)
        let secretData = Data(credential.password.utf8)
        do {
            try save(
                sourceID: sourceID,
                metadataData: metadataData,
                secretData: secretData,
                synchronizable: synchronizesCredentials
            )
        } catch KeychainCredentialStoreError.unexpectedStatus(errSecMissingEntitlement) {
            try save(
                sourceID: sourceID,
                metadataData: metadataData,
                secretData: secretData,
                synchronizable: false
            )
        }
    }

    private func save(
        sourceID: UUID,
        metadataData: Data,
        secretData: Data,
        synchronizable: Bool
    ) throws {
        let query = baseQuery(sourceID: sourceID, synchronizable: synchronizable)
        var attributes: [String: Any] = [
            kSecAttrGeneric as String: metadataData,
            kSecValueData as String: secretData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        if synchronizable {
            attributes[kSecAttrSynchronizable as String] = kCFBooleanTrue
        }

        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            attributes as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainCredentialStoreError.unexpectedStatus(updateStatus)
        }

        var item = query
        attributes.forEach { item[$0.key] = $0.value }
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainCredentialStoreError.unexpectedStatus(addStatus)
        }
    }

    public func load(sourceID: UUID) throws -> StoredSMBCredential? {
        do {
            return try performLoad(sourceID: sourceID)
        } catch {
            return nil
        }
    }

    private func performLoad(sourceID: UUID) throws -> StoredSMBCredential? {
        try validateService()
        do {
            return try performLoad(
                sourceID: sourceID,
                synchronizable: synchronizesCredentials
            )
        } catch KeychainCredentialStoreError.unexpectedStatus(errSecMissingEntitlement) {
            return try performLoad(sourceID: sourceID, synchronizable: false)
        }
    }

    private func performLoad(
        sourceID: UUID,
        synchronizable: Bool
    ) throws -> StoredSMBCredential? {
        try validateService()
        var query = baseQuery(sourceID: sourceID, synchronizable: synchronizable)
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw KeychainCredentialStoreError.unexpectedStatus(status)
        }
        guard
            let item = result as? [String: Any],
            let secretData = item[kSecValueData as String] as? Data,
            let password = String(data: secretData, encoding: .utf8),
            let metadataData = item[kSecAttrGeneric as String] as? Data,
            let metadata = try? decoder.decode(
                KeychainCredentialMetadata.self,
                from: metadataData
            )
        else {
            return nil
        }

        guard let credential = try? SMBCredential(
            username: metadata.username,
            password: password
        ) else {
            return nil
        }
        return StoredSMBCredential(credential: credential, domain: metadata.domain)
    }

    public func delete(sourceID: UUID) throws {
        try validateService()
        let status = SecItemDelete(baseQuery(
            sourceID: sourceID,
            synchronizable: synchronizesCredentials
        ) as CFDictionary)
        if status == errSecMissingEntitlement, synchronizesCredentials {
            let fallbackStatus = SecItemDelete(baseQuery(
                sourceID: sourceID,
                synchronizable: false
            ) as CFDictionary)
            guard fallbackStatus == errSecSuccess || fallbackStatus == errSecItemNotFound else {
                throw KeychainCredentialStoreError.unexpectedStatus(fallbackStatus)
            }
            return
        }
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainCredentialStoreError.unexpectedStatus(status)
        }
    }

    nonisolated func baseQuery(sourceID: UUID, synchronizable: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: sourceID.uuidString,
        ]
        if synchronizable {
            query[kSecAttrSynchronizable as String] = kCFBooleanTrue
        }
        return query
    }

    private func validateService() throws {
        guard !service.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KeychainCredentialStoreError.invalidService
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
