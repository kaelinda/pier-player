import Dispatch
import Foundation

public struct DiagnosticOperation: Sendable {
    public let context: DiagnosticContext

    private let recorder: any DiagnosticRecording
    private let name: DiagnosticEventName
    private let level: DiagnosticLevel
    private let persistence: DiagnosticPersistence
    private let startedAt: ContinuousClock.Instant

    public init(
        recorder: any DiagnosticRecording,
        parentContext: DiagnosticContext,
        name: DiagnosticEventName,
        level: DiagnosticLevel = .debug,
        payload: DiagnosticPayload = DiagnosticPayload(),
        persistence: DiagnosticPersistence
    ) {
        self.recorder = recorder
        self.context = parentContext.child()
        self.name = name
        self.level = level
        self.persistence = persistence
        self.startedAt = .now
        recorder.record(DiagnosticEvent(
            sequence: 0,
            wallTime: Date(),
            monotonicNanoseconds: DispatchTime.now().uptimeNanoseconds,
            level: level,
            name: name,
            context: context,
            phase: .begin,
            payload: payload,
            persistence: persistence
        ))
    }

    public func end(
        outcome: DiagnosticOutcome,
        payload: DiagnosticPayload = DiagnosticPayload(),
        error: DiagnosticErrorDescriptor? = nil,
        level endLevel: DiagnosticLevel? = nil
    ) {
        recorder.record(DiagnosticEvent(
            sequence: 0,
            wallTime: Date(),
            monotonicNanoseconds: DispatchTime.now().uptimeNanoseconds,
            level: endLevel ?? level(for: outcome),
            name: name,
            context: context,
            phase: .end,
            outcome: outcome,
            durationMilliseconds: Self.milliseconds(startedAt.duration(to: .now)),
            payload: DiagnosticPayload(
                sourceID: payload.sourceID,
                fileID: payload.fileID,
                container: payload.container,
                fileSize: payload.fileSize,
                offset: payload.offset,
                requestedLength: payload.requestedLength,
                actualLength: payload.actualLength,
                droppedEssentialEvents: payload.droppedEssentialEvents,
                droppedDetailedEvents: payload.droppedDetailedEvents,
                cacheHits: payload.cacheHits,
                cacheMisses: payload.cacheMisses,
                upstreamReads: payload.upstreamReads,
                upstreamBytes: payload.upstreamBytes,
                playbackSessionID: payload.playbackSessionID,
                playbackGeneration: payload.playbackGeneration,
                oldPlaybackState: payload.oldPlaybackState,
                newPlaybackState: payload.newPlaybackState,
                playbackPositionSeconds: payload.playbackPositionSeconds,
                incidentKind: payload.incidentKind,
                error: error ?? payload.error
            ),
            persistence: persistence
        ))
    }

    private func level(for outcome: DiagnosticOutcome) -> DiagnosticLevel {
        switch outcome {
        case .success: level
        case .cancelled, .discarded: .notice
        case .failure: .error
        }
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}

public extension DiagnosticEvent {
    static func instant(
        level: DiagnosticLevel,
        name: DiagnosticEventName,
        context: DiagnosticContext,
        outcome: DiagnosticOutcome? = nil,
        payload: DiagnosticPayload = DiagnosticPayload(),
        persistence: DiagnosticPersistence
    ) -> DiagnosticEvent {
        DiagnosticEvent(
            sequence: 0,
            wallTime: Date(),
            monotonicNanoseconds: DispatchTime.now().uptimeNanoseconds,
            level: level,
            name: name,
            context: context,
            phase: .instant,
            outcome: outcome,
            payload: payload,
            persistence: persistence
        )
    }
}
