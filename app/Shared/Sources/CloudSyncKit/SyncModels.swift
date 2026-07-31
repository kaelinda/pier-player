import Foundation

public enum SyncStatus: Equatable, Sendable {
    case localOnly
    case syncing
    case upToDate
    case accountUnavailable
    case temporarilyUnavailable
}

public struct SyncedSMBSource: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let displayName: String
    public let host: String
    public let share: String
    public let domain: String?
    public let requiresEncryption: Bool
    public let modifiedAt: Date
    public let isDeleted: Bool

    public init(
        id: UUID,
        displayName: String,
        host: String,
        share: String,
        domain: String?,
        requiresEncryption: Bool,
        modifiedAt: Date,
        isDeleted: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.host = host
        self.share = share
        self.domain = domain
        self.requiresEncryption = requiresEncryption
        self.modifiedAt = modifiedAt
        self.isDeleted = isDeleted
    }
}

public enum PlaybackProgressError: Error, Equatable, Sendable {
    case invalidMediaID
    case invalidPosition
    case invalidDuration
}

public struct PlaybackProgress: Codable, Equatable, Identifiable, Sendable {
    public let mediaID: String
    public let sourceID: UUID
    public let position: TimeInterval
    public let duration: TimeInterval
    public let modifiedAt: Date
    public let isCompleted: Bool

    public var id: String { mediaID }

    public var effectiveResumePosition: TimeInterval {
        guard !isCompleted, position >= 5 else { return 0 }
        return position
    }

    public init(
        mediaID: String,
        sourceID: UUID,
        position: TimeInterval,
        duration: TimeInterval,
        modifiedAt: Date = Date(),
        isCompleted: Bool? = nil
    ) throws {
        guard mediaID.count == 64,
              mediaID.allSatisfy({ $0.isHexDigit }) else {
            throw PlaybackProgressError.invalidMediaID
        }
        guard position.isFinite, position >= 0 else {
            throw PlaybackProgressError.invalidPosition
        }
        guard duration.isFinite, duration > 0 else {
            throw PlaybackProgressError.invalidDuration
        }
        self.mediaID = mediaID.lowercased()
        self.sourceID = sourceID
        self.position = min(position, duration)
        self.duration = duration
        self.modifiedAt = modifiedAt
        self.isCompleted = isCompleted ?? (position / duration >= 0.95)
    }
}
