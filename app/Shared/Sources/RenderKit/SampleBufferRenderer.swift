import AVFoundation
import CoreMedia
import FFmpegKit
import Foundation

@MainActor
public final class SampleBufferRenderer {
    public let displayLayer: AVSampleBufferDisplayLayer
    public let audioRenderer: AVSampleBufferAudioRenderer
    public let maximumPendingDuration: TimeInterval

    private let synchronizer: AVSampleBufferRenderSynchronizer
    private let videoRenderer: any AVQueuedSampleBufferRendering
    private let readinessQueue = DispatchQueue(
        label: "dev.pierplayer.render.readiness",
        qos: .userInitiated
    )
    private var lastVideoEndTime: TimeInterval = 0
    private var lastAudioEndTime: TimeInterval = 0

    public init(maximumPendingDuration: TimeInterval = 2) {
        precondition(maximumPendingDuration.isFinite && maximumPendingDuration > 0)

        let displayLayer = AVSampleBufferDisplayLayer()
        let audioRenderer = AVSampleBufferAudioRenderer()
        let synchronizer = AVSampleBufferRenderSynchronizer()
        let videoRenderer: any AVQueuedSampleBufferRendering
        if #available(macOS 15.0, *) {
            videoRenderer = displayLayer.sampleBufferRenderer
        } else {
            videoRenderer = displayLayer
        }

        self.displayLayer = displayLayer
        self.audioRenderer = audioRenderer
        self.synchronizer = synchronizer
        self.videoRenderer = videoRenderer
        self.maximumPendingDuration = maximumPendingDuration

        synchronizer.addRenderer(videoRenderer)
        synchronizer.addRenderer(audioRenderer)
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
        synchronizer.setRate(0, time: .zero)
    }

    public var attachedRendererCount: Int {
        synchronizer.renderers.count
    }

    public var state: RenderState {
        let currentTime = timelineTime
        return RenderState(
            rate: synchronizer.rate,
            currentTime: currentTime,
            pendingVideoDuration: max(0, lastVideoEndTime - currentTime),
            pendingAudioDuration: max(0, lastAudioEndTime - currentTime)
        )
    }

    public var timelineTime: TimeInterval {
        let time = synchronizer.currentTime()
        return time.isNumeric ? max(0, time.seconds) : 0
    }

    @discardableResult
    public func enqueueVideo(_ sample: CMSampleBuffer) -> Bool {
        guard canEnqueue(sample, lastEndTime: lastVideoEndTime),
              videoRenderer.isReadyForMoreMediaData else {
            return false
        }
        videoRenderer.enqueue(sample)
        lastVideoEndTime = max(lastVideoEndTime, endTime(of: sample))
        return true
    }

    @discardableResult
    public func enqueueVideo(_ sample: DecodedVideoSample) throws -> Bool {
        try enqueueVideo(MediaSampleFactory.videoSample(from: sample))
    }

    @discardableResult
    public func enqueueAudio(_ sample: CMSampleBuffer) -> Bool {
        guard canEnqueue(sample, lastEndTime: lastAudioEndTime),
              audioRenderer.isReadyForMoreMediaData else {
            return false
        }
        audioRenderer.enqueue(sample)
        lastAudioEndTime = max(lastAudioEndTime, endTime(of: sample))
        return true
    }

    @discardableResult
    public func enqueueAudio(_ sample: DecodedAudioSample) throws -> Bool {
        try enqueueAudio(MediaSampleFactory.audioSample(from: sample))
    }

    public func play(at time: TimeInterval? = nil) {
        if let time {
            synchronizer.setRate(1, time: mediaTime(time))
        } else {
            synchronizer.rate = 1
        }
    }

    public func pause() {
        synchronizer.rate = 0
    }

    public func freezeForUnderrun() {
        pause()
    }

    @discardableResult
    public func startWhenReady(
        minimumVideoDuration: TimeInterval,
        minimumAudioDuration: TimeInterval,
        hasAudio: Bool
    ) -> Bool {
        let snapshot = state
        guard snapshot.pendingVideoDuration >= minimumVideoDuration,
              !hasAudio || snapshot.pendingAudioDuration >= minimumAudioDuration else {
            return false
        }
        play()
        return true
    }

    public func flush(at time: TimeInterval) {
        synchronizer.setRate(0, time: mediaTime(time))
        videoRenderer.flush()
        audioRenderer.flush()
        lastVideoEndTime = time
        lastAudioEndTime = time
    }

    public func requestMediaDataWhenReady(
        for lane: RenderLane,
        on queue: DispatchQueue,
        using block: @escaping @Sendable () -> Void
    ) {
        renderer(for: lane).requestMediaDataWhenReady(on: queue, using: block)
    }

    public func stopRequestingMediaData(for lane: RenderLane) {
        renderer(for: lane).stopRequestingMediaData()
    }

    public func isReady(for lane: RenderLane) -> Bool {
        renderer(for: lane).isReadyForMoreMediaData
    }

    public func waitUntilReady(for lane: RenderLane) async throws {
        if isReady(for: lane) { return }
        let waiter = RendererReadinessWaiter()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiter.install(continuation)
                renderer(for: lane).requestMediaDataWhenReady(
                    on: readinessQueue
                ) {
                    waiter.resume()
                }
            }
        } onCancel: {
            waiter.resume()
        }
        stopRequestingMediaData(for: lane)
        try Task.checkCancellation()
    }

    private func renderer(
        for lane: RenderLane
    ) -> any AVQueuedSampleBufferRendering {
        switch lane {
        case .video: videoRenderer
        case .audio: audioRenderer
        }
    }

    private func canEnqueue(
        _ sample: CMSampleBuffer,
        lastEndTime: TimeInterval
    ) -> Bool {
        let duration = CMSampleBufferGetDuration(sample).seconds
        guard duration.isFinite, duration > 0 else { return false }
        let pendingDuration = max(0, lastEndTime - timelineTime)
        return pendingDuration + duration <= maximumPendingDuration
    }

    private func endTime(of sample: CMSampleBuffer) -> TimeInterval {
        CMSampleBufferGetPresentationTimeStamp(sample).seconds +
            CMSampleBufferGetDuration(sample).seconds
    }

    private func mediaTime(_ seconds: TimeInterval) -> CMTime {
        CMTime(
            seconds: seconds.isFinite ? max(0, seconds) : 0,
            preferredTimescale: 1_000_000
        )
    }
}

private final class RendererReadinessWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var wasResumed = false

    func install(_ continuation: CheckedContinuation<Void, Never>) {
        let resumeImmediately = lock.withLock {
            if wasResumed { return true }
            self.continuation = continuation
            return false
        }
        if resumeImmediately {
            continuation.resume()
        }
    }

    func resume() {
        let continuation = lock.withLock {
            guard !wasResumed else { return nil as CheckedContinuation<Void, Never>? }
            wasResumed = true
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume()
    }
}
