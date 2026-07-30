import Foundation
import MediaSourceKit

enum ProgressiveMediaLoaderError: Error, Equatable, Sendable {
    case invalidMaximumReadLength(Int)
    case invalidRange(offset: Int64, length: Int64?)
    case unexpectedEndOfFile(offset: Int64)
    case closed
}

actor ProgressiveMediaLoader {
    nonisolated let identity: MediaFileIdentity

    private let file: any MediaReadableFile
    private let maximumReadLength: Int
    private var isClosed = false

    init(
        file: any MediaReadableFile,
        maximumReadLength: Int = 512 * 1024
    ) throws {
        guard maximumReadLength > 0 else {
            throw ProgressiveMediaLoaderError.invalidMaximumReadLength(maximumReadLength)
        }

        self.file = file
        self.identity = file.identity
        self.maximumReadLength = maximumReadLength
    }

    func load(
        offset: Int64,
        length: Int64?,
        consume: @Sendable (Data) async throws -> Void
    ) async throws {
        guard !isClosed else {
            throw ProgressiveMediaLoaderError.closed
        }
        guard offset >= 0 else {
            throw ProgressiveMediaLoaderError.invalidRange(offset: offset, length: length)
        }
        if let length, length <= 0 {
            throw ProgressiveMediaLoaderError.invalidRange(offset: offset, length: length)
        }

        let requestedEnd = try endOffset(start: offset, length: length)
        guard offset < identity.size else { return }

        let end = min(identity.size, requestedEnd)
        var cursor = offset

        while cursor < end {
            try Task.checkCancellation()
            guard !isClosed else {
                throw ProgressiveMediaLoaderError.closed
            }

            let readLength = Int(min(Int64(maximumReadLength), end - cursor))
            let data = try await file.read(at: cursor, length: readLength)

            try Task.checkCancellation()
            guard !isClosed else {
                throw ProgressiveMediaLoaderError.closed
            }
            guard !data.isEmpty else {
                throw ProgressiveMediaLoaderError.unexpectedEndOfFile(offset: cursor)
            }

            let acceptedData = Data(data.prefix(readLength))
            try await consume(acceptedData)
            cursor += Int64(acceptedData.count)
        }
    }

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        await file.close()
    }

    private func endOffset(start: Int64, length: Int64?) throws -> Int64 {
        guard let length else { return identity.size }
        let (end, overflowed) = start.addingReportingOverflow(length)
        guard !overflowed else {
            throw ProgressiveMediaLoaderError.invalidRange(offset: start, length: length)
        }
        return end
    }
}
