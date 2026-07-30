import DiagnosticsKit
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

    @Test func nativeFileRecordsReadFailureAndIdempotentClose() async throws {
        let recorder = LibRecordingDiagnosticRecorder()
        let handle = RecordingNativeFileHandle(
            result: Data([8, 9]),
            error: SMBClientError.readFailed
        )
        let connection = RecordingNativeConnection(fileHandle: handle)
        let file = LibSMB2File(
            size: 10,
            handle: handle,
            connection: connection,
            diagnosticRecorder: recorder,
            diagnosticContext: libDiagnosticContext,
            sourceID: libSourceID,
            fileID: String(repeating: "a", count: 64)
        )

        await #expect(throws: SMBClientError.readFailed) {
            try await file.read(at: 0, length: 2)
        }
        await file.close()
        await file.close()

        let events = recorder.snapshot
        let reads = events.filter { $0.name == .smbRead }
        #expect(reads.map(\.phase) == [.begin, .end])
        #expect(reads.last?.outcome == .failure)
        #expect(reads.last?.payload.error?.code == .sourceReadFailed)
        #expect(reads.last?.payload.fileID == String(repeating: "a", count: 64))
        let closes = events.filter { $0.name == .smbClose }
        #expect(closes.map(\.phase) == [.begin, .end])
        #expect(closes.last?.outcome == .success)
        #expect(await handle.closeCount == 1)
        #expect(await connection.disconnectCount == 1)
    }

    @Test func nativeLifecycleUsesCorrelatedOpaqueDiagnostics() async throws {
        let recorder = LibRecordingDiagnosticRecorder()
        let identityProvider = HMACDiagnosticIdentityProvider(keyData: Data(repeating: 5, count: 32))
        let modifiedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let handle = RecordingNativeFileHandle(result: Data([1, 2]))
        let sourceConnection = RecordingNativeConnection(
            entries: [.init(name: "private.mkv", kind: .file, size: 2, modifiedAt: modifiedAt)],
            fileHandle: handle
        )
        let fileConnection = RecordingNativeConnection(
            stat: .init(size: 2, modifiedAt: modifiedAt, kind: .file),
            fileHandle: handle
        )
        let factory = RecordingNativeConnectionFactory(
            connections: [sourceConnection, fileConnection]
        )
        let configuration = try SMBConnectionConfiguration(
            sourceID: libSourceID,
            displayName: "Private NAS",
            host: "private.example",
            share: "Confidential"
        )
        let client = LibSMB2Client(
            configuration: configuration,
            credential: try SMBCredential(username: "viewer", password: "secret"),
            nativeFactory: factory,
            diagnosticRecorder: recorder,
            diagnosticContext: libDiagnosticContext,
            identityProvider: identityProvider
        )

        try await client.connect()
        _ = try await client.list(directory: SMBPath("/Private"))
        let opened = try await client.open(file: SMBPath("/Private/customer.mkv"))
        _ = try await opened.file.read(at: 0, length: 2)
        await opened.file.close()
        await opened.file.close()
        await client.disconnect()

        let events = recorder.snapshot
        for name in [
            DiagnosticEventName.smbConnect,
            .smbList,
            .smbStat,
            .smbOpen,
            .smbRead,
            .smbClose,
        ] {
            let matching = events.filter { $0.name == name }
            #expect(matching.map(\.phase) == [.begin, .end])
            #expect(matching.first?.context.operationID == matching.last?.context.operationID)
            #expect(matching.last?.outcome == .success)
        }
        let open = try #require(events.first { $0.name == .smbOpen && $0.phase == .begin })
        let stat = try #require(events.first { $0.name == .smbStat && $0.phase == .begin })
        let read = try #require(events.first { $0.name == .smbRead && $0.phase == .begin })
        #expect(stat.context.parentOperationID == open.context.operationID)
        #expect(read.context.parentOperationID == open.context.operationID)
        #expect(events.allSatisfy { $0.payload.sourceID == libSourceID })

        let expectedFileID = identityProvider.fileIdentity(
            sourceID: libSourceID,
            normalizedPath: "/Private/customer.mkv",
            size: 2,
            modifiedAt: modifiedAt
        ).value
        #expect(events.contains { $0.name == .smbRead && $0.payload.fileID == expectedFileID })
        let encoded = try events.map(DiagnosticEventEncoder.encode)
            .map { String(decoding: $0, as: UTF8.self) }
            .joined()
            .lowercased()
        #expect(!encoded.contains("private.example"))
        #expect(!encoded.contains("confidential"))
        #expect(!encoded.contains("customer"))
        #expect(!encoded.contains("viewer"))
        #expect(!encoded.contains("secret"))
    }
}

private let libSourceID = UUID(uuidString: "00000000-0000-0000-0000-000000000311")!
private let libDiagnosticContext = DiagnosticContext(
    appRunID: UUID(uuidString: "00000000-0000-0000-0000-000000000312")!,
    activityID: UUID(uuidString: "00000000-0000-0000-0000-000000000313")!,
    operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000314")!
)

private final class LibRecordingDiagnosticRecorder: DiagnosticRecording, @unchecked Sendable {
    private let lock = NSLock()
    private var events: [DiagnosticEvent] = []

    var snapshot: [DiagnosticEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    func record(_ event: DiagnosticEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
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
    private let error: (any Error & Sendable)?
    private(set) var reads: [Read] = []
    private(set) var closeCount = 0

    init(result: Data = Data(), error: (any Error & Sendable)? = nil) {
        self.result = result
        self.error = error
    }

    func read(at offset: Int64, length: Int) async throws -> Data {
        reads.append(.init(offset: offset, length: length))
        if let error { throw error }
        return result
    }

    func close() async {
        closeCount += 1
    }
}
