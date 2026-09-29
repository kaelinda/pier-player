import Foundation
import MediaSourceKit
import Testing
@testable import PierPlayerApp

@Test func playbackQueueClampsItsInitialSelection() {
    let entries = playbackQueueFixture()

    let queue = PlaybackQueueState(entries: entries, startIndex: 99)

    #expect(queue.current?.title == "Third")
    #expect(queue.positionLabel == "3 of 3")
    #expect(queue.canAdvance == false)
    #expect(queue.canRetreat)
}

@Test func playbackQueueMovesInBothDirectionsWithoutWrapping() {
    let entries = playbackQueueFixture()
    var queue = PlaybackQueueState(entries: entries, startIndex: 1)

    #expect(queue.current?.title == "Second")
    let advancedToThird = queue.advance()
    #expect(advancedToThird)
    #expect(queue.current?.title == "Third")
    let refusedPastEnd = queue.advance()
    #expect(!refusedPastEnd)
    let returnedToSecond = queue.retreat()
    #expect(returnedToSecond)
    #expect(queue.current?.title == "Second")
    let returnedToFirst = queue.retreat()
    #expect(returnedToFirst)
    #expect(queue.current?.title == "First")
    let refusedBeforeStart = queue.retreat()
    #expect(!refusedBeforeStart)
}

@Test func playbackQueueSupportsExplicitSelectionAndAutoplayConfiguration() {
    let entries = playbackQueueFixture()
    var queue = PlaybackQueueState(
        entries: entries,
        startIndex: 0,
        autoplayEnabled: false
    )

    #expect(queue.autoplayEnabled == false)
    let selectedLast = queue.select(index: 2)
    #expect(selectedLast)
    #expect(queue.current?.id == entries[2].id)
    let refusedInvalidSelection = queue.select(index: 3)
    #expect(!refusedInvalidSelection)
    #expect(queue.currentIndex == 2)
    queue.toggleAutoplay()
    #expect(queue.autoplayEnabled)
}

@Test func emptyPlaybackQueueHasNoCurrentItemOrNavigation() {
    var queue = PlaybackQueueState(entries: [])

    #expect(queue.current == nil)
    #expect(queue.positionLabel == nil)
    #expect(!queue.canAdvance)
    #expect(!queue.canRetreat)
    let refusedAdvance = queue.advance()
    #expect(!refusedAdvance)
    let refusedRetreat = queue.retreat()
    #expect(!refusedRetreat)
}

private func playbackQueueFixture() -> [PlaybackQueueEntry] {
    let sourceID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    return ["First", "Second", "Third"].enumerated().map { index, title in
        PlaybackQueueEntry(
            sourceID: sourceID,
            sourceName: "Home NAS",
            media: MediaSourceItem(
                name: "\(title).mkv",
                path: "/Shows/\(index + 1).mkv",
                kind: .file,
                size: 1_024,
                modifiedAt: nil
            )
        )
    }
}
