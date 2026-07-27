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

    private func makeSource(
        sourceID: UUID = UUID(),
        client: FakeSMBClient
    ) throws -> SMBMediaSource {
        let configuration = try SMBConnectionConfiguration(
            sourceID: sourceID,
            displayName: "NAS",
            host: "nas.local",
            share: "Media"
        )
        return SMBMediaSource(configuration: configuration, client: client)
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

    func connect() throws {
        events.append(.connect)
        if let error { throw error }
    }

    func disconnect() {
        events.append(.disconnect)
    }

    func list(directory path: SMBPath) throws -> [SMBDirectoryEntry] {
        events.append(.list(path))
        if let error { throw error }
        return entries
    }

    func open(file path: SMBPath) throws -> SMBOpenedFile {
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

    func read(at offset: Int64, length: Int) throws -> Data {
        reads.append(.init(offset: offset, length: length))
        if let error { throw error }
        let start = Int(offset)
        let end = min(start + length, data.count)
        return data.subdata(in: start..<end)
    }

    func close() {
        closeCount += 1
    }
}
