import CoreVideo
import DiagnosticsKit
import FFmpegKit
import Foundation
import MediaSourceKit
import RenderKit
import StreamIOKit
import SubtitleKit

public actor PlaybackCoordinator {
    private final class Resources: @unchecked Sendable {
        let executor: FFmpegSessionExecutor
        let blockingReader: BlockingMediaReader
        let metadata: MediaMetadata
        let decoderStatus: VideoDecoderStatus

        init(
            executor: FFmpegSessionExecutor,
            blockingReader: BlockingMediaReader,
            metadata: MediaMetadata,
            decoderStatus: VideoDecoderStatus
        ) {
            self.executor = executor
            self.blockingReader = blockingReader
            self.metadata = metadata
            self.decoderStatus = decoderStatus
        }
    }

    private struct RecoveryCandidate: @unchecked Sendable {
        let resources: Resources
        let nativeGeneration: UInt64
    }

    private enum RecoveryAttemptOutcome: @unchecked Sendable {
        case opened(RecoveryCandidate)
        case fileChanged
        case failed
        case timedOut
        case cancelled
    }

    private actor RecoveryAttemptGate {
        private var outcome: RecoveryAttemptOutcome?
        private var continuation: CheckedContinuation<RecoveryAttemptOutcome, Never>?

        func wait() async -> RecoveryAttemptOutcome {
            if let outcome { return outcome }
            return await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }

        func resolve(_ outcome: RecoveryAttemptOutcome) -> Bool {
            guard self.outcome == nil else { return false }
            self.outcome = outcome
            continuation?.resume(returning: outcome)
            continuation = nil
            return true
        }
    }

    public private(set) var snapshot: PlaybackCoordinatorSnapshot = .idle
    public nonisolated let snapshots: AsyncStream<PlaybackCoordinatorSnapshot>

    private let snapshotContinuation: AsyncStream<PlaybackCoordinatorSnapshot>.Continuation
    private let renderer: SampleBufferRenderer
    private let configuration: PlaybackCoordinatorConfiguration
    private let diagnosticRecorder: any DiagnosticRecording
    private let diagnosticContext: DiagnosticContext
    private let identityProvider: (any DiagnosticIdentityProviding)?
    private let stateMachine: PlaybackSession

    private var resources: Resources?
    private var reopenFile: MediaFileReopener?
    private var sourceIdentity: MediaFileIdentity?
    private var currentToken: PlaybackOperationToken?
    private var tracks: [PlaybackTrack] = []
    private var duration: TimeInterval = 0
    private var decoderMode: VideoDecoderMode = .none
    private var failure: PlaybackFailure?
    private var subtitleCues: [SubtitleCue] = []
    private var subtitleTimeline = SubtitleTimeline()
    private var externalSubtitleCues: [Int: [SubtitleCue]] = [:]
    private var selectedExternalSubtitleIndex: Int?

    private var videoQueue: BoundedMediaQueue<DecodedVideoSample>?
    private var audioQueue: BoundedMediaQueue<DecodedAudioSample>?
    private var producerTask: Task<Void, Never>?
    private var videoConsumerTask: Task<Void, Never>?
    private var audioConsumerTask: Task<Void, Never>?
    private var timelineTask: Task<Void, Never>?
    private var finishTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var finishedLanes: Set<RenderLane> = []
    private var decodeFinished = false

    @MainActor
    public init(
        renderer: SampleBufferRenderer,
        configuration: PlaybackCoordinatorConfiguration = .default,
        diagnosticRecorder: any DiagnosticRecording = NoopDiagnosticRecorder(),
        diagnosticContext: DiagnosticContext? = nil,
        identityProvider: (any DiagnosticIdentityProviding)? = nil
    ) {
        let diagnosticContext = diagnosticContext ?? DiagnosticContext(
            appRunID: UUID(),
            activityID: UUID(),
            operationID: UUID()
        )
        let stream = AsyncStream<PlaybackCoordinatorSnapshot>.makeStream(
            bufferingPolicy: .bufferingNewest(32)
        )
        self.snapshots = stream.stream
        self.snapshotContinuation = stream.continuation
        self.renderer = renderer
        self.configuration = configuration
        self.diagnosticRecorder = diagnosticRecorder
        self.diagnosticContext = diagnosticContext
        self.identityProvider = identityProvider
        self.stateMachine = PlaybackSession(
            diagnosticRecorder: diagnosticRecorder,
            diagnosticContext: diagnosticContext
        )
        stream.continuation.yield(.idle)
    }

    public func start(file: any MediaReadableFile) async throws {
        try await start(file: file, reopenFile: nil)
    }

    public func start(
        file: any MediaReadableFile,
        reopenFile: @escaping MediaFileReopener
    ) async throws {
        try await start(file: file, reopenFile: Optional(reopenFile))
    }

    private func start(
        file: any MediaReadableFile,
        reopenFile: MediaFileReopener?
    ) async throws {
        let token = try await stateMachine.open()
        currentToken = token
        self.reopenFile = reopenFile
        sourceIdentity = file.identity
        failure = nil
        await publishSnapshot()

        do {
            _ = await stateMachine.connectionEstablished(token: token)
            await publishSnapshot()
            let opened = try await openResources(file: file)
            guard accepts(token) else {
                await close(opened)
                throw CancellationError()
            }

            resources = opened
            applyMetadata(opened.metadata, decoderStatus: opened.decoderStatus)
            guard await stateMachine.mediaOpened(token: token), accepts(token) else {
                resources = nil
                await close(opened)
                throw CancellationError()
            }
            await publishSnapshot()
            guard accepts(token) else { throw CancellationError() }
            launchGeneration(token: token, executor: opened.executor, nativeGeneration: 0)
        } catch {
            if !(error is CancellationError) {
                let playbackFailure = nativeFailure(error)
                await fail(playbackFailure)
            }
            throw error
        }
    }

    public func pause() async throws {
        try await stateMachine.pause()
        finishTask?.cancel()
        finishTask = nil
        await renderer.pause()
        await publishSnapshot()
    }

    public func resume() async throws {
        try await stateMachine.resume()
        let core = await stateMachine.snapshot
        if core.state == .playing {
            await renderer.play()
        }
        await publishSnapshot()
        if decodeFinished {
            scheduleDrainCompletion()
        }
    }

    @discardableResult
    public func seek(to position: TimeInterval) async throws -> UInt64 {
        guard let resources else { throw PlaybackCommandError.invalidTransition(state: snapshot.state, command: "seek") }
        let token = try await stateMachine.seek(to: position)
        currentToken = token
        await resources.blockingReader.interruptPendingReads()
        await cancelGenerationTasks()
        guard accepts(token) else { throw CancellationError() }
        await renderer.flush(at: position)
        resetSubtitlesForSeek(to: position)
        guard accepts(token) else { throw CancellationError() }
        await publishSnapshot()

        guard accepts(token) else { throw CancellationError() }
        let nativeGeneration = try await resources.executor.seek(to: position)
        guard accepts(token) else { throw CancellationError() }
        launchGeneration(
            token: token,
            executor: resources.executor,
            nativeGeneration: nativeGeneration
        )
        return token.generation
    }

    @discardableResult
    public func selectAudioTrack(index: Int) async throws -> UInt64 {
        guard let resources else { throw PlaybackCommandError.invalidTransition(state: snapshot.state, command: "selectAudioTrack") }
        let position = max(snapshot.position, await renderer.timelineTime)
        let token = try await stateMachine.seek(to: position)
        currentToken = token
        await resources.blockingReader.interruptPendingReads()
        await cancelGenerationTasks()
        guard accepts(token) else { throw CancellationError() }
        await renderer.flush(at: position)
        guard accepts(token) else { throw CancellationError() }
        let nativeGeneration = try await resources.executor.selectAudioTrack(
            index: index,
            at: position
        )
        guard accepts(token) else { throw CancellationError() }
        tracks = tracks.map {
            guard $0.kind == .audio else { return $0 }
            return PlaybackTrack(
                index: $0.index,
                kind: $0.kind,
                codecName: $0.codecName,
                language: $0.language,
                title: $0.title,
                isSelected: $0.index == index
            )
        }
        launchGeneration(
            token: token,
            executor: resources.executor,
            nativeGeneration: nativeGeneration
        )
        await publishSnapshot()
        return token.generation
    }

    public func selectSubtitleTrack(index: Int?) async throws {
        guard let resources else { throw PlaybackCommandError.invalidTransition(state: snapshot.state, command: "selectSubtitleTrack") }
        if let index, let cues = externalSubtitleCues[index] {
            try await resources.executor.selectSubtitleTrack(index: nil)
            selectedExternalSubtitleIndex = index
            subtitleCues.removeAll()
            subtitleTimeline.select(cues)
        } else {
            try await resources.executor.selectSubtitleTrack(index: index)
            selectedExternalSubtitleIndex = nil
            subtitleCues.removeAll()
            subtitleTimeline.select(index == nil ? nil : [])
        }
        tracks = tracks.map {
            guard $0.kind == .subtitle else { return $0 }
            return PlaybackTrack(
                index: $0.index,
                kind: $0.kind,
                codecName: $0.codecName,
                language: $0.language,
                title: $0.title,
                isSelected: $0.index == index
            )
        }
        await publishSnapshot()
    }

    public func registerExternalSubtitles(
        _ subtitles: [ExternalPlaybackSubtitle]
    ) async {
        tracks.removeAll { $0.kind == .subtitle && $0.index < 0 }
        externalSubtitleCues.removeAll()
        selectedExternalSubtitleIndex = nil

        for (offset, subtitle) in subtitles.enumerated() {
            let index = -offset - 1
            externalSubtitleCues[index] = subtitle.cues
            tracks.append(
                PlaybackTrack(
                    index: index,
                    kind: .subtitle,
                    codecName: subtitle.codecName,
                    language: subtitle.language,
                    title: subtitle.title,
                    isSelected: false
                )
            )
        }
        await publishSnapshot()
    }

    public func stop() async {
        currentToken = nil
        await stateMachine.stop()
        recoveryTask?.cancel()
        recoveryTask = nil
        reopenFile = nil
        sourceIdentity = nil
        let resources = self.resources
        self.resources = nil
        if let resources {
            resources.executor.cancel()
        }
        await cancelGenerationTasks()
        await renderer.stopRequestingMediaData(for: .video)
        await renderer.stopRequestingMediaData(for: .audio)
        await renderer.flush(at: 0)
        if let resources {
            await resources.executor.close()
            await resources.blockingReader.closeAndWait()
        }
        tracks = []
        duration = 0
        decoderMode = .none
        failure = nil
        subtitleCues = []
        subtitleTimeline.select(nil)
        externalSubtitleCues = [:]
        selectedExternalSubtitleIndex = nil
        await publishSnapshot()
    }

    private func openResources(file: any MediaReadableFile) async throws -> Resources {
        let cachedReader: CachedMediaReader
        do {
            cachedReader = try CachedMediaReader(
                file: file,
                pageSize: configuration.pageSize,
                capacityBytes: configuration.cacheCapacityBytes,
                diagnosticRecorder: diagnosticRecorder,
                diagnosticContext: diagnosticContext,
                identityProvider: identityProvider
            )
        } catch {
            await file.close()
            throw error
        }

        let blockingReader = BlockingMediaReader(
            reader: cachedReader,
            timeout: configuration.ioTimeout
        )
        var executor: FFmpegSessionExecutor?
        do {
            let openedExecutor = try await FFmpegSessionExecutor.open(source: blockingReader)
            executor = openedExecutor
            let metadata = try await openedExecutor.metadata()
            try await openedExecutor.prepareForDecoding(
                configuration: configuration.decodeConfiguration
            )
            let decoderStatus = try await openedExecutor.videoDecoderStatus()
            return Resources(
                executor: openedExecutor,
                blockingReader: blockingReader,
                metadata: metadata,
                decoderStatus: decoderStatus
            )
        } catch {
            executor?.cancel()
            if let executor { await executor.close() }
            await blockingReader.closeAndWait()
            throw error
        }
    }

    private func close(_ resources: Resources) async {
        resources.executor.cancel()
        await resources.executor.close()
        await resources.blockingReader.closeAndWait()
    }

    private func applyMetadata(
        _ metadata: MediaMetadata,
        decoderStatus: VideoDecoderStatus
    ) {
        duration = metadata.duration
        decoderMode = decoderStatus.mode
        tracks = metadata.tracks.map { track in
            PlaybackTrack(
                index: track.index,
                kind: track.kind,
                codecName: track.codecName,
                language: track.language,
                title: track.title,
                isSelected: track.isDefault
            )
        }
    }

    private func handleProducerFailure(
        _ error: Error,
        token: PlaybackOperationToken
    ) async {
        guard accepts(token) else { return }
        if let ffmpegError = error as? FFmpegError,
           ffmpegError.isInputOutputFailure,
           reopenFile != nil,
           recoveryTask == nil {
            recoveryTask = Task { [weak self] in
                await self?.recoverAfterReadFailure(token: token)
            }
            return
        }
        await fail(nativeFailure(error))
    }

    private func recoverAfterReadFailure(token failedToken: PlaybackOperationToken) async {
        guard accepts(failedToken),
              let reopenFile,
              let sourceIdentity else {
            recoveryTask = nil
            return
        }

        let position = max(snapshot.position, await renderer.timelineTime)
        let selectedAudioIndex = tracks.first {
            $0.kind == .audio && $0.isSelected
        }?.index
        let selectedEmbeddedSubtitleIndex = tracks.first {
            $0.kind == .subtitle && $0.index >= 0 && $0.isSelected
        }?.index
        let externalTracks = tracks.filter { $0.kind == .subtitle && $0.index < 0 }
        let selectedExternalIndex = selectedExternalSubtitleIndex

        let recoveryToken: PlaybackOperationToken
        do {
            recoveryToken = try await stateMachine.beginReconnection(at: position)
        } catch {
            recoveryTask = nil
            await fail(nativeFailure(error))
            return
        }
        currentToken = recoveryToken
        await renderer.pause()
        await publishSnapshot()

        let previousResources = resources
        resources = nil
        previousResources?.executor.cancel()
        await cancelGenerationTasks()
        if let previousResources {
            await close(previousResources)
        }

        let startedAt = ProcessInfo.processInfo.systemUptime
        let deadline = startedAt + configuration.maximumRetryDuration
        var attempt = 0
        while attempt < configuration.maximumRetryAttempts,
              ProcessInfo.processInfo.systemUptime <= deadline {
            guard accepts(recoveryToken), !Task.isCancelled else {
                recoveryTask = nil
                return
            }
            attempt += 1

            let outcome = await raceRecoveryAttempt(
                reopenFile: reopenFile,
                sourceIdentity: sourceIdentity,
                position: position,
                selectedAudioIndex: selectedAudioIndex,
                selectedEmbeddedSubtitleIndex: selectedEmbeddedSubtitleIndex,
                selectedExternalIndex: selectedExternalIndex,
                deadline: deadline
            )
            switch outcome {
            case .failed:
                await waitBeforeRecoveryRetry(
                    attempt: attempt,
                    deadline: deadline,
                    token: recoveryToken
                )
                continue
            case .timedOut:
                attempt = configuration.maximumRetryAttempts
                continue
            case .cancelled:
                recoveryTask = nil
                return
            case .fileChanged:
                recoveryTask = nil
                await fail(
                    PlaybackFailure(
                        boundary: .fileChanged,
                        message: "The media file changed while reconnecting"
                    )
                )
                return
            case let .opened(candidate):
                let opened = candidate.resources
                guard accepts(recoveryToken), !Task.isCancelled else {
                    await close(opened)
                    recoveryTask = nil
                    return
                }

                resources = opened
                applyRecoveredMetadata(
                    opened.metadata,
                    decoderStatus: opened.decoderStatus,
                    selectedAudioIndex: selectedAudioIndex,
                    selectedEmbeddedSubtitleIndex: selectedEmbeddedSubtitleIndex,
                    selectedExternalIndex: selectedExternalIndex,
                    externalTracks: externalTracks
                )
                guard await stateMachine.connectionRecovered(token: recoveryToken) else {
                    resources = nil
                    await close(opened)
                    recoveryTask = nil
                    return
                }
                await renderer.flush(at: position)
                guard accepts(recoveryToken), !Task.isCancelled else {
                    recoveryTask = nil
                    return
                }
                failure = nil
                resetSubtitlesForSeek(to: position)
                launchGeneration(
                    token: recoveryToken,
                    executor: opened.executor,
                    nativeGeneration: candidate.nativeGeneration
                )
                recoveryTask = nil
                await publishSnapshot()
                return
            }
        }

        guard accepts(recoveryToken), !Task.isCancelled else {
            recoveryTask = nil
            return
        }
        recoveryTask = nil
        await fail(
            PlaybackFailure(
                boundary: .networkRead,
                message: "The media source stopped responding"
            )
        )
    }

    private func raceRecoveryAttempt(
        reopenFile: @escaping MediaFileReopener,
        sourceIdentity: MediaFileIdentity,
        position: TimeInterval,
        selectedAudioIndex: Int?,
        selectedEmbeddedSubtitleIndex: Int?,
        selectedExternalIndex: Int?,
        deadline: TimeInterval
    ) async -> RecoveryAttemptOutcome {
        let gate = RecoveryAttemptGate()
        let operationTask = Task { [weak self] in
            let reopenedFile: any MediaReadableFile
            do {
                reopenedFile = try await reopenFile()
            } catch {
                _ = await gate.resolve(Task.isCancelled ? .cancelled : .failed)
                return
            }
            guard !Task.isCancelled else {
                await reopenedFile.close()
                _ = await gate.resolve(.cancelled)
                return
            }
            guard reopenedFile.identity == sourceIdentity else {
                await reopenedFile.close()
                _ = await gate.resolve(.fileChanged)
                return
            }
            guard let self else {
                await reopenedFile.close()
                _ = await gate.resolve(.cancelled)
                return
            }
            let outcome = await self.prepareRecoveryCandidate(
                reopenedFile: reopenedFile,
                position: position,
                selectedAudioIndex: selectedAudioIndex,
                selectedEmbeddedSubtitleIndex: selectedEmbeddedSubtitleIndex,
                selectedExternalIndex: selectedExternalIndex
            )
            guard await gate.resolve(outcome) else {
                await self.discardRecoveryOutcome(outcome)
                return
            }
        }
        let timeoutTask = Task {
            let remaining = max(0, deadline - ProcessInfo.processInfo.systemUptime)
            if remaining > 0 {
                try? await Task.sleep(for: .seconds(remaining))
            }
            guard !Task.isCancelled else { return }
            _ = await gate.resolve(.timedOut)
        }

        let outcome = await withTaskCancellationHandler {
            await gate.wait()
        } onCancel: {
            Task { _ = await gate.resolve(.cancelled) }
        }
        operationTask.cancel()
        timeoutTask.cancel()
        return outcome
    }

    private func prepareRecoveryCandidate(
        reopenedFile: any MediaReadableFile,
        position: TimeInterval,
        selectedAudioIndex: Int?,
        selectedEmbeddedSubtitleIndex: Int?,
        selectedExternalIndex: Int?
    ) async -> RecoveryAttemptOutcome {
        var openedResources: Resources?
        do {
            let opened = try await openResources(file: reopenedFile)
            openedResources = opened
            guard !Task.isCancelled else {
                await close(opened)
                return .cancelled
            }
            let nativeGeneration: UInt64
            if let selectedAudioIndex,
               opened.metadata.tracks.contains(where: {
                   $0.kind == .audio && $0.index == selectedAudioIndex
               }) {
                nativeGeneration = try await opened.executor.selectAudioTrack(
                    index: selectedAudioIndex,
                    at: position
                )
            } else {
                nativeGeneration = try await opened.executor.seek(to: position)
            }
            try await opened.executor.selectSubtitleTrack(
                index: selectedExternalIndex == nil ? selectedEmbeddedSubtitleIndex : nil
            )
            guard !Task.isCancelled else {
                await close(opened)
                return .cancelled
            }
            openedResources = nil
            return .opened(
                RecoveryCandidate(
                    resources: opened,
                    nativeGeneration: nativeGeneration
                )
            )
        } catch {
            if let openedResources {
                await close(openedResources)
            }
            return Task.isCancelled ? .cancelled : .failed
        }
    }

    private func discardRecoveryOutcome(_ outcome: RecoveryAttemptOutcome) async {
        guard case let .opened(candidate) = outcome else { return }
        await close(candidate.resources)
    }

    private func waitBeforeRecoveryRetry(
        attempt: Int,
        deadline: TimeInterval,
        token: PlaybackOperationToken
    ) async {
        guard attempt < configuration.maximumRetryAttempts,
              accepts(token),
              ProcessInfo.processInfo.systemUptime < deadline else {
            return
        }
        try? await Task.sleep(for: .milliseconds(100))
    }

    private func applyRecoveredMetadata(
        _ metadata: MediaMetadata,
        decoderStatus: VideoDecoderStatus,
        selectedAudioIndex: Int?,
        selectedEmbeddedSubtitleIndex: Int?,
        selectedExternalIndex: Int?,
        externalTracks: [PlaybackTrack]
    ) {
        duration = metadata.duration
        decoderMode = decoderStatus.mode
        tracks = metadata.tracks.map { track in
            let isSelected: Bool
            switch track.kind {
            case .audio:
                isSelected = selectedAudioIndex.map { $0 == track.index } ?? track.isDefault
            case .subtitle:
                isSelected = selectedExternalIndex == nil &&
                    selectedEmbeddedSubtitleIndex == track.index
            default:
                isSelected = track.isDefault
            }
            return PlaybackTrack(
                index: track.index,
                kind: track.kind,
                codecName: track.codecName,
                language: track.language,
                title: track.title,
                isSelected: isSelected
            )
        }
        tracks.append(contentsOf: externalTracks.map { track in
            PlaybackTrack(
                index: track.index,
                kind: track.kind,
                codecName: track.codecName,
                language: track.language,
                title: track.title,
                isSelected: track.index == selectedExternalIndex
            )
        })
    }

    private func launchGeneration(
        token: PlaybackOperationToken,
        executor: FFmpegSessionExecutor,
        nativeGeneration: UInt64
    ) {
        let videoQueue = BoundedMediaQueue<DecodedVideoSample>(
            limits: configuration.videoQueueLimits
        )
        let audioQueue = BoundedMediaQueue<DecodedAudioSample>(
            limits: configuration.audioQueueLimits
        )
        self.videoQueue = videoQueue
        self.audioQueue = audioQueue
        finishedLanes = []
        decodeFinished = false
        finishTask?.cancel()
        finishTask = nil

        videoConsumerTask = Task { [weak self] in
            await self?.consumeVideo(queue: videoQueue, token: token)
        }
        audioConsumerTask = Task { [weak self] in
            await self?.consumeAudio(queue: audioQueue, token: token)
        }
        producerTask = Task { [weak self] in
            await self?.produce(
                executor: executor,
                videoQueue: videoQueue,
                audioQueue: audioQueue,
                token: token,
                nativeGeneration: nativeGeneration
            )
        }
        timelineTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled else { return }
                guard await self?.refreshTimeline(token: token) == true else { return }
            }
        }
    }

    private func produce(
        executor: FFmpegSessionExecutor,
        videoQueue: BoundedMediaQueue<DecodedVideoSample>,
        audioQueue: BoundedMediaQueue<DecodedAudioSample>,
        token: PlaybackOperationToken,
        nativeGeneration: UInt64
    ) async {
        do {
            while !Task.isCancelled, let sample = try await executor.readNextSample() {
                guard accepts(token) else { return }
                try await refreshDecoderStatusIfNeeded(executor: executor, token: token)
                guard accepts(token) else { return }
                switch sample {
                case let .video(video):
                    guard video.generation == nativeGeneration else { continue }
                    let video = video.withGeneration(token.generation)
                    try await videoQueue.enqueue(
                        video,
                        ownedByteCount: CVPixelBufferGetDataSize(video.pixelBuffer),
                        duration: video.duration
                    )
                case let .audio(audio):
                    guard audio.generation == nativeGeneration else { continue }
                    let audio = audio.withGeneration(token.generation)
                    try await audioQueue.enqueue(
                        audio,
                        ownedByteCount: audio.data.count,
                        duration: audio.duration
                    )
                case let .subtitle(subtitle):
                    guard subtitle.generation == nativeGeneration else { continue }
                    let subtitle = subtitle.withGeneration(token.generation)
                    receiveSubtitle(subtitle, token: token)
                }
            }
            guard accepts(token) else { return }
            await videoQueue.finish()
            await audioQueue.finish()
        } catch is CancellationError {
            return
        } catch BoundedMediaQueueError.closed {
            return
        } catch {
            guard accepts(token) else { return }
            await handleProducerFailure(error, token: token)
        }
    }

    private func consumeVideo(
        queue: BoundedMediaQueue<DecodedVideoSample>,
        token: PlaybackOperationToken
    ) async {
        do {
            while let sample = try await queue.dequeue() {
                guard accepts(token), sample.generation == token.generation else { continue }
                try await enqueueVideo(sample, token: token)
            }
            await consumerFinished(lane: .video, token: token)
        } catch is CancellationError {
            return
        } catch {
            guard accepts(token) else { return }
            await fail(
                PlaybackFailure(boundary: .render, message: "Unable to render video sample")
            )
        }
    }

    private func refreshDecoderStatusIfNeeded(
        executor: FFmpegSessionExecutor,
        token: PlaybackOperationToken
    ) async throws {
        guard decoderMode == .videoToolbox else { return }
        let status = try await executor.videoDecoderStatus()
        guard accepts(token), status.mode != decoderMode else { return }
        decoderMode = status.mode
        await publishSnapshot()
    }

    private func consumeAudio(
        queue: BoundedMediaQueue<DecodedAudioSample>,
        token: PlaybackOperationToken
    ) async {
        do {
            while let sample = try await queue.dequeue() {
                guard accepts(token), sample.generation == token.generation else { continue }
                try await enqueueAudio(sample, token: token)
            }
            await consumerFinished(lane: .audio, token: token)
        } catch is CancellationError {
            return
        } catch {
            guard accepts(token) else { return }
            await fail(
                PlaybackFailure(boundary: .render, message: "Unable to render audio sample")
            )
        }
    }

    private func enqueueVideo(
        _ sample: DecodedVideoSample,
        token: PlaybackOperationToken
    ) async throws {
        while accepts(token) {
            if try await renderer.enqueueVideo(sample) {
                await sampleWasEnqueued(token: token)
                return
            }
            try await renderer.waitUntilReady(
                for: .video,
                requiredDuration: sample.duration
            )
        }
        throw CancellationError()
    }

    private func enqueueAudio(
        _ sample: DecodedAudioSample,
        token: PlaybackOperationToken
    ) async throws {
        while accepts(token) {
            if try await renderer.enqueueAudio(sample) {
                await sampleWasEnqueued(token: token)
                return
            }
            try await renderer.waitUntilReady(
                for: .audio,
                requiredDuration: sample.duration
            )
        }
        throw CancellationError()
    }

    private func sampleWasEnqueued(token: PlaybackOperationToken) async {
        await completeBufferingIfReady(token: token)
    }

    private func completeBufferingIfReady(token: PlaybackOperationToken) async {
        guard accepts(token) else { return }
        let core = await stateMachine.snapshot
        guard case .buffering = core.state else { return }
        let renderState = await renderer.state
        let hasAudio = tracks.contains { $0.kind == .audio && $0.isSelected }
        let videoReady = finishedLanes.contains(.video) ||
            renderState.pendingVideoDuration >= configuration.startupVideoDuration
        let audioReady = !hasAudio || finishedLanes.contains(.audio) ||
            renderState.pendingAudioDuration >= configuration.startupAudioDuration
        guard videoReady, audioReady else {
            return
        }
        guard await stateMachine.bufferingCompleted(token: token) else { return }
        let updated = await stateMachine.snapshot
        if updated.intendsToPlay {
            await renderer.play(at: updated.position)
        } else {
            await renderer.pause()
        }
        await publishSnapshot()
    }

    private func receiveSubtitle(
        _ sample: DecodedSubtitleSample,
        token: PlaybackOperationToken
    ) {
        guard accepts(token), selectedExternalSubtitleIndex == nil,
              !sample.text.isEmpty else { return }
        subtitleCues.append(
            SubtitleCue(
                startTime: sample.presentationTime,
                endTime: sample.presentationTime + sample.duration,
                text: sample.text
            )
        )
        subtitleTimeline.select(subtitleCues)
    }

    private func resetSubtitlesForSeek(to position: TimeInterval) {
        subtitleTimeline.seek(to: position)
        if let selectedExternalSubtitleIndex,
           let cues = externalSubtitleCues[selectedExternalSubtitleIndex] {
            subtitleTimeline.select(cues)
            return
        }
        subtitleCues.removeAll()
        let hasSelectedEmbeddedTrack = tracks.contains {
            $0.kind == .subtitle && $0.index >= 0 && $0.isSelected
        }
        subtitleTimeline.select(hasSelectedEmbeddedTrack ? [] : nil)
    }

    private func refreshTimeline(token: PlaybackOperationToken) async -> Bool {
        guard accepts(token) else { return false }
        let core = await stateMachine.snapshot
        switch core.state {
        case .idle, .ended, .failed:
            return false
        default:
            break
        }
        let renderState = await renderer.state
        let position = max(core.position, renderState.currentTime)
        if core.state == .playing, !decodeFinished {
            let hasAudio = tracks.contains { $0.kind == .audio && $0.isSelected }
            let videoUnderrun = !finishedLanes.contains(.video) &&
                renderState.pendingVideoDuration < configuration.startupVideoDuration
            let audioUnderrun = hasAudio && !finishedLanes.contains(.audio) &&
                renderState.pendingAudioDuration < configuration.startupAudioDuration
            if videoUnderrun || audioUnderrun,
               await stateMachine.beginRebuffering(token: token, at: position) {
                await renderer.freezeForUnderrun()
                await publishSnapshot()
                return true
            }
        }
        let subtitle = subtitleTimeline.activeCues(at: position)
            .map(\.text)
            .joined(separator: "\n")
        let subtitleText = subtitle.isEmpty ? nil : subtitle
        if abs(snapshot.position - position) >= 0.05 || snapshot.subtitleText != subtitleText {
            await publishSnapshot()
        }
        return true
    }

    private func consumerFinished(
        lane: RenderLane,
        token: PlaybackOperationToken
    ) async {
        guard accepts(token) else { return }
        finishedLanes.insert(lane)
        await completeBufferingIfReady(token: token)
        guard finishedLanes.count == 2 else { return }
        decodeFinished = true
        scheduleDrainCompletion()
    }

    private func scheduleDrainCompletion() {
        guard finishTask == nil, let token = currentToken else { return }
        finishTask = Task { [weak self] in
            guard let self else { return }
            let core = await self.stateMachine.snapshot
            guard core.intendsToPlay else {
                await self.clearFinishTask(token: token)
                return
            }
            let renderState = await self.renderer.state
            let remaining = max(
                renderState.pendingVideoDuration,
                renderState.pendingAudioDuration
            )
            if remaining > 0 {
                try? await Task.sleep(for: .seconds(remaining))
            }
            await self.completePlayback(token: token)
        }
    }

    private func clearFinishTask(token: PlaybackOperationToken) {
        guard accepts(token) else { return }
        finishTask = nil
    }

    private func completePlayback(token: PlaybackOperationToken) async {
        guard !Task.isCancelled, accepts(token) else { return }
        let core = await stateMachine.snapshot
        guard core.intendsToPlay else {
            finishTask = nil
            return
        }
        _ = await stateMachine.playbackEnded(token: token, position: duration)
        await renderer.pause()
        finishTask = nil
        await publishSnapshot()
    }

    private func cancelGenerationTasks() async {
        let producerTask = self.producerTask
        let videoConsumerTask = self.videoConsumerTask
        let audioConsumerTask = self.audioConsumerTask
        let timelineTask = self.timelineTask
        let finishTask = self.finishTask
        let videoQueue = self.videoQueue
        let audioQueue = self.audioQueue

        self.producerTask = nil
        self.videoConsumerTask = nil
        self.audioConsumerTask = nil
        self.timelineTask = nil
        self.finishTask = nil
        self.videoQueue = nil
        self.audioQueue = nil
        finishedLanes = []
        decodeFinished = false

        producerTask?.cancel()
        videoConsumerTask?.cancel()
        audioConsumerTask?.cancel()
        timelineTask?.cancel()
        finishTask?.cancel()
        if let videoQueue { await videoQueue.close() }
        if let audioQueue { await audioQueue.close() }
    }

    private func fail(_ failure: PlaybackFailure) async {
        self.failure = failure
        await stateMachine.fail(failure.message)
        currentToken = nil
        recoveryTask?.cancel()
        recoveryTask = nil
        let activeResources = resources
        resources = nil
        activeResources?.executor.cancel()
        await cancelGenerationTasks()
        await renderer.stopRequestingMediaData(for: .video)
        await renderer.stopRequestingMediaData(for: .audio)
        await renderer.pause()
        if let activeResources {
            await close(activeResources)
        }
        await publishSnapshot()
    }

    private func publishSnapshot() async {
        let core = await stateMachine.snapshot
        let renderState = await renderer.state
        let position = max(core.position, renderState.currentTime)
        let subtitle = subtitleTimeline.activeCues(at: position)
            .map(\.text)
            .joined(separator: "\n")
        let updated = PlaybackCoordinatorSnapshot(
            sessionID: core.sessionID,
            generation: core.generation,
            state: core.state,
            intendsToPlay: core.intendsToPlay,
            position: position,
            duration: duration,
            videoDecoderMode: decoderMode,
            tracks: tracks,
            subtitleText: subtitle.isEmpty ? nil : subtitle,
            failure: failure
        )
        snapshot = updated
        snapshotContinuation.yield(updated)
    }

    private func accepts(_ token: PlaybackOperationToken) -> Bool {
        currentToken == token
    }

    private func nativeFailure(_ error: Error) -> PlaybackFailure {
        if case let FFmpegError.native(code, message) = error {
            return PlaybackFailure(
                boundary: .demux,
                message: message,
                diagnosticCode: code
            )
        }
        if error is BlockingMediaReaderError {
            return PlaybackFailure(
                boundary: .networkRead,
                message: "The media source stopped responding"
            )
        }
        return PlaybackFailure(
            boundary: .demux,
            message: "Playback could not continue"
        )
    }
}

private extension DecodedVideoSample {
    func withGeneration(_ generation: UInt64) -> DecodedVideoSample {
        DecodedVideoSample(
            pixelBuffer: pixelBuffer,
            presentationTime: presentationTime,
            duration: duration,
            streamIndex: streamIndex,
            generation: generation
        )
    }
}

private extension DecodedAudioSample {
    func withGeneration(_ generation: UInt64) -> DecodedAudioSample {
        DecodedAudioSample(
            data: data,
            presentationTime: presentationTime,
            duration: duration,
            sampleCount: sampleCount,
            sampleRate: sampleRate,
            channelCount: channelCount,
            streamIndex: streamIndex,
            generation: generation
        )
    }
}

private extension DecodedSubtitleSample {
    func withGeneration(_ generation: UInt64) -> DecodedSubtitleSample {
        DecodedSubtitleSample(
            text: text,
            presentationTime: presentationTime,
            duration: duration,
            streamIndex: streamIndex,
            generation: generation
        )
    }
}
