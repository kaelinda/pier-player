import Foundation
import Testing
@testable import PlaybackCore

@Test func producerSuspendsAtHighWatermarkAndResumesBelowLowWatermark() async throws {
    let queue = BoundedMediaQueue<Int>(
        limits: BoundedMediaQueueLimits(
            high: MediaQueueWatermark(itemCount: 2, byteCount: 10, duration: 1),
            low: MediaQueueWatermark(itemCount: 1, byteCount: 4, duration: 0.4)
        )
    )
    try await queue.enqueue(1, ownedByteCount: 4, duration: 0.4)
    try await queue.enqueue(2, ownedByteCount: 4, duration: 0.4)

    let completion = QueueCompletionFlag()
    let producer = Task {
        try await queue.enqueue(3, ownedByteCount: 4, duration: 0.4)
        await completion.markCompleted()
    }
    try await Task.sleep(for: .milliseconds(20))
    #expect(await !completion.isCompleted)

    #expect(try await queue.dequeue() == 1)
    try await Task.sleep(for: .milliseconds(20))
    #expect(await !completion.isCompleted)
    #expect(try await queue.dequeue() == 2)
    try await producer.value
    #expect(await completion.isCompleted)

    let snapshot = await queue.snapshot
    #expect(snapshot.itemCount == 1)
    #expect(snapshot.byteCount == 4)
    #expect(snapshot.duration == 0.4)
}

@Test func cancellationClearAndCloseWakeWaitersExactlyOnce() async throws {
    let limits = BoundedMediaQueueLimits(
        high: MediaQueueWatermark(itemCount: 1, byteCount: 4, duration: 1),
        low: MediaQueueWatermark(itemCount: 0, byteCount: 0, duration: 0)
    )
    let queue = BoundedMediaQueue<Int>(limits: limits)
    try await queue.enqueue(1, ownedByteCount: 4, duration: 0.5)

    let cancelledProducer = Task {
        try await queue.enqueue(2, ownedByteCount: 4, duration: 0.5)
    }
    try await Task.sleep(for: .milliseconds(10))
    cancelledProducer.cancel()
    await #expect(throws: CancellationError.self) {
        try await cancelledProducer.value
    }

    let waitingConsumerQueue = BoundedMediaQueue<Int>(limits: limits)
    let waitingConsumer = Task { try await waitingConsumerQueue.dequeue() }
    try await Task.sleep(for: .milliseconds(10))
    await waitingConsumerQueue.clear()
    await #expect(throws: CancellationError.self) {
        _ = try await waitingConsumer.value
    }

    await queue.close()
    await #expect(throws: BoundedMediaQueueError.closed) {
        try await queue.enqueue(3, ownedByteCount: 1, duration: 0.1)
    }
    #expect(try await queue.dequeue() == nil)
}

private actor QueueCompletionFlag {
    private(set) var isCompleted = false
    func markCompleted() { isCompleted = true }
}
