import Foundation

public struct DiagnosticCenterConfiguration: Equatable, Sendable {
    public let detailedDuration: TimeInterval
    public let incidentFollowUpDuration: TimeInterval
    public let incidentCoalescingDuration: TimeInterval
    public let flightRecorderMaximumAge: TimeInterval
    public let flightRecorderMaximumBytes: Int

    public init(
        detailedDuration: TimeInterval = 30 * 60,
        incidentFollowUpDuration: TimeInterval = 30,
        incidentCoalescingDuration: TimeInterval = 60,
        flightRecorderMaximumAge: TimeInterval = 120,
        flightRecorderMaximumBytes: Int = 8 * 1_024 * 1_024
    ) {
        precondition(detailedDuration > 0)
        precondition(incidentFollowUpDuration > 0)
        precondition(incidentCoalescingDuration > 0)
        precondition(flightRecorderMaximumAge > 0)
        precondition(flightRecorderMaximumBytes > 0)
        self.detailedDuration = detailedDuration
        self.incidentFollowUpDuration = incidentFollowUpDuration
        self.incidentCoalescingDuration = incidentCoalescingDuration
        self.flightRecorderMaximumAge = flightRecorderMaximumAge
        self.flightRecorderMaximumBytes = flightRecorderMaximumBytes
    }
}

public enum DiagnosticCenterWarning: String, Equatable, Sendable {
    case storageUnavailable = "storage_unavailable"
    case storageLimitReached = "storage_limit_reached"
    case privacyAuditFailed = "privacy_audit_failed"
}

public struct DiagnosticStatusSnapshot: Equatable, Sendable {
    public let policy: DiagnosticCollectionPolicy
    public let detailedUntil: Date?
    public let isCapturingIncident: Bool
    public let storageBytes: Int64
    public let recentRuns: [DiagnosticRunSummary]
    public let warning: DiagnosticCenterWarning?

    public init(
        policy: DiagnosticCollectionPolicy,
        detailedUntil: Date?,
        isCapturingIncident: Bool,
        storageBytes: Int64,
        recentRuns: [DiagnosticRunSummary],
        warning: DiagnosticCenterWarning?
    ) {
        self.policy = policy
        self.detailedUntil = detailedUntil
        self.isCapturingIncident = isCapturingIncident
        self.storageBytes = storageBytes
        self.recentRuns = recentRuns
        self.warning = warning
    }
}

public actor DiagnosticCenter {
    private struct IncidentKey: Hashable {
        let activityID: UUID
        let kind: DiagnosticIncidentKind
    }

    private struct IncidentState {
        let key: IncidentKey
        let triggeredAt: Date
        let followUpUntil: Date
    }

    public nonisolated let emitter: DiagnosticEmitter
    public nonisolated let statusUpdates: AsyncStream<DiagnosticStatusSnapshot>

    private let runID: UUID
    private let environment: DiagnosticRunEnvironment
    private let store: any DiagnosticStore
    private let systemLogger: any DiagnosticSystemLogging
    private let now: @Sendable () -> Date
    private let configuration: DiagnosticCenterConfiguration
    private let statusContinuation: AsyncStream<DiagnosticStatusSnapshot>.Continuation
    private var flightRecorder: DiagnosticFlightRecorder
    private var policy: DiagnosticCollectionPolicy = .standard
    private var detailedUntil: Date?
    private var incidents: [UUID: IncidentState] = [:]
    private var recentIncidentTriggers: [IncidentKey: Date] = [:]
    private var persistedSequences: Set<UInt64> = []
    private var warning: DiagnosticCenterWarning?
    private var diskEnabled = true
    private var storeRunOpened = false
    private var isStarted = false
    private var drainTasks: [Task<Void, Never>] = []

    public init(
        runID: UUID = UUID(),
        environment: DiagnosticRunEnvironment,
        store: any DiagnosticStore,
        systemLogger: any DiagnosticSystemLogging = AppleDiagnosticSystemLogger(),
        emitter: DiagnosticEmitter = DiagnosticEmitter(),
        now: @escaping @Sendable () -> Date = Date.init,
        configuration: DiagnosticCenterConfiguration = DiagnosticCenterConfiguration()
    ) {
        self.runID = runID
        self.environment = environment
        self.store = store
        self.systemLogger = systemLogger
        self.emitter = emitter
        self.now = now
        self.configuration = configuration
        self.flightRecorder = DiagnosticFlightRecorder(
            maximumAge: configuration.flightRecorderMaximumAge,
            maximumEncodedBytes: configuration.flightRecorderMaximumBytes
        )

        var capturedContinuation: AsyncStream<DiagnosticStatusSnapshot>.Continuation?
        statusUpdates = AsyncStream(bufferingPolicy: .bufferingNewest(8)) {
            capturedContinuation = $0
        }
        guard let capturedContinuation else {
            preconditionFailure("Failed to create the diagnostic status stream")
        }
        self.statusContinuation = capturedContinuation
    }

    public func start() async {
        guard !isStarted else { return }
        isStarted = true
        let startedAt = now()
        do {
            try await store.startRun(DiagnosticRunManifest(
                runID: runID,
                startedAt: startedAt,
                policy: .standard,
                environment: environment
            ))
            storeRunOpened = true
            let retention = try await store.enforceRetention(now: startedAt)
            if retention.storageLimitReached {
                warning = .storageLimitReached
            }
        } catch {
            diskEnabled = false
            warning = .storageUnavailable
        }

        let essentialEvents = emitter.essentialEvents
        let detailedEvents = emitter.detailedEvents
        drainTasks = [
            Task { [weak self] in
                for await event in essentialEvents {
                    await self?.ingest(event)
                }
            },
            Task { [weak self] in
                for await event in detailedEvents {
                    await self?.ingest(event)
                }
            },
        ]
        await publishStatus()
    }

    public func stop() async {
        guard isStarted else { return }
        emitter.finish()
        let tasks = drainTasks
        drainTasks.removeAll()
        for task in tasks {
            await task.value
        }
        if storeRunOpened {
            do {
                try await store.flush()
            } catch {
                diskEnabled = false
                warning = .storageUnavailable
            }
            do {
                try await store.closeRun(endedAt: now())
            } catch {
                diskEnabled = false
                warning = .storageUnavailable
            }
            storeRunOpened = false
        }
        isStarted = false
        await publishStatus()
        statusContinuation.finish()
    }

    public func setDetailedEnabled(_ enabled: Bool) async {
        if enabled {
            policy = .detailed
            detailedUntil = now().addingTimeInterval(configuration.detailedDuration)
        } else {
            policy = .standard
            detailedUntil = nil
        }
        await publishStatus()
    }

    public func statusSnapshot() async -> DiagnosticStatusSnapshot {
        refreshTimeBasedState()
        var storageBytes: Int64 = 0
        var recentRuns: [DiagnosticRunSummary] = []
        if diskEnabled {
            do {
                storageBytes = try await store.currentUsageBytes()
                recentRuns = try await store.summaries().sorted { $0.startedAt > $1.startedAt }
            } catch {
                warning = .storageUnavailable
                diskEnabled = false
            }
        } else {
            storageBytes = 0
            recentRuns = []
        }
        return DiagnosticStatusSnapshot(
            policy: effectivePolicy,
            detailedUntil: detailedUntil,
            isCapturingIncident: !incidents.isEmpty,
            storageBytes: storageBytes,
            recentRuns: recentRuns,
            warning: warning
        )
    }

    public func recordMetric(_ metric: DiagnosticMetricRecord) async {
        guard isStarted, diskEnabled, effectivePolicy != .standard else { return }
        do {
            try await store.appendMetrics([try DiagnosticMetricRecordEncoder.encode(metric)])
        } catch {
            diskEnabled = false
            warning = .storageUnavailable
            await publishStatus()
        }
    }

    public func clearClosedRuns() async {
        guard diskEnabled else { return }
        do {
            try await store.clearClosedRuns()
        } catch {
            diskEnabled = false
            warning = .storageUnavailable
        }
        await publishStatus()
    }

    func ingest(_ event: DiagnosticEvent) async {
        guard isStarted else { return }
        refreshTimeBasedState()

        let encoded: Data
        do {
            encoded = try DiagnosticEventEncoder.encode(event)
        } catch {
            return
        }

        if event.persistence == .detailed {
            flightRecorder.append(event, encodedByteCount: encoded.count)
        }

        let currentTime = now()
        let newIncident = beginIncidentIfNeeded(for: event, at: currentTime)
        if newIncident, policy != .detailed {
            let prelude = flightRecorder.snapshot().filter {
                $0.context.activityID == event.context.activityID
                    && $0.sequence != event.sequence
            }
            for preludeEvent in prelude {
                await persist(preludeEvent)
            }
        }

        let incidentCapturesEvent = incidents[event.context.activityID]
            .map { currentTime <= $0.followUpUntil } ?? false
        let shouldRoute = event.persistence == .essential
            || policy == .detailed
            || incidentCapturesEvent
        if shouldRoute {
            systemLogger.log(DiagnosticSystemLogRecord(event: event))
            await persist(event)
        }

        if event.name == .playbackStop {
            incidents[event.context.activityID] = nil
        }
        if newIncident || event.name == .playbackStop {
            await publishStatus()
        }
        await persistDroppedEventSummaryIfNeeded(anchor: event)
    }

    private var effectivePolicy: DiagnosticCollectionPolicy {
        if !incidents.isEmpty { return .incident }
        return policy
    }

    private func refreshTimeBasedState() {
        let currentTime = now()
        if let deadline = detailedUntil, currentTime > deadline {
            detailedUntil = nil
            policy = .standard
        }
        incidents = incidents.filter { currentTime <= $0.value.followUpUntil }
        recentIncidentTriggers = recentIncidentTriggers.filter {
            currentTime.timeIntervalSince($0.value) <= configuration.incidentCoalescingDuration
        }
    }

    private func beginIncidentIfNeeded(for event: DiagnosticEvent, at date: Date) -> Bool {
        guard let kind = event.incidentKind else { return false }
        let key = IncidentKey(activityID: event.context.activityID, kind: kind)
        if let prior = recentIncidentTriggers[key],
           date.timeIntervalSince(prior) <= configuration.incidentCoalescingDuration
        {
            return false
        }
        recentIncidentTriggers[key] = date
        incidents[event.context.activityID] = IncidentState(
            key: key,
            triggeredAt: date,
            followUpUntil: date.addingTimeInterval(configuration.incidentFollowUpDuration)
        )
        return true
    }

    private func persist(_ event: DiagnosticEvent) async {
        guard diskEnabled, !persistedSequences.contains(event.sequence) else { return }
        do {
            try await store.appendEvents([try DiagnosticEventEncoder.encode(event)])
            persistedSequences.insert(event.sequence)
        } catch {
            diskEnabled = false
            warning = .storageUnavailable
        }
    }

    private func persistDroppedEventSummaryIfNeeded(anchor: DiagnosticEvent) async {
        let counts = emitter.takeDroppedCounts()
        guard counts.essential > 0 || counts.detailed > 0 else { return }
        let currentTime = now()
        let event = emitter.assignSequence(to: DiagnosticEvent(
            sequence: 0,
            wallTime: currentTime,
            monotonicNanoseconds: anchor.monotonicNanoseconds,
            level: .warning,
            name: .eventsDropped,
            context: anchor.context.child(),
            phase: .instant,
            payload: DiagnosticPayload(
                droppedEssentialEvents: counts.essential,
                droppedDetailedEvents: counts.detailed,
                incidentKind: .eventLoss
            ),
            persistence: .essential
        ))
        await ingest(event)
    }

    private func publishStatus() async {
        statusContinuation.yield(await statusSnapshot())
    }
}
