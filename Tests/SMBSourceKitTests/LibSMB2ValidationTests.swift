import Foundation
import Testing
@testable import SMBSourceKit

@Suite struct LibSMB2ValidationTests {
    @Test func invalidConfigurationFailsBeforeNativeAllocation() async throws {
        let factory = RecordingNativeConnectionFactory(connections: [])
        let credential = try SMBCredential(username: "viewer", password: "secret")

        #expect(throws: SMBConfigurationError.invalidHost) {
            try LibSMB2Client(
                displayName: "NAS",
                host: "nas.local/Media",
                share: "Media",
                credential: credential,
                nativeFactory: factory
            )
        }

        #expect(await factory.connectionCount == 0)
    }

    @Test(arguments: [
        (offset: Int64(-1), length: 1),
        (offset: Int64(0), length: 0),
        (offset: Int64(0), length: -1),
        (offset: Int64(0), length: Int(UInt32.max) + 1),
    ])
    func rejectsInvalidReadsWithoutCallingNative(
        offset: Int64,
        length: Int
    ) async throws {
        let handle = RecordingNativeFileHandle()
        let connection = RecordingNativeConnection(fileHandle: handle)
        let file = LibSMB2File(size: 10, handle: handle, connection: connection)

        await #expect(throws: SMBClientError.invalidRead(offset: offset, length: length)) {
            try await file.read(at: offset, length: length)
        }

        #expect(await handle.reads.isEmpty)
    }

    @Test func eofReturnsEmptyWithoutCallingNative() async throws {
        let handle = RecordingNativeFileHandle()
        let connection = RecordingNativeConnection(fileHandle: handle)
        let file = LibSMB2File(size: 10, handle: handle, connection: connection)

        let data = try await file.read(at: 10, length: 4)

        #expect(data.isEmpty)
        #expect(await handle.reads.isEmpty)
    }

    @Test func readIsClampedToKnownFileSize() async throws {
        let handle = RecordingNativeFileHandle(result: Data([8, 9]))
        let connection = RecordingNativeConnection(fileHandle: handle)
        let file = LibSMB2File(size: 10, handle: handle, connection: connection)

        let data = try await file.read(at: 8, length: 8)

        #expect(data == Data([8, 9]))
        #expect(await handle.reads == [.init(offset: 8, length: 2)])
    }

    @Test func closeIsIdempotentAndReleasesDedicatedConnection() async {
        let handle = RecordingNativeFileHandle()
        let connection = RecordingNativeConnection(fileHandle: handle)
        let file = LibSMB2File(size: 10, handle: handle, connection: connection)

        await file.close()
        await file.close()

        #expect(await handle.closeCount == 1)
        #expect(await connection.disconnectCount == 1)
    }

    @Test func openUsesAConnectionSeparateFromDirectoryBrowsing() async throws {
        let handle = RecordingNativeFileHandle()
        let sourceConnection = RecordingNativeConnection(fileHandle: handle)
        let fileConnection = RecordingNativeConnection(
            stat: .init(size: 20, modifiedAt: nil, kind: .file),
            fileHandle: handle
        )
        let factory = RecordingNativeConnectionFactory(
            connections: [sourceConnection, fileConnection]
        )
        let configuration = try SMBConnectionConfiguration(
            displayName: "NAS",
            host: "nas.local",
            share: "Media"
        )
        let credential = try SMBCredential(username: "viewer", password: "secret")
        let client = LibSMB2Client(
            configuration: configuration,
            credential: credential,
            nativeFactory: factory
        )

        try await client.connect()
        let opened = try await client.open(file: SMBPath("/film.mkv"))
        await opened.file.close()
        await client.disconnect()

        #expect(await factory.connectionCount == 2)
        #expect(await sourceConnection.disconnectCount == 1)
        #expect(await fileConnection.disconnectCount == 1)
    }
}

private actor RecordingNativeConnectionFactory: SMBNativeConnectionFactory {
    private var connections: [RecordingNativeConnection]
    private(set) var connectionCount = 0

    init(connections: [RecordingNativeConnection]) {
        self.connections = connections
    }

    func connect(
        configuration: SMBConnectionConfiguration,
        credential: SMBCredential
    ) async throws -> any SMBNativeConnection {
        connectionCount += 1
        return connections.removeFirst()
    }
}

private actor RecordingNativeConnection: SMBNativeConnection {
    private let entries: [SMBDirectoryEntry]
    private let statValue: SMBNativeStat
    private let fileHandle: RecordingNativeFileHandle
    private(set) var disconnectCount = 0

    init(
        entries: [SMBDirectoryEntry] = [],
        stat: SMBNativeStat = .init(size: 0, modifiedAt: nil, kind: .directory),
        fileHandle: RecordingNativeFileHandle
    ) {
        self.entries = entries
        self.statValue = stat
        self.fileHandle = fileHandle
    }

    func list(directory path: SMBPath) async throws -> [SMBDirectoryEntry] {
        entries
    }

    func stat(path: SMBPath) async throws -> SMBNativeStat {
        statValue
    }

    func open(file path: SMBPath) async throws -> any SMBNativeFileHandle {
        fileHandle
    }

    func disconnect() async {
        disconnectCount += 1
    }
}

private actor RecordingNativeFileHandle: SMBNativeFileHandle {
    struct Read: Equatable, Sendable {
        let offset: Int64
        let length: Int
    }

    private let result: Data
    private(set) var reads: [Read] = []
    private(set) var closeCount = 0

    init(result: Data = Data()) {
        self.result = result
    }

    func read(at offset: Int64, length: Int) async throws -> Data {
        reads.append(.init(offset: offset, length: length))
        return result
    }

    func close() async {
        closeCount += 1
    }
}
