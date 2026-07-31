import Foundation

public actor SyncCoordinator: CloudSyncCoordinating {
    public private(set) var status: SyncStatus = .localOnly

    private let transport: any CloudSyncTransport
    private let stateStore: SyncStateStore

    public init(
        transport: any CloudSyncTransport,
        stateStore: SyncStateStore
    ) {
        self.transport = transport
        self.stateStore = stateStore
    }

    public func enqueue(_ mutation: CloudSyncMutation) async {
        try? await stateStore.enqueue(mutation)
    }

    public func synchronize(local: CloudSyncSnapshot) async -> CloudSyncSnapshot {
        guard await transport.accountAvailable() else {
            status = .accountUnavailable
            return local
        }

        status = .syncing
        do {
            let remote = try await transport.fetchSnapshot()
            var pending = try await stateStore.pendingMutations()
            var merged = merge(local: local, remote: remote, pending: pending)

            let pendingKeys = Set(pending.map(\.key))
            for source in local.sources where
                !pendingKeys.contains("source:\(source.id.uuidString)")
                    && remote.sources.first(where: { $0.id == source.id }) == nil {
                let mutation = CloudSyncMutation.upsertSource(source)
                try await stateStore.enqueue(mutation)
                pending.append(mutation)
            }
            for progress in local.progress where
                !pendingKeys.contains("progress:\(progress.mediaID)")
                    && remote.progress.first(where: { $0.mediaID == progress.mediaID }) == nil {
                let mutation = CloudSyncMutation.upsertProgress(progress)
                try await stateStore.enqueue(mutation)
                pending.append(mutation)
            }

            merged = applying(pending, to: merged)
            if !pending.isEmpty {
                try await transport.save(pending)
                try await stateStore.remove(pending)
            }
            status = .upToDate
            return merged
        } catch let error as CloudSyncError {
            status = error == .accountUnavailable ? .accountUnavailable : .temporarilyUnavailable
            return applying((try? await stateStore.pendingMutations()) ?? [], to: local)
        } catch {
            status = .temporarilyUnavailable
            return applying((try? await stateStore.pendingMutations()) ?? [], to: local)
        }
    }

    private func merge(
        local: CloudSyncSnapshot,
        remote: CloudSyncSnapshot,
        pending: [CloudSyncMutation]
    ) -> CloudSyncSnapshot {
        let pendingSourceIDs = Set(pending.compactMap(\.sourceID))
        let pendingMediaIDs = Set(pending.compactMap(\.mediaID))
        var sources = Dictionary(uniqueKeysWithValues: remote.sources.map { ($0.id, $0) })
        for source in local.sources {
            guard pendingSourceIDs.contains(source.id)
                    || source.modifiedAt > sources[source.id]?.modifiedAt ?? .distantPast else {
                continue
            }
            sources[source.id] = source
        }
        var progress = Dictionary(uniqueKeysWithValues: remote.progress.map { ($0.mediaID, $0) })
        for value in local.progress {
            guard pendingMediaIDs.contains(value.mediaID)
                    || value.modifiedAt > progress[value.mediaID]?.modifiedAt ?? .distantPast else {
                continue
            }
            progress[value.mediaID] = value
        }
        let deletedSourceIDs = Set(sources.values.filter(\.isDeleted).map(\.id))
        return CloudSyncSnapshot(
            sources: sources.values
                .filter { !$0.isDeleted }
                .sorted { $0.id.uuidString < $1.id.uuidString },
            progress: progress.values
                .filter { !deletedSourceIDs.contains($0.sourceID) }
                .sorted { $0.mediaID < $1.mediaID }
        )
    }

    private func applying(
        _ mutations: [CloudSyncMutation],
        to snapshot: CloudSyncSnapshot
    ) -> CloudSyncSnapshot {
        var sources = Dictionary(uniqueKeysWithValues: snapshot.sources.map { ($0.id, $0) })
        var progress = Dictionary(uniqueKeysWithValues: snapshot.progress.map { ($0.mediaID, $0) })
        for mutation in mutations {
            switch mutation {
            case let .upsertSource(source):
                sources[source.id] = source
            case let .deleteSource(id, _):
                sources[id] = nil
                progress = progress.filter { $0.value.sourceID != id }
            case let .upsertProgress(value):
                progress[value.mediaID] = value
            }
        }
        return CloudSyncSnapshot(
            sources: sources.values
                .filter { !$0.isDeleted }
                .sorted { $0.id.uuidString < $1.id.uuidString },
            progress: progress.values.sorted { $0.mediaID < $1.mediaID }
        )
    }
}
