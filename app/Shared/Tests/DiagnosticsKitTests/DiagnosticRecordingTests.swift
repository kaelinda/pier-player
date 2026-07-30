import Foundation
import Testing
@testable import DiagnosticsKit

@Test func emitterKeepsEssentialCapacityWhenDetailedLaneIsFull() async {
    let emitter = DiagnosticEmitter(essentialCapacity: 1, detailedCapacity: 2)
    var essentialIterator = emitter.essentialEvents.makeAsyncIterator()
    var detailedIterator = emitter.detailedEvents.makeAsyncIterator()

    emitter.record(event(persistence: .detailed, monotonicNanoseconds: 1))
    emitter.record(event(persistence: .detailed, monotonicNanoseconds: 2))
    emitter.record(event(persistence: .detailed, monotonicNanoseconds: 3))
    emitter.record(event(persistence: .essential, monotonicNanoseconds: 4))
    emitter.finish()

    let detailedFirst = await detailedIterator.next()
    let detailedSecond = await detailedIterator.next()
    let essential = await essentialIterator.next()
    let drops = emitter.takeDroppedCounts()

    #expect(detailedFirst?.monotonicNanoseconds == 2)
    #expect(detailedSecond?.monotonicNanoseconds == 3)
    #expect(essential?.monotonicNanoseconds == 4)
    #expect(detailedFirst?.sequence == 2)
    #expect(detailedSecond?.sequence == 3)
    #expect(essential?.sequence == 4)
    #expect(drops.detailed == 1)
    #expect(drops.essential == 0)
    #expect(emitter.takeDroppedCounts() == DiagnosticDropCounts())
}

@Test func noopRecorderAcceptsEventsWithoutSideEffects() {
    let recorder: any DiagnosticRecording = NoopDiagnosticRecorder()
    recorder.record(event(persistence: .essential, monotonicNanoseconds: 1))
}

private func event(
    persistence: DiagnosticPersistence,
    monotonicNanoseconds: UInt64
) -> DiagnosticEvent {
    let id = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    return DiagnosticEvent(
        sequence: 0,
        wallTime: Date(timeIntervalSince1970: TimeInterval(monotonicNanoseconds)),
        monotonicNanoseconds: monotonicNanoseconds,
        level: .info,
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
