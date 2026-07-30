import FFmpegKit
import Foundation
import MediaSourceKit
import PlaybackCore
import RenderKit
import SwiftUI

protocol PlaybackCoordinatorControlling: Sendable {
    var snapshots: AsyncStream<PlaybackCoordinatorSnapshot> { get }

    func start(file: any MediaReadableFile) async throws
    func pause() async throws
    func resume() async throws
    func seek(to position: TimeInterval) async throws -> UInt64
    func selectAudioTrack(index: Int) async throws -> UInt64
    func selectSubtitleTrack(index: Int?) async throws
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
    private var snapshotTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    private var hasStarted = false

    init(
        item: MediaSourceItem,
        source: any MediaSource,
        renderer: SampleBufferRenderer? = nil,
        coordinator: (any PlaybackCoordinatorControlling)? = nil
    ) {
        let renderer = renderer ?? SampleBufferRenderer()
        self.item = item
        self.source = source
        self.renderer = renderer
        self.coordinator = coordinator ?? PlaybackCoordinator(renderer: renderer)
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
        consumeSnapshots()
        updateProgress()

        do {
            let file = try await source.open(file: item.path)
            guard hasStarted, !Task.isCancelled else {
                await file.close()
                if hasStarted {
                    await stop()
                }
                return
            }
            try await coordinator.start(file: file)
        } catch is CancellationError {
            await stop()
        } catch {
            await coordinator.stop()
            publishFailure(error)
        }
    }

    func stop() async {
        guard hasStarted else { return }
        hasStarted = false
        snapshotTask?.cancel()
        progressTask?.cancel()
        snapshotTask = nil
        progressTask = nil
        await coordinator.stop()
        snapshot = .idle
        timelinePosition = 0
    }

    func togglePlayback() async {
        do {
            if snapshot.intendsToPlay {
                try await coordinator.pause()
            } else {
                try await coordinator.resume()
            }
        } catch {
            publishFailure(error)
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
        isScrubbing = false
        timelinePosition = target
        do {
            _ = try await coordinator.seek(to: target)
        } catch {
            publishFailure(error)
        }
    }

    func selectAudioTrack(_ index: Int) async {
        do {
            _ = try await coordinator.selectAudioTrack(index: index)
        } catch {
            publishFailure(error)
        }
    }

    func selectSubtitleTrack(_ index: Int?) async {
        do {
            try await coordinator.selectSubtitleTrack(index: index)
        } catch {
            publishFailure(error)
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

    private func updateProgress() {
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !self.isScrubbing {
                    self.timelinePosition = max(self.snapshot.position, self.renderer.timelineTime)
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    private func receive(_ snapshot: PlaybackCoordinatorSnapshot) {
        self.snapshot = snapshot
        if !isScrubbing {
            timelinePosition = snapshot.position
        }
    }

    private func clamped(_ position: TimeInterval) -> TimeInterval {
        guard position.isFinite else { return 0 }
        return min(max(position, 0), max(snapshot.duration, 0))
    }

    private func publishFailure(_ error: Error) {
        let message = String(describing: error)
        snapshot = PlaybackCoordinatorSnapshot(
            sessionID: snapshot.sessionID,
            generation: snapshot.generation,
            state: .failed(message),
            intendsToPlay: false,
            position: timelinePosition,
            duration: snapshot.duration,
            videoDecoderMode: snapshot.videoDecoderMode,
            tracks: snapshot.tracks,
            subtitleText: snapshot.subtitleText,
            failure: PlaybackFailure(boundary: .sourceOpen, message: message)
        )
    }
}
