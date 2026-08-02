import Foundation

@MainActor
final class ActivePlaybackLifecycle {
    typealias Action = @MainActor @Sendable () async -> Void

    private struct Registration {
        let sourceID: UUID
        let stop: Action
        let forcePersist: Action
    }

    private var registrations: [UUID: Registration] = [:]
    private var stopTasks: [UUID: Task<Void, Never>] = [:]
    private var forcePersistTask: (id: UUID, task: Task<Void, Never>)?
    private var forcePersistWaiters: [UUID: @MainActor () -> Void] = [:]

    @discardableResult
    func register(
        sourceID: UUID,
        stop: @escaping Action,
        forcePersist: @escaping Action
    ) -> UUID {
        let token = UUID()
        registrations[token] = Registration(
            sourceID: sourceID,
            stop: stop,
            forcePersist: forcePersist
        )
        return token
    }

    func unregister(token: UUID) {
        registrations[token] = nil
    }

    func forcePersistActive() async {
        await withCheckedContinuation { continuation in
            _ = beginForcePersist {
                continuation.resume()
            }
        }
    }

    @discardableResult
    func beginForcePersist(onCompletion: @escaping @MainActor () -> Void) -> UUID? {
        let actions = registrations.values.map(\.forcePersist)
        guard !actions.isEmpty else {
            onCompletion()
            return nil
        }
        let waiterToken = UUID()
        forcePersistWaiters[waiterToken] = onCompletion
        guard forcePersistTask == nil else { return waiterToken }
        let id = UUID()
        let task = Task { @MainActor in
            for action in actions {
                await action()
            }
            finishForcePersist(id: id)
        }
        forcePersistTask = (id, task)
        return waiterToken
    }

    func cancelForcePersistWaiter(token: UUID) {
        forcePersistWaiters[token] = nil
    }

    private func finishForcePersist(id: UUID) {
        if forcePersistTask?.id == id {
            forcePersistTask = nil
        }
        let completions = Array(forcePersistWaiters.values)
        forcePersistWaiters.removeAll()
        for completion in completions {
            completion()
        }
    }

    func stopActive(sourceID: UUID) async {
        let tokens = registrations.compactMap { token, registration in
            registration.sourceID == sourceID ? token : nil
        }
        for token in tokens {
            await stop(token: token)
        }
    }

    func stop(token: UUID) async {
        if let task = stopTasks[token] {
            await task.value
            return
        }
        guard let registration = registrations[token] else { return }
        let task = Task { @MainActor in
            await registration.stop()
        }
        stopTasks[token] = task
        await task.value
        registrations[token] = nil
        stopTasks[token] = nil
    }
}

@MainActor
final class ApplicationLifecycleCoordinator {
    typealias DiagnosticsAction = @MainActor @Sendable () async -> Void

    private let activePlayback: ActivePlaybackLifecycle
    private let flushTimeout: Duration

    init(
        activePlayback: ActivePlaybackLifecycle,
        flushTimeout: Duration = .seconds(2)
    ) {
        self.activePlayback = activePlayback
        self.flushTimeout = flushTimeout
    }

    func sceneDidBecomeInactive(flushDiagnostics: DiagnosticsAction) async {
        await boundedForcePersist()
        await flushDiagnostics()
    }

    func prepareForTermination(stopDiagnostics: DiagnosticsAction) async {
        await boundedForcePersist()
        await stopDiagnostics()
    }

    private func boundedForcePersist() async {
        await withCheckedContinuation { continuation in
            let gate = LifecycleContinuationGate(continuation: continuation)
            let waiterToken = activePlayback.beginForcePersist {
                gate.resolve()
            }
            guard let waiterToken else { return }
            Task { @MainActor [activePlayback, flushTimeout] in
                try? await Task.sleep(for: flushTimeout)
                gate.resolve()
                activePlayback.cancelForcePersistWaiter(token: waiterToken)
            }
        }
    }
}

@MainActor
private final class LifecycleContinuationGate {
    private var continuation: CheckedContinuation<Void, Never>?

    init(continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func resolve() {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume()
    }
}
