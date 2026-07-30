import Foundation
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
}

private func item(
    name: String,
    path: String,
    sourceID: UUID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
    sourceName: String = "NAS",
    modifiedAt: Date? = nil
) -> MediaLibraryItem {
    MediaLibraryItem(
        sourceID: sourceID,
        sourceName: sourceName,
        media: MediaSourceItem(
            name: name,
            path: path,
            kind: .file,
            size: nil,
            modifiedAt: modifiedAt
        )
    )
}

private func date(_ timeIntervalSince1970: TimeInterval) -> Date {
    Date(timeIntervalSince1970: timeIntervalSince1970)
}
