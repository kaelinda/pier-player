import Foundation

@MainActor
final class ActivePlaybackLifecycle {
    typealias Stop = @MainActor @Sendable () async -> Void

    private struct Registration {
        let sourceID: UUID
        let stop: Stop
    }

    private var registrations: [UUID: Registration] = [:]
    private var stopTasks: [UUID: Task<Void, Never>] = [:]

    @discardableResult
    func register(sourceID: UUID, stop: @escaping Stop) -> UUID {
        let token = UUID()
        registrations[token] = Registration(sourceID: sourceID, stop: stop)
        return token
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
