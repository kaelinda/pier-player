import Foundation
import MediaSourceKit
import Testing
@testable import StreamIOKit

private actor CountingReadableFile: MediaReadableFile {
    nonisolated let identity: MediaFileIdentity

    private let bytes: Data
    private let delay: Duration
    private var readsByOffset: [Int64: Int] = [:]

    init(bytes: Data, delay: Duration = .zero) {
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
        readsByOffset[offset, default: 0] += 1
        if delay > .zero {
            try await Task.sleep(for: delay)
        }
        guard offset < Int64(bytes.count) else { return Data() }
        let start = Int(offset)
        let end = min(start + length, bytes.count)
        return bytes.subdata(in: start..<end)
    }

    func close() async {}

    func readCount(at offset: Int64) -> Int {
        readsByOffset[offset, default: 0]
    }

    func totalReadCount() -> Int {
        readsByOffset.values.reduce(0, +)
    }
}

private actor ControlledReadableFile: MediaReadableFile {
    nonisolated let identity: MediaFileIdentity

    private let bytes: Data
    private var continuations: [Int: CheckedContinuation<Data, Never>] = [:]
    private var reads = 0

    init(bytes: Data) {
        self.bytes = bytes
        self.identity = MediaFileIdentity(
            sourceID: UUID(),
            path: "controlled.mkv",
            size: Int64(bytes.count),
            modifiedAt: nil
        )
    }

    func read(at offset: Int64, length: Int) async throws -> Data {
        reads += 1
        let readID = reads
        return await withCheckedContinuation { continuation in
            continuations[readID] = continuation
        }
    }

    func close() async {
        for readID in continuations.keys.sorted() {
            release(readID)
        }
    }

    func readCount() -> Int {
        reads
    }

    func release(_ readID: Int) {
        continuations.removeValue(forKey: readID)?.resume(returning: bytes.prefix(4))
    }
}

@Test func concurrentRequestsForSamePageShareOneUpstreamRead() async throws {
    let file = CountingReadableFile(
        bytes: Data(0..<16),
        delay: .milliseconds(30)
    )
    let reader = try CachedMediaReader(file: file, pageSize: 4, capacityBytes: 16)

    async let first = reader.read(at: 0, length: 4)
    async let second = reader.read(at: 1, length: 2)
    let values = try await (first, second)

    #expect(values.0 == Data([0, 1, 2, 3]))
    #expect(values.1 == Data([1, 2]))
    #expect(await file.readCount(at: 0) == 1)
    #expect(await reader.metrics.upstreamBytes == 4)
}

@Test func cacheHitAvoidsAdditionalUpstreamRead() async throws {
    let file = CountingReadableFile(bytes: Data(0..<16))
    let reader = try CachedMediaReader(file: file, pageSize: 4, capacityBytes: 16)

    _ = try await reader.read(at: 0, length: 4)
    let cached = try await reader.read(at: 1, length: 2)
    let metrics = await reader.metrics

    #expect(cached == Data([1, 2]))
    #expect(await file.readCount(at: 0) == 1)
    #expect(metrics.cacheHits == 1)
    #expect(metrics.upstreamReads == 1)
}

@Test func crossPageReadIsAssembledInOrder() async throws {
    let file = CountingReadableFile(bytes: Data(0..<16))
    let reader = try CachedMediaReader(file: file, pageSize: 4, capacityBytes: 16)

    let value = try await reader.read(at: 2, length: 5)

    #expect(value == Data([2, 3, 4, 5, 6]))
    #expect(await file.readCount(at: 0) == 1)
    #expect(await file.readCount(at: 4) == 1)
}

@Test func readAtEndOfFileReturnsAvailableBytes() async throws {
    let file = CountingReadableFile(bytes: Data(0..<6))
    let reader = try CachedMediaReader(file: file, pageSize: 4, capacityBytes: 8)

    let value = try await reader.read(at: 4, length: 4)
    let eof = try await reader.read(at: 6, length: 4)

    #expect(value == Data([4, 5]))
    #expect(eof.isEmpty)
}

@Test func invalidReadDoesNotReachUpstream() async throws {
    let file = CountingReadableFile(bytes: Data(0..<8))
    let reader = try CachedMediaReader(file: file, pageSize: 4, capacityBytes: 8)

    await #expect(throws: MediaSourceError.self) {
        try await reader.read(at: -1, length: 1)
    }
    await #expect(throws: MediaSourceError.self) {
        try await reader.read(at: 0, length: 0)
    }

    #expect(await file.totalReadCount() == 0)
}

@Test func clearingCacheForcesNextReadUpstream() async throws {
    let file = CountingReadableFile(bytes: Data(0..<8))
    let reader = try CachedMediaReader(file: file, pageSize: 4, capacityBytes: 8)

    _ = try await reader.read(at: 0, length: 4)
    await reader.removeAllCachedData()
    _ = try await reader.read(at: 0, length: 4)

    #expect(await file.readCount(at: 0) == 2)
}

@Test func interruptedLateReadDoesNotRemoveNewSamePageTask() async throws {
    let file = ControlledReadableFile(bytes: Data(0..<8))
    let reader = try CachedMediaReader(file: file, pageSize: 4, capacityBytes: 8)

    let first = Task { try await reader.read(at: 0, length: 4) }
    try await waitForReadCount(1, file: file)
    await reader.interruptPendingReads()

    let second = Task { try await reader.read(at: 0, length: 4) }
    try await waitForReadCount(2, file: file)
    await file.release(1)
    await #expect(throws: CancellationError.self) {
        try await first.value
    }

    let third = Task { try await reader.read(at: 1, length: 2) }
    try await Task.sleep(for: .milliseconds(30))
    let readCount = await file.readCount()

    #expect(readCount == 2)
    await file.release(2)
    if readCount > 2 {
        await file.release(3)
    }
    #expect(try await second.value == Data([0, 1, 2, 3]))
    #expect(try await third.value == Data([1, 2]))
}

private func waitForReadCount(
    _ expectedCount: Int,
    file: ControlledReadableFile
) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 1
    while ProcessInfo.processInfo.systemUptime < deadline {
        if await file.readCount() >= expectedCount { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("timed out waiting for upstream read count \(expectedCount)")
}
