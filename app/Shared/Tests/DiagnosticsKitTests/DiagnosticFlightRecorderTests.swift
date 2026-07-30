import Foundation
import Testing
@testable import DiagnosticsKit

@Test func flightRecorderEvictsByEncodedBytes() {
    var recorder = DiagnosticFlightRecorder(
        maximumAge: 120,
        maximumEncodedBytes: 100
    )
    let first = event(at: 1)
    let second = event(at: 2)

    recorder.append(first, encodedByteCount: 60)
    recorder.append(second, encodedByteCount: 60)

    #expect(recorder.events == [second])
    #expect(recorder.encodedByteCount == 60)
}

@Test func flightRecorderEvictsByAge() {
    var recorder = DiagnosticFlightRecorder(
        maximumAge: 120,
        maximumEncodedBytes: 1_000
    )
    let first = event(at: 1)
    let second = event(at: 122)

    recorder.append(first, encodedByteCount: 50)
    recorder.append(second, encodedByteCount: 50)

    #expect(recorder.events == [second])
    #expect(recorder.snapshot() == [second])
}

@Test func oversizedEventIsNotRetained() {
    var recorder = DiagnosticFlightRecorder(
        maximumAge: 120,
        maximumEncodedBytes: 10
    )

    recorder.append(event(at: 1), encodedByteCount: 11)

    #expect(recorder.events.isEmpty)
    #expect(recorder.encodedByteCount == 0)
}

private func event(at seconds: TimeInterval) -> DiagnosticEvent {
    let id = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
    return DiagnosticEvent(
        sequence: UInt64(seconds),
        wallTime: Date(timeIntervalSince1970: seconds),
        monotonicNanoseconds: UInt64(seconds * 1_000_000_000),
        level: .debug,
        name: .resourceRead,
        context: DiagnosticContext(
            appRunID: id,
            activityID: id,
            operationID: id
        ),
        phase: .instant,
        persistence: .detailed
    )
}
