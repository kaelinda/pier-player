import CloudSyncKit
import DiagnosticsKit
import FFmpegKit
import Foundation
import MediaSourceKit
import PlaybackCore
import RenderKit
import SubtitleKit
import SwiftUI

protocol PlaybackCoordinatorControlling: Sendable {
    var snapshots: AsyncStream<PlaybackCoordinatorSnapshot> { get }

    func start(
        file: any MediaReadableFile,
        reopenFile: @escaping MediaFileReopener
    ) async throws
    func pause() async throws
    func resume() async throws
    func seek(to position: TimeInterval) async throws -> UInt64
    func selectAudioTrack(index: Int) async throws -> UInt64
    func selectSubtitleTrack(index: Int?) async throws
    func registerExternalSubtitles(_ subtitles: [ExternalPlaybackSubtitle]) async
    func stop() async
}

extension PlaybackCoordinator: PlaybackCoordinatorControlling {}

@MainActor
final class VideoPlayerModel: ObservableObject {
    let item: MediaSourceItem
    let renderer: SampleBufferRenderer

    @Published private(set) var snapshot: PlaybackCoordinatorSnapshot = .idle
    @Published private(set) var timelinePosition: TimeInterval = 0
    @Published private(set) var isScrubbing = false
    @Published private(set) var scrubPosition: TimeInterval = 0
    @Published private(set) var volume: Double = 1
    @Published private(set) var isMuted = false

    private let source: any MediaSource
    private let coordinator: any PlaybackCoordinatorControlling
    private let diagnosticRecorder: any DiagnosticRecording
    private let diagnosticContext: DiagnosticContext
    private let identityProvider: (any DiagnosticIdentityProviding)?
    private let progressManager: (any PlaybackProgressManaging)?
    private let historyStore: (any PlaybackHistoryStoring)?
    private let sourceDisplayName: String
    private var snapshotTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    private var hasStarted = false
    private var activeSessionID: UUID?
    private var activeMediaID: String?
    private var canPersistProgress = false
    private var terminalFlushTask: Task<Void, Never>?
    private var terminalFlushSessionID: UUID?

    init(
        item: MediaSourceItem,
        source: any MediaSource,
        renderer: SampleBufferRenderer? = nil,
        coordinator: (any PlaybackCoordinatorControlling)? = nil,
        diagnosticRecorder: any DiagnosticRecording = NoopDiagnosticRecorder(),
        diagnosticContext: DiagnosticContext? = nil,
        identityProvider: (any DiagnosticIdentityProviding)? = nil,
        progressManager: (any PlaybackProgressManaging)? = nil,
        historyStore: (any PlaybackHistoryStoring)? = nil,
        sourceDisplayName: String? = nil
    ) {
        let renderer = renderer ?? SampleBufferRenderer()
        let diagnosticContext = diagnosticContext ?? DiagnosticContext(
            appRunID: UUID(),
            activityID: UUID(),
            operationID: UUID()
        )
        self.item = item
        self.source = source
        self.renderer = renderer
        self.diagnosticRecorder = diagnosticRecorder
        self.diagnosticContext = diagnosticContext
        self.identityProvider = identityProvider
        self.progressManager = progressManager
        self.historyStore = historyStore
        self.sourceDisplayName = sourceDisplayName ?? source.displayName
        self.coordinator = coordinator ?? PlaybackCoordinator(
            renderer: renderer,
            diagnosticRecorder: diagnosticRecorder,
            diagnosticContext: diagnosticContext,
            identityProvider: identityProvider
        )
    }

    deinit {
        snapshotTask?.cancel()
        progressTask?.cancel()
        let coordinator = coordinator
        Task { await coordinator.stop() }
    }

    var position: TimeInterval {
        isScrubbing ? scrubPosition : timelinePosition
    }

    var audioTracks: [PlaybackTrack] {
        snapshot.tracks.filter { $0.kind == .audio }
    }

    var subtitleTracks: [PlaybackTrack] {
        snapshot.tracks.filter { $0.kind == .subtitle }
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        let sessionID = UUID()
        activeSessionID = sessionID
        terminalFlushTask = nil
        terminalFlushSessionID = nil
        consumeSnapshots()
        updateProgress()

        await openAndStartPlayback(sessionID: sessionID)
    }

    private func openAndStartPlayback(sessionID: UUID) async {
        do {
            let file = try await openPlaybackFile(
                source: source,
                item: item,
                recorder: diagnosticRecorder,
                context: diagnosticContext,
                identityProvider: identityProvider
            )
            guard isActive(sessionID) else {
                await file.close()
                return
            }
            let identity = file.identity
            try await coordinator.start(
                file: file,
                reopenFile: { [
                    source,
                    item,
                    diagnosticRecorder,
                    diagnosticContext,
                    identityProvider,
                ] in
                    try await openPlaybackFile(
                        source: source,
                        item: item,
                        recorder: diagnosticRecorder,
                        context: diagnosticContext,
                        identityProvider: identityProvider
                    )
                }
            )
            guard isActive(sessionID) else { return }
            activeMediaID = MediaSyncIdentity.make(from: identity)
            canPersistProgress = false
            await recordPlaybackHistory(identity: identity)
            guard isActive(sessionID) else { return }
            if isTerminal(snapshot.state) {
                canPersistProgress = true
                scheduleTerminalFlush()
                await terminalFlushTask?.value
                return
            }
            await restoreProgressIfAvailable(sessionID: sessionID)
            guard isActive(sessionID) else { return }
            canPersistProgress = true
            if isTerminal(snapshot.state) {
                scheduleTerminalFlush()
                await terminalFlushTask?.value
                return
            }
            guard isActive(sessionID) else { return }
            await discoverExternalSubtitles(sessionID: sessionID)
        } catch is CancellationError {
            if isActive(sessionID) {
                await stop()
            }
        } catch {
            guard isActive(sessionID) else { return }
            await coordinator.stop()
            guard isActive(sessionID) else { return }
            await publishFailure(error)
        }
    }

    func stop() async {
        guard hasStarted, let sessionID = activeSessionID else { return }
        hasStarted = false
        if terminalFlushSessionID == sessionID, let terminalFlushTask {
            await terminalFlushTask.value
        } else {
            await persistProgress(force: true, sessionID: sessionID)
        }
        guard activeSessionID == sessionID else { return }
        activeSessionID = nil
        let snapshotTask = self.snapshotTask
        let progressTask = self.progressTask
        self.snapshotTask = nil
        self.progressTask = nil
        snapshotTask?.cancel()
        progressTask?.cancel()
        await snapshotTask?.value
        await progressTask?.value
        await coordinator.stop()
        activeMediaID = nil
        canPersistProgress = false
        terminalFlushTask = nil
        terminalFlushSessionID = nil
        snapshot = .idle
        timelinePosition = 0
    }

    func forcePersistProgress() async {
        guard let sessionID = activeSessionID else { return }
        await persistProgress(force: true, sessionID: sessionID)
    }

    func retry() async {
        guard hasStarted, case .failed = snapshot.state else { return }
        await coordinator.stop()
        canPersistProgress = false
        activeMediaID = nil
        let sessionID = UUID()
        activeSessionID = sessionID
        terminalFlushTask = nil
        terminalFlushSessionID = nil
        snapshot = .idle
        timelinePosition = 0
        await openAndStartPlayback(sessionID: sessionID)
    }

    func togglePlayback() async {
        do {
            if snapshot.intendsToPlay {
                try await coordinator.pause()
                await persistProgress(force: true)
            } else {
                try await coordinator.resume()
            }
        } catch {
            await publishFailure(error)
        }
    }

    func beginScrubbing() {
        isScrubbing = true
        scrubPosition = timelinePosition
    }

    func updateScrubPosition(_ position: TimeInterval) {
        guard isScrubbing else { return }
        scrubPosition = clamped(position)
    }

    func endScrubbing() async {
        guard isScrubbing else { return }
        let target = scrubPosition
        let acceptedPosition = timelinePosition
        isScrubbing = false
        do {
            _ = try await coordinator.seek(to: target)
            timelinePosition = target
            await persistProgress(force: true)
        } catch {
            timelinePosition = acceptedPosition
            await publishFailure(error)
        }
    }

    func selectAudioTrack(_ index: Int) async {
        do {
            _ = try await coordinator.selectAudioTrack(index: index)
        } catch {
            await publishFailure(error)
        }
    }

    func selectSubtitleTrack(_ index: Int?) async {
        do {
            try await coordinator.selectSubtitleTrack(index: index)
        } catch {
            await publishFailure(error)
        }
    }

    func setVolume(_ value: Double) {
        volume = min(max(value, 0), 1)
        renderer.volume = Float(volume)
        if volume > 0, isMuted {
            isMuted = false
            renderer.isMuted = false
        }
    }

    func toggleMute() {
        isMuted.toggle()
        renderer.isMuted = isMuted
    }

    private func consumeSnapshots() {
        let snapshots = coordinator.snapshots
        snapshotTask = Task { [weak self] in
            for await snapshot in snapshots {
                guard !Task.isCancelled else { return }
                self?.receive(snapshot)
            }
        }
    }

    private func discoverExternalSubtitles(sessionID: UUID) async {
        let parent = (item.path as NSString).deletingLastPathComponent
        let directory = parent.isEmpty ? "/" : parent
        guard let items = try? await source.list(directory: directory),
              isActive(sessionID) else {
            return
        }
        let candidates = ExternalSubtitleDiscovery.discover(
            videoPath: item.path,
            among: items
        )
        var subtitles: [ExternalPlaybackSubtitle] = []
        for candidate in candidates {
            guard isActive(sessionID) else { return }
            let result = try? await ExternalSubtitleDiscovery.load(
                candidate,
                from: source
            )
            guard isActive(sessionID) else { return }
            guard let result else {
                continue
            }
            subtitles.append(
                ExternalPlaybackSubtitle(
                    identifier: candidate.item.path,
                    codecName: candidate.format.rawValue,
                    language: candidate.language,
                    title: candidate.item.name,
                    cues: result.cues
                )
            )
        }
        guard isActive(sessionID) else { return }
        await coordinator.registerExternalSubtitles(subtitles)
    }

    private func updateProgress() {
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !self.isScrubbing {
                    self.timelinePosition = max(self.snapshot.position, self.renderer.timelineTime)
                }
                await self.persistProgress(force: false)
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    private func receive(_ snapshot: PlaybackCoordinatorSnapshot) {
        guard hasStarted else { return }
        self.snapshot = snapshot
        if !isScrubbing {
            timelinePosition = snapshot.position
        }
        switch snapshot.state {
        case .ended, .failed:
            scheduleTerminalFlush()
        default:
            break
        }
    }

    private func restoreProgressIfAvailable(sessionID: UUID) async {
        guard let activeMediaID,
              let progressManager,
              let progress = await progressManager.progress(mediaID: activeMediaID),
              isActive(sessionID),
              !isTerminal(snapshot.state),
              progress.effectiveResumePosition > 0 else { return }
        do {
            _ = try await coordinator.seek(to: progress.effectiveResumePosition)
            guard isActive(sessionID) else { return }
            timelinePosition = progress.effectiveResumePosition
        } catch {
            return
        }
    }

    private func persistProgress(force: Bool) async {
        guard let sessionID = activeSessionID else { return }
        await persistProgress(force: force, sessionID: sessionID)
    }

    private func persistProgress(force: Bool, sessionID: UUID) async {
        guard activeSessionID == sessionID,
              canPersistProgress,
              let activeMediaID,
              let progressManager,
              snapshot.duration.isFinite,
              snapshot.duration > 0 else { return }
        await progressManager.record(
            mediaID: activeMediaID,
            sourceID: source.id,
            position: timelinePosition,
            duration: snapshot.duration,
            force: force
        )
    }

    private func scheduleTerminalFlush() {
        guard let sessionID = activeSessionID,
              canPersistProgress,
              activeMediaID != nil,
              snapshot.duration.isFinite,
              snapshot.duration > 0 else { return }
        if terminalFlushSessionID == sessionID, terminalFlushTask != nil { return }
        terminalFlushSessionID = sessionID
        terminalFlushTask = Task { [weak self] in
            await self?.persistProgress(force: true, sessionID: sessionID)
        }
    }

    private func isActive(_ sessionID: UUID) -> Bool {
        hasStarted && activeSessionID == sessionID && !Task.isCancelled
    }

    private func isTerminal(_ state: PlaybackState) -> Bool {
        switch state {
        case .ended, .failed:
            true
        default:
            false
        }
    }

    private func recordPlaybackHistory(identity: MediaFileIdentity) async {
        guard let historyStore,
              let entry = try? PlaybackHistoryEntry(
                  mediaID: MediaSyncIdentity.make(from: identity),
                  sourceID: identity.sourceID,
                  sourceDisplayName: sourceDisplayName,
                  fileName: item.name,
                  path: identity.path,
                  size: identity.size,
                  modifiedAt: identity.modifiedAt
              ) else { return }
        try? await historyStore.upsert(entry)
    }

    private func clamped(_ position: TimeInterval) -> TimeInterval {
        guard position.isFinite else { return 0 }
        return min(max(position, 0), max(snapshot.duration, 0))
    }

    private func publishFailure(_ error: Error) async {
        let failure = PlaybackFailure.classify(error, defaultBoundary: .sourceOpen)
        snapshot = PlaybackCoordinatorSnapshot(
            sessionID: snapshot.sessionID,
            generation: snapshot.generation,
            state: .failed(failure.message),
            intendsToPlay: false,
            position: timelinePosition,
            duration: snapshot.duration,
            videoDecoderMode: snapshot.videoDecoderMode,
            tracks: snapshot.tracks,
            subtitleText: snapshot.subtitleText,
            failure: failure
        )
        if canPersistProgress,
           activeMediaID != nil,
           snapshot.duration.isFinite,
           snapshot.duration > 0 {
            scheduleTerminalFlush()
            await terminalFlushTask?.value
        }
    }
}

private func openPlaybackFile(
    source: any MediaSource,
    item: MediaSourceItem,
    recorder: any DiagnosticRecording,
    context: DiagnosticContext,
    identityProvider: (any DiagnosticIdentityProviding)?
) async throws -> any MediaReadableFile {
    let initialPayload = DiagnosticPayload(
        sourceID: source.id,
        container: DiagnosticContainerKind(fileName: item.name),
        fileSize: item.size
    )
    let operation = DiagnosticOperation(
        recorder: recorder,
        parentContext: context,
        name: .fileOpen,
        level: .info,
        payload: initialPayload,
        persistence: .essential
    )
    do {
        let file = try await source.open(file: item.path)
        let fileID = identityProvider?.fileIdentity(
            sourceID: file.identity.sourceID,
            normalizedPath: file.identity.path,
            size: file.identity.size,
            modifiedAt: file.identity.modifiedAt
        ).value
        operation.end(
            outcome: .success,
            payload: DiagnosticPayload(
                sourceID: file.identity.sourceID,
                fileID: fileID,
                container: DiagnosticContainerKind(fileName: item.name),
                fileSize: file.identity.size
            )
        )
        return file
    } catch {
        if error is CancellationError {
            operation.end(outcome: .cancelled, payload: initialPayload)
        } else {
            operation.end(
                outcome: .failure,
                payload: initialPayload,
                error: playbackOpenDiagnosticDescriptor(for: error)
            )
        }
        throw error
    }
}

private func playbackOpenDiagnosticDescriptor(
    for error: Error
) -> DiagnosticErrorDescriptor {
    switch error {
    case MediaSourceError.notConnected:
        DiagnosticErrorDescriptor(code: .sourceNotConnected, isRetryable: true)
    case MediaSourceError.authenticationFailed:
        DiagnosticErrorDescriptor(code: .sourceAuthenticationFailed)
    case MediaSourceError.unreachable:
        DiagnosticErrorDescriptor(code: .sourceUnreachable, isRetryable: true)
    case MediaSourceError.notFound:
        DiagnosticErrorDescriptor(code: .sourceNotFound)
    case MediaSourceError.invalidRead:
        DiagnosticErrorDescriptor(code: .sourceInvalidRead)
    case MediaSourceError.readFailed:
        DiagnosticErrorDescriptor(code: .sourceReadFailed, isRetryable: true)
    case MediaSourceError.remoteFileChanged:
        DiagnosticErrorDescriptor(code: .sourceRemoteFileChanged)
    case MediaSourceError.unsupported:
        DiagnosticErrorDescriptor(code: .sourceUnsupported)
    default:
        DiagnosticErrorDescriptor(code: .playerFailed)
    }
}
