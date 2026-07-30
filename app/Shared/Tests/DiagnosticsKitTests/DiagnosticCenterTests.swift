import Foundation
import Testing
@testable import DiagnosticsKit

@Test func centerRoutesStandardDetailedAndExpiredPolicies() async throws {
    let store = MemoryDiagnosticStore()
    let clock = TestDiagnosticClock(Date(timeIntervalSince1970: 10))
    let center = makeCenter(store: store, clock: clock)
    await center.start()

    await center.ingest(event(sequence: 1, persistence: .detailed, at: 10))
    await center.ingest(event(sequence: 2, persistence: .essential, at: 10))
    #expect(try await store.decodedEventSequences() == [2])

    await center.setDetailedEnabled(true)
    await center.ingest(event(sequence: 3, persistence: .detailed, at: 10))
    #expect(try await store.decodedEventSequences() == [2, 3])

    clock.advance(by: 1_801)
    await center.ingest(event(sequence: 4, persistence: .detailed, at: 1_811))
    #expect(try await store.decodedEventSequences() == [2, 3])
    #expect(await center.statusSnapshot().policy == .standard)

    await center.stop()
}

@Test func centerPersistsIncidentPreludeAndCoalescesEquivalentTriggers() async throws {
    let store = MemoryDiagnosticStore()
    let clock = TestDiagnosticClock(Date(timeIntervalSince1970: 3))
    let center = makeCenter(store: store, clock: clock)
    await center.start()

    await center.ingest(event(sequence: 1, persistence: .detailed, at: 1))
    await center.ingest(event(sequence: 2, persistence: .detailed, at: 2))
    await center.ingest(event(
        sequence: 3,
        persistence: .essential,
        name: .playbackFailed,
        level: .error,
        outcome: .failure,
        at: 3
    ))
    await center.ingest(event(sequence: 4, persistence: .detailed, at: 4))

    clock.advance(by: 5)
    await center.ingest(event(
        sequence: 5,
        persistence: .essential,
        name: .playbackFailed,
        level: .error,
        outcome: .failure,
        at: 8
    ))

    clock.advance(by: 26)
    await center.ingest(event(sequence: 6, persistence: .detailed, at: 34))

    #expect(try await store.decodedEventSequences() == [1, 2, 3, 4, 5])
    #expect(await center.statusSnapshot().isCapturingIncident == false)

    await center.stop()
}

@Test func centerDegradesWithoutThrowingWhenStoreFails() async throws {
    let store = MemoryDiagnosticStore()
    let clock = TestDiagnosticClock(Date(timeIntervalSince1970: 0))
    let center = makeCenter(store: store, clock: clock)
    await center.start()
    await store.setFailAppends(true)

    await center.ingest(event(sequence: 1, persistence: .essential, at: 0))

    #expect(await center.statusSnapshot().warning == .storageUnavailable)
    await center.stop()
    #expect(await store.closeCount == 1)
}

@Test func centerPersistsDroppedEventSummaryWithoutRecursion() async throws {
    let store = MemoryDiagnosticStore()
    let clock = TestDiagnosticClock(Date(timeIntervalSince1970: 0))
    let emitter = DiagnosticEmitter(essentialCapacity: 1, detailedCapacity: 1)
    emitter.record(event(sequence: 0, persistence: .detailed, at: 0))
    emitter.record(event(sequence: 0, persistence: .detailed, at: 0))
    let center = DiagnosticCenter(
        runID: UUID(),
        environment: testEnvironment,
        store: store,
        systemLogger: NoopDiagnosticSystemLogger(),
        emitter: emitter,
        now: { clock.now }
    )
    await center.start()

    await center.ingest(event(sequence: 100, persistence: .essential, at: 0))

    let events = try await decodedEvents(
        from: store,
        containing: .eventsDropped
    )
    let dropEvent = try #require(events.first { $0.name == .eventsDropped })
    #expect(dropEvent.payload.droppedDetailedEvents == 1)
    #expect(dropEvent.payload.droppedEssentialEvents == 0)
    await center.stop()
}

private func decodedEvents(
    from store: MemoryDiagnosticStore,
    containing name: DiagnosticEventName
) async throws -> [DiagnosticEvent] {
    for _ in 0..<100 {
        let events = try await store.decodedEvents()
        if events.contains(where: { $0.name == name }) {
            return events
        }
        await Task.yield()
    }
    return try await store.decodedEvents()
}

private func makeCenter(
    store: MemoryDiagnosticStore,
    clock: TestDiagnosticClock
) -> DiagnosticCenter {
    DiagnosticCenter(
        runID: UUID(),
        environment: testEnvironment,
        store: store,
        systemLogger: NoopDiagnosticSystemLogger(),
        now: { clock.now },
        configuration: DiagnosticCenterConfiguration(
            detailedDuration: 1_800,
            incidentFollowUpDuration: 30,
            incidentCoalescingDuration: 60,
            flightRecorderMaximumAge: 120,
            flightRecorderMaximumBytes: 8 * 1_024 * 1_024
        )
    )
}

private func event(
    sequence: UInt64,
    persistence: DiagnosticPersistence,
    name: DiagnosticEventName = .resourceRead,
    level: DiagnosticLevel = .debug,
    outcome: DiagnosticOutcome? = nil,
    at seconds: TimeInterval
) -> DiagnosticEvent {
    let activityID = UUID(uuidString: "00000000-0000-0000-0000-000000000006")!
    return DiagnosticEvent(
        sequence: sequence,
        wallTime: Date(timeIntervalSince1970: seconds),
        monotonicNanoseconds: UInt64(seconds * 1_000_000_000),
        level: level,
        name: name,
        context: DiagnosticContext(
            appRunID: UUID(uuidString: "00000000-0000-0000-0000-000000000007")!,
            activityID: activityID,
            operationID: UUID()
        ),
        phase: .instant,
        outcome: outcome,
        persistence: persistence
    )
}

private let testEnvironment = DiagnosticRunEnvironment(
    appVersion: "1.0",
    appBuild: "1",
    osVersion: "macOS",
    architecture: .arm64,
    hardwareClass: .mac,
    networkAvailability: .available,
    networkInterface: .ethernet
)

private final class TestDiagnosticClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        value = value.addingTimeInterval(interval)
        lock.unlock()
    }
}

private actor MemoryDiagnosticStore: DiagnosticStore {
    private var events: [Data] = []
    private var metrics: [Data] = []
    private var manifest: DiagnosticRunManifest?
    private var failAppends = false
    private(set) var closeCount = 0

    func setFailAppends(_ value: Bool) {
        failAppends = value
    }

    func startRun(_ manifest: DiagnosticRunManifest) throws {
        self.manifest = manifest
    }

    func appendEvents(_ records: [Data]) throws {
        if failAppends { throw DiagnosticStoreError.invalidRecord }
        events.append(contentsOf: records)
    }

    func appendMetrics(_ records: [Data]) throws {
        if failAppends { throw DiagnosticStoreError.invalidRecord }
        metrics.append(contentsOf: records)
    }

    func flush() throws {}

    func closeRun(endedAt: Date) throws {
        closeCount += 1
    }

    func summaries() throws -> [DiagnosticRunSummary] { [] }

    func snapshot(runID: UUID) throws -> DiagnosticStoreSnapshot {
        guard let manifest else { throw DiagnosticStoreError.runNotFound }
        return DiagnosticStoreSnapshot(
            manifest: manifest,
            eventSegments: events,
            metricSegments: metrics,
            eventSegmentURLs: [],
            metricSegmentURLs: []
        )
    }

    func currentUsageBytes() throws -> Int64 { 0 }

    func enforceRetention(now: Date) throws -> DiagnosticRetentionResult {
        DiagnosticRetentionResult(deletedRunIDs: [], storageLimitReached: false, totalBytes: 0)
    }

    func clearClosedRuns() throws {}

    func decodedEventSequences() throws -> [UInt64] {
        try decodedEvents().map(\.sequence)
    }

    func decodedEvents() throws -> [DiagnosticEvent] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try events.map { try decoder.decode(DiagnosticEvent.self, from: $0) }
    }
}
