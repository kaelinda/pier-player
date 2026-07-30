import Foundation
import Testing
@testable import MediaSourceKit

@Test func supportedVideoDetectionIsCaseInsensitive() {
    let mkv = MediaSourceItem(
        name: "Feature.MKV",
        path: "Movies/Feature.MKV",
        kind: .file,
        size: 8_000_000_000,
        modifiedAt: nil
    )
    let mp4 = MediaSourceItem(
        name: "clip.mp4",
        path: "Clips/clip.mp4",
        kind: .file,
        size: 1_000,
        modifiedAt: nil
    )

    #expect(mkv.isSupportedVideo)
    #expect(mp4.isSupportedVideo)
}

@Test func directoriesAreNotVideosEvenWhenNamedLikeFiles() {
    let directory = MediaSourceItem(
        name: "Archive.mkv",
        path: "Archive.mkv",
        kind: .directory,
        size: nil,
        modifiedAt: nil
    )

    #expect(!directory.isSupportedVideo)
}

@Test func unsupportedExtensionsAreRejected() {
    let item = MediaSourceItem(
        name: "notes.txt",
        path: "Movies/notes.txt",
        kind: .file,
        size: 42,
        modifiedAt: nil
    )

    #expect(!item.isSupportedVideo)
}

@Test func commonVideoContainerExtensionsAreRecognized() {
    let supportedExtensions = [
        "mkv", "webm", "mp4", "mov", "m4v", "avi", "flv", "ts", "m2ts",
        "mts", "mpeg", "mpg", "vob", "ogv", "3gp", "asf", "wmv",
    ]

    for fileExtension in supportedExtensions {
        let item = MediaSourceItem(
            name: "Feature.\(fileExtension.uppercased())",
            path: "Movies/Feature.\(fileExtension.uppercased())",
            kind: .file,
            size: 1_000,
            modifiedAt: nil
        )
        #expect(item.isSupportedVideo, "Expected .\(fileExtension) to be recognized")
    }
}

@Test func identityChangesWhenRemoteMetadataChanges() {
    let sourceID = UUID()
    let original = MediaFileIdentity(
        sourceID: sourceID,
        path: "Movies/Feature.mkv",
        size: 100,
        modifiedAt: Date(timeIntervalSince1970: 1_000)
    )
    let resized = MediaFileIdentity(
        sourceID: sourceID,
        path: "Movies/Feature.mkv",
        size: 101,
        modifiedAt: Date(timeIntervalSince1970: 1_000)
    )
    let modified = MediaFileIdentity(
        sourceID: sourceID,
        path: "Movies/Feature.mkv",
        size: 100,
        modifiedAt: Date(timeIntervalSince1970: 2_000)
    )

    #expect(original != resized)
    #expect(original != modified)
}
