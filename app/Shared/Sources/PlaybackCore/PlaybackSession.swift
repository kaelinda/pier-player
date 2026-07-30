import DiagnosticsKit
import Foundation

public actor PlaybackSession {
    public private(set) var snapshot: PlaybackSnapshot = .idle
    private let diagnosticRecorder: any DiagnosticRecording
    private let diagnosticContext: DiagnosticContext

    public init(
        diagnosticRecorder: any DiagnosticRecording = NoopDiagnosticRecorder(),
        diagnosticContext: DiagnosticContext? = nil
    ) {
        self.diagnosticRecorder = diagnosticRecorder
        self.diagnosticContext = diagnosticContext ?? DiagnosticContext(
            appRunID: UUID(),
            activityID: UUID(),
            operationID: UUID()
        )
    }

    @discardableResult
    public func open() throws -> PlaybackOperationToken {
        switch snapshot.state {
        case .idle, .ended, .failed:
            break
        default:
            recordRejection(name: .playbackPrepare)
            throw PlaybackCommandError.invalidTransition(
                state: snapshot.state,
                command: "open"
            )
        }

        let sessionID = UUID()
        transition(name: .playbackPrepare, to: PlaybackSnapshot(
            sessionID: sessionID,
            generation: 0,
            state: .connecting,
            intendsToPlay: true,
            position: 0
        ))
        return PlaybackOperationToken(sessionID: sessionID, generation: 0)
    }

    @discardableResult
    public func connectionEstablished(token: PlaybackOperationToken) -> Bool {
        guard accepts(token), snapshot.state == .connecting else {
            recordRejection(name: .playbackPrepare)
            return false
        }
        update(name: .playbackPrepare, state: .opening)
        return true
    }

    @discardableResult
    public func mediaOpened(token: PlaybackOperationToken) -> Bool {
        guard accepts(token), snapshot.state == .opening else {
            recordRejection(name: .playbackPrepare)
            return false
        }
        update(name: .playbackPrepare, state: .buffering(.initial))
        return true
    }

    @discardableResult
    public func bufferingCompleted(token: PlaybackOperationToken) -> Bool {
        guard accepts(token) else {
            recordRejection(name: .playbackPrepare)
            return false
        }
        guard case .buffering = snapshot.state else {
            recordRejection(name: .playbackPrepare)
            return false
        }
        let state: PlaybackState = snapshot.intendsToPlay ? .playing : .paused
        update(name: snapshot.intendsToPlay ? .playbackPlay : .playbackPause, state: state)
        return true
    }

    public func pause() throws {
        switch snapshot.state {
        case .playing:
            update(name: .playbackPause, state: .paused, intendsToPlay: false)
        case .buffering, .reconnecting:
            update(name: .playbackPause, intendsToPlay: false)
        default:
            recordRejection(name: .playbackPause)
            throw PlaybackCommandError.invalidTransition(
                state: snapshot.state,
                command: "pause"
            )
        }
    }

    public func resume() throws {
        switch snapshot.state {
        case .paused:
            update(name: .playbackPlay, state: .playing, intendsToPlay: true)
        case .buffering, .reconnecting:
            update(name: .playbackPlay, intendsToPlay: true)
        default:
            recordRejection(name: .playbackPlay)
            throw PlaybackCommandError.invalidTransition(
                state: snapshot.state,
                command: "resume"
            )
        }
    }

    @discardableResult
    public func seek(to position: TimeInterval) throws -> PlaybackOperationToken {
        guard position.isFinite, position >= 0 else {
            recordRejection(name: .playbackSeek)
            throw PlaybackCommandError.invalidPosition(position)
        }
        switch snapshot.state {
        case .playing, .paused, .buffering:
            break
        default:
            recordRejection(name: .playbackSeek)
            throw PlaybackCommandError.invalidTransition(
                state: snapshot.state,
                command: "seek"
            )
        }

        let token = try nextGeneration(command: "seek", eventName: .playbackSeek)
        update(
            name: .playbackSeek,
            generation: token.generation,
            state: .buffering(.seek),
            position: position
        )
        return token
    }

    @discardableResult
    public func beginReconnection() throws -> PlaybackOperationToken {
        switch snapshot.state {
        case .playing, .paused, .buffering:
            break
        default:
            recordRejection(name: .playbackStall)
            throw PlaybackCommandError.invalidTransition(
                state: snapshot.state,
                command: "beginReconnection"
            )
        }

        let token = try nextGeneration(
            command: "beginReconnection",
            eventName: .playbackStall
        )
        update(
            name: .playbackStall,
            generation: token.generation,
            state: .reconnecting
        )
        return token
    }

    @discardableResult
    public func connectionRecovered(token: PlaybackOperationToken) -> Bool {
        guard accepts(token), snapshot.state == .reconnecting else {
            recordRejection(name: .playbackRecover)
            return false
        }
        update(name: .playbackRecover, state: .buffering(.recovery))
        return true
    }

    public func stop() {
        transition(name: .playbackStop, to: PlaybackSnapshot(
            sessionID: nil,
            generation: snapshot.generation &+ 1,
            state: .idle,
            intendsToPlay: false,
            position: 0
        ))
    }

    public func fail(_ message: String) {
        update(
            name: .playbackFailed,
            state: .failed(message),
            intendsToPlay: false,
            outcome: .failure,
            error: DiagnosticErrorDescriptor(code: .playerFailed)
        )
    }

    private func accepts(_ token: PlaybackOperationToken) -> Bool {
        token.sessionID == snapshot.sessionID && token.generation == snapshot.generation
    }

    private func nextGeneration(
        command: String,
        eventName: DiagnosticEventName
    ) throws -> PlaybackOperationToken {
        guard let sessionID = snapshot.sessionID else {
            recordRejection(name: eventName)
            throw PlaybackCommandError.invalidTransition(
                state: snapshot.state,
                command: command
            )
        }
        let generation = snapshot.generation &+ 1
        return PlaybackOperationToken(
            sessionID: sessionID,
            generation: generation
        )
    }

    private func update(
        name: DiagnosticEventName,
        generation: UInt64? = nil,
        state: PlaybackState? = nil,
        intendsToPlay: Bool? = nil,
        position: TimeInterval? = nil,
        outcome: DiagnosticOutcome = .success,
        error: DiagnosticErrorDescriptor? = nil
    ) {
        transition(name: name, to: PlaybackSnapshot(
            sessionID: snapshot.sessionID,
            generation: generation ?? snapshot.generation,
            state: state ?? snapshot.state,
            intendsToPlay: intendsToPlay ?? snapshot.intendsToPlay,
            position: position ?? snapshot.position
        ), outcome: outcome, error: error)
    }

    private func transition(
        name: DiagnosticEventName,
        to next: PlaybackSnapshot,
        outcome: DiagnosticOutcome = .success,
        error: DiagnosticErrorDescriptor? = nil
    ) {
        let previous = snapshot
        snapshot = next
        diagnosticRecorder.record(.instant(
            level: outcome == .failure ? .error : .info,
            name: name,
            context: diagnosticContext.child(),
            outcome: outcome,
            payload: DiagnosticPayload(
                playbackSessionID: next.sessionID ?? previous.sessionID,
                playbackGeneration: next.generation,
                oldPlaybackState: previous.state.diagnosticState,
                newPlaybackState: next.state.diagnosticState,
                playbackPositionSeconds: next.position,
                error: error
            ),
            persistence: .essential
        ))
    }

    private func recordRejection(name: DiagnosticEventName) {
        diagnosticRecorder.record(.instant(
            level: .warning,
            name: name,
            context: diagnosticContext.child(),
            outcome: .discarded,
            payload: DiagnosticPayload(
                playbackSessionID: snapshot.sessionID,
                playbackGeneration: snapshot.generation,
                oldPlaybackState: snapshot.state.diagnosticState,
                newPlaybackState: snapshot.state.diagnosticState,
                playbackPositionSeconds: snapshot.position
            ),
            persistence: .essential
        ))
    }
}

private extension PlaybackState {
    var diagnosticState: DiagnosticPlaybackState {
        switch self {
        case .idle: .idle
        case .connecting: .connecting
        case .opening: .opening
        case .buffering(.initial): .bufferingInitial
        case .buffering(.seek): .bufferingSeek
        case .buffering(.recovery): .bufferingRecovery
        case .playing: .playing
        case .paused: .paused
        case .reconnecting: .reconnecting
        case .ended: .ended
        case .failed: .failed
        }
    }
}
