import Foundation
import MediaSourceKit

public actor CachedMediaReader {
    public nonisolated let identity: MediaFileIdentity
    public private(set) var metrics = StreamMetrics()

    private let file: any MediaReadableFile
    private let cache: PageCache
    private let pageSize: Int
    private var inFlightPages: [Int64: Task<Data, Error>] = [:]

    public init(
        file: any MediaReadableFile,
        pageSize: Int,
        capacityBytes: Int
    ) throws {
        self.file = file
        self.identity = file.identity
        self.pageSize = pageSize
        self.cache = try PageCache(pageSize: pageSize, capacityBytes: capacityBytes)
    }

    public func read(at offset: Int64, length: Int) async throws -> Data {
        guard offset >= 0, length > 0 else {
            throw MediaSourceError.invalidRead(offset: offset, length: length)
        }
        guard offset < identity.size else { return Data() }

        let available = identity.size - offset
        let actualLength = Int(min(Int64(length), available))

        if let cached = try await cache.data(at: offset, length: actualLength) {
            metrics.cacheHits &+= 1
            return cached
        }
        metrics.cacheMisses &+= 1

        let pageSize64 = Int64(pageSize)
        var pageOffset = (offset / pageSize64) * pageSize64
        let endOffset = offset + Int64(actualLength)
        while pageOffset < endOffset {
            try await loadPage(at: pageOffset)
            pageOffset += pageSize64
        }

        guard let assembled = try await cache.data(at: offset, length: actualLength) else {
            throw StreamIOError.cacheAssemblyFailed(offset: offset, length: actualLength)
        }
        return assembled
    }

    public func removeAllCachedData() async {
        await cache.removeAll()
    }

    public func close() async {
        for task in inFlightPages.values {
            task.cancel()
        }
        inFlightPages.removeAll()
        await cache.removeAll()
        await file.close()
    }

    private func loadPage(at pageOffset: Int64) async throws {
        let remaining = identity.size - pageOffset
        let expectedLength = Int(min(Int64(pageSize), remaining))
        guard expectedLength > 0 else { return }

        if try await cache.data(at: pageOffset, length: expectedLength) != nil {
            return
        }

        let task: Task<Data, Error>
        let ownsTask: Bool
        if let existing = inFlightPages[pageOffset] {
            task = existing
            ownsTask = false
        } else {
            let upstream = file
            task = Task {
                try await upstream.read(at: pageOffset, length: expectedLength)
            }
            inFlightPages[pageOffset] = task
            metrics.upstreamReads &+= 1
            ownsTask = true
        }

        do {
            let data = try await task.value
            guard data.count == expectedLength else {
                throw StreamIOError.unexpectedShortRead(
                    offset: pageOffset,
                    expected: expectedLength,
                    actual: data.count
                )
            }
            try await cache.insert(page: data, at: pageOffset)
            if ownsTask {
                metrics.upstreamBytes &+= UInt64(data.count)
                inFlightPages[pageOffset] = nil
            }
        } catch {
            if ownsTask {
                inFlightPages[pageOffset] = nil
            }
            throw error
        }
    }
}
