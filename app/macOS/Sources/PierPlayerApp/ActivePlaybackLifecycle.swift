import Foundation

struct ActivePlaybackTokenHandoff {
    private(set) var current: UUID?

    mutating func install(_ token: UUID) {
        current = token
    }

    mutating func take() -> UUID? {
        defer { current = nil }
        return current
    }
}

@MainActor
final class ActivePlaybackLifecycle {
    typealias Action = @MainActor @Sendable () async -> Void

    private struct Registration {
        let sourceID: UUID
        let stop: Action
        let forcePersist: Action
    }

    private struct ForcePersistWaiter {
        let registrationToken: UUID
        let action: Action
        let completion: @MainActor () -> Void
    }

    private var registrations: [UUID: Registration] = [:]
    private var activeRegistrationToken: UUID?
    private var stopTasks: [UUID: Task<Void, Never>] = [:]
    private var forcePersistTask: (
        id: UUID,
        registrationToken: UUID,
        task: Task<Void, Never>
    )?
    private var forcePersistWaiters: [UUID: ForcePersistWaiter] = [:]
    private var forcePersistWaiterOrder: [UUID] = []

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
        activeRegistrationToken = token
        return token
    }

    func unregister(token: UUID) {
        registrations[token] = nil
        if activeRegistrationToken == token {
            activeRegistrationToken = nil
        }
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
        guard let activeRegistrationToken,
              let action = registrations[activeRegistrationToken]?.forcePersist else {
            onCompletion()
            return nil
        }
        let waiterToken = UUID()
        forcePersistWaiters[waiterToken] = ForcePersistWaiter(
            registrationToken: activeRegistrationToken,
            action: action,
            completion: onCompletion
        )
        forcePersistWaiterOrder.append(waiterToken)
        startNextForcePersist()
        return waiterToken
    }

    private func startNextForcePersist() {
        guard forcePersistTask == nil,
              let waiterToken = forcePersistWaiterOrder.first,
              let waiter = forcePersistWaiters[waiterToken] else { return }
        let id = UUID()
        let task = Task { @MainActor in
            await waiter.action()
            finishForcePersist(id: id)
        }
        forcePersistTask = (id, waiter.registrationToken, task)
    }

    func cancelForcePersistWaiter(token: UUID) {
        guard forcePersistWaiters.removeValue(forKey: token) != nil else { return }
        forcePersistWaiterOrder.removeAll { $0 == token }
        guard let forcePersistTask else { return }
        let hasCurrentGenerationWaiters = forcePersistWaiters.values.contains {
            $0.registrationToken == forcePersistTask.registrationToken
        }
        guard !hasCurrentGenerationWaiters else { return }
        forcePersistTask.task.cancel()
        self.forcePersistTask = nil
        startNextForcePersist()
    }

    private func finishForcePersist(id: UUID) {
        guard let forcePersistTask, forcePersistTask.id == id else { return }
        self.forcePersistTask = nil
        let completedWaiterTokens = forcePersistWaiterOrder.filter {
            forcePersistWaiters[$0]?.registrationToken == forcePersistTask.registrationToken
        }
        let completions = completedWaiterTokens.compactMap {
            forcePersistWaiters.removeValue(forKey: $0)?.completion
        }
        forcePersistWaiterOrder.removeAll { completedWaiterTokens.contains($0) }
        startNextForcePersist()
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
        if activeRegistrationToken == token {
            activeRegistrationToken = nil
        }
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
