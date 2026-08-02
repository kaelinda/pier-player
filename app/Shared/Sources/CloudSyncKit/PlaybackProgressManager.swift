import Foundation

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
    }

    private let store: PlaybackProgressStore
    private let syncCoordinator: (any CloudSyncCoordinating)?
    private let minimumSaveInterval: TimeInterval
    private let now: @Sendable () -> Date
    private var lastSavedAt: [String: LastSave] = [:]

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
        var completionOverride: Bool?
        if position < 5 {
            completionOverride = (try? await store.progress(mediaID: mediaID))?.isCompleted
        }
        guard let progress = try? PlaybackProgress(
            mediaID: mediaID,
            sourceID: sourceID,
            position: position,
            duration: duration,
            modifiedAt: timestamp,
            isCompleted: completionOverride
        ) else { return }
        do {
            try await store.upsert(progress)
            lastSavedAt[mediaID] = LastSave(sourceID: sourceID, savedAt: timestamp)
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
        let current = try await store.load()
        try await store.replaceAll(
            current.filter { $0.sourceID != sourceID } + snapshot
        )
        lastSavedAt = lastSavedAt.filter { $0.value.sourceID != sourceID }
    }
}
