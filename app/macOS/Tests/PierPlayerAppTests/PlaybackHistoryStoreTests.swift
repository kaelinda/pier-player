import Foundation
import Testing

@testable import PierPlayerApp

@Suite("PlaybackHistoryStoreTests")
struct PlaybackHistoryStoreTests {
    @Test func entryRejectsTraversalAndNonPathRepresentations() {
        let invalidPaths = [
            "/Movies/../Private.mkv",
            #"\\server\share\Movie.mkv"#,
            "/Movies/Bad\0Name.mkv",
            "smb://media-host/private/Movie.mkv",
            "//media-host/private/Movie.mkv",
        ]

        for path in invalidPaths {
            #expect(throws: PlaybackHistoryEntryError.invalidPath) {
                try entry(mediaID: mediaID("0"), path: path)
            }
        }
    }

    @Test func loadIsolatesEncodedEntriesContainingAnInvalidPath() async throws {
        let fixture = try HistoryStoreFixture(initialData: try encodedEntry(
            path: "/Movies/../Private.mkv"
        ))
        let store = PlaybackHistoryStore(fileURL: fixture.fileURL)

        #expect(try await store.load().isEmpty)
    }

    @Test func roundTripsEntriesAndLoadsNewestFirstWithStableTies() async throws {
        let fixture = try HistoryStoreFixture()
        let store = PlaybackHistoryStore(fileURL: fixture.fileURL)
        let sourceA = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let sourceB = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let oldest = try entry(
            mediaID: mediaID("a"),
            sourceID: sourceA,
            path: "Movies//./Old.mkv",
            lastPlayedAt: date(100)
        )
        let tiedLater = try entry(
            mediaID: mediaID("c"),
            sourceID: sourceB,
            path: "/Movies/Tied-C.mkv",
            lastPlayedAt: date(200)
        )
        let tiedEarlier = try entry(
            mediaID: mediaID("b"),
            sourceID: sourceA,
            path: "/Movies/Tied-B.mkv",
            lastPlayedAt: date(200)
        )

        try await store.upsert(oldest)
        try await store.upsert(tiedLater)
        try await store.upsert(tiedEarlier)

        let loaded = try await store.load()
        #expect(loaded.map(\.mediaID) == [mediaID("b"), mediaID("c"), mediaID("a")])
        #expect(loaded.last?.path == "/Movies/Old.mkv")

        let reopened = PlaybackHistoryStore(fileURL: fixture.fileURL)
        #expect(try await reopened.load() == loaded)
    }

    @Test func corruptFileIsIsolatedAsEmptyAndCanBeReplaced() async throws {
        let fixture = try HistoryStoreFixture(initialData: Data("not-json".utf8))
        let store = PlaybackHistoryStore(fileURL: fixture.fileURL)

        #expect(try await store.load().isEmpty)

        let replacement = try entry(mediaID: mediaID("d"), path: "/Movies/New.mkv")
        try await store.upsert(replacement)
        #expect(try await store.load() == [replacement])
    }

    @Test func upsertReplacesChangedIdentityAtSameNormalizedSourcePath() async throws {
        let fixture = try HistoryStoreFixture()
        let store = PlaybackHistoryStore(fileURL: fixture.fileURL)
        let sourceID = UUID()
        let old = try entry(
            mediaID: mediaID("e"),
            sourceID: sourceID,
            path: "Shows/./Pilot.mkv",
            size: 1_000,
            lastPlayedAt: date(100)
        )
        let replacement = try entry(
            mediaID: mediaID("f"),
            sourceID: sourceID,
            path: "/Shows/Pilot.mkv",
            size: 2_000,
            lastPlayedAt: date(200)
        )

        try await store.upsert(old)
        try await store.upsert(replacement)

        #expect(try await store.load() == [replacement])
    }

    @Test func samePathOnDifferentSourcesDoesNotReplaceHistory() async throws {
        let fixture = try HistoryStoreFixture()
        let store = PlaybackHistoryStore(fileURL: fixture.fileURL)
        let first = try entry(
            mediaID: mediaID("1"),
            sourceID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            path: "/Movies/Shared.mkv"
        )
        let second = try entry(
            mediaID: mediaID("2"),
            sourceID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            path: "/Movies/Shared.mkv"
        )

        try await store.upsert(first)
        try await store.upsert(second)

        #expect(
            Set(try await store.load().map(\.mediaID))
                == Set([first.mediaID, second.mediaID])
        )
    }

    @Test func removeAllDeletesOnlyTheRequestedSource() async throws {
        let fixture = try HistoryStoreFixture()
        let store = PlaybackHistoryStore(fileURL: fixture.fileURL)
        let removedSourceID = UUID()
        let removed = try entry(mediaID: mediaID("3"), sourceID: removedSourceID)
        let retained = try entry(mediaID: mediaID("4"), sourceID: UUID())
        try await store.upsert(removed)
        try await store.upsert(retained)

        try await store.removeAll(sourceID: removedSourceID)

        #expect(try await store.load() == [retained])
    }

    @Test func encodedHistoryIsDeterministicAndContainsNoConnectionSecrets() async throws {
        let fixture = try HistoryStoreFixture()
        let store = PlaybackHistoryStore(fileURL: fixture.fileURL)
        try await store.upsert(try entry(mediaID: mediaID("6"), path: "/Movies/Z.mkv"))
        try await store.upsert(try entry(mediaID: mediaID("5"), path: "/Movies/A.mkv"))
        let firstEncoding = try Data(contentsOf: fixture.fileURL)

        let loaded = try await store.load()
        for value in loaded.reversed() {
            try await store.upsert(value)
        }
        let secondEncoding = try Data(contentsOf: fixture.fileURL)
        let json = try #require(String(data: secondEncoding, encoding: .utf8))

        #expect(firstEncoding == secondEncoding)
        for forbiddenKey in ["credential", "password", "host", "share", "domain"] {
            #expect(!json.lowercased().contains("\"\(forbiddenKey)\""))
        }
    }
}

private final class HistoryStoreFixture: @unchecked Sendable {
    let directoryURL: URL
    let fileURL: URL

    init(initialData: Data? = nil) throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PierPlayerHistoryTests-\(UUID().uuidString)", isDirectory: true)
        fileURL = directoryURL.appendingPathComponent("nested/playback-history.json")
        if let initialData {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try initialData.write(to: fileURL)
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

private func entry(
    mediaID: String,
    sourceID: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
    sourceDisplayName: String = "Living Room NAS",
    fileName: String = "Movie.mkv",
    path: String = "/Movies/Movie.mkv",
    size: Int64 = 1_024,
    modifiedAt: Date? = date(50),
    lastPlayedAt: Date = date(100)
) throws -> PlaybackHistoryEntry {
    try PlaybackHistoryEntry(
        mediaID: mediaID,
        sourceID: sourceID,
        sourceDisplayName: sourceDisplayName,
        fileName: fileName,
        path: path,
        size: size,
        modifiedAt: modifiedAt,
        lastPlayedAt: lastPlayedAt
    )
}

private func mediaID(_ character: Character) -> String {
    String(repeating: String(character), count: 64)
}

private func date(_ interval: TimeInterval) -> Date {
    Date(timeIntervalSince1970: interval)
}

private func encodedEntry(path: String) throws -> Data {
    try JSONSerialization.data(withJSONObject: [[
        "mediaID": mediaID("a"),
        "sourceID": "00000000-0000-0000-0000-000000000001",
        "sourceDisplayName": "Living Room NAS",
        "fileName": "Movie.mkv",
        "path": path,
        "size": 1_024,
        "modifiedAt": -978_307_150,
        "lastPlayedAt": -978_307_100,
    ]])
}
