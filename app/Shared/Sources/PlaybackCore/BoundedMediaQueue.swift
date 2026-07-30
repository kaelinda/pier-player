import Foundation

public struct MediaQueueWatermark: Equatable, Sendable {
    public let itemCount: Int
    public let byteCount: Int
    public let duration: TimeInterval

    public init(itemCount: Int, byteCount: Int, duration: TimeInterval) {
        self.itemCount = itemCount
        self.byteCount = byteCount
        self.duration = duration
    }
}

public struct BoundedMediaQueueLimits: Equatable, Sendable {
    public let high: MediaQueueWatermark
    public let low: MediaQueueWatermark

    public init(high: MediaQueueWatermark, low: MediaQueueWatermark) {
        precondition(high.itemCount > 0 && high.byteCount > 0 && high.duration > 0)
        precondition(low.itemCount >= 0 && low.itemCount <= high.itemCount)
        precondition(low.byteCount >= 0 && low.byteCount <= high.byteCount)
        precondition(low.duration >= 0 && low.duration <= high.duration)
        self.high = high
        self.low = low
    }
}

public struct MediaQueueSnapshot: Equatable, Sendable {
    public let itemCount: Int
    public let byteCount: Int
    public let duration: TimeInterval

    public init(itemCount: Int, byteCount: Int, duration: TimeInterval) {
        self.itemCount = itemCount
        self.byteCount = byteCount
        self.duration = duration
    }

    public static let empty = MediaQueueSnapshot(itemCount: 0, byteCount: 0, duration: 0)
}

public enum BoundedMediaQueueError: Error, Equatable, Sendable {
    case closed
    case invalidMetrics
    case itemExceedsLimits
}

public actor BoundedMediaQueue<Element: Sendable> {
    private struct Entry: Sendable {
        let element: Element
        let ownedByteCount: Int
        let duration: TimeInterval
    }

    public let limits: BoundedMediaQueueLimits
    public private(set) var snapshot: MediaQueueSnapshot = .empty

    private var entries: [Entry] = []
    private var producerWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var consumerWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var isClosed = false

    public init(limits: BoundedMediaQueueLimits) {
        self.limits = limits
    }

    public func enqueue(
        _ element: Element,
        ownedByteCount: Int,
        duration: TimeInterval
    ) async throws {
        guard ownedByteCount >= 0, duration.isFinite, duration >= 0 else {
            throw BoundedMediaQueueError.invalidMetrics
        }
        guard ownedByteCount <= limits.high.byteCount,
              duration <= limits.high.duration else {
            throw BoundedMediaQueueError.itemExceedsLimits
        }

        while wouldExceedHighWatermark(ownedByteCount: ownedByteCount, duration: duration) {
            guard !isClosed else { throw BoundedMediaQueueError.closed }
            try await waitForProducerSpace()
        }
        guard !isClosed else { throw BoundedMediaQueueError.closed }

        entries.append(
            Entry(
                element: element,
                ownedByteCount: ownedByteCount,
                duration: duration
            )
        )
        snapshot = MediaQueueSnapshot(
            itemCount: snapshot.itemCount + 1,
            byteCount: snapshot.byteCount + ownedByteCount,
            duration: snapshot.duration + duration
        )
        resumeOneConsumer()
    }

    public func dequeue() async throws -> Element? {
        while entries.isEmpty {
            if isClosed { return nil }
            try await waitForElement()
        }

        let entry = entries.removeFirst()
        snapshot = MediaQueueSnapshot(
            itemCount: snapshot.itemCount - 1,
            byteCount: snapshot.byteCount - entry.ownedByteCount,
            duration: max(0, snapshot.duration - entry.duration)
        )
        resumeProducersIfBelowLowWatermark()
        return entry.element
    }

    public func clear() {
        entries.removeAll(keepingCapacity: true)
        snapshot = .empty
        cancelAllWaiters()
    }

    public func close() {
        guard !isClosed else { return }
        isClosed = true
        entries.removeAll(keepingCapacity: false)
        snapshot = .empty
        cancelAllWaiters()
    }

    public func finish() {
        guard !isClosed else { return }
        isClosed = true
        let producers = Array(producerWaiters.values)
        let consumers = Array(consumerWaiters.values)
        producerWaiters.removeAll()
        consumerWaiters.removeAll()
        for continuation in producers {
            continuation.resume(throwing: BoundedMediaQueueError.closed)
        }
        for continuation in consumers {
            continuation.resume()
        }
    }

    private func wouldExceedHighWatermark(
        ownedByteCount: Int,
        duration: TimeInterval
    ) -> Bool {
        snapshot.itemCount + 1 > limits.high.itemCount ||
            snapshot.byteCount + ownedByteCount > limits.high.byteCount ||
            snapshot.duration + duration > limits.high.duration
    }

    private var isBelowLowWatermark: Bool {
        below(snapshot.itemCount, threshold: limits.low.itemCount) &&
            below(snapshot.byteCount, threshold: limits.low.byteCount) &&
            below(snapshot.duration, threshold: limits.low.duration)
    }

    private func below<T: Comparable & AdditiveArithmetic>(
        _ value: T,
        threshold: T
    ) -> Bool {
        threshold == .zero ? value == .zero : value < threshold
    }

    private func waitForProducerSpace() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                producerWaiters[id] = continuation
            }
        } onCancel: {
            Task { await self.cancelProducerWaiter(id) }
        }
    }

    private func waitForElement() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                consumerWaiters[id] = continuation
            }
        } onCancel: {
            Task { await self.cancelConsumerWaiter(id) }
        }
    }

    private func cancelProducerWaiter(_ id: UUID) {
        guard let continuation = producerWaiters.removeValue(forKey: id) else { return }
        continuation.resume(throwing: CancellationError())
    }

    private func cancelConsumerWaiter(_ id: UUID) {
        guard let continuation = consumerWaiters.removeValue(forKey: id) else { return }
        continuation.resume(throwing: CancellationError())
    }

    private func resumeProducersIfBelowLowWatermark() {
        guard isBelowLowWatermark else { return }
        let continuations = Array(producerWaiters.values)
        producerWaiters.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    private func resumeOneConsumer() {
        guard let id = consumerWaiters.keys.first,
              let continuation = consumerWaiters.removeValue(forKey: id) else {
            return
        }
        continuation.resume()
    }

    private func cancelAllWaiters() {
        let producers = Array(producerWaiters.values)
        let consumers = Array(consumerWaiters.values)
        producerWaiters.removeAll()
        consumerWaiters.removeAll()
        for continuation in producers + consumers {
            continuation.resume(throwing: CancellationError())
        }
    }
}
