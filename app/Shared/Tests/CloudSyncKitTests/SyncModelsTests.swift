import Foundation
import MediaSourceKit
import Testing
@testable import CloudSyncKit

@Test func progressNormalizesResumeBoundariesAndCompletion() throws {
    let mediaID = String(repeating: "a", count: 64)
    let sourceID = UUID()

    let opening = try PlaybackProgress(
        mediaID: mediaID,
        sourceID: sourceID,
        position: 4.9,
        duration: 100,
        modifiedAt: Date(timeIntervalSince1970: 1)
    )
    #expect(opening.effectiveResumePosition == 0)
    #expect(!opening.isCompleted)

    let completed = try PlaybackProgress(
        mediaID: mediaID,
        sourceID: sourceID,
        position: 95,
        duration: 100,
        modifiedAt: Date(timeIntervalSince1970: 2)
    )
    #expect(completed.isCompleted)
    #expect(completed.effectiveResumePosition == 0)

    let resumable = try PlaybackProgress(
        mediaID: mediaID,
        sourceID: sourceID,
        position: 42,
        duration: 100,
        modifiedAt: Date(timeIntervalSince1970: 3)
    )
    #expect(resumable.effectiveResumePosition == 42)
}

@Test func progressRejectsInvalidNumbersAndIdentity() {
    #expect(throws: PlaybackProgressError.invalidMediaID) {
        try PlaybackProgress(
            mediaID: "raw/path",
            sourceID: UUID(),
            position: 1,
            duration: 2
        )
    }
    #expect(throws: PlaybackProgressError.invalidPosition) {
        try PlaybackProgress(
            mediaID: String(repeating: "b", count: 64),
            sourceID: UUID(),
            position: .infinity,
            duration: 2
        )
    }
    #expect(throws: PlaybackProgressError.invalidDuration) {
        try PlaybackProgress(
            mediaID: String(repeating: "b", count: 64),
            sourceID: UUID(),
            position: 1,
            duration: 0
        )
    }
}

@Test func mediaIdentityIsOpaqueStableAndMetadataSensitive() {
    let sourceID = UUID()
    let base = MediaFileIdentity(
        sourceID: sourceID,
        path: "/Movies/Private Name.mkv",
        size: 100,
        modifiedAt: Date(timeIntervalSince1970: 10)
    )
    let same = MediaFileIdentity(
        sourceID: sourceID,
        path: "/Movies//Private Name.mkv",
        size: 100,
        modifiedAt: Date(timeIntervalSince1970: 10)
    )

    let first = MediaSyncIdentity.make(from: base)
    #expect(first == MediaSyncIdentity.make(from: same))
    #expect(first.count == 64)
    #expect(!first.contains("Movies"))
    #expect(first != MediaSyncIdentity.make(from: MediaFileIdentity(
        sourceID: sourceID,
        path: base.path,
        size: 101,
        modifiedAt: base.modifiedAt
    )))
}
