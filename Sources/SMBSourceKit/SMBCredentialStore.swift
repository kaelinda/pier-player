import Foundation

public struct StoredSMBCredential: Sendable {
    public let credential: SMBCredential
    public let domain: String?

    public init(credential: SMBCredential, domain: String?) {
        self.credential = credential
        self.domain = domain
    }
}

public protocol SMBCredentialStore: Sendable {
    func save(
        sourceID: UUID,
        credential: SMBCredential,
        domain: String?
    ) async throws
    func load(sourceID: UUID) async throws -> StoredSMBCredential?
    func delete(sourceID: UUID) async throws
}
