import DiagnosticsKit
import Foundation
import MediaSourceKit
import Testing
@testable import SMBSourceKit

@Suite struct SMBMediaSourceTests {
    @Test func delegatesConnectionLifecycle() async throws {
        let client = FakeSMBClient()
        let source = try makeSource(client: client)

        try await source.connect()
        await source.disconnect()

        #expect(await client.events == [.connect, .disconnect])
    }

    @Test func mapsFiltersAndSortsDirectoryEntries() async throws {
        let client = FakeSMBClient(entries: [
            .init(name: "zeta.mkv", kind: .file, size: 12, modifiedAt: nil),
            .init(name: ".metadata", kind: .file, size: 1, modifiedAt: nil),
            .init(name: "Movies", kind: .directory, size: nil, modifiedAt: nil),
            .init(name: "alpha.mp4", kind: .file, size: 8, modifiedAt: nil),
            .init(name: "..", kind: .directory, size: nil, modifiedAt: nil),
        ])
        let source = try makeSource(client: client)
        try await source.connect()

        let items = try await source.list(directory: "/Library")

        #expect(items.map(\.name) == ["Movies", "alpha.mp4", "zeta.mkv"])
        #expect(items.map(\.path) == [
            "/Library/Movies",
            "/Library/alpha.mp4",
            "/Library/zeta.mkv",
        ])
        #expect(items.map(\.kind) == [.directory, .file, .file])
    }

    @Test func rejectsOpenBeforeConnect() async throws {
        let source = try makeSource(client: FakeSMBClient())

        await #expect(throws: MediaSourceError.notConnected) {
            try await source.open(file: "/film.mkv")
        }
    }

    @Test func mapsFileIdentityAndRandomReads() async throws {
        let sourceID = UUID()
        let modifiedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let file = FakeSMBClientFile(data: Data([0, 1, 2, 3, 4]))
        let client = FakeSMBClient(
            openedFile: SMBOpenedFile(file: file, size: 5, modifiedAt: modifiedAt)
        )
        let source = try makeSource(sourceID: sourceID, client: client)
        try await source.connect()

        let readable = try await source.open(file: "/Movies/film.mkv")
        let data = try await readable.read(at: 2, length: 2)
        await readable.close()

        #expect(readable.identity == MediaFileIdentity(
            sourceID: sourceID,
            path: "/Movies/film.mkv",
            size: 5,
            modifiedAt: modifiedAt
        ))
        #expect(data == Data([2, 3]))
        #expect(await file.reads == [.init(offset: 2, length: 2)])
        #expect(await file.closeCount == 1)
    }

    @Test func mapsClientErrorsWithoutNativeDetails() async throws {
        let client = FakeSMBClient(error: .unreachable)
        let source = try makeSource(client: client)

        do {
            try await source.connect()
            Issue.record("Expected connection to fail")
        } catch let error as MediaSourceError {
            #expect(error == .unreachable(details: nil))
        }
    }

    @Test func mapsFileReadErrorsWithoutNativeDetails() async throws {
        let file = FakeSMBClientFile(data: Data(), error: .readFailed)
        let client = FakeSMBClient(
            openedFile: SMBOpenedFile(file: file, size: 1, modifiedAt: nil)
        )
        let source = try makeSource(client: client)
        try await source.connect()
        let readable = try await source.open(file: "/film.mkv")

        await #expect(throws: MediaSourceError.readFailed(details: nil)) {
            try await readable.read(at: 0, length: 1)
        }
    }

    @Test func recordsCorrelatedResourceLifecycleWithoutRawIdentifiers() async throws {
        let recorder = RecordingDiagnosticRecorder()
        let identityProvider = HMACDiagnosticIdentityProvider(keyData: Data(repeating: 7, count: 32))
        let sourceID = UUID(uuidString: "00000000-0000-0000-0000-000000000301")!
        let modifiedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let file = FakeSMBClientFile(data: Data([0, 1, 2, 3]))
        let client = FakeSMBClient(
            entries: [.init(name: "film.mkv", kind: .file, size: 4, modifiedAt: modifiedAt)],
            openedFile: SMBOpenedFile(file: file, size: 4, modifiedAt: modifiedAt)
        )
        let source = try makeSource(
            sourceID: sourceID,
            client: client,
            recorder: recorder,
            identityProvider: identityProvider
        )

        try await source.connect()
        _ = try await source.list(directory: "/Private")
        let readable = try await source.open(file: "/Private/customer-film.mkv")
        _ = try await readable.read(at: 0, length: 2)
        await readable.close()
        await readable.close()
        await source.disconnect()

        let events = recorder.snapshot
        assertOperationPair(named: .sourceConnect, in: events, outcome: .success)
        assertOperationPair(named: .directoryList, in: events, outcome: .success)
        assertOperationPair(named: .fileOpen, in: events, outcome: .success)
        assertOperationPair(named: .fileClose, in: events, outcome: .success)
        assertOperationPair(named: .sourceDisconnect, in: events, outcome: .success)
        #expect(events.filter { $0.name == .fileClose }.count == 2)
        #expect(events.allSatisfy { $0.payload.sourceID == sourceID })

        let expectedFileID = identityProvider.fileIdentity(
            sourceID: sourceID,
            normalizedPath: "/Private/customer-film.mkv",
            size: 4,
            modifiedAt: modifiedAt
        ).value
        #expect(events.filter { $0.name == .fileOpen || $0.name == .fileClose }
            .contains { $0.payload.fileID == expectedFileID })
        let encoded = try events.map(DiagnosticEventEncoder.encode)
            .map { String(decoding: $0, as: UTF8.self) }
            .joined()
            .lowercased()
        #expect(!encoded.contains("nas.local"))
        #expect(!encoded.contains("media"))
        #expect(!encoded.contains("private"))
        #expect(!encoded.contains("customer-film"))
    }

    @Test func recordsMappedConnectionFailure() async throws {
        let recorder = RecordingDiagnosticRecorder()
        let source = try makeSource(
            client: FakeSMBClient(error: .unreachable),
            recorder: recorder
        )

        await #expect(throws: MediaSourceError.unreachable(details: nil)) {
            try await source.connect()
        }

        let end = try #require(recorder.snapshot.last)
        #expect(end.name == .sourceConnect)
        #expect(end.phase == .end)
        #expect(end.outcome == .failure)
        #expect(end.payload.error?.code == .sourceUnreachable)
    }

    private func makeSource(
        sourceID: UUID = UUID(),
        client: FakeSMBClient,
        recorder: any DiagnosticRecording = NoopDiagnosticRecorder(),
        identityProvider: (any DiagnosticIdentityProviding)? = nil
    ) throws -> SMBMediaSource {
        let configuration = try SMBConnectionConfiguration(
            sourceID: sourceID,
            displayName: "NAS",
            host: "nas.local",
            share: "Media"
        )
        return SMBMediaSource(
            configuration: configuration,
            client: client,
            diagnosticRecorder: recorder,
            diagnosticContext: fixedDiagnosticContext,
            identityProvider: identityProvider
        )
    }
}

private let fixedDiagnosticContext = DiagnosticContext(
    appRunID: UUID(uuidString: "00000000-0000-0000-0000-000000000302")!,
    activityID: UUID(uuidString: "00000000-0000-0000-0000-000000000303")!,
    operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000304")!
)

private func assertOperationPair(
    named name: DiagnosticEventName,
    in events: [DiagnosticEvent],
    outcome: DiagnosticOutcome
) {
    let matching = events.filter { $0.name == name }
    #expect(matching.count == 2)
    #expect(matching.map(\.phase) == [.begin, .end])
    #expect(matching.first?.context.operationID == matching.last?.context.operationID)
    #expect(matching.last?.outcome == outcome)
}

private final class RecordingDiagnosticRecorder: DiagnosticRecording, @unchecked Sendable {
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

private actor FakeSMBClient: SMBClient {
    enum Event: Equatable, Sendable {
        case connect
        case disconnect
        case list(SMBPath)
        case open(SMBPath)
    }

    private(set) var events: [Event] = []
    private let entries: [SMBDirectoryEntry]
    private let openedFile: SMBOpenedFile
    private let error: SMBClientError?

    init(
        entries: [SMBDirectoryEntry] = [],
        openedFile: SMBOpenedFile = SMBOpenedFile(
            file: FakeSMBClientFile(data: Data()),
            size: 0,
            modifiedAt: nil
        ),
        error: SMBClientError? = nil
    ) {
        self.entries = entries
        self.openedFile = openedFile
        self.error = error
    }

    func connect() async throws {
        events.append(.connect)
        if let error { throw error }
    }

    func disconnect() async {
        events.append(.disconnect)
    }

    func list(directory path: SMBPath) async throws -> [SMBDirectoryEntry] {
        events.append(.list(path))
        if let error { throw error }
        return entries
    }

    func open(file path: SMBPath) async throws -> SMBOpenedFile {
        events.append(.open(path))
        if let error { throw error }
        return openedFile
    }
}

private actor FakeSMBClientFile: SMBClientFile {
    struct Read: Equatable, Sendable {
        let offset: Int64
        let length: Int
    }

    private let data: Data
    private let error: SMBClientError?
    private(set) var reads: [Read] = []
    private(set) var closeCount = 0

    init(data: Data, error: SMBClientError? = nil) {
        self.data = data
        self.error = error
    }

    func read(at offset: Int64, length: Int) async throws -> Data {
        reads.append(.init(offset: offset, length: length))
        if let error { throw error }
        let start = Int(offset)
        let end = min(start + length, data.count)
        return data.subdata(in: start..<end)
    }

    func close() async {
        closeCount += 1
    }
}
