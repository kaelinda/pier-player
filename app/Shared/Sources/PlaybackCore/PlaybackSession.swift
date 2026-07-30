import Foundation

public actor PlaybackSession {
    public private(set) var snapshot: PlaybackSnapshot = .idle

    public init() {}

    @discardableResult
    public func open() throws -> PlaybackOperationToken {
        switch snapshot.state {
        case .idle, .ended, .failed:
            break
        default:
            throw PlaybackCommandError.invalidTransition(
                state: snapshot.state,
                command: "open"
            )
        }

        let sessionID = UUID()
        snapshot = PlaybackSnapshot(
            sessionID: sessionID,
            generation: 0,
            state: .connecting,
            intendsToPlay: true,
            position: 0
        )
        return PlaybackOperationToken(sessionID: sessionID, generation: 0)
    }

    @discardableResult
    public func connectionEstablished(token: PlaybackOperationToken) -> Bool {
        guard accepts(token), snapshot.state == .connecting else { return false }
        update(state: .opening)
        return true
    }

    @discardableResult
    public func mediaOpened(token: PlaybackOperationToken) -> Bool {
        guard accepts(token), snapshot.state == .opening else { return false }
        update(state: .buffering(.initial))
        return true
    }

    @discardableResult
    public func bufferingCompleted(token: PlaybackOperationToken) -> Bool {
        guard accepts(token) else { return false }
        guard case .buffering = snapshot.state else { return false }
        update(state: snapshot.intendsToPlay ? .playing : .paused)
        return true
    }

    public func pause() throws {
        switch snapshot.state {
        case .playing:
            update(state: .paused, intendsToPlay: false)
        case .buffering, .reconnecting:
            update(intendsToPlay: false)
        default:
            throw PlaybackCommandError.invalidTransition(
                state: snapshot.state,
                command: "pause"
            )
        }
    }

    public func resume() throws {
        switch snapshot.state {
        case .paused:
            update(state: .playing, intendsToPlay: true)
        case .buffering, .reconnecting:
            update(intendsToPlay: true)
        default:
            throw PlaybackCommandError.invalidTransition(
                state: snapshot.state,
                command: "resume"
            )
        }
    }

    @discardableResult
    public func seek(to position: TimeInterval) throws -> PlaybackOperationToken {
        guard position.isFinite, position >= 0 else {
            throw PlaybackCommandError.invalidPosition(position)
        }
        switch snapshot.state {
        case .playing, .paused, .buffering:
            break
        default:
            throw PlaybackCommandError.invalidTransition(
                state: snapshot.state,
                command: "seek"
            )
        }

        let token = try nextGeneration(command: "seek")
        update(state: .buffering(.seek), position: position)
        return token
    }

    @discardableResult
    public func beginReconnection() throws -> PlaybackOperationToken {
        switch snapshot.state {
        case .playing, .paused, .buffering:
            break
        default:
            throw PlaybackCommandError.invalidTransition(
                state: snapshot.state,
                command: "beginReconnection"
            )
        }

        let token = try nextGeneration(command: "beginReconnection")
        update(state: .reconnecting)
        return token
    }

    @discardableResult
    public func connectionRecovered(token: PlaybackOperationToken) -> Bool {
        guard accepts(token), snapshot.state == .reconnecting else { return false }
        update(state: .buffering(.recovery))
        return true
    }

    public func stop() {
        snapshot = PlaybackSnapshot(
            sessionID: nil,
            generation: snapshot.generation &+ 1,
            state: .idle,
            intendsToPlay: false,
            position: 0
        )
    }

    public func fail(_ message: String) {
        update(state: .failed(message), intendsToPlay: false)
    }

    @discardableResult
    public func playbackEnded(
        token: PlaybackOperationToken,
        position: TimeInterval
    ) -> Bool {
        guard accepts(token) else { return false }
        update(state: .ended, intendsToPlay: false, position: position)
        return true
    }

    private func accepts(_ token: PlaybackOperationToken) -> Bool {
        token.sessionID == snapshot.sessionID && token.generation == snapshot.generation
    }

    private func nextGeneration(command: String) throws -> PlaybackOperationToken {
        guard let sessionID = snapshot.sessionID else {
            throw PlaybackCommandError.invalidTransition(
                state: snapshot.state,
                command: command
            )
        }
        let generation = snapshot.generation &+ 1
        update(generation: generation)
        return PlaybackOperationToken(
            sessionID: sessionID,
            generation: generation
        )
    }

    private func update(
        generation: UInt64? = nil,
        state: PlaybackState? = nil,
        intendsToPlay: Bool? = nil,
        position: TimeInterval? = nil
    ) {
        snapshot = PlaybackSnapshot(
            sessionID: snapshot.sessionID,
            generation: generation ?? snapshot.generation,
            state: state ?? snapshot.state,
            intendsToPlay: intendsToPlay ?? snapshot.intendsToPlay,
            position: position ?? snapshot.position
        )
    }
}
