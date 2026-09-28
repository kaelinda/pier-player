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
    func remove(mediaID: String) async
    func removeAll() async
    func allProgress() async -> [PlaybackProgress]
    func replaceAll(_ progress: [PlaybackProgress]) async
}

public actor PlaybackProgressManager: PlaybackProgressManaging {
    private let store: PlaybackProgressStore
    private let syncCoordinator: (any CloudSyncCoordinating)?
    private let minimumSaveInterval: TimeInterval
    private let now: @Sendable () -> Date
    private var lastSavedAt: [String: Date] = [:]

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
           timestamp.timeIntervalSince(lastSaved) < minimumSaveInterval {
            return
        }
        guard let progress = try? PlaybackProgress(
            mediaID: mediaID,
            sourceID: sourceID,
            position: position,
            duration: duration,
            modifiedAt: timestamp
        ) else { return }
        do {
            try await store.upsert(progress)
            lastSavedAt[mediaID] = timestamp
            await syncCoordinator?.enqueue(.upsertProgress(progress))
        } catch {
            return
        }
    }

    public func remove(mediaID: String) async {
        guard let existing = try? await store.record(mediaID: mediaID),
              !existing.isDeleted else {
            return
        }

        let timestamp = now()
        guard let tombstone = try? PlaybackProgress(
            mediaID: existing.mediaID,
            sourceID: existing.sourceID,
            position: 0,
            duration: max(existing.duration, 1),
            modifiedAt: timestamp,
            isCompleted: true,
            isDeleted: true
        ) else {
            return
        }

        do {
            try await store.upsert(tombstone)
            lastSavedAt[mediaID] = nil
            await syncCoordinator?.enqueue(.deleteProgress(tombstone))
        } catch {
            return
        }
    }

    public func removeAll() async {
        let values = await allProgress()
        for value in values where !value.isDeleted {
            await remove(mediaID: value.mediaID)
        }
    }

    public func allProgress() async -> [PlaybackProgress] {
        (try? await store.load()) ?? []
    }

    public func replaceAll(_ progress: [PlaybackProgress]) async {
        try? await store.replaceAll(progress)
    }
}
