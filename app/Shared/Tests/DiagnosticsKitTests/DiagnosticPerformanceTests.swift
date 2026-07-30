import Foundation
import Testing
@testable import DiagnosticsKit

@Suite(.serialized) struct DiagnosticPerformanceTests {
    @Test func saturatedEmissionRemainsBoundedAndKeepsEssentialCapacity() async throws {
        let eventCount = 100_000
        let detailedCapacity = 4_096
        let maximumFlightRecorderBytes = 8 * 1_024 * 1_024
        let emitter = DiagnosticEmitter(
            essentialCapacity: 32,
            detailedCapacity: detailedCapacity
        )
        var essentialIterator = emitter.essentialEvents.makeAsyncIterator()
        let detailedEvent = performanceEvent(persistence: .detailed)
        let essentialEvent = performanceEvent(persistence: .essential)
        let encodedByteCount = try DiagnosticEventEncoder.encode(detailedEvent).count
        let clock = ContinuousClock()
        var latencies: [Duration] = []
        latencies.reserveCapacity(eventCount)
        var flightRecorder = DiagnosticFlightRecorder(
            maximumAge: 120,
            maximumEncodedBytes: maximumFlightRecorderBytes
        )

        for _ in 0..<eventCount {
            let start = clock.now
            emitter.record(detailedEvent)
            latencies.append(start.duration(to: clock.now))
            flightRecorder.append(detailedEvent, encodedByteCount: encodedByteCount)
        }
        emitter.record(essentialEvent)
        emitter.finish()

        let drops = emitter.takeDroppedCounts()
        let essential = await essentialIterator.next()
        let sortedLatencies = latencies.sorted()
        let p95 = sortedLatencies[(eventCount * 95 / 100) - 1]
        let p95Microseconds = microseconds(p95)

        #expect(drops.detailed == UInt64(eventCount - detailedCapacity))
        #expect(drops.essential == 0)
        #expect(essential?.persistence == .essential)
        #expect(flightRecorder.encodedByteCount <= maximumFlightRecorderBytes)
        #expect(p95Microseconds < 100)
        print(
            "diagnostics_performance events=\(eventCount) p95_us=\(format(p95Microseconds)) "
                + "flight_recorder_bytes=\(flightRecorder.encodedByteCount) "
                + "dropped_detailed=\(drops.detailed)"
        )
    }
}

private func performanceEvent(persistence: DiagnosticPersistence) -> DiagnosticEvent {
    let id = UUID(uuidString: "00000000-0000-0000-0000-000000000301")!
    return DiagnosticEvent(
        sequence: 0,
        wallTime: Date(timeIntervalSince1970: 1),
        monotonicNanoseconds: 1_000_000_000,
        level: .debug,
        name: .resourceRead,
        context: DiagnosticContext(
            appRunID: id,
            activityID: id,
            operationID: id
        ),
        phase: .instant,
        persistence: persistence
    )
}

private func microseconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) * 1_000_000
        + Double(components.attoseconds) / 1_000_000_000_000
}

private func format(_ value: Double) -> String {
    String(format: "%.3f", value)
}
