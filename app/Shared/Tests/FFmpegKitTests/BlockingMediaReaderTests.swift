import Foundation
import MediaSourceKit
import StreamIOKit
import Testing
@testable import FFmpegKit

@Test func blockingReaderCoalescesSamePositionAndRunsUpstreamOffMainThread() async throws {
    let file = BlockingTestFile(
        bytes: Data(0..<64),
        delay: .milliseconds(30)
    )
    let cached = try CachedMediaReader(file: file, pageSize: 16, capacityBytes: 64)
    let blocking = BlockingMediaReader(reader: cached, timeout: 1)

    async let first = Task.detached { try blocking.read(at: 4, length: 8) }.value
    async let second = Task.detached { try blocking.read(at: 4, length: 8) }.value
    let results = try await (first, second)

    #expect(results.0 == Data(4..<12))
    #expect(results.1 == Data(4..<12))
    #expect(await file.readCount == 1)
    #expect(await file.observedMainThread == false)
}

@Test func blockingReaderTimesOutAndCloseWakesBlockedReads() async throws {
    let timeoutFile = BlockingTestFile(
        bytes: Data(0..<64),
        delay: .milliseconds(100)
    )
    let timeoutCache = try CachedMediaReader(
        file: timeoutFile,
        pageSize: 16,
        capacityBytes: 64
    )
    let timeoutReader = BlockingMediaReader(reader: timeoutCache, timeout: 0.005)
    #expect(throws: BlockingMediaReaderError.timedOut) {
        _ = try timeoutReader.read(at: 0, length: 8)
    }

    let closeFile = BlockingTestFile(
        bytes: Data(0..<64),
        delay: .seconds(5)
    )
    let closeCache = try CachedMediaReader(
        file: closeFile,
        pageSize: 16,
        capacityBytes: 64
    )
    let closeReader = BlockingMediaReader(reader: closeCache, timeout: 10)
    let blockedRead = Task.detached { try closeReader.read(at: 0, length: 8) }
    try await Task.sleep(for: .milliseconds(20))
    closeReader.close()

    await #expect(throws: BlockingMediaReaderError.closed) {
        _ = try await blockedRead.value
    }
}

private actor BlockingTestFile: MediaReadableFile {
    nonisolated let identity: MediaFileIdentity
    private let bytes: Data
    private let delay: Duration
    private(set) var readCount = 0
    private(set) var observedMainThread = false

    init(bytes: Data, delay: Duration) {
        self.bytes = bytes
        self.delay = delay
        self.identity = MediaFileIdentity(
            sourceID: UUID(),
            path: "fixture.mkv",
            size: Int64(bytes.count),
            modifiedAt: nil
        )
    }

    func read(at offset: Int64, length: Int) async throws -> Data {
        readCount += 1
        observedMainThread = observedMainThread || Thread.isMainThread
        try await Task.sleep(for: delay)
        let start = Int(offset)
        let end = min(start + length, bytes.count)
        return dataSlice(start: start, end: end)
    }

    func close() async {}

    private func dataSlice(start: Int, end: Int) -> Data {
        guard start >= 0, start < end else { return Data() }
        return bytes.subdata(in: start..<end)
    }
}
