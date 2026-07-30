import DiagnosticsKit
import Foundation

protocol DiagnosticsCenterClient: Sendable {
    var statusUpdates: AsyncStream<DiagnosticStatusSnapshot> { get }
    func statusSnapshot() async -> DiagnosticStatusSnapshot
    func requestDetailedCapture(duration: TimeInterval) async
    func stopDetailedCapture() async
    func clearClosedRuns() async
    func export(runIDs: [UUID], to destination: URL) async throws
}

struct LiveDiagnosticsCenterClient: DiagnosticsCenterClient {
    let center: DiagnosticCenter

    var statusUpdates: AsyncStream<DiagnosticStatusSnapshot> {
        center.statusUpdates
    }

    func statusSnapshot() async -> DiagnosticStatusSnapshot {
        await center.statusSnapshot()
    }

    func requestDetailedCapture(duration: TimeInterval) async {
        await center.requestDetailedCapture(duration: duration)
    }

    func stopDetailedCapture() async {
        await center.stopDetailedCapture()
    }

    func clearClosedRuns() async {
        await center.clearClosedRuns()
    }

    func export(runIDs: [UUID], to destination: URL) async throws {
        _ = try await center.export(runIDs: runIDs, to: destination)
    }
}

@MainActor
final class DiagnosticsViewModel: ObservableObject {
    static let detailedCaptureDuration: TimeInterval = 30 * 60
    static let maximumStorageBytes: Int64 = 100 * 1_024 * 1_024

    @Published private(set) var snapshot: DiagnosticStatusSnapshot
    @Published var selectedRunIDs: Set<UUID> = []
    @Published private(set) var isExporting = false

    private let client: any DiagnosticsCenterClient
    private let now: @Sendable () -> Date
    private var observationTask: Task<Void, Never>?

    init(
        client: any DiagnosticsCenterClient,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.client = client
        self.now = now
        self.snapshot = DiagnosticStatusSnapshot(
            policy: .standard,
            detailedUntil: nil,
            isCapturingIncident: false,
            storageBytes: 0,
            recentRuns: [],
            warning: nil
        )
    }

    var mode: DiagnosticCollectionPolicy { snapshot.policy }
    var isDetailedEnabled: Bool { snapshot.detailedUntil != nil }
    var isCapturingIncident: Bool { snapshot.isCapturingIncident }
    var storageBytes: Int64 { snapshot.storageBytes }
    var recentRuns: [DiagnosticRunSummary] { snapshot.recentRuns }
    var warning: DiagnosticCenterWarning? { snapshot.warning }

    var remainingTime: TimeInterval? {
        guard let detailedUntil = snapshot.detailedUntil else { return nil }
        return max(0, detailedUntil.timeIntervalSince(now()))
    }

    var storageFraction: Double {
        min(1, max(0, Double(storageBytes) / Double(Self.maximumStorageBytes)))
    }

    func start() async {
        apply(await client.statusSnapshot())
        guard observationTask == nil else { return }
        let updates = client.statusUpdates
        observationTask = Task { [weak self] in
            for await status in updates {
                guard !Task.isCancelled else { return }
                self?.apply(status)
            }
        }
    }

    func setDetailedEnabled(_ enabled: Bool) async {
        if enabled {
            await client.requestDetailedCapture(duration: Self.detailedCaptureDuration)
        } else {
            await client.stopDetailedCapture()
        }
        apply(await client.statusSnapshot())
    }

    func clearHistory() async {
        await client.clearClosedRuns()
        apply(await client.statusSnapshot())
    }

    func exportSelectedRuns(to destination: URL) async throws {
        let runIDs = selectedRunIDs.sorted { $0.uuidString < $1.uuidString }
        guard !runIDs.isEmpty else { return }
        isExporting = true
        defer { isExporting = false }
        try await client.export(runIDs: runIDs, to: destination)
        apply(await client.statusSnapshot())
    }

    private func apply(_ status: DiagnosticStatusSnapshot) {
        snapshot = status
        let available = Set(status.recentRuns.map(\.runID))
        selectedRunIDs.formIntersection(available)
        if selectedRunIDs.isEmpty, let newest = status.recentRuns.first {
            selectedRunIDs.insert(newest.runID)
        }
    }
}
