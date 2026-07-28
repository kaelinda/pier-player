import Foundation

public enum SMBClientError: Error, Equatable, Sendable {
    case notConnected
    case authenticationFailed
    case unreachable
    case notFound
    case invalidRead(offset: Int64, length: Int)
    case readFailed
    case remoteFileChanged
    case unsupported
}

public struct SMBDirectoryEntry: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case file
        case directory
    }

    public let name: String
    public let kind: Kind
    public let size: Int64?
    public let modifiedAt: Date?

    public init(name: String, kind: Kind, size: Int64?, modifiedAt: Date?) {
        self.name = name
        self.kind = kind
        self.size = size
        self.modifiedAt = modifiedAt
    }
}

public struct SMBOpenedFile: Sendable {
    public let file: any SMBClientFile
    public let size: Int64
    public let modifiedAt: Date?

    public init(file: any SMBClientFile, size: Int64, modifiedAt: Date?) {
        self.file = file
        self.size = size
        self.modifiedAt = modifiedAt
    }
}

public protocol SMBClient: Sendable {
    func connect() async throws
    func disconnect() async
    func list(directory path: SMBPath) async throws -> [SMBDirectoryEntry]
    func open(file path: SMBPath) async throws -> SMBOpenedFile
}

public protocol SMBClientFile: Sendable {
    func read(at offset: Int64, length: Int) async throws -> Data
    func close() async
}
