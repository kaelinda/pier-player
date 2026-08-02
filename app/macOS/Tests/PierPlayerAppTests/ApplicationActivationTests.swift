import AppKit
import Testing
@testable import PierPlayerApp

@MainActor
@Test func applicationUsesRegularActivationPolicy() {
    ApplicationActivation.activate()

    #expect(NSApplication.shared.activationPolicy() == .regular)
}

@MainActor
@Test func applicationActivatesAfterFinishingLaunch() {
    var activationCount = 0
    let delegate = AppDelegate {
        activationCount += 1
    }

    delegate.applicationDidFinishLaunching(
        Notification(name: NSApplication.didFinishLaunchingNotification)
    )

    #expect(activationCount == 1)
}

@MainActor
@Test func inactiveFlushesPlaybackBeforeDiagnostics() async {
    let playback = ActivePlaybackLifecycle()
    var events: [String] = []
    _ = playback.register(
        sourceID: UUID(),
        stop: {},
        forcePersist: { events.append("playback") }
    )
    let lifecycle = ApplicationLifecycleCoordinator(
        activePlayback: playback,
        flushTimeout: .seconds(1)
    )

    await lifecycle.sceneDidBecomeInactive {
        events.append("diagnostics")
    }

    #expect(events == ["playback", "diagnostics"])
}

@MainActor
@Test func noActivePlaybackContinuesToDiagnosticsImmediately() async {
    let lifecycle = ApplicationLifecycleCoordinator(
        activePlayback: ActivePlaybackLifecycle(),
        flushTimeout: .seconds(1)
    )
    var didFlushDiagnostics = false

    await lifecycle.sceneDidBecomeInactive {
        didFlushDiagnostics = true
    }

    #expect(didFlushDiagnostics)
}

@MainActor
@Test func hungPlaybackFlushTimesOutBeforeStoppingDiagnostics() async {
    let playback = ActivePlaybackLifecycle()
    let blocker = LifecycleFlushBlocker()
    _ = playback.register(
        sourceID: UUID(),
        stop: {},
        forcePersist: { await blocker.wait() }
    )
    let lifecycle = ApplicationLifecycleCoordinator(
        activePlayback: playback,
        flushTimeout: .milliseconds(10)
    )
    var didStopDiagnostics = false

    await lifecycle.prepareForTermination {
        didStopDiagnostics = true
    }

    #expect(didStopDiagnostics)
    await blocker.release()
}

@MainActor
@Test func concurrentInactiveAndTerminationShareOnePlaybackFlush() async {
    let playback = ActivePlaybackLifecycle()
    let blocker = LifecycleFlushBlocker()
    var flushCount = 0
    _ = playback.register(
        sourceID: UUID(),
        stop: {},
        forcePersist: {
            flushCount += 1
            await blocker.wait()
        }
    )
    let lifecycle = ApplicationLifecycleCoordinator(
        activePlayback: playback,
        flushTimeout: .seconds(1)
    )
    var diagnosticsCount = 0
    var requestIterator = blocker.requests.makeAsyncIterator()

    let inactive = Task { @MainActor in
        await lifecycle.sceneDidBecomeInactive { diagnosticsCount += 1 }
    }
    _ = await requestIterator.next()
    let termination = Task { @MainActor in
        await lifecycle.prepareForTermination { diagnosticsCount += 1 }
    }
    await Task.yield()
    #expect(flushCount == 1)

    await blocker.release()
    await inactive.value
    await termination.value
    #expect(diagnosticsCount == 2)
}

@MainActor
@Test func unregisteringStaleTokenKeepsNewPlaybackRegistration() async {
    let playback = ActivePlaybackLifecycle()
    var oldFlushCount = 0
    var newFlushCount = 0
    let oldToken = playback.register(
        sourceID: UUID(),
        stop: {},
        forcePersist: { oldFlushCount += 1 }
    )
    _ = playback.register(
        sourceID: UUID(),
        stop: {},
        forcePersist: { newFlushCount += 1 }
    )

    playback.unregister(token: oldToken)
    await playback.forcePersistActive()

    #expect(oldFlushCount == 0)
    #expect(newFlushCount == 1)
}

@MainActor
@Test func timedOutFlushDoesNotBlockOrCompleteTheNextGeneration() async throws {
    let playback = ActivePlaybackLifecycle()
    let oldBlocker = LifecycleFlushBlocker()
    let newBlocker = LifecycleFlushBlocker()
    _ = playback.register(
        sourceID: UUID(),
        stop: {},
        forcePersist: { await oldBlocker.wait() }
    )
    let shortLifecycle = ApplicationLifecycleCoordinator(
        activePlayback: playback,
        flushTimeout: .milliseconds(10)
    )
    await shortLifecycle.sceneDidBecomeInactive {}

    var newFlushCount = 0
    var newDiagnosticsFinished = false
    _ = playback.register(
        sourceID: UUID(),
        stop: {},
        forcePersist: {
            newFlushCount += 1
            await newBlocker.wait()
        }
    )
    let longLifecycle = ApplicationLifecycleCoordinator(
        activePlayback: playback,
        flushTimeout: .seconds(1)
    )
    let nextGeneration = Task { @MainActor in
        await longLifecycle.sceneDidBecomeInactive {
            newDiagnosticsFinished = true
        }
    }
    try await Task.sleep(for: .milliseconds(20))
    #expect(newFlushCount == 1)

    await oldBlocker.release()
    try await Task.sleep(for: .milliseconds(10))
    #expect(!newDiagnosticsFinished)

    await newBlocker.release()
    await nextGeneration.value
    #expect(newDiagnosticsFinished)
}

@Test func tokenHandoffKeepsAReappearedRegistrationSeparate() {
    var handoff = ActivePlaybackTokenHandoff()
    let oldToken = UUID()
    let newToken = UUID()
    handoff.install(oldToken)

    let disappearingToken = handoff.take()
    handoff.install(newToken)

    #expect(disappearingToken == oldToken)
    #expect(handoff.current == newToken)
}

private actor LifecycleFlushBlocker {
    nonisolated let requests: AsyncStream<Void>
    private let requestContinuation: AsyncStream<Void>.Continuation
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReleased = false

    init() {
        let stream = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        requests = stream.stream
        requestContinuation = stream.continuation
    }

    func wait() async {
        requestContinuation.yield()
        guard !isReleased else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}
