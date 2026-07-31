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

    public func allProgress() async -> [PlaybackProgress] {
        (try? await store.load()) ?? []
    }

    public func replaceAll(_ progress: [PlaybackProgress]) async {
        try? await store.replaceAll(progress)
    }
}
