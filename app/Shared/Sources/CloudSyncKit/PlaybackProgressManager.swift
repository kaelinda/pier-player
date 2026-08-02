import Foundation

protocol PlaybackProgressStoring: Actor {
    func load() async throws -> [PlaybackProgress]
    func progress(mediaID: String) async throws -> PlaybackProgress?
    func record(
        mediaID: String,
        sourceID: UUID,
        position: TimeInterval,
        duration: TimeInterval,
        modifiedAt: Date
    ) async throws -> PlaybackProgress
    func upsert(_ progress: PlaybackProgress) async throws
    func removeAll(sourceID: UUID) async throws
    func replaceAll(_ values: [PlaybackProgress]) async throws
    func restore(_ snapshot: [PlaybackProgress], sourceID: UUID) async throws
}

public protocol PlaybackProgressManaging: Sendable {
    func progress(mediaID: String) async -> PlaybackProgress?
    func record(
        mediaID: String,
        sourceID: UUID,
        position: TimeInterval,
        duration: TimeInterval,
        force: Bool
    ) async
    func allProgress() async -> [PlaybackProgress]
    func replaceAll(_ progress: [PlaybackProgress]) async
    func removeAll(sourceID: UUID) async
}

public protocol PlaybackProgressCleanupManaging: PlaybackProgressManaging {
    func snapshotPersistently(sourceID: UUID) async throws -> [PlaybackProgress]
    func removePersistently(sourceID: UUID) async throws
    func restorePersistently(
        _ snapshot: [PlaybackProgress],
        sourceID: UUID
    ) async throws
}

public actor PlaybackProgressManager: PlaybackProgressCleanupManaging {
    private struct LastSave: Sendable {
        let sourceID: UUID
        let savedAt: Date
        let sequence: UInt64
    }

    private let store: any PlaybackProgressStoring
    private let syncCoordinator: (any CloudSyncCoordinating)?
    private let minimumSaveInterval: TimeInterval
    private let now: @Sendable () -> Date
    private var lastSavedAt: [String: LastSave] = [:]
    private var nextRecordSequence: UInt64 = 0

    public init(
        store: PlaybackProgressStore,
        syncCoordinator: (any CloudSyncCoordinating)? = nil,
        minimumSaveInterval: TimeInterval = 15,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.syncCoordinator = syncCoordinator
        self.minimumSaveInterval = minimumSaveInterval
        self.now = now
    }

    init(
        store: any PlaybackProgressStoring,
        syncCoordinator: (any CloudSyncCoordinating)? = nil,
        minimumSaveInterval: TimeInterval = 15,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.syncCoordinator = syncCoordinator
        self.minimumSaveInterval = minimumSaveInterval
        self.now = now
    }

    public func progress(mediaID: String) async -> PlaybackProgress? {
        try? await store.progress(mediaID: mediaID)
    }

    public func record(
        mediaID: String,
        sourceID: UUID,
        position: TimeInterval,
        duration: TimeInterval,
        force: Bool
    ) async {
        let timestamp = now()
        if !force,
           let lastSaved = lastSavedAt[mediaID],
           lastSaved.sourceID == sourceID,
           timestamp.timeIntervalSince(lastSaved.savedAt) < minimumSaveInterval {
            return
        }
        let sequence = nextRecordSequence
        nextRecordSequence &+= 1
        do {
            let progress = try await store.record(
                mediaID: mediaID,
                sourceID: sourceID,
                position: position,
                duration: duration,
                modifiedAt: timestamp
            )
            if let lastSaved = lastSavedAt[mediaID], lastSaved.sequence > sequence {
                return
            }
            lastSavedAt[mediaID] = LastSave(
                sourceID: sourceID,
                savedAt: timestamp,
                sequence: sequence
            )
            await syncCoordinator?.enqueue(.upsertProgress(progress))
        } catch {
            return
        }
    }

    public func allProgress() async -> [PlaybackProgress] {
        (try? await store.load()) ?? []
    }

    public func replaceAll(_ progress: [PlaybackProgress]) async {
        try? await store.replaceAll(progress)
    }

    public func removeAll(sourceID: UUID) async {
        do {
            try await store.removeAll(sourceID: sourceID)
            lastSavedAt = lastSavedAt.filter { $0.value.sourceID != sourceID }
        } catch {
            return
        }
    }

    public func snapshotPersistently(sourceID: UUID) async throws -> [PlaybackProgress] {
        try await store.load().filter { $0.sourceID == sourceID }
    }

    public func removePersistently(sourceID: UUID) async throws {
        try await store.removeAll(sourceID: sourceID)
        lastSavedAt = lastSavedAt.filter { $0.value.sourceID != sourceID }
    }

    public func restorePersistently(
        _ snapshot: [PlaybackProgress],
        sourceID: UUID
    ) async throws {
        try await store.restore(snapshot, sourceID: sourceID)
        lastSavedAt = lastSavedAt.filter { $0.value.sourceID != sourceID }
    }
}
