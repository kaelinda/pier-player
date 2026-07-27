import Foundation
import MediaSourceKit

public actor SMBMediaSource: MediaSource {
    public nonisolated let id: UUID
    public nonisolated let displayName: String

    private let client: any SMBClient
    private var isConnected = false

    public init(
        configuration: SMBConnectionConfiguration,
        client: any SMBClient
    ) {
        id = configuration.sourceID
        displayName = configuration.displayName
        self.client = client
    }

    public func connect() async throws {
        do {
            try await client.connect()
            isConnected = true
        } catch {
            isConnected = false
            throw mapSMBError(error)
        }
    }

    public func disconnect() async {
        isConnected = false
        await client.disconnect()
    }

    public func list(directory path: String) async throws -> [MediaSourceItem] {
        guard isConnected else {
            throw MediaSourceError.notConnected
        }

        do {
            let directory = try SMBPath(path)
            let entries = try await client.list(directory: directory)
            return try entries
                .filter { !$0.name.hasPrefix(".") }
                .map { entry in
                    let childPath = try directory.appending(entry.name)
                    return MediaSourceItem(
                        name: entry.name,
                        path: childPath.string,
                        kind: entry.kind == .directory ? .directory : .file,
                        size: entry.size,
                        modifiedAt: entry.modifiedAt
                    )
                }
                .sorted(by: Self.sortItems)
        } catch {
            throw mapSMBError(error, path: path)
        }
    }

    public func open(file path: String) async throws -> any MediaReadableFile {
        guard isConnected else {
            throw MediaSourceError.notConnected
        }

        do {
            let normalizedPath = try SMBPath(path)
            let opened = try await client.open(file: normalizedPath)
            let identity = MediaFileIdentity(
                sourceID: id,
                path: normalizedPath.string,
                size: opened.size,
                modifiedAt: opened.modifiedAt
            )
            return SMBReadableFile(identity: identity, file: opened.file)
        } catch {
            throw mapSMBError(error, path: path)
        }
    }

    private static func sortItems(_ lhs: MediaSourceItem, _ rhs: MediaSourceItem) -> Bool {
        if lhs.kind != rhs.kind {
            return lhs.kind == .directory
        }
        let comparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if comparison == .orderedSame {
            return lhs.name < rhs.name
        }
        return comparison == .orderedAscending
    }
}

private actor SMBReadableFile: MediaReadableFile {
    nonisolated let identity: MediaFileIdentity
    private let file: any SMBClientFile

    init(identity: MediaFileIdentity, file: any SMBClientFile) {
        self.identity = identity
        self.file = file
    }

    func read(at offset: Int64, length: Int) async throws -> Data {
        do {
            return try await file.read(at: offset, length: length)
        } catch {
            throw mapSMBError(error, path: identity.path)
        }
    }

    func close() async {
        await file.close()
    }
}

private func mapSMBError(_ error: Error, path: String? = nil) -> MediaSourceError {
    guard let error = error as? SMBClientError else {
        if error is SMBConfigurationError {
            return .unsupported(reason: "Invalid SMB path")
        }
        return .unreachable(details: nil)
    }

    switch error {
    case .notConnected:
        return .notConnected
    case .authenticationFailed:
        return .authenticationFailed
    case .unreachable:
        return .unreachable(details: nil)
    case .notFound:
        return .notFound(path: path ?? "/")
    case let .invalidRead(offset, length):
        return .invalidRead(offset: offset, length: length)
    case .readFailed:
        return .readFailed(details: nil)
    case .remoteFileChanged:
        return .remoteFileChanged
    case .unsupported:
        return .unsupported(reason: "Unsupported SMB operation")
    }
}
