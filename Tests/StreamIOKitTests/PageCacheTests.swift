import Foundation
import Testing
@testable import StreamIOKit

@Test func cachedReadCanSpanAdjacentPages() async throws {
    let cache = try PageCache(pageSize: 4, capacityBytes: 8)
    try await cache.insert(page: Data([0, 1, 2, 3]), at: 0)
    try await cache.insert(page: Data([4, 5, 6, 7]), at: 4)

    let value = try await cache.data(at: 2, length: 4)

    #expect(value == Data([2, 3, 4, 5]))
}

@Test func cachedReadMissesWhenAnyRequiredPageIsAbsent() async throws {
    let cache = try PageCache(pageSize: 4, capacityBytes: 8)
    try await cache.insert(page: Data([0, 1, 2, 3]), at: 0)

    let value = try await cache.data(at: 2, length: 4)

    #expect(value == nil)
}

@Test func leastRecentlyUsedPageIsEvictedFirst() async throws {
    let cache = try PageCache(pageSize: 4, capacityBytes: 8)
    try await cache.insert(page: Data([0, 1, 2, 3]), at: 0)
    try await cache.insert(page: Data([4, 5, 6, 7]), at: 4)
    _ = try await cache.data(at: 0, length: 1)

    try await cache.insert(page: Data([8, 9, 10, 11]), at: 8)

    #expect(try await cache.data(at: 0, length: 1) == Data([0]))
    #expect(try await cache.data(at: 4, length: 1) == nil)
    #expect(try await cache.data(at: 8, length: 1) == Data([8]))
}

@Test func replacingPageDoesNotDoubleCountResidentBytes() async throws {
    let cache = try PageCache(pageSize: 4, capacityBytes: 8)
    try await cache.insert(page: Data([0, 1, 2, 3]), at: 0)
    try await cache.insert(page: Data([9, 8]), at: 0)

    #expect(await cache.residentByteCount == 2)
    #expect(try await cache.data(at: 0, length: 2) == Data([9, 8]))
}

@Test func cacheRejectsInvalidConfigurationAndRanges() async throws {
    #expect(throws: PageCacheError.self) {
        try PageCache(pageSize: 4, capacityBytes: 3)
    }

    let cache = try PageCache(pageSize: 4, capacityBytes: 8)

    await #expect(throws: PageCacheError.self) {
        try await cache.insert(page: Data([1]), at: 1)
    }
    await #expect(throws: PageCacheError.self) {
        try await cache.insert(page: Data(repeating: 1, count: 5), at: 0)
    }
    await #expect(throws: PageCacheError.self) {
        try await cache.data(at: -1, length: 1)
    }
    await #expect(throws: PageCacheError.self) {
        try await cache.data(at: 0, length: 0)
    }
}
