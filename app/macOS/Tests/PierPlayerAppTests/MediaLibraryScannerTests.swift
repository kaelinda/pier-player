import Foundation
import MediaSourceKit
import Testing

@testable import PierPlayerApp

@Suite("MediaLibraryScannerTests")
struct MediaLibraryScannerTests {
    @Test func scanIncludesOnlySupportedVideoFiles() async throws {
        let sourceID = UUID()
        let source = MediaLibrarySource(
            id: sourceID,
            displayName: "Living Room NAS",
            listDirectory: { path in
                #expect(path == "/")
                return [
                    mediaItem(name: "movie.mp4", path: "/movie.mp4"),
                    mediaItem(name: "FEATURE.MKV", path: "/FEATURE.MKV"),
                    mediaItem(name: "notes.txt", path: "/notes.txt"),
                    mediaItem(name: "archive.avi", path: "/archive.avi"),
                ]
            }
        )

        let result = try await MediaLibraryScanner().scan(source: source)

        #expect(result.items.map(\.media.path) == ["/movie.mp4", "/FEATURE.MKV"])
        #expect(result.items.allSatisfy { $0.sourceID == sourceID })
        #expect(result.items.allSatisfy { $0.sourceName == "Living Room NAS" })
        #expect(result.failure == nil)
    }

    @Test func scanUsesBreadthFirstTraversalAndDoesNotListPastDepthThree() async throws {
        let reads = DirectoryReadRecorder()
        let tree: [String: [MediaSourceItem]] = [
            "/": [
                directoryItem(name: "alpha", path: "/alpha"),
                directoryItem(name: "beta", path: "/beta"),
                mediaItem(name: "root.mp4", path: "/root.mp4"),
            ],
            "/alpha": [
                directoryItem(name: "one", path: "/alpha/one"),
                mediaItem(name: "alpha.mov", path: "/alpha/alpha.mov"),
            ],
            "/beta": [
                mediaItem(name: "beta.m4v", path: "/beta/beta.m4v")
            ],
            "/alpha/one": [
                directoryItem(name: "two", path: "/alpha/one/two")
            ],
            "/alpha/one/two": [
                directoryItem(name: "too-deep", path: "/alpha/one/two/too-deep"),
                mediaItem(name: "deep.mkv", path: "/alpha/one/two/deep.mkv"),
            ],
            "/alpha/one/two/too-deep": [
                mediaItem(name: "excluded.mp4", path: "/alpha/one/two/too-deep/excluded.mp4")
            ],
        ]
        let source = MediaLibrarySource(id: UUID(), displayName: "NAS") { path in
            await reads.record(path)
            return tree[path, default: []]
        }

        let result = try await MediaLibraryScanner().scan(source: source)

        #expect(
            await reads.snapshot() == [
                "/",
                "/alpha",
                "/beta",
                "/alpha/one",
                "/alpha/one/two",
            ])
        #expect(
            result.items.map(\.media.path) == [
                "/root.mp4",
                "/alpha/alpha.mov",
                "/beta/beta.m4v",
                "/alpha/one/two/deep.mkv",
            ])
    }

    @Test func scanStopsAtDefaultMaximumVideoCount() async throws {
        let reads = DirectoryReadRecorder()
        let rootItems =
            (0..<250).map { index in
                mediaItem(name: "video-\(index).mp4", path: "/video-\(index).mp4")
            } + [directoryItem(name: "unread", path: "/unread")]
        let source = MediaLibrarySource(id: UUID(), displayName: "NAS") { path in
            await reads.record(path)
            if path == "/" {
                return rootItems
            }
            return [mediaItem(name: "unexpected.mp4", path: "/unread/unexpected.mp4")]
        }

        let result = try await MediaLibraryScanner().scan(source: source)

        #expect(
            MediaLibraryScanLimits()
                == MediaLibraryScanLimits(
                    maximumDepth: 3,
                    maximumVideoCount: 200
                ))
        #expect(result.items.count == 200)
        #expect(result.items.last?.media.path == "/video-199.mp4")
        #expect(await reads.snapshot() == ["/"])
    }

    @Test func scanRetainsVideosAndSanitizesNestedDirectoryFailure() async throws {
        let sourceID = UUID()
        let source = MediaLibrarySource(id: sourceID, displayName: "Private NAS") { path in
            switch path {
            case "/":
                return [
                    mediaItem(name: "kept.mp4", path: "/kept.mp4"),
                    directoryItem(name: "restricted", path: "/restricted"),
                ]
            case "/restricted":
                throw SensitiveListingError(message: "smb://user:secret@private-host/share")
            default:
                return []
            }
        }

        let result = try await MediaLibraryScanner().scan(source: source)
        let failure = try #require(result.failure)

        #expect(result.items.map(\.media.path) == ["/kept.mp4"])
        #expect(failure.id == sourceID)
        #expect(failure.sourceID == sourceID)
        #expect(failure.sourceName == "Private NAS")
    }

    @Test func cancellationPropagatesAndStopsFurtherDirectoryReads() async {
        let reads = DirectoryReadRecorder()
        let source = MediaLibrarySource(id: UUID(), displayName: "NAS") { path in
            await reads.record(path)
            switch path {
            case "/":
                return [
                    directoryItem(name: "first", path: "/first"),
                    directoryItem(name: "second", path: "/second"),
                ]
            case "/first":
                try await Task.sleep(for: .milliseconds(250))
                return []
            default:
                return []
            }
        }
        let task = Task {
            try await MediaLibraryScanner().scan(source: source)
        }

        let reachedFirstDirectory = await reads.waitUntilRead(
            "/first",
            timeout: .seconds(1)
        )
        #expect(reachedFirstDirectory)
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(await reads.snapshot() == ["/", "/first"])
    }

    @Test func mediaLibraryItemIdentityCombinesSourceAndPath() {
        let media = mediaItem(name: "movie.mp4", path: "/movie.mp4")
        let firstSourceID = UUID()
        let secondSourceID = UUID()

        let first = MediaLibraryItem(
            sourceID: firstSourceID,
            sourceName: "First",
            media: media
        )
        let renamed = MediaLibraryItem(
            sourceID: firstSourceID,
            sourceName: "Renamed",
            media: media
        )
        let second = MediaLibraryItem(
            sourceID: secondSourceID,
            sourceName: "Second",
            media: media
        )

        #expect(first.id == renamed.id)
        #expect(first.id != second.id)
    }
}

private actor DirectoryReadRecorder {
    private var paths: [String] = []

    func record(_ path: String) {
        paths.append(path)
    }

    func snapshot() -> [String] {
        paths
    }

    func waitUntilRead(_ path: String, timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

        while !paths.contains(path), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }

        return paths.contains(path)
    }
}

private struct SensitiveListingError: Error {
    let message: String
}

private func mediaItem(name: String, path: String) -> MediaSourceItem {
    MediaSourceItem(
        name: name,
        path: path,
        kind: .file,
        size: nil,
        modifiedAt: nil
    )
}

private func directoryItem(name: String, path: String) -> MediaSourceItem {
    MediaSourceItem(
        name: name,
        path: path,
        kind: .directory,
        size: nil,
        modifiedAt: nil
    )
}
