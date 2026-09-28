import CloudSyncKit
import Foundation
import MediaSourceKit
import Testing

@testable import PierPlayerApp

@Suite("PlaybackHistoryPresentationTests")
struct PlaybackHistoryPresentationTests {
    @Test func continueWatchingIncludesOnlyResolvedResumableItems() throws {
        let sourceID = UUID()
        let item = mediaItem(
            name: "Arrival.mkv",
            path: "/Movies/Arrival.mkv",
            sourceID: sourceID,
            size: 100
        )
        let progress = try makeProgress(
            for: item,
            position: 40,
            duration: 100,
            modifiedAt: 20
        )
        let short = try makeProgress(
            for: mediaItem(
                name: "Short.mp4",
                path: "/Movies/Short.mp4",
                sourceID: sourceID,
                size: 101
            ),
            position: 2,
            duration: 100,
            modifiedAt: 30
        )
        let completed = try makeProgress(
            for: mediaItem(
                name: "Done.mp4",
                path: "/Movies/Done.mp4",
                sourceID: sourceID,
                size: 102
            ),
            position: 100,
            duration: 100,
            modifiedAt: 40
        )

        let history = PlaybackHistoryPresentation.make(
            progress: [progress, short, completed],
            items: [item],
            sourceNames: [sourceID: "Living Room NAS"]
        )

        #expect(history.continueWatching.map(\.id) == [progress.mediaID])
        #expect(history.recentlyPlayed.map(\.id) == [completed.mediaID, short.mediaID])
    }

    @Test func recentlyPlayedKeepsUnavailableRecordsWithConfiguredSourceName() throws {
        let sourceID = UUID()
        let missing = try PlaybackProgress(
            mediaID: String(repeating: "b", count: 64),
            sourceID: sourceID,
            position: 90,
            duration: 100,
            modifiedAt: Date(timeIntervalSince1970: 50),
            isCompleted: true
        )

        let history = PlaybackHistoryPresentation.make(
            progress: [missing],
            items: [],
            sourceNames: [sourceID: "Offline NAS"]
        )

        #expect(history.continueWatching.isEmpty)
        #expect(history.recentlyPlayed.count == 1)
        #expect(history.recentlyPlayed[0].isUnavailable)
        #expect(history.recentlyPlayed[0].title == "Unavailable Video")
        #expect(history.recentlyPlayed[0].sourceName == "Offline NAS")
    }

    @Test func duplicateProgressUsesNewestThenDeterministicTieBreakers() throws {
        let item = mediaItem(
            name: "Duplicate.mp4",
            path: "/Duplicate.mp4",
            sourceID: UUID(),
            size: 100
        )
        let older = try makeProgress(
            for: item,
            position: 20,
            duration: 100,
            modifiedAt: 10
        )
        let newer = try makeProgress(
            for: item,
            position: 60,
            duration: 100,
            modifiedAt: 20
        )
        let sameDateCompleted = try PlaybackProgress(
            mediaID: newer.mediaID,
            sourceID: newer.sourceID,
            position: 100,
            duration: 100,
            modifiedAt: newer.modifiedAt,
            isCompleted: true
        )

        let history = PlaybackHistoryPresentation.make(
            progress: [older, sameDateCompleted, newer],
            items: [item],
            sourceNames: [:]
        )

        #expect(history.all.map(\.progress.position) == [100])
        #expect(history.all.first?.progress.isCompleted == true)
    }

    @Test func historyLimitsEachSectionToEightItems() throws {
        let sourceID = UUID()
        let items = (0..<12).map { index in
            mediaItem(
                name: "Video-\(index).mp4",
                path: "/Video-\(index).mp4",
                sourceID: sourceID,
                size: Int64(index + 1)
            )
        }
        let progress = try items.enumerated().map { index, item in
            try makeProgress(
                for: item,
                position: 20,
                duration: 100,
                modifiedAt: TimeInterval(index)
            )
        }

        let history = PlaybackHistoryPresentation.make(
            progress: progress,
            items: items,
            sourceNames: [sourceID: "NAS"]
        )

        #expect(history.continueWatching.count == 8)
        #expect(history.recentlyPlayed.count == 4)
    }
}

private func mediaItem(
    name: String,
    path: String,
    sourceID: UUID,
    size: Int64?
) -> MediaLibraryItem {
    MediaLibraryItem(
        sourceID: sourceID,
        sourceName: "Connected NAS",
        media: MediaSourceItem(
            name: name,
            path: path,
            kind: .file,
            size: size,
            modifiedAt: Date(timeIntervalSince1970: 1)
        )
    )
}

private func makeProgress(
    for item: MediaLibraryItem,
    position: TimeInterval,
    duration: TimeInterval,
    modifiedAt: TimeInterval
) throws -> PlaybackProgress {
    let identity = MediaFileIdentity(
        sourceID: item.sourceID,
        path: item.media.path,
        size: item.media.size ?? 0,
        modifiedAt: item.media.modifiedAt
    )
    return try PlaybackProgress(
        mediaID: MediaSyncIdentity.make(from: identity),
        sourceID: item.sourceID,
        position: position,
        duration: duration,
        modifiedAt: Date(timeIntervalSince1970: modifiedAt)
    )
}
