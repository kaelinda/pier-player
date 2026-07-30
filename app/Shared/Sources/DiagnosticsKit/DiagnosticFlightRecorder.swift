import Foundation

public struct DiagnosticFlightRecorder: Sendable {
    private struct Entry: Sendable {
        let event: DiagnosticEvent
        let encodedByteCount: Int
    }

    public let maximumAge: TimeInterval
    public let maximumEncodedBytes: Int
    public private(set) var encodedByteCount = 0

    private var entries: [Entry] = []
    private var headIndex = 0

    public init(maximumAge: TimeInterval = 120, maximumEncodedBytes: Int = 8 * 1_024 * 1_024) {
        precondition(maximumAge > 0)
        precondition(maximumEncodedBytes > 0)
        self.maximumAge = maximumAge
        self.maximumEncodedBytes = maximumEncodedBytes
    }

    public var events: [DiagnosticEvent] {
        entries[headIndex...].map(\.event)
    }

    public mutating func append(_ event: DiagnosticEvent, encodedByteCount: Int) {
        guard encodedByteCount > 0, encodedByteCount <= maximumEncodedBytes else {
            return
        }

        entries.append(Entry(event: event, encodedByteCount: encodedByteCount))
        self.encodedByteCount += encodedByteCount
        evict(olderThan: event.wallTime.addingTimeInterval(-maximumAge))

        while self.encodedByteCount > maximumEncodedBytes, headIndex < entries.endIndex {
            removeFirst()
        }
    }

    public mutating func evict(olderThan cutoff: Date) {
        while headIndex < entries.endIndex, entries[headIndex].event.wallTime < cutoff {
            removeFirst()
        }
    }

    public func snapshot() -> [DiagnosticEvent] {
        events
    }

    public mutating func removeAll() {
        entries.removeAll(keepingCapacity: true)
        headIndex = 0
        encodedByteCount = 0
    }

    private mutating func removeFirst() {
        let removed = entries[headIndex]
        headIndex += 1
        encodedByteCount -= removed.encodedByteCount
        compactIfNeeded()
    }

    private mutating func compactIfNeeded() {
        guard headIndex >= 1_024, headIndex * 2 >= entries.count else { return }
        entries.removeFirst(headIndex)
        headIndex = 0
    }
}
