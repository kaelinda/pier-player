import CryptoKit
import Foundation
import Security

public enum DiagnosticIdentityStability: String, Codable, Equatable, Sendable {
    case stable
    case transient
}

public struct DiagnosticOpaqueIdentity: Codable, Equatable, Sendable {
    public let value: String
    public let stability: DiagnosticIdentityStability

    public init(value: String, stability: DiagnosticIdentityStability) {
        self.value = value
        self.stability = stability
    }
}

public protocol DiagnosticIdentityKeyStore: Sendable {
    func loadOrCreateKey() throws -> Data
}

public protocol DiagnosticIdentityProviding: Sendable {
    func fileIdentity(
        sourceID: UUID,
        normalizedPath: String,
        size: Int64,
        modifiedAt: Date?
    ) -> DiagnosticOpaqueIdentity
}

public struct HMACDiagnosticIdentityProvider: DiagnosticIdentityProviding {
    private let key: SymmetricKey
    private let stability: DiagnosticIdentityStability

    public init(keyData: Data) {
        precondition(!keyData.isEmpty)
        self.key = SymmetricKey(data: keyData)
        self.stability = .stable
    }

    public init(keyStore: any DiagnosticIdentityKeyStore) {
        do {
            let data = try keyStore.loadOrCreateKey()
            guard !data.isEmpty else { throw DiagnosticIdentityKeyStoreError.invalidKey }
            self.key = SymmetricKey(data: data)
            self.stability = .stable
        } catch {
            self.key = SymmetricKey(size: .bits256)
            self.stability = .transient
        }
    }

    public func fileIdentity(
        sourceID: UUID,
        normalizedPath: String,
        size: Int64,
        modifiedAt: Date?
    ) -> DiagnosticOpaqueIdentity {
        var canonical = Data()
        canonical.appendLengthPrefixed(sourceID.byteData)
        canonical.appendLengthPrefixed(Data(normalizedPath.utf8))
        canonical.appendLengthPrefixed(size.bigEndianData)
        if let modifiedAt {
            canonical.appendLengthPrefixed(modifiedAt.timeIntervalSince1970.bitPattern.bigEndianData)
        } else {
            canonical.appendLengthPrefixed(Data())
        }

        let authenticationCode = HMAC<SHA256>.authenticationCode(
            for: canonical,
            using: key
        )
        let value = authenticationCode.map { String(format: "%02x", $0) }.joined()
        return DiagnosticOpaqueIdentity(value: value, stability: stability)
    }
}

public enum DiagnosticIdentityKeyStoreError: Error, Equatable, Sendable {
    case invalidKey
    case randomGenerationFailed(Int32)
    case keychainReadFailed(Int32)
    case keychainWriteFailed(Int32)
}

public struct KeychainDiagnosticIdentityKeyStore: DiagnosticIdentityKeyStore {
    private let service: String
    private let account: String

    public init(
        service: String = "app.pier-player.diagnostics",
        account: String = "file-identity-hmac-v1"
    ) {
        self.service = service
        self.account = account
    }

    public func loadOrCreateKey() throws -> Data {
        if let existing = try readKey() {
            guard !existing.isEmpty else { throw DiagnosticIdentityKeyStoreError.invalidKey }
            return existing
        }

        var key = Data(repeating: 0, count: 32)
        let randomStatus = key.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard randomStatus == errSecSuccess else {
            throw DiagnosticIdentityKeyStoreError.randomGenerationFailed(randomStatus)
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: key,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem, let existing = try readKey() {
            return existing
        }
        guard status == errSecSuccess else {
            throw DiagnosticIdentityKeyStoreError.keychainWriteFailed(status)
        }
        return key
    }

    private func readKey() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw DiagnosticIdentityKeyStoreError.keychainReadFailed(status)
        }
        guard let data = result as? Data else {
            throw DiagnosticIdentityKeyStoreError.invalidKey
        }
        return data
    }
}

private extension UUID {
    var byteData: Data {
        var value = uuid
        return withUnsafeBytes(of: &value) { Data($0) }
    }
}

private extension Int64 {
    var bigEndianData: Data {
        var value = bigEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }
}

private extension UInt64 {
    var bigEndianData: Data {
        var value = bigEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }
}

private extension Data {
    mutating func appendLengthPrefixed(_ value: Data) {
        append(UInt64(value.count).bigEndianData)
        append(value)
    }
}
