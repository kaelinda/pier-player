import Foundation
import MediaSourceKit
import Testing
@testable import SubtitleKit

@Test func discoveryMatchesSameBasenameCaseInsensitively() {
    let items = [
        subtitleItem("MOVIE.SRT", size: 10),
        subtitleItem("Movie.en.ass", size: 10),
        subtitleItem("movie.zh-Hans.vtt", size: 10),
        subtitleItem("movie2.srt", size: 10),
        MediaSourceItem(name: "movie.srt", path: "/movie.srt", kind: .directory, size: nil, modifiedAt: nil),
    ]

    let matches = ExternalSubtitleDiscovery.discover(
        videoPath: "/Movie.MKV",
        among: items
    )

    #expect(matches.map(\.item.name) == ["Movie.en.ass", "MOVIE.SRT", "movie.zh-Hans.vtt"])
    #expect(matches.map(\.language) == ["en", nil, "zh-Hans"])
}

@Test func externalLoadEnforcesCapBeforeOpenAndAlwaysClosesHandle() async throws {
    let oversized = subtitleItem("movie.srt", size: 8 * 1024 * 1024 + 1)
    let oversizedSource = SubtitleTestSource(bytes: Data())
    let oversizedCandidate = ExternalSubtitleCandidate(
        item: oversized,
        format: .subRip,
        language: nil
    )
    await #expect(throws: ExternalSubtitleError.fileTooLarge) {
        _ = try await ExternalSubtitleDiscovery.load(
            oversizedCandidate,
            from: oversizedSource
        )
    }
    #expect(await oversizedSource.openCount == 0)

    let bytes = Data("1\n00:00:00,000 --> 00:00:01,000\nLoaded\n".utf8)
    let source = SubtitleTestSource(bytes: bytes)
    let candidate = ExternalSubtitleCandidate(
        item: subtitleItem("movie.srt", size: Int64(bytes.count)),
        format: .subRip,
        language: nil
    )
    let result = try await ExternalSubtitleDiscovery.load(candidate, from: source)
    #expect(result.cues.map(\.text) == ["Loaded"])
    #expect(source.file.closeCount == 1)
}

private func subtitleItem(_ name: String, size: Int64) -> MediaSourceItem {
    MediaSourceItem(
        name: name,
        path: "/\(name)",
        kind: .file,
        size: size,
        modifiedAt: nil
    )
}

private final class SubtitleTestFile: MediaReadableFile, @unchecked Sendable {
    let identity: MediaFileIdentity
    private let bytes: Data
    private let lock = NSLock()
    private var closes = 0

    var closeCount: Int { lock.withLock { closes } }

    init(bytes: Data) {
        self.bytes = bytes
        self.identity = MediaFileIdentity(
            sourceID: UUID(),
            path: "/movie.srt",
            size: Int64(bytes.count),
            modifiedAt: nil
        )
    }

    func read(at offset: Int64, length: Int) async throws -> Data {
        let start = Int(offset)
        let end = min(start + length, bytes.count)
        guard start >= 0, start < end else { return Data() }
        return bytes.subdata(in: start..<end)
    }

    func close() async {
        lock.withLock { closes += 1 }
    }
}

private actor SubtitleTestSource: MediaSource {
    nonisolated let id = UUID()
    nonisolated let displayName = "Test"
    nonisolated let file: SubtitleTestFile
    private(set) var openCount = 0

    init(bytes: Data) {
        self.file = SubtitleTestFile(bytes: bytes)
    }

    func connect() async throws {}
    func disconnect() async {}
    func list(directory path: String) async throws -> [MediaSourceItem] { [] }

    func open(file path: String) async throws -> any MediaReadableFile {
        openCount += 1
        return file
    }
}
