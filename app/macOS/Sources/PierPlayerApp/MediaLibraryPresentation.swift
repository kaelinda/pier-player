import Foundation

struct MediaPosterStyle: Equatable, Sendable {
    let paletteIndex: Int
    let symbolIndex: Int
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
