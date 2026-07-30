import CoreVideo
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

        init(
            executor: FFmpegSessionExecutor,
            blockingReader: BlockingMediaReader,
            metadata: MediaMetadata
        ) {
            self.executor = executor
            self.blockingReader = blockingReader
            self.metadata = metadata
        }
    }

    public private(set) var snapshot: PlaybackCoordinatorSnapshot = .idle
    public nonisolated let snapshots: AsyncStream<PlaybackCoordinatorSnapshot>

    private let snapshotContinuation: AsyncStream<PlaybackCoordinatorSnapshot>.Continuation
    private let renderer: SampleBufferRenderer
    private let configuration: PlaybackCoordinatorConfiguration
    private let stateMachine = PlaybackSession()

    private var resources: Resources?
    private var currentToken: PlaybackOperationToken?
    private var tracks: [PlaybackTrack] = []
    private var duration: TimeInterval = 0
    private var decoderMode: VideoDecoderMode = .none
    private var failure: PlaybackFailure?
    private var subtitleCues: [SubtitleCue] = []
    private var subtitleTimeline = SubtitleTimeline()

    private var videoQueue: BoundedMediaQueue<DecodedVideoSample>?
    private var audioQueue: BoundedMediaQueue<DecodedAudioSample>?
    private var producerTask: Task<Void, Never>?
    private var videoConsumerTask: Task<Void, Never>?
    private var audioConsumerTask: Task<Void, Never>?
    private var finishTask: Task<Void, Never>?
    private var finishedConsumerCount = 0
    private var decodeFinished = false

    @MainActor
    public init(
        renderer: SampleBufferRenderer,
        configuration: PlaybackCoordinatorConfiguration = .default
    ) {
        let stream = AsyncStream<PlaybackCoordinatorSnapshot>.makeStream(
            bufferingPolicy: .bufferingNewest(32)
        )
        self.snapshots = stream.stream
        self.snapshotContinuation = stream.continuation
        self.renderer = renderer
        self.configuration = configuration
        stream.continuation.yield(.idle)
    }

    public func start(file: any MediaReadableFile) async throws {
        let token = try await stateMachine.open()
        currentToken = token
        failure = nil
        await publishSnapshot()

        let cachedReader: CachedMediaReader
        do {
            cachedReader = try CachedMediaReader(
                file: file,
                pageSize: configuration.pageSize,
                capacityBytes: configuration.cacheCapacityBytes
            )
        } catch {
            await fail(
                PlaybackFailure(boundary: .sourceOpen, message: "Unable to create media cache")
            )
            await file.close()
            throw error
        }
        let blockingReader = BlockingMediaReader(
            reader: cachedReader,
            timeout: configuration.ioTimeout
        )

        do {
            _ = await stateMachine.connectionEstablished(token: token)
            await publishSnapshot()
            let executor = try await FFmpegSessionExecutor.open(source: blockingReader)
            let metadata = try await executor.metadata()
            try await executor.prepareForDecoding()
            let status = try await executor.videoDecoderStatus()
            guard accepts(token) else {
                await executor.close()
                await blockingReader.closeAndWait()
                throw CancellationError()
            }

            resources = Resources(
                executor: executor,
                blockingReader: blockingReader,
                metadata: metadata
            )
            duration = metadata.duration
            decoderMode = status.mode
            tracks = metadata.tracks.map {
                PlaybackTrack(
                    index: $0.index,
                    kind: $0.kind,
                    codecName: $0.codecName,
                    language: $0.language,
                    title: $0.title,
                    isSelected: $0.isDefault
                )
            }
            _ = await stateMachine.mediaOpened(token: token)
            await publishSnapshot()
            launchGeneration(token: token, executor: executor)
        } catch {
            await blockingReader.closeAndWait()
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
        await cancelGenerationTasks()
        await renderer.flush(at: position)
        await publishSnapshot()

        _ = try await resources.executor.seek(to: position)
        guard accepts(token) else { throw CancellationError() }
        launchGeneration(token: token, executor: resources.executor)
        return token.generation
    }

    @discardableResult
    public func selectAudioTrack(index: Int) async throws -> UInt64 {
        guard let resources else { throw PlaybackCommandError.invalidTransition(state: snapshot.state, command: "selectAudioTrack") }
        let position = max(snapshot.position, await renderer.timelineTime)
        let token = try await stateMachine.seek(to: position)
        currentToken = token
        await cancelGenerationTasks()
        await renderer.flush(at: position)
        _ = try await resources.executor.selectAudioTrack(index: index, at: position)
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
        launchGeneration(token: token, executor: resources.executor)
        await publishSnapshot()
        return token.generation
    }

    public func selectSubtitleTrack(index: Int?) async throws {
        guard let resources else { throw PlaybackCommandError.invalidTransition(state: snapshot.state, command: "selectSubtitleTrack") }
        try await resources.executor.selectSubtitleTrack(index: index)
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
        subtitleCues.removeAll()
        subtitleTimeline.select(index == nil ? nil : [])
        await publishSnapshot()
    }

    public func stop() async {
        currentToken = nil
        await stateMachine.stop()
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
        await publishSnapshot()
    }

    private func launchGeneration(
        token: PlaybackOperationToken,
        executor: FFmpegSessionExecutor
    ) {
        let videoQueue = BoundedMediaQueue<DecodedVideoSample>(
            limits: configuration.videoQueueLimits
        )
        let audioQueue = BoundedMediaQueue<DecodedAudioSample>(
            limits: configuration.audioQueueLimits
        )
        self.videoQueue = videoQueue
        self.audioQueue = audioQueue
        finishedConsumerCount = 0
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
                token: token
            )
        }
    }

    private func produce(
        executor: FFmpegSessionExecutor,
        videoQueue: BoundedMediaQueue<DecodedVideoSample>,
        audioQueue: BoundedMediaQueue<DecodedAudioSample>,
        token: PlaybackOperationToken
    ) async {
        do {
            while !Task.isCancelled, let sample = try await executor.readNextSample() {
                guard accepts(token) else { return }
                switch sample {
                case let .video(video):
                    guard video.generation == token.generation else { continue }
                    try await videoQueue.enqueue(
                        video,
                        ownedByteCount: CVPixelBufferGetDataSize(video.pixelBuffer),
                        duration: video.duration
                    )
                case let .audio(audio):
                    guard audio.generation == token.generation else { continue }
                    try await audioQueue.enqueue(
                        audio,
                        ownedByteCount: audio.data.count,
                        duration: audio.duration
                    )
                case let .subtitle(subtitle):
                    guard subtitle.generation == token.generation else { continue }
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
            await fail(nativeFailure(error))
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
            consumerFinished(token: token)
        } catch is CancellationError {
            return
        } catch {
            guard accepts(token) else { return }
            await fail(
                PlaybackFailure(boundary: .render, message: "Unable to render video sample")
            )
        }
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
            consumerFinished(token: token)
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
            try await renderer.waitUntilReady(for: .video)
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
            try await renderer.waitUntilReady(for: .audio)
        }
        throw CancellationError()
    }

    private func sampleWasEnqueued(token: PlaybackOperationToken) async {
        guard accepts(token) else { return }
        let core = await stateMachine.snapshot
        guard case .buffering = core.state else { return }
        let renderState = await renderer.state
        let hasAudio = tracks.contains { $0.kind == .audio && $0.isSelected }
        guard renderState.pendingVideoDuration >= configuration.startupVideoDuration,
              !hasAudio || renderState.pendingAudioDuration >= configuration.startupAudioDuration else {
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
        guard accepts(token), !sample.text.isEmpty else { return }
        subtitleCues.append(
            SubtitleCue(
                startTime: sample.presentationTime,
                endTime: sample.presentationTime + sample.duration,
                text: sample.text
            )
        )
        subtitleTimeline.select(subtitleCues)
    }

    private func consumerFinished(token: PlaybackOperationToken) {
        guard accepts(token) else { return }
        finishedConsumerCount += 1
        guard finishedConsumerCount == 2 else { return }
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
        producerTask?.cancel()
        videoConsumerTask?.cancel()
        audioConsumerTask?.cancel()
        finishTask?.cancel()
        producerTask = nil
        videoConsumerTask = nil
        audioConsumerTask = nil
        finishTask = nil
        if let videoQueue { await videoQueue.close() }
        if let audioQueue { await audioQueue.close() }
        videoQueue = nil
        audioQueue = nil
        finishedConsumerCount = 0
        decodeFinished = false
    }

    private func fail(_ failure: PlaybackFailure) async {
        self.failure = failure
        await stateMachine.fail(failure.message)
        await renderer.pause()
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
