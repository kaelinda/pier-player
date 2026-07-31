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

    var key: String {
        switch self {
        case let .upsertSource(source): "source:\(source.id.uuidString)"
        case let .deleteSource(id, _): "source:\(id.uuidString)"
        case let .upsertProgress(progress): "progress:\(progress.mediaID)"
        }
    }

    var sourceID: UUID? {
        switch self {
        case let .upsertSource(source): source.id
        case let .deleteSource(id, _): id
        case .upsertProgress: nil
        }
    }

    var mediaID: String? {
        guard case let .upsertProgress(progress) = self else { return nil }
        return progress.mediaID
    }
}

public protocol CloudSyncTransport: Sendable {
    func accountAvailable() async -> Bool
    func fetchSnapshot() async throws -> CloudSyncSnapshot
    func save(_ mutations: [CloudSyncMutation]) async throws
}
