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

    public init(maximumAge: TimeInterval = 120, maximumEncodedBytes: Int = 8 * 1_024 * 1_024) {
        precondition(maximumAge > 0)
        precondition(maximumEncodedBytes > 0)
        self.maximumAge = maximumAge
        self.maximumEncodedBytes = maximumEncodedBytes
    }

    public var events: [DiagnosticEvent] {
        entries.map(\.event)
    }

    public mutating func append(_ event: DiagnosticEvent, encodedByteCount: Int) {
        guard encodedByteCount > 0, encodedByteCount <= maximumEncodedBytes else {
            return
        }

        entries.append(Entry(event: event, encodedByteCount: encodedByteCount))
        self.encodedByteCount += encodedByteCount
        evict(olderThan: event.wallTime.addingTimeInterval(-maximumAge))

        while self.encodedByteCount > maximumEncodedBytes, !entries.isEmpty {
            removeFirst()
        }
    }

    public mutating func evict(olderThan cutoff: Date) {
        while let first = entries.first, first.event.wallTime < cutoff {
            removeFirst()
        }
    }

    public func snapshot() -> [DiagnosticEvent] {
        events
    }

    public mutating func removeAll() {
        entries.removeAll(keepingCapacity: true)
        encodedByteCount = 0
    }

    private mutating func removeFirst() {
        let removed = entries.removeFirst()
        encodedByteCount -= removed.encodedByteCount
    }
}
