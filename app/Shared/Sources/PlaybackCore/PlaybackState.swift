import Foundation

public enum BufferingReason: String, Equatable, Codable, Sendable {
    case initial
    case seek
    case recovery
    case underrun
}

public enum PlaybackState: Equatable, Sendable {
    case idle
    case connecting
    case opening
    case buffering(BufferingReason)
    case playing
    case paused
    case reconnecting
    case ended
    case failed(String)
}

public struct PlaybackOperationToken: Equatable, Hashable, Sendable {
    public let sessionID: UUID
    public let generation: UInt64

    public init(sessionID: UUID, generation: UInt64) {
        self.sessionID = sessionID
        self.generation = generation
    }
}

public struct PlaybackSnapshot: Equatable, Sendable {
    public let sessionID: UUID?
    public let generation: UInt64
    public let state: PlaybackState
    public let intendsToPlay: Bool
    public let position: TimeInterval

    public init(
        sessionID: UUID?,
        generation: UInt64,
        state: PlaybackState,
        intendsToPlay: Bool,
        position: TimeInterval
    ) {
        self.sessionID = sessionID
        self.generation = generation
        self.state = state
        self.intendsToPlay = intendsToPlay
        self.position = position
    }

    public static let idle = PlaybackSnapshot(
        sessionID: nil,
        generation: 0,
        state: .idle,
        intendsToPlay: false,
        position: 0
    )
}

public enum PlaybackCommandError: Error, Equatable, Sendable {
    case invalidTransition(state: PlaybackState, command: String)
    case invalidPosition(TimeInterval)
}
