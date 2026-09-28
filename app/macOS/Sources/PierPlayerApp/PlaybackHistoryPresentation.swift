import CloudSyncKit
import Foundation
import MediaSourceKit

struct PlaybackHistoryItem: Equatable, Identifiable, Sendable {
    let progress: PlaybackProgress
    let media: MediaLibraryItem?
    let sourceName: String
    let title: String

    var id: String { progress.mediaID }

    var isUnavailable: Bool { media == nil }

    var fractionCompleted: Double {
        guard progress.duration > 0 else { return 0 }
        return min(max(progress.position / progress.duration, 0), 1)
    }

    var percentageCompleted: Int {
        Int((fractionCompleted * 100).rounded())
    }

    var remainingTime: TimeInterval {
        max(progress.duration - progress.position, 0)
    }
}

struct PlaybackHistorySnapshot: Equatable, Sendable {
    let all: [PlaybackHistoryItem]
    let continueWatching: [PlaybackHistoryItem]
    let recentlyPlayed: [PlaybackHistoryItem]

    static let empty = PlaybackHistorySnapshot(
        all: [],
        continueWatching: [],
        recentlyPlayed: []
    )

    var hasActiveHistory: Bool {
        !all.isEmpty
    }
}

enum PlaybackHistoryPresentation {
    static let defaultLimit = 8

    static func make(
        progress: [PlaybackProgress],
        items: [MediaLibraryItem],
        sourceNames: [UUID: String],
        limit: Int = defaultLimit
    ) -> PlaybackHistorySnapshot {
        guard limit > 0 else {
            return .empty
        }

        let mediaByIdentity = Dictionary(
            items.map { (identity(for: $0), $0) },
            uniquingKeysWith: chooseMediaItem
        )
        let uniqueProgress = Dictionary(
            progress.map { ($0.mediaID, $0) },
            uniquingKeysWith: chooseProgress
        )
        let active = uniqueProgress.values
            .filter { !$0.isDeleted }
            .sorted(by: isMoreRecent)

        let all = active.map { value in
            makeItem(
                progress: value,
                media: mediaByIdentity[value.mediaID],
                sourceNames: sourceNames
            )
        }
        let continueWatching = Array(
            all.filter {
                guard let media = $0.media, media.media.kind == .file else {
                    return false
                }
                return !$0.progress.isCompleted
                    && $0.progress.effectiveResumePosition > 0
            }.prefix(limit)
        )
        let continueIDs = Set(continueWatching.map(\.id))
        let recentlyPlayed = Array(
            all.filter { !continueIDs.contains($0.id) }.prefix(limit)
        )

        return PlaybackHistorySnapshot(
            all: all,
            continueWatching: continueWatching,
            recentlyPlayed: recentlyPlayed
        )
    }

    static func displayRemainingTime(_ duration: TimeInterval) -> String {
        let totalSeconds = max(Int(duration.rounded()), 0)
        if totalSeconds < 60 {
            return "<1 min"
        }
        let minutes = totalSeconds / 60
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        if hours > 0 {
            return remainingMinutes == 0
                ? "\(hours) hr"
                : "\(hours) hr \(remainingMinutes) min"
        }
        return "\(minutes) min"
    }

    private static func makeItem(
        progress: PlaybackProgress,
        media: MediaLibraryItem?,
        sourceNames: [UUID: String]
    ) -> PlaybackHistoryItem {
        PlaybackHistoryItem(
            progress: progress,
            media: media,
            sourceName: media?.sourceName
                ?? sourceNames[progress.sourceID]
                ?? "Unavailable Source",
            title: media.map(MediaLibraryPresentation.displayTitle(for:))
                ?? "Unavailable Video"
        )
    }

    private static func identity(for item: MediaLibraryItem) -> String {
        MediaSyncIdentity.make(
            from: MediaFileIdentity(
                sourceID: item.sourceID,
                path: item.media.path,
                size: item.media.size ?? 0,
                modifiedAt: item.media.modifiedAt
            )
        )
    }

    private static func chooseMediaItem(
        _ lhs: MediaLibraryItem,
        _ rhs: MediaLibraryItem
    ) -> MediaLibraryItem {
        lhs.id <= rhs.id ? lhs : rhs
    }

    private static func chooseProgress(
        _ lhs: PlaybackProgress,
        _ rhs: PlaybackProgress
    ) -> PlaybackProgress {
        if lhs.modifiedAt != rhs.modifiedAt {
            return lhs.modifiedAt > rhs.modifiedAt ? lhs : rhs
        }
        if lhs.isDeleted != rhs.isDeleted {
            return lhs.isDeleted ? lhs : rhs
        }
        if lhs.sourceID != rhs.sourceID {
            return lhs.sourceID.uuidString > rhs.sourceID.uuidString ? lhs : rhs
        }
        if lhs.position != rhs.position {
            return lhs.position > rhs.position ? lhs : rhs
        }
        if lhs.duration != rhs.duration {
            return lhs.duration > rhs.duration ? lhs : rhs
        }
        return lhs.mediaID >= rhs.mediaID ? lhs : rhs
    }

    private static func isMoreRecent(
        _ lhs: PlaybackProgress,
        _ rhs: PlaybackProgress
    ) -> Bool {
        if lhs.modifiedAt != rhs.modifiedAt {
            return lhs.modifiedAt > rhs.modifiedAt
        }
        if lhs.mediaID != rhs.mediaID {
            return lhs.mediaID > rhs.mediaID
        }
        return lhs.sourceID.uuidString > rhs.sourceID.uuidString
    }
}
