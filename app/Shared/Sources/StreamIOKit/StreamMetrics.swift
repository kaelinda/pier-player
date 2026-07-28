public struct StreamMetrics: Equatable, Sendable {
    public internal(set) var cacheHits: UInt64 = 0
    public internal(set) var cacheMisses: UInt64 = 0
    public internal(set) var upstreamReads: UInt64 = 0
    public internal(set) var upstreamBytes: UInt64 = 0

    public init() {}

    public var cacheHitRatio: Double {
        let total = cacheHits + cacheMisses
        guard total > 0 else { return 0 }
        return Double(cacheHits) / Double(total)
    }
}

public enum StreamIOError: Error, Equatable, Sendable {
    case unexpectedShortRead(offset: Int64, expected: Int, actual: Int)
    case cacheAssemblyFailed(offset: Int64, length: Int)
}
