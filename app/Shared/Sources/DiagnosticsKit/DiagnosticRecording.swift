import Foundation

public protocol DiagnosticRecording: Sendable {
    func record(_ event: DiagnosticEvent)
}

public struct NoopDiagnosticRecorder: DiagnosticRecording {
    public init() {}

    public func record(_ event: DiagnosticEvent) {}
}

public struct DiagnosticDropCounts: Equatable, Sendable {
    public var essential: UInt64
    public var detailed: UInt64

    public init(essential: UInt64 = 0, detailed: UInt64 = 0) {
        self.essential = essential
        self.detailed = detailed
    }
}

public final class DiagnosticEmitter: DiagnosticRecording, @unchecked Sendable {
    public let essentialEvents: AsyncStream<DiagnosticEvent>
    public let detailedEvents: AsyncStream<DiagnosticEvent>

    private let lock = NSLock()
    private let essentialContinuation: AsyncStream<DiagnosticEvent>.Continuation
    private let detailedContinuation: AsyncStream<DiagnosticEvent>.Continuation
    private var nextSequence: UInt64 = 0
    private var dropped = DiagnosticDropCounts()

    public init(essentialCapacity: Int = 512, detailedCapacity: Int = 4_096) {
        precondition(essentialCapacity > 0)
        precondition(detailedCapacity > 0)

        var capturedEssential: AsyncStream<DiagnosticEvent>.Continuation?
        essentialEvents = AsyncStream(bufferingPolicy: .bufferingNewest(essentialCapacity)) {
            capturedEssential = $0
        }
        guard let capturedEssential else {
            preconditionFailure("Failed to create the essential diagnostic stream")
        }
        essentialContinuation = capturedEssential

        var capturedDetailed: AsyncStream<DiagnosticEvent>.Continuation?
        detailedEvents = AsyncStream(bufferingPolicy: .bufferingNewest(detailedCapacity)) {
            capturedDetailed = $0
        }
        guard let capturedDetailed else {
            preconditionFailure("Failed to create the detailed diagnostic stream")
        }
        detailedContinuation = capturedDetailed
    }

    public func record(_ event: DiagnosticEvent) {
        lock.lock()
        defer { lock.unlock() }

        nextSequence &+= 1
        let sequenced = event.withSequence(nextSequence)
        let result: AsyncStream<DiagnosticEvent>.Continuation.YieldResult
        switch event.persistence {
        case .essential:
            result = essentialContinuation.yield(sequenced)
        case .detailed:
            result = detailedContinuation.yield(sequenced)
        }

        guard case .dropped = result else { return }
        switch event.persistence {
        case .essential:
            dropped.essential &+= 1
        case .detailed:
            dropped.detailed &+= 1
        }
    }

    public func takeDroppedCounts() -> DiagnosticDropCounts {
        lock.lock()
        defer { lock.unlock() }
        let result = dropped
        dropped = DiagnosticDropCounts()
        return result
    }

    func assignSequence(to event: DiagnosticEvent) -> DiagnosticEvent {
        lock.lock()
        defer { lock.unlock() }
        nextSequence &+= 1
        return event.withSequence(nextSequence)
    }

    public func finish() {
        essentialContinuation.finish()
        detailedContinuation.finish()
    }
}
