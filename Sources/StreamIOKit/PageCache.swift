import Foundation

public actor PageCache {
    private struct Entry: Sendable {
        let data: Data
        var lastAccess: UInt64
    }

    public let pageSize: Int
    public let capacityBytes: Int
    public private(set) var residentByteCount = 0

    private var entries: [Int64: Entry] = [:]
    private var accessCounter: UInt64 = 0

    public init(pageSize: Int, capacityBytes: Int) throws {
        guard pageSize > 0, capacityBytes >= pageSize else {
            throw PageCacheError.invalidConfiguration(
                pageSize: pageSize,
                capacityBytes: capacityBytes
            )
        }
        self.pageSize = pageSize
        self.capacityBytes = capacityBytes
    }

    public func data(at offset: Int64, length: Int) throws -> Data? {
        let range = try ByteRange(offset: offset, length: length)
        let pageSize64 = Int64(pageSize)
        var cursor = range.offset
        var slices: [(offset: Int64, range: Range<Int>)] = []

        while cursor < range.endOffset {
            let pageOffset = (cursor / pageSize64) * pageSize64
            let index = Int(cursor - pageOffset)
            let remaining = Int(range.endOffset - cursor)
            let count = min(pageSize - index, remaining)

            guard let entry = entries[pageOffset], entry.data.count >= index + count else {
                return nil
            }
            slices.append((pageOffset, index..<(index + count)))
            cursor += Int64(count)
        }

        var result = Data(capacity: length)
        for slice in slices {
            guard var entry = entries[slice.offset] else { return nil }
            result.append(entry.data.subdata(in: slice.range))
            accessCounter &+= 1
            entry.lastAccess = accessCounter
            entries[slice.offset] = entry
        }
        return result
    }

    public func insert(page data: Data, at alignedOffset: Int64) throws {
        guard alignedOffset >= 0, alignedOffset % Int64(pageSize) == 0 else {
            throw PageCacheError.unalignedPageOffset(alignedOffset)
        }
        guard !data.isEmpty, data.count <= pageSize else {
            throw PageCacheError.invalidPageSize(data.count)
        }

        if let previous = entries.removeValue(forKey: alignedOffset) {
            residentByteCount -= previous.data.count
        }

        while residentByteCount + data.count > capacityBytes {
            guard let victim = entries.min(by: { lhs, rhs in
                if lhs.value.lastAccess == rhs.value.lastAccess {
                    return lhs.key < rhs.key
                }
                return lhs.value.lastAccess < rhs.value.lastAccess
            }) else {
                break
            }
            entries.removeValue(forKey: victim.key)
            residentByteCount -= victim.value.data.count
        }

        accessCounter &+= 1
        entries[alignedOffset] = Entry(data: data, lastAccess: accessCounter)
        residentByteCount += data.count
    }

    public func removeAll() {
        entries.removeAll(keepingCapacity: true)
        residentByteCount = 0
    }
}
