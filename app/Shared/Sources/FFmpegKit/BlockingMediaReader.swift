import Foundation
import StreamIOKit

public enum BlockingMediaReaderError: Error, Equatable, Sendable {
    case timedOut
    case closed
}

public final class BlockingMediaReader: FFmpegByteSource, @unchecked Sendable {
    private struct ReadKey: Hashable {
        let offset: Int64
        let length: Int
    }

    private final class PendingRead: @unchecked Sendable {
        private let condition = NSCondition()
        private var result: Result<Data, Error>?
        private var task: Task<Void, Never>?

        func install(task: Task<Void, Never>) {
            condition.withLock {
                self.task = task
            }
        }

        func complete(_ result: Result<Data, Error>) {
            condition.withLock {
                guard self.result == nil else { return }
                self.result = result
                condition.broadcast()
            }
        }

        func cancel(with error: BlockingMediaReaderError) {
            condition.withLock {
                guard result == nil else { return }
                result = .failure(error)
                task?.cancel()
                condition.broadcast()
            }
        }

        func wait(timeout: TimeInterval) throws -> Data {
            let deadline = Date(timeIntervalSinceNow: timeout)
            return try condition.withLock {
                while result == nil && condition.wait(until: deadline) {}
                guard let result else {
                    throw BlockingMediaReaderError.timedOut
                }
                return try result.get()
            }
        }
    }

    public let size: Int64

    private let reader: CachedMediaReader
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var pendingReads: [ReadKey: PendingRead] = [:]
    private var isClosed = false
    private var closeTask: Task<Void, Never>?

    public init(reader: CachedMediaReader, timeout: TimeInterval = 10) {
        precondition(timeout.isFinite && timeout > 0)
        self.reader = reader
        self.timeout = timeout
        self.size = reader.identity.size
    }

    public func read(at offset: Int64, length: Int) throws -> Data {
        let key = ReadKey(offset: offset, length: length)
        let operation = try lock.withLock { () throws -> PendingRead in
            guard !isClosed else { throw BlockingMediaReaderError.closed }
            if let pending = pendingReads[key] {
                return pending
            }

            let pending = PendingRead()
            pendingReads[key] = pending
            let reader = self.reader
            let task = Task.detached { [weak self, pending] in
                do {
                    let data = try await reader.read(at: offset, length: length)
                    pending.complete(.success(data))
                } catch {
                    pending.complete(.failure(error))
                }
                self?.remove(pending, for: key)
            }
            pending.install(task: task)
            return pending
        }

        do {
            return try operation.wait(timeout: timeout)
        } catch BlockingMediaReaderError.timedOut {
            operation.cancel(with: .timedOut)
            remove(operation, for: key)
            throw BlockingMediaReaderError.timedOut
        }
    }

    public func close() {
        let operations: [PendingRead] = lock.withLock {
            guard !isClosed else { return [] }
            isClosed = true
            let operations = Array(pendingReads.values)
            pendingReads.removeAll()
            closeTask = Task { [reader] in
                await reader.close()
            }
            return operations
        }
        for operation in operations {
            operation.cancel(with: .closed)
        }
    }

    public func closeAndWait() async {
        close()
        let task = lock.withLock { closeTask }
        await task?.value
    }

    private func remove(_ operation: PendingRead, for key: ReadKey) {
        lock.withLock {
            guard pendingReads[key] === operation else { return }
            pendingReads[key] = nil
        }
    }
}
