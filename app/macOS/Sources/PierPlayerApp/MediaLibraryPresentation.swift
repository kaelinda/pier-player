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
        query: String
    ) -> [MediaLibraryItem] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return items
        }

        return items.filter { item in
            containsCaseInsensitive(item.media.name, query: trimmedQuery)
                || containsCaseInsensitive(item.sourceName, query: trimmedQuery)
        }
    }

    static func displayTitle(for item: MediaLibraryItem) -> String {
        let title = (item.media.name as NSString).deletingPathExtension
        return title.isEmpty ? item.media.name : title
    }

    static func recentlyAdded(
        _ items: [MediaLibraryItem],
        limit: Int = 12
    ) -> [MediaLibraryItem] {
        guard limit > 0 else {
            return []
        }

        return Array(
            items.sorted(by: isMoreRecent).prefix(limit)
        )
    }

    static func allVideos(_ items: [MediaLibraryItem]) -> [MediaLibraryItem] {
        items.sorted(by: isOrderedByTitle)
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

    private static func containsCaseInsensitive(_ value: String, query: String) -> Bool {
        value.range(
            of: query,
            options: [.caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ) != nil
    }

    private static func isMoreRecent(
        _ lhs: MediaLibraryItem,
        _ rhs: MediaLibraryItem
    ) -> Bool {
        switch (lhs.media.modifiedAt, rhs.media.modifiedAt) {
        case let (lhsDate?, rhsDate?) where lhsDate != rhsDate:
            return lhsDate > rhsDate
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            return isOrderedByTitle(lhs, rhs)
        }
    }

    private static func isOrderedByTitle(
        _ lhs: MediaLibraryItem,
        _ rhs: MediaLibraryItem
    ) -> Bool {
        let titleOrder = caseInsensitiveCompare(
            displayTitle(for: lhs),
            displayTitle(for: rhs)
        )
        if titleOrder != .orderedSame {
            return titleOrder == .orderedAscending
        }

        let pathOrder = caseInsensitiveCompare(lhs.media.path, rhs.media.path)
        if pathOrder != .orderedSame {
            return pathOrder == .orderedAscending
        }
        if lhs.media.path != rhs.media.path {
            return lhs.media.path < rhs.media.path
        }

        return lhs.id < rhs.id
    }

    private static func caseInsensitiveCompare(
        _ lhs: String,
        _ rhs: String
    ) -> ComparisonResult {
        let locale = Locale(identifier: "en_US_POSIX")
        let lhsKey = lhs.lowercased(with: locale)
        let rhsKey = rhs.lowercased(with: locale)
        if lhsKey == rhsKey {
            return .orderedSame
        }
        return lhsKey < rhsKey ? .orderedAscending : .orderedDescending
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
