public struct ByteRange: Equatable, Sendable {
    public let offset: Int64
    public let length: Int
    public let endOffset: Int64

    public init(offset: Int64, length: Int) throws {
        guard offset >= 0, length > 0 else {
            throw PageCacheError.invalidRange(offset: offset, length: length)
        }
        let (endOffset, overflow) = offset.addingReportingOverflow(Int64(length))
        guard !overflow else {
            throw PageCacheError.invalidRange(offset: offset, length: length)
        }
        self.offset = offset
        self.length = length
        self.endOffset = endOffset
    }
}

public enum PageCacheError: Error, Equatable, Sendable {
    case invalidConfiguration(pageSize: Int, capacityBytes: Int)
    case invalidRange(offset: Int64, length: Int)
    case unalignedPageOffset(Int64)
    case invalidPageSize(Int)
}
