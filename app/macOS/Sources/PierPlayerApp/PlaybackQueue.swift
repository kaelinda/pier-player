import Foundation
import MediaSourceKit

struct PlaybackQueueEntry: Equatable, Hashable, Identifiable, Sendable {
    let sourceID: UUID
    let sourceName: String
    let media: MediaSourceItem

    var id: String {
        "\(sourceID.uuidString):\(media.path)"
    }

    var title: String {
        let value = (media.name as NSString).deletingPathExtension
        return value.isEmpty ? media.name : value
    }
}

struct PlaybackQueueState: Equatable, Sendable {
    let entries: [PlaybackQueueEntry]
    private(set) var autoplayEnabled: Bool
    private(set) var currentIndex: Int

    init(
        entries: [PlaybackQueueEntry],
        startIndex: Int = 0,
        autoplayEnabled: Bool = true
    ) {
        self.entries = entries
        self.autoplayEnabled = autoplayEnabled
        if entries.isEmpty {
            currentIndex = 0
        } else {
            currentIndex = min(max(startIndex, 0), entries.count - 1)
        }
    }

    var current: PlaybackQueueEntry? {
        guard entries.indices.contains(currentIndex) else { return nil }
        return entries[currentIndex]
    }

    var positionLabel: String? {
        guard !entries.isEmpty else { return nil }
        return "\(currentIndex + 1) of \(entries.count)"
    }

    var canAdvance: Bool {
        currentIndex + 1 < entries.count
    }

    var canRetreat: Bool {
        currentIndex > 0
    }

    @discardableResult
    mutating func advance() -> Bool {
        guard canAdvance else { return false }
        currentIndex += 1
        return true
    }

    @discardableResult
    mutating func retreat() -> Bool {
        guard canRetreat else { return false }
        currentIndex -= 1
        return true
    }

    @discardableResult
    mutating func select(index: Int) -> Bool {
        guard entries.indices.contains(index) else { return false }
        currentIndex = index
        return true
    }

    mutating func toggleAutoplay() {
        autoplayEnabled.toggle()
    }
}
