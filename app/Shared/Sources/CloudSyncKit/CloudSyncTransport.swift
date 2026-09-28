import Foundation

public enum CloudSyncError: Error, Equatable, Sendable {
    case accountUnavailable
    case temporarilyUnavailable
    case invalidRemoteRecord
    case entitlementMissing
}

public struct CloudSyncSnapshot: Equatable, Sendable {
    public let sources: [SyncedSMBSource]
    public let progress: [PlaybackProgress]

    public static let empty = CloudSyncSnapshot(sources: [], progress: [])

    public init(sources: [SyncedSMBSource], progress: [PlaybackProgress]) {
        self.sources = sources
        self.progress = progress
    }
}

public enum CloudSyncMutation: Codable, Equatable, Sendable {
    case upsertSource(SyncedSMBSource)
    case deleteSource(id: UUID, modifiedAt: Date)
    case upsertProgress(PlaybackProgress)
    case deleteProgress(PlaybackProgress)

    var key: String {
        switch self {
        case let .upsertSource(source): "source:\(source.id.uuidString)"
        case let .deleteSource(id, _): "source:\(id.uuidString)"
        case let .upsertProgress(progress): "progress:\(progress.mediaID)"
        case let .deleteProgress(progress): "progress:\(progress.mediaID)"
        }
    }

    var sourceID: UUID? {
        switch self {
        case let .upsertSource(source): source.id
        case let .deleteSource(id, _): id
        case let .upsertProgress(progress), let .deleteProgress(progress):
            progress.sourceID
        }
    }

    var mediaID: String? {
        switch self {
        case let .upsertProgress(progress), let .deleteProgress(progress):
            return progress.mediaID
        default:
            return nil
        }
    }

    var progressValue: PlaybackProgress? {
        switch self {
        case let .upsertProgress(progress), let .deleteProgress(progress):
            return progress
        default:
            return nil
        }
    }
}

public protocol CloudSyncTransport: Sendable {
    func accountAvailable() async -> Bool
    func fetchSnapshot() async throws -> CloudSyncSnapshot
    func save(_ mutations: [CloudSyncMutation]) async throws
}

public protocol CloudSyncCoordinating: Sendable {
    func enqueue(_ mutation: CloudSyncMutation) async
    func synchronize(local: CloudSyncSnapshot) async -> CloudSyncSnapshot
}
