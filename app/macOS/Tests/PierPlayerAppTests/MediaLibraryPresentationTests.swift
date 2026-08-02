import Foundation
import CloudSyncKit
import MediaSourceKit
import Testing

@testable import PierPlayerApp

@Suite("MediaLibraryPresentationTests")
struct MediaLibraryPresentationTests {
    @Test func filtersByFilenameAndSourceNameWithoutCaseSensitivity() {
        let items = [
            item(name: "Arrival.MKV", path: "/Movies/Arrival.MKV", sourceName: "Living Room NAS"),
            item(name: "Moon.mp4", path: "/Movies/Moon.mp4", sourceName: "Office Archive"),
            item(name: "Heat.mov", path: "/Movies/Heat.mov", sourceName: "Living Room NAS"),
        ]

        #expect(
            MediaLibraryPresentation.filtered(items, query: "arrival").map(\.media.path)
                == ["/Movies/Arrival.MKV"]
        )
        #expect(
            MediaLibraryPresentation.filtered(items, query: "OFFICE").map(\.media.path)
                == ["/Movies/Moon.mp4"]
        )
    }

    @Test func whitespaceOnlyFilterReturnsAllItemsInInputOrder() {
        let items = [
            item(name: "First.mp4", path: "/First.mp4"),
            item(name: "Second.mkv", path: "/Second.mkv"),
        ]

        #expect(MediaLibraryPresentation.filtered(items, query: " \n\t ") == items)
    }

    @Test func filterUsesInjectedLocaleForCaseInsensitiveMatching() {
        let istanbul = item(name: "İstanbul.mkv", path: "/İstanbul.mkv")

        #expect(
            MediaLibraryPresentation.filtered(
                [istanbul],
                query: "istanbul",
                locale: Locale(identifier: "tr_TR")
            ) == [istanbul]
        )
    }

    @Test func displayTitleRemovesOnlyTheFinalExtension() {
        let item = item(name: "Episode.01.final.mkv", path: "/Episode.01.final.mkv")

        #expect(MediaLibraryPresentation.displayTitle(for: item) == "Episode.01.final")
    }

    @Test func displayTitlePreservesNamesWithoutARemovableExtension() {
        let item = item(name: ".mkv", path: "/.mkv")

        #expect(MediaLibraryPresentation.displayTitle(for: item) == ".mkv")
    }

    @Test func recentlyAddedSortsNewestFirstAndPlacesMissingDatesLast() {
        let oldest = item(name: "Old.mp4", path: "/Old.mp4", modifiedAt: date(100))
        let undated = item(name: "Unknown.mp4", path: "/Unknown.mp4", modifiedAt: nil)
        let newest = item(name: "New.mp4", path: "/New.mp4", modifiedAt: date(300))
        let middle = item(name: "Middle.mp4", path: "/Middle.mp4", modifiedAt: date(200))

        #expect(
            MediaLibraryPresentation.recentlyAdded(
                [oldest, undated, newest, middle]
            ).map(\.media.path) == ["/New.mp4", "/Middle.mp4", "/Old.mp4", "/Unknown.mp4"]
        )
    }

    @Test func recentlyAddedUsesDeterministicTitleAndPathTies() {
        let timestamp = date(100)
        let laterPath = item(name: "Same.mp4", path: "/z/Same.mp4", modifiedAt: timestamp)
        let titleLater = item(name: "Zulu.mp4", path: "/a/Zulu.mp4", modifiedAt: timestamp)
        let earlierPath = item(name: "same.MKV", path: "/a/same.MKV", modifiedAt: timestamp)

        #expect(
            MediaLibraryPresentation.recentlyAdded(
                [laterPath, titleLater, earlierPath]
            ).map(\.media.path) == ["/a/same.MKV", "/z/Same.mp4", "/a/Zulu.mp4"]
        )
    }

    @Test func recentlyAddedUsesLocalizedTitlesForEqualDates() {
        let timestamp = date(100)
        let items = [
            item(name: "Zulu.mp4", path: "/Zulu.mp4", modifiedAt: timestamp),
            item(name: "Éclair.mp4", path: "/Éclair.mp4", modifiedAt: timestamp),
            item(name: "eagle.mp4", path: "/eagle.mp4", modifiedAt: timestamp),
        ]

        #expect(
            MediaLibraryPresentation.recentlyAdded(
                items,
                locale: Locale(identifier: "en_US")
            ).map(\.media.name) == ["eagle.mp4", "Éclair.mp4", "Zulu.mp4"]
        )
    }

    @Test func recentlyAddedUsesTwelveAsItsDefaultLimit() {
        let items = (0..<15).map { index in
            item(
                name: "Video-\(index).mp4",
                path: "/Video-\(index).mp4",
                modifiedAt: date(TimeInterval(index))
            )
        }

        let result = MediaLibraryPresentation.recentlyAdded(items)

        #expect(result.count == 12)
        #expect(result.first?.media.path == "/Video-14.mp4")
        #expect(result.last?.media.path == "/Video-3.mp4")
    }

    @Test func recentlyAddedReturnsEmptyForNonPositiveLimits() {
        let items = [item(name: "Movie.mp4", path: "/Movie.mp4", modifiedAt: date(100))]

        #expect(MediaLibraryPresentation.recentlyAdded(items, limit: 0).isEmpty)
        #expect(MediaLibraryPresentation.recentlyAdded(items, limit: -1).isEmpty)
    }

    @Test func allVideosSortsCaseInsensitivelyWithPathAndIdentityTies() {
        let firstSourceID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondSourceID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let items = [
            item(name: "Zulu.mp4", path: "/Zulu.mp4", sourceID: firstSourceID),
            item(name: "alpha.mov", path: "/z/alpha.mov", sourceID: firstSourceID),
            item(name: "Alpha.mp4", path: "/a/Alpha.mp4", sourceID: secondSourceID),
            item(name: "Alpha.mp4", path: "/a/Alpha.mp4", sourceID: firstSourceID),
        ]

        #expect(
            MediaLibraryPresentation.allVideos(items).map(\.id) == [
                "\(firstSourceID.uuidString):/a/Alpha.mp4",
                "\(secondSourceID.uuidString):/a/Alpha.mp4",
                "\(firstSourceID.uuidString):/z/alpha.mov",
                "\(firstSourceID.uuidString):/Zulu.mp4",
            ]
        )
    }

    @Test func allVideosUsesLocalizedAccentedTitleOrdering() {
        let items = [
            item(name: "Zulu.mp4", path: "/Zulu.mp4"),
            item(name: "Éclair.mp4", path: "/Éclair.mp4"),
            item(name: "eagle.mp4", path: "/eagle.mp4"),
        ]

        #expect(
            MediaLibraryPresentation.allVideos(
                items,
                locale: Locale(identifier: "en_US")
            ).map(\.media.name) == ["eagle.mp4", "Éclair.mp4", "Zulu.mp4"]
        )
    }

    @Test func allVideosRemainsStrictAcrossEquivalentSortKeys() {
        let firstSourceID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondSourceID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let locale = Locale(identifier: "en_US")
        let duplicate = item(
            name: "Duplicate.mp4",
            path: "/Duplicate.mp4",
            sourceID: firstSourceID
        )
        let items = [
            item(name: "alpha.mp4", path: "/case.mp4", sourceID: firstSourceID),
            item(name: "ALPHA.mp4", path: "/Case.mp4", sourceID: secondSourceID),
            item(name: "Café.mp4", path: "/Café.mp4", sourceID: firstSourceID),
            item(name: "Cafe\u{301}.mp4", path: "/Cafe\u{301}.mp4", sourceID: secondSourceID),
            duplicate,
            duplicate,
        ]

        let sorted = MediaLibraryPresentation.allVideos(items, locale: locale)
        let sortedFromReverse = MediaLibraryPresentation.allVideos(
            Array(items.reversed()),
            locale: locale
        )

        #expect(sorted == MediaLibraryPresentation.allVideos(sorted, locale: locale))
        #expect(sorted.map(\.id) == sortedFromReverse.map(\.id))
        #expect(
            sorted.map(\.id) == [
                "\(secondSourceID.uuidString):/Case.mp4",
                "\(firstSourceID.uuidString):/case.mp4",
                "\(secondSourceID.uuidString):/Cafe\u{301}.mp4",
                "\(firstSourceID.uuidString):/Café.mp4",
                duplicate.id,
                duplicate.id,
            ]
        )
    }

    @Test func posterStyleHasAStableKnownIdentityMapping() {
        let item = item(
            name: "Arrival.mkv",
            path: "/Movies/Arrival.mkv",
            sourceID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        )

        #expect(
            MediaLibraryPresentation.posterStyle(for: item)
                == MediaPosterStyle(paletteIndex: 2, symbolIndex: 2)
        )
    }

    @Test func posterStyleIsRepeatableAndAlwaysWithinDeclaredRanges() {
        let items = (0..<100).map { index in
            item(name: "Video-\(index).mp4", path: "/folder/Video-\(index).mp4")
        }

        for item in items {
            let first = MediaLibraryPresentation.posterStyle(for: item)
            let second = MediaLibraryPresentation.posterStyle(for: item)

            #expect(first == second)
            #expect((0..<MediaLibraryPresentation.paletteCount).contains(first.paletteIndex))
            #expect((0..<MediaLibraryPresentation.symbolCount).contains(first.symbolIndex))
        }
    }

    @Test func projectionJoinsScannedMediaHistoryAndProgressByMediaIdentity() throws {
        let sourceID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let scanned = item(
            name: "Arrival.mkv",
            path: "/Movies/Arrival.mkv",
            sourceID: sourceID,
            sourceName: "Current NAS",
            size: 1_024,
            modifiedAt: date(100)
        )
        let mediaID = mediaID(for: scanned)
        let history = try historyEntry(
            mediaID: mediaID,
            item: scanned,
            sourceDisplayName: "Old NAS",
            lastPlayedAt: date(200)
        )
        let progress = try playbackProgress(
            mediaID: mediaID,
            sourceID: sourceID,
            position: 40,
            duration: 100,
            modifiedAt: date(300)
        )

        let result = MediaLibraryPresentation.project(
            scannedItems: [scanned],
            history: [history],
            progress: [progress],
            configuredSourceIDs: [sourceID],
            connectedSourceIDs: [sourceID]
        )

        #expect(result.allVideos.count == 1)
        #expect(result.allVideos[0].mediaID == mediaID)
        #expect(result.allVideos[0].item.sourceName == "Current NAS")
        #expect(result.allVideos[0].lastPlayedAt == date(200))
        #expect(result.allVideos[0].effectiveResumePosition == 40)
        #expect(result.allVideos[0].progressRatio == 0.4)
        #expect(result.allVideos[0].isAvailable)
    }

    @Test func projectionKeepsConfiguredDisconnectedHistoryUnavailable() throws {
        let sourceID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let historicalItem = item(
            name: "Moon.mp4",
            path: "/Movies/Moon.mp4",
            sourceID: sourceID,
            sourceName: "Bedroom NAS",
            size: 2_048,
            modifiedAt: date(100)
        )
        let mediaID = mediaID(for: historicalItem)
        let history = try historyEntry(
            mediaID: mediaID,
            item: historicalItem,
            lastPlayedAt: date(200)
        )
        let progress = try playbackProgress(
            mediaID: mediaID,
            sourceID: sourceID,
            position: 25,
            duration: 100,
            modifiedAt: date(300)
        )

        let result = MediaLibraryPresentation.project(
            scannedItems: [],
            history: [history],
            progress: [progress],
            configuredSourceIDs: [sourceID],
            connectedSourceIDs: []
        )

        #expect(result.allVideos.map(\.item) == [historicalItem])
        #expect(result.continueWatching.map(\.mediaID) == [mediaID])
        #expect(result.allVideos[0].isAvailable == false)
    }

    @Test func projectionDropsHistoryForSourcesNoLongerConfigured() throws {
        let sourceID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let historicalItem = item(
            name: "Removed.mp4",
            path: "/Removed.mp4",
            sourceID: sourceID,
            size: 100
        )
        let history = try historyEntry(
            mediaID: mediaID(for: historicalItem),
            item: historicalItem,
            lastPlayedAt: date(200)
        )

        let result = MediaLibraryPresentation.project(
            scannedItems: [],
            history: [history],
            progress: [],
            configuredSourceIDs: [],
            connectedSourceIDs: []
        )

        #expect(result.allVideos.isEmpty)
        #expect(result.recentlyPlayed.isEmpty)
    }

    @Test func changedFileIdentityDoesNotInheritOldProgress() throws {
        let sourceID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let oldItem = item(
            name: "Movie.mkv",
            path: "/Movie.mkv",
            sourceID: sourceID,
            size: 100,
            modifiedAt: date(100)
        )
        let changedItem = item(
            name: "Movie.mkv",
            path: "/Movie.mkv",
            sourceID: sourceID,
            size: 200,
            modifiedAt: date(200)
        )
        let oldMediaID = mediaID(for: oldItem)
        let history = try historyEntry(
            mediaID: oldMediaID,
            item: oldItem,
            lastPlayedAt: date(300)
        )
        let oldProgress = try playbackProgress(
            mediaID: oldMediaID,
            sourceID: sourceID,
            position: 50,
            duration: 100,
            modifiedAt: date(400)
        )

        let result = MediaLibraryPresentation.project(
            scannedItems: [changedItem],
            history: [history],
            progress: [oldProgress],
            configuredSourceIDs: [sourceID],
            connectedSourceIDs: [sourceID]
        )
        let changedProjection = try #require(
            result.allVideos.first { $0.item.media.size == 200 }
        )

        #expect(changedProjection.mediaID == mediaID(for: changedItem))
        #expect(changedProjection.effectiveResumePosition == 0)
        #expect(changedProjection.progressRatio == 0)
        #expect(changedProjection.isCompleted == false)
        #expect(result.allVideos.map(\.mediaID) == [mediaID(for: changedItem)])
        #expect(result.continueWatching.isEmpty)
        #expect(result.recentlyPlayed.isEmpty)
    }

    @Test func projectedSearchResultsExcludeReplacedHistoryAtTheSamePath() throws {
        let sourceID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let oldItem = item(
            name: "Movie.mkv",
            path: "/Movie.mkv",
            sourceID: sourceID,
            size: 100,
            modifiedAt: date(100)
        )
        let replacement = item(
            name: "Movie.mkv",
            path: "/Movie.mkv",
            sourceID: sourceID,
            size: 200,
            modifiedAt: date(200)
        )
        let projection = MediaLibraryPresentation.project(
            scannedItems: [replacement],
            history: [
                try historyEntry(
                    mediaID: mediaID(for: oldItem),
                    item: oldItem,
                    lastPlayedAt: date(300)
                ),
            ],
            progress: [],
            configuredSourceIDs: [sourceID],
            connectedSourceIDs: [sourceID]
        )

        let results = MediaLibraryPresentation.searchResults(
            projectedItems: projection.allVideos,
            matching: [replacement]
        )

        #expect(results.map(\.item) == [replacement])
    }

    @Test func scannedItemsWithoutSizeRemainVisibleButCannotJoinProgress() throws {
        let sourceID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let scanned = item(
            name: "Unknown.mp4",
            path: "/Unknown.mp4",
            sourceID: sourceID,
            size: nil
        )
        let unrelatedProgress = try playbackProgress(
            mediaID: String(repeating: "a", count: 64),
            sourceID: sourceID,
            position: 50,
            duration: 100,
            modifiedAt: date(100)
        )

        let result = MediaLibraryPresentation.project(
            scannedItems: [scanned],
            history: [],
            progress: [unrelatedProgress],
            configuredSourceIDs: [sourceID],
            connectedSourceIDs: [sourceID]
        )

        #expect(result.allVideos.count == 1)
        #expect(result.allVideos[0].mediaID == nil)
        #expect(result.allVideos[0].progressRatio == 0)
        #expect(result.continueWatching.isEmpty)
    }

    @Test func continueWatchingUsesResumeEligibilityNewestProgressAndStableTies() throws {
        let sourceID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let candidates = try (0..<15).map { index in
            let item = item(
                name: "Video-\(index).mp4",
                path: "/Video-\(index).mp4",
                sourceID: sourceID,
                size: Int64(1_000 + index)
            )
            let mediaID = mediaID(for: item)
            return (
                item,
                try historyEntry(
                    mediaID: mediaID,
                    item: item,
                    lastPlayedAt: date(TimeInterval(index))
                ),
                try playbackProgress(
                    mediaID: mediaID,
                    sourceID: sourceID,
                    position: 10,
                    duration: 100,
                    modifiedAt: date(TimeInterval(index))
                )
            )
        }
        let completed = try completedProjectionInput(sourceID: sourceID)
        let tooEarly = try earlyProjectionInput(sourceID: sourceID)

        let result = MediaLibraryPresentation.project(
            scannedItems: candidates.map(\.0) + [completed.item, tooEarly.item],
            history: candidates.map(\.1) + [completed.history, tooEarly.history],
            progress: candidates.map(\.2)
                + [completed.progress, tooEarly.progress].compactMap { $0 },
            configuredSourceIDs: [sourceID],
            connectedSourceIDs: [sourceID]
        )

        #expect(result.continueWatching.count == 12)
        #expect(result.continueWatching.first?.item.media.name == "Video-14.mp4")
        #expect(result.continueWatching.last?.item.media.name == "Video-3.mp4")
        #expect(result.continueWatching.allSatisfy { $0.effectiveResumePosition > 0 })

        let tied = try stableTieProjection(sourceID: sourceID)
        let tiedMediaIDs = tied.continueWatching.compactMap(\.mediaID)
        #expect(tiedMediaIDs == tiedMediaIDs.sorted())
    }

    @Test func recentlyPlayedExcludesContinueWatchingAndIncludesCompleted() throws {
        let sourceID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let active = try projectionInput(
            name: "Active.mp4",
            sourceID: sourceID,
            position: 20,
            isCompleted: false,
            lastPlayedAt: date(100)
        )
        let completed = try projectionInput(
            name: "Completed.mp4",
            sourceID: sourceID,
            position: 100,
            isCompleted: true,
            lastPlayedAt: date(300)
        )
        let noProgress = try projectionInput(
            name: "NoProgress.mp4",
            sourceID: sourceID,
            progress: false,
            lastPlayedAt: date(200)
        )

        let result = MediaLibraryPresentation.project(
            scannedItems: [active.item, completed.item, noProgress.item],
            history: [active.history, completed.history, noProgress.history],
            progress: [active.progress, completed.progress].compactMap { $0 },
            configuredSourceIDs: [sourceID],
            connectedSourceIDs: [sourceID]
        )

        #expect(result.continueWatching.map(\.item.media.name) == ["Active.mp4"])
        #expect(
            result.recentlyPlayed.map(\.item.media.name)
                == ["Completed.mp4", "NoProgress.mp4"]
        )
        #expect(result.recentlyPlayed.first?.isCompleted == true)
        #expect(result.recentlyPlayed.first?.isWatched == true)
    }
}

private func item(
    name: String,
    path: String,
    sourceID: UUID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
    sourceName: String = "NAS",
    size: Int64? = nil,
    modifiedAt: Date? = nil
) -> MediaLibraryItem {
    MediaLibraryItem(
        sourceID: sourceID,
        sourceName: sourceName,
        media: MediaSourceItem(
            name: name,
            path: path,
            kind: .file,
            size: size,
            modifiedAt: modifiedAt
        )
    )
}

private func mediaID(for item: MediaLibraryItem) -> String {
    MediaSyncIdentity.make(
        from: MediaFileIdentity(
            sourceID: item.sourceID,
            path: item.media.path,
            size: item.media.size!,
            modifiedAt: item.media.modifiedAt
        )
    )
}

private func historyEntry(
    mediaID: String,
    item: MediaLibraryItem,
    sourceDisplayName: String? = nil,
    lastPlayedAt: Date
) throws -> PlaybackHistoryEntry {
    try PlaybackHistoryEntry(
        mediaID: mediaID,
        sourceID: item.sourceID,
        sourceDisplayName: sourceDisplayName ?? item.sourceName,
        fileName: item.media.name,
        path: item.media.path,
        size: item.media.size!,
        modifiedAt: item.media.modifiedAt,
        lastPlayedAt: lastPlayedAt
    )
}

private func playbackProgress(
    mediaID: String,
    sourceID: UUID,
    position: TimeInterval,
    duration: TimeInterval,
    modifiedAt: Date,
    isCompleted: Bool? = nil
) throws -> PlaybackProgress {
    try PlaybackProgress(
        mediaID: mediaID,
        sourceID: sourceID,
        position: position,
        duration: duration,
        modifiedAt: modifiedAt,
        isCompleted: isCompleted
    )
}

private typealias ProjectionInput = (
    item: MediaLibraryItem,
    history: PlaybackHistoryEntry,
    progress: PlaybackProgress?
)

private func projectionInput(
    name: String,
    sourceID: UUID,
    position: TimeInterval = 0,
    isCompleted: Bool = false,
    progress includesProgress: Bool = true,
    lastPlayedAt: Date
) throws -> ProjectionInput {
    let item = item(
        name: name,
        path: "/\(name)",
        sourceID: sourceID,
        size: Int64(abs(name.hashValue)) + 1
    )
    let mediaID = mediaID(for: item)
    return (
        item,
        try historyEntry(mediaID: mediaID, item: item, lastPlayedAt: lastPlayedAt),
        includesProgress
            ? try playbackProgress(
                mediaID: mediaID,
                sourceID: sourceID,
                position: position,
                duration: 100,
                modifiedAt: lastPlayedAt,
                isCompleted: isCompleted
            )
            : nil
    )
}

private func completedProjectionInput(sourceID: UUID) throws -> ProjectionInput {
    try projectionInput(
        name: "Completed.mp4",
        sourceID: sourceID,
        position: 100,
        isCompleted: true,
        lastPlayedAt: date(1_000)
    )
}

private func earlyProjectionInput(sourceID: UUID) throws -> ProjectionInput {
    try projectionInput(
        name: "Early.mp4",
        sourceID: sourceID,
        position: 4,
        lastPlayedAt: date(1_001)
    )
}

private func stableTieProjection(sourceID: UUID) throws -> MediaLibraryProjection {
    let first = try projectionInput(
        name: "A.mp4",
        sourceID: sourceID,
        position: 10,
        lastPlayedAt: date(100)
    )
    let second = try projectionInput(
        name: "B.mp4",
        sourceID: sourceID,
        position: 10,
        lastPlayedAt: date(100)
    )
    return MediaLibraryPresentation.project(
        scannedItems: [second.item, first.item],
        history: [second.history, first.history],
        progress: [second.progress, first.progress].compactMap { $0 },
        configuredSourceIDs: [sourceID],
        connectedSourceIDs: [sourceID]
    )
}

private func date(_ timeIntervalSince1970: TimeInterval) -> Date {
    Date(timeIntervalSince1970: timeIntervalSince1970)
}
