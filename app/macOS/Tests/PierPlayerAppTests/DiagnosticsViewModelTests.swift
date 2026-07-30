import DiagnosticsKit
import Foundation
import Testing
@testable import PierPlayerApp

@Suite @MainActor struct DiagnosticsViewModelTests {
    @Test func statusStreamUpdatesModeRemainingTimeUsageRunsAndWarning() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let run = diagnosticRun(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            startedAt: now.addingTimeInterval(-60),
            endedAt: now.addingTimeInterval(-10),
            policy: .standard,
            byteCount: 2_048
        )
        let client = FakeDiagnosticsCenterClient(snapshot: diagnosticStatus())
        let viewModel = DiagnosticsViewModel(client: client, now: { now })

        await viewModel.start()
        client.send(diagnosticStatus(
            policy: .detailed,
            detailedUntil: now.addingTimeInterval(25 * 60),
            storageBytes: 42 * 1_024 * 1_024,
            recentRuns: [run],
            warning: .storageLimitReached
        ))

        try await waitUntil { viewModel.mode == .detailed }
        #expect(viewModel.isDetailedEnabled)
        let remainingTime = try #require(viewModel.remainingTime)
        #expect(abs(remainingTime - 25 * 60) < 0.001)
        #expect(viewModel.storageBytes == 42 * 1_024 * 1_024)
        #expect(viewModel.storageFraction == 0.42)
        #expect(viewModel.recentRuns == [run])
        #expect(viewModel.warning == .storageLimitReached)

        client.send(diagnosticStatus(policy: .incident, isCapturingIncident: true))
        try await waitUntil { viewModel.mode == .incident }
        #expect(viewModel.isCapturingIncident)
    }

    @Test func detailedToggleRequestsThirtyMinutesAndCanStopEarly() async {
        let client = FakeDiagnosticsCenterClient(snapshot: diagnosticStatus())
        let viewModel = DiagnosticsViewModel(client: client)

        await viewModel.setDetailedEnabled(true)
        await viewModel.setDetailedEnabled(false)

        #expect(await client.detailedRequests == [30 * 60])
        #expect(await client.stopDetailedRequestCount == 1)
    }

    @Test func clearHistoryUsesClosedRunOperation() async {
        let client = FakeDiagnosticsCenterClient(snapshot: diagnosticStatus())
        let viewModel = DiagnosticsViewModel(client: client)

        await viewModel.clearHistory()

        #expect(await client.clearClosedRunCount == 1)
    }

    @Test func exportPassesOnlySelectedRunIDsToDestination() async throws {
        let first = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
        let second = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        let ignored = UUID(uuidString: "20000000-0000-0000-0000-000000000003")!
        let destination = URL(fileURLWithPath: "/tmp/selected-runs.pierdiag")
        let client = FakeDiagnosticsCenterClient(snapshot: diagnosticStatus(recentRuns: [
            diagnosticRun(id: first),
            diagnosticRun(id: second),
            diagnosticRun(id: ignored),
        ]))
        let viewModel = DiagnosticsViewModel(client: client)
        viewModel.selectedRunIDs = [second, first]

        try await viewModel.exportSelectedRuns(to: destination)

        let request = try #require(await client.exportRequests.first)
        #expect(request.runIDs == [first, second])
        #expect(request.destination == destination)
    }
}

private actor FakeDiagnosticsCenterClient: DiagnosticsCenterClient {
    nonisolated let statusUpdates: AsyncStream<DiagnosticStatusSnapshot>
    private nonisolated let continuation: AsyncStream<DiagnosticStatusSnapshot>.Continuation
    private var snapshot: DiagnosticStatusSnapshot
    private(set) var detailedRequests: [TimeInterval] = []
    private(set) var stopDetailedRequestCount = 0
    private(set) var clearClosedRunCount = 0
    private(set) var exportRequests: [(runIDs: [UUID], destination: URL)] = []

    init(snapshot: DiagnosticStatusSnapshot) {
        self.snapshot = snapshot
        var captured: AsyncStream<DiagnosticStatusSnapshot>.Continuation?
        statusUpdates = AsyncStream(bufferingPolicy: .bufferingNewest(8)) { captured = $0 }
        continuation = captured!
    }

    nonisolated func send(_ snapshot: DiagnosticStatusSnapshot) {
        continuation.yield(snapshot)
    }

    func statusSnapshot() async -> DiagnosticStatusSnapshot {
        snapshot
    }

    func requestDetailedCapture(duration: TimeInterval) async {
        detailedRequests.append(duration)
    }

    func stopDetailedCapture() async {
        stopDetailedRequestCount += 1
    }

    func clearClosedRuns() async {
        clearClosedRunCount += 1
    }

    func export(runIDs: [UUID], to destination: URL) async throws {
        exportRequests.append((runIDs, destination))
    }
}

private func diagnosticStatus(
    policy: DiagnosticCollectionPolicy = .standard,
    detailedUntil: Date? = nil,
    isCapturingIncident: Bool = false,
    storageBytes: Int64 = 0,
    recentRuns: [DiagnosticRunSummary] = [],
    warning: DiagnosticCenterWarning? = nil
) -> DiagnosticStatusSnapshot {
    DiagnosticStatusSnapshot(
        policy: policy,
        detailedUntil: detailedUntil,
        isCapturingIncident: isCapturingIncident,
        storageBytes: storageBytes,
        recentRuns: recentRuns,
        warning: warning
    )
}

private func diagnosticRun(
    id: UUID,
    startedAt: Date = Date(timeIntervalSince1970: 1_799_999_000),
    endedAt: Date? = Date(timeIntervalSince1970: 1_799_999_100),
    policy: DiagnosticCollectionPolicy = .standard,
    byteCount: Int64 = 1_024
) -> DiagnosticRunSummary {
    DiagnosticRunSummary(
        runID: id,
        startedAt: startedAt,
        endedAt: endedAt,
        policy: policy,
        byteCount: byteCount
    )
}

@MainActor
private func waitUntil(
    timeout: Duration = .seconds(1),
    condition: @escaping @MainActor () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
        guard clock.now < deadline else {
            Issue.record("Timed out waiting for diagnostics state")
            return
        }
        await Task.yield()
    }
}
