import Foundation

public protocol MediaReadableFile: Sendable {
    var identity: MediaFileIdentity { get }

    func read(at offset: Int64, length: Int) async throws -> Data
    func close() async
}

public protocol MediaSource: Sendable {
    var id: UUID { get }
    var displayName: String { get }

    func connect() async throws
    func disconnect() async
    func list(directory path: String) async throws -> [MediaSourceItem]
    func open(file path: String) async throws -> any MediaReadableFile
}
