import Foundation

struct SMBNativeStat: Sendable {
    let size: Int64
    let modifiedAt: Date?
    let kind: SMBDirectoryEntry.Kind
}

protocol SMBNativeConnectionFactory: Sendable {
    func connect(
        configuration: SMBConnectionConfiguration,
        credential: SMBCredential
    ) async throws -> any SMBNativeConnection
}

protocol SMBNativeConnection: Sendable {
    func list(directory path: SMBPath) async throws -> [SMBDirectoryEntry]
    func stat(path: SMBPath) async throws -> SMBNativeStat
    func open(file path: SMBPath) async throws -> any SMBNativeFileHandle
    func disconnect() async
}

protocol SMBNativeFileHandle: Sendable {
    func read(at offset: Int64, length: Int) async throws -> Data
    func close() async
}
