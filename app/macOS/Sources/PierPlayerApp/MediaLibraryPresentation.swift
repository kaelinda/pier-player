import CloudSyncKit
import Foundation
import MediaSourceKit

struct MediaPosterStyle: Equatable, Sendable {
    let paletteIndex: Int
    let symbolIndex: Int
}

struct MediaLibraryProjectedItem: Equatable, Sendable {
    let mediaID: String?
    let item: MediaLibraryItem
    let lastPlayedAt: Date?
    let progress: PlaybackProgress?
    let isAvailable: Bool

    var effectiveResumePosition: TimeInterval {
        progress?.effectiveResumePosition ?? 0
    }

    var progressRatio: Double {
        guard let progress else { return 0 }
        return min(max(progress.position / progress.duration, 0), 1)
    }

    var isCompleted: Bool {
        progress?.isCompleted ?? false
    }

    var isWatched: Bool {
        isCompleted
    }
}

struct MediaLibraryProjection: Equatable, Sendable {
    let continueWatching: [MediaLibraryProjectedItem]
    let recentlyPlayed: [MediaLibraryProjectedItem]
    let allVideos: [MediaLibraryProjectedItem]
}

enum MediaLibraryPresentation {
    static let paletteCount = 8
    static let symbolCount = 6

    static func filtered(
        _ items: [MediaLibraryItem],
        query: String,
        locale: Locale = .current
    ) -> [MediaLibraryItem] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return items
        }

        return items.filter { item in
            containsCaseInsensitive(
                item.media.name,
                query: trimmedQuery,
                locale: locale
            ) || containsCaseInsensitive(
                item.sourceName,
                query: trimmedQuery,
                locale: locale
            )
        }
    }

    static func displayTitle(for item: MediaLibraryItem) -> String {
        let title = (item.media.name as NSString).deletingPathExtension
        return title.isEmpty ? item.media.name : title
    }

    static func recentlyAdded(
        _ items: [MediaLibraryItem],
        limit: Int = 12,
        locale: Locale = .current
    ) -> [MediaLibraryItem] {
        guard limit > 0 else {
            return []
        }

        return Array(
            items.sorted { lhs, rhs in
                isMoreRecent(lhs, rhs, locale: locale)
            }.prefix(limit)
        )
    }

    static func allVideos(
        _ items: [MediaLibraryItem],
        locale: Locale = .current
    ) -> [MediaLibraryItem] {
        items.sorted { lhs, rhs in
            isOrderedByTitle(lhs, rhs, locale: locale)
        }
    }

    static func project(
        scannedItems: [MediaLibraryItem],
        history: [PlaybackHistoryEntry],
        progress: [PlaybackProgress],
        configuredSourceIDs: Set<UUID>,
        connectedSourceIDs: Set<UUID>
    ) -> MediaLibraryProjection {
        let progressByMediaID = latestProgressByMediaID(progress)
        let retainedHistory = history.filter {
            configuredSourceIDs.contains($0.sourceID)
        }
        let historyByMediaID = latestHistoryByMediaID(retainedHistory)
        var projectedByMediaID: [String: MediaLibraryProjectedItem] = [:]

        for entry in historyByMediaID.values {
            projectedByMediaID[entry.mediaID] = MediaLibraryProjectedItem(
                mediaID: entry.mediaID,
                item: mediaLibraryItem(from: entry),
                lastPlayedAt: entry.lastPlayedAt,
                progress: progressByMediaID[entry.mediaID],
                isAvailable: connectedSourceIDs.contains(entry.sourceID)
            )
        }

        var unidentifiedScannedItems: [MediaLibraryProjectedItem] = []
        for item in scannedItems {
            guard let mediaID = mediaID(for: item) else {
                unidentifiedScannedItems.append(
                    MediaLibraryProjectedItem(
                        mediaID: nil,
                        item: item,
                        lastPlayedAt: nil,
                        progress: nil,
                        isAvailable: connectedSourceIDs.contains(item.sourceID)
                    )
                )
                continue
            }

            projectedByMediaID[mediaID] = MediaLibraryProjectedItem(
                mediaID: mediaID,
                item: item,
                lastPlayedAt: historyByMediaID[mediaID]?.lastPlayedAt,
                progress: progressByMediaID[mediaID],
                isAvailable: connectedSourceIDs.contains(item.sourceID)
            )
        }

        let projectedItems = Array(projectedByMediaID.values) + unidentifiedScannedItems
        let continueWatching = Array(
            projectedItems
                .filter { $0.effectiveResumePosition > 0 }
                .sorted(by: isContinueWatchingBefore)
                .prefix(12)
        )
        let continuingMediaIDs = Set(continueWatching.compactMap(\.mediaID))
        let recentlyPlayed = Array(
            projectedItems
                .filter {
                    $0.lastPlayedAt != nil
                        && ($0.mediaID.map { !continuingMediaIDs.contains($0) } ?? true)
                }
                .sorted(by: isRecentlyPlayedBefore)
                .prefix(12)
        )
        let sortedAllVideos = projectedItems.sorted {
            isOrderedByTitle($0.item, $1.item, locale: .current)
        }

        return MediaLibraryProjection(
            continueWatching: continueWatching,
            recentlyPlayed: recentlyPlayed,
            allVideos: sortedAllVideos
        )
    }

    static func posterStyle(for item: MediaLibraryItem) -> MediaPosterStyle {
        let hash = fnv1aHash(item.id)
        let paletteIndex = Int(hash % UInt64(paletteCount))
        let symbolIndex = Int(
            (hash / UInt64(paletteCount)) % UInt64(symbolCount)
        )
        return MediaPosterStyle(
            paletteIndex: paletteIndex,
            symbolIndex: symbolIndex
        )
    }

    private static func containsCaseInsensitive(
        _ value: String,
        query: String,
        locale: Locale
    ) -> Bool {
        value.range(
            of: query,
            options: [.caseInsensitive],
            range: nil,
            locale: locale
        ) != nil
    }

    private static func mediaID(for item: MediaLibraryItem) -> String? {
        guard let size = item.media.size else { return nil }
        return MediaSyncIdentity.make(
            from: MediaFileIdentity(
                sourceID: item.sourceID,
                path: item.media.path,
                size: size,
                modifiedAt: item.media.modifiedAt
            )
        )
    }

    private static func mediaLibraryItem(
        from history: PlaybackHistoryEntry
    ) -> MediaLibraryItem {
        MediaLibraryItem(
            sourceID: history.sourceID,
            sourceName: history.sourceDisplayName,
            media: MediaSourceItem(
                name: history.fileName,
                path: history.path,
                kind: .file,
                size: history.size,
                modifiedAt: history.modifiedAt
            )
        )
    }

    private static func latestProgressByMediaID(
        _ values: [PlaybackProgress]
    ) -> [String: PlaybackProgress] {
        values.reduce(into: [:]) { result, value in
            guard value.modifiedAt > result[value.mediaID]?.modifiedAt ?? .distantPast else {
                return
            }
            result[value.mediaID] = value
        }
    }

    private static func latestHistoryByMediaID(
        _ values: [PlaybackHistoryEntry]
    ) -> [String: PlaybackHistoryEntry] {
        values.reduce(into: [:]) { result, value in
            guard value.lastPlayedAt > result[value.mediaID]?.lastPlayedAt ?? .distantPast else {
                return
            }
            result[value.mediaID] = value
        }
    }

    private static func isContinueWatchingBefore(
        _ lhs: MediaLibraryProjectedItem,
        _ rhs: MediaLibraryProjectedItem
    ) -> Bool {
        let lhsDate = lhs.progress?.modifiedAt ?? .distantPast
        let rhsDate = rhs.progress?.modifiedAt ?? .distantPast
        if lhsDate != rhsDate { return lhsDate > rhsDate }
        return optionalRawCompare(lhs.mediaID, rhs.mediaID) == .orderedAscending
    }

    private static func isRecentlyPlayedBefore(
        _ lhs: MediaLibraryProjectedItem,
        _ rhs: MediaLibraryProjectedItem
    ) -> Bool {
        let lhsDate = lhs.lastPlayedAt ?? .distantPast
        let rhsDate = rhs.lastPlayedAt ?? .distantPast
        if lhsDate != rhsDate { return lhsDate > rhsDate }
        return optionalRawCompare(lhs.mediaID, rhs.mediaID) == .orderedAscending
    }

    private static func optionalRawCompare(
        _ lhs: String?,
        _ rhs: String?
    ) -> ComparisonResult {
        switch (lhs, rhs) {
        case let (lhs?, rhs?):
            rawCompare(lhs, rhs)
        case (_?, nil):
            .orderedAscending
        case (nil, _?):
            .orderedDescending
        case (nil, nil):
            .orderedSame
        }
    }

    private static func isMoreRecent(
        _ lhs: MediaLibraryItem,
        _ rhs: MediaLibraryItem,
        locale: Locale
    ) -> Bool {
        switch (lhs.media.modifiedAt, rhs.media.modifiedAt) {
        case let (lhsDate?, rhsDate?) where lhsDate != rhsDate:
            return lhsDate > rhsDate
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            return isOrderedByTitle(lhs, rhs, locale: locale)
        }
    }

    private static func isOrderedByTitle(
        _ lhs: MediaLibraryItem,
        _ rhs: MediaLibraryItem,
        locale: Locale
    ) -> Bool {
        let titleOrder = caseInsensitiveCompare(
            displayTitle(for: lhs),
            displayTitle(for: rhs),
            locale: locale
        )
        if titleOrder != .orderedSame {
            return titleOrder == .orderedAscending
        }

        let pathOrder = caseInsensitiveCompare(
            lhs.media.path,
            rhs.media.path,
            locale: locale
        )
        if pathOrder != .orderedSame {
            return pathOrder == .orderedAscending
        }

        let rawPathOrder = rawCompare(lhs.media.path, rhs.media.path)
        if rawPathOrder != .orderedSame {
            return rawPathOrder == .orderedAscending
        }

        return rawCompare(lhs.id, rhs.id) == .orderedAscending
    }

    private static func caseInsensitiveCompare(
        _ lhs: String,
        _ rhs: String,
        locale: Locale
    ) -> ComparisonResult {
        lhs.compare(
            rhs,
            options: [.caseInsensitive],
            range: nil,
            locale: locale
        )
    }

    private static func rawCompare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        if lhs.utf8.elementsEqual(rhs.utf8) {
            return .orderedSame
        }
        return lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
            ? .orderedAscending
            : .orderedDescending
    }

    private static func fnv1aHash(_ value: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }
}
