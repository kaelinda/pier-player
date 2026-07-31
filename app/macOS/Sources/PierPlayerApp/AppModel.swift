import CloudSyncKit
import DiagnosticsKit
import MediaSourceKit
import PlaybackCore
import SMBSourceKit
import SwiftUI

enum SMBSourceUpdateError: Error, Equatable {
    case changesNotSaved
    case credentialRollbackFailed
}

@MainActor
final class AppModel: ObservableObject {
    typealias SourceFactory = (
        _ configuration: SMBConnectionConfiguration,
        _ credential: SMBCredential
    ) -> any MediaSource

    struct PlaybackDiagnosticDependencies {
        let recorder: any DiagnosticRecording
        let context: DiagnosticContext
        let identityProvider: (any DiagnosticIdentityProviding)?
    }

    struct ConnectedSource: Identifiable {
        let id: UUID
        let displayName: String
        let username: String
        let source: any MediaSource
        let configuration: SMBConnectionConfiguration
    }

    enum SourceConnectionState: Equatable {
        case connected
        case needsCredential
        case unavailable
    }

    struct ConfiguredSource: Identifiable {
        let id: UUID
        let displayName: String
        let username: String?
        let configuration: SMBConnectionConfiguration
        let connectionState: SourceConnectionState
    }

    @Published private(set) var snapshot: PlaybackSnapshot = .idle
    @Published private(set) var sources: [ConnectedSource] = []
    @Published private(set) var configuredSources: [ConfiguredSource] = []
    @Published private(set) var isRestoring = true
    @Published private(set) var sourceRevision = 0

    let playbackSession: PlaybackSession
    private let credentialStore: any SMBCredentialStore
    private let sourceStore: any SMBSourceStoring
    private let diagnosticRecorder: any DiagnosticRecording
    private let diagnosticContext: DiagnosticContext
    private let identityProvider: (any DiagnosticIdentityProviding)?
    private let sourceFactory: SourceFactory?
    private let syncCoordinator: (any CloudSyncCoordinating)?

    init(
        playbackSession: PlaybackSession = PlaybackSession(),
        credentialStore: any SMBCredentialStore = KeychainCredentialStore(),
        sourceStore: (any SMBSourceStoring)? = nil,
        diagnosticRecorder: any DiagnosticRecording = NoopDiagnosticRecorder(),
        diagnosticContext: DiagnosticContext? = nil,
        identityProvider: (any DiagnosticIdentityProviding)? = nil,
        sourceFactory: SourceFactory? = nil,
        syncCoordinator: (any CloudSyncCoordinating)? = nil
    ) {
        self.playbackSession = playbackSession
        self.credentialStore = credentialStore
        self.sourceStore = sourceStore
            ?? (try? SMBSourceStore())
            ?? SMBSourceStore(fallback: ())
        self.diagnosticRecorder = diagnosticRecorder
        self.diagnosticContext = diagnosticContext ?? DiagnosticContext(
            appRunID: UUID(),
            activityID: UUID(),
            operationID: UUID()
        )
        self.identityProvider = identityProvider
        self.sourceFactory = sourceFactory
        self.syncCoordinator = syncCoordinator
    }

    func restore() async {
        isRestoring = true
        defer { isRestoring = false }
        let operation = DiagnosticOperation(
            recorder: diagnosticRecorder,
            parentContext: diagnosticContext,
            name: .sourceRestore,
            level: .info,
            persistence: .essential
        )

        let storedSources: [SMBStorageSource]
        do {
            try await sourceStore.migrateCredentials(to: credentialStore)
            storedSources = try await sourceStore.load()
        } catch {
            operation.end(
                outcome: .failure,
                error: DiagnosticErrorDescriptor(code: .diagnosticsStorageFailed)
            )
            return
        }

        await restore(storedSources, operation: operation)
        operation.end(outcome: .success)
    }

    private func restore(
        _ storedSources: [SMBStorageSource],
        operation: DiagnosticOperation
    ) async {
        for stored in storedSources {
            let restoreOperation = DiagnosticOperation(
                recorder: diagnosticRecorder,
                parentContext: operation.context,
                name: .sourceRestore,
                payload: DiagnosticPayload(sourceID: stored.id),
                persistence: .essential
            )
            do {
                let configuration = try configuration(from: stored)
                configuredSources.append(ConfiguredSource(
                    id: configuration.sourceID,
                    displayName: configuration.displayName,
                    username: nil,
                    configuration: configuration,
                    connectionState: .needsCredential
                ))
                try await restoreSource(
                    stored,
                    configuration: configuration,
                    context: restoreOperation.context
                )
                restoreOperation.end(
                    outcome: .success,
                    payload: DiagnosticPayload(sourceID: stored.id)
                )
            } catch {
                updateConfiguredState(id: stored.id, state: .unavailable)
                finishAppSourceOperation(
                    restoreOperation,
                    error: error,
                    sourceID: stored.id
                )
            }
        }
    }

    private func restoreSource(
        _ stored: SMBStorageSource,
        configuration: SMBConnectionConfiguration,
        context: DiagnosticContext
    ) async throws {
        guard let storedCredential = try await credentialStore.load(sourceID: stored.id) else {
            updateConfiguredState(id: stored.id, state: .needsCredential)
            return
        }
        let credential = storedCredential.credential
        let source = makeSource(
            configuration: configuration,
            credential: credential,
            context: context
        )
        try await source.connect()
        sources.append(ConnectedSource(
            id: configuration.sourceID,
            displayName: configuration.displayName,
            username: credential.username,
            source: source,
            configuration: configuration
        ))
        updateConfiguredState(
            id: stored.id,
            username: credential.username,
            state: .connected
        )
    }

    func synchronizeSources() async {
        guard let syncCoordinator,
              let stored = try? await sourceStore.load() else { return }
        let local = CloudSyncSnapshot(
            sources: stored.map(\.syncedSource),
            progress: []
        )
        let merged = await syncCoordinator.synchronize(local: local)
        let mergedStorage = merged.sources.map(\.storageSource)
        guard mergedStorage != stored else { return }

        try? await sourceStore.replaceAll(mergedStorage)
        for connected in sources { await connected.source.disconnect() }
        sources.removeAll()
        configuredSources.removeAll()
        let operation = DiagnosticOperation(
            recorder: diagnosticRecorder,
            parentContext: diagnosticContext,
            name: .sourceRestore,
            persistence: .essential
        )
        await restore(mergedStorage, operation: operation)
        operation.end(outcome: .success)
        sourceRevision &+= 1
    }

    var phaseLabel: String {
        switch snapshot.state {
        case .idle: "Idle"
        case .connecting: "Connecting"
        case .opening: "Opening"
        case .buffering: "Buffering"
        case .playing: "Playing"
        case .paused: "Paused"
        case .reconnecting: "Reconnecting"
        case .ended: "Ended"
        case .failed: "Failed"
        }
    }

    func addSMBSource(
        displayName: String,
        host: String,
        share: String,
        username: String,
        password: String,
        domain: String?,
        requiresEncryption: Bool
    ) async throws {
        let configuration = try SMBConnectionConfiguration(
            displayName: displayName,
            host: host,
            share: share,
            domain: domain,
            requiresEncryption: requiresEncryption
        )
        let credential = try SMBCredential(username: username, password: password)
        let source = makeSource(
            configuration: configuration,
            credential: credential,
            context: diagnosticContext
        )

        do {
            try await source.connect()
            try await credentialStore.save(
                sourceID: configuration.sourceID,
                credential: credential,
                domain: configuration.domain
            )
            let storedSource = SMBStorageSource.from(configuration: configuration)
            try await sourceStore.add(storedSource)
            sources.append(ConnectedSource(
                id: configuration.sourceID,
                displayName: configuration.displayName,
                username: credential.username,
                source: source,
                configuration: configuration
            ))
            configuredSources.append(ConfiguredSource(
                id: configuration.sourceID,
                displayName: configuration.displayName,
                username: credential.username,
                configuration: configuration,
                connectionState: .connected
            ))
            await syncCoordinator?.enqueue(.upsertSource(storedSource.syncedSource))
            sourceRevision &+= 1
        } catch {
            await source.disconnect()
            throw error
        }
    }

    func updateSMBSource(
        id: UUID,
        displayName: String,
        host: String,
        share: String,
        username: String,
        replacementPassword: String?,
        domain: String?,
        requiresEncryption: Bool
    ) async throws {
        guard configuredSources.contains(where: { $0.id == id }) else {
            throw SMBSourceStoreError.sourceNotFound(id)
        }
        guard let sourceIndex = sources.firstIndex(where: { $0.id == id }) else {
            try await reconnectSMBSource(
                id: id,
                displayName: displayName,
                host: host,
                share: share,
                username: username,
                replacementPassword: replacementPassword,
                domain: domain,
                requiresEncryption: requiresEncryption
            )
            return
        }

        let storedSources = try await sourceStore.load()
        guard let previousStorage = storedSources.first(where: { $0.id == id }) else {
            throw SMBSourceStoreError.sourceNotFound(id)
        }
        guard let storedCredential = try await credentialStore.load(sourceID: id) else {
            throw MediaSourceError.notConnected
        }
        let password = replacementPassword ?? storedCredential.credential.password
        let configuration = try SMBConnectionConfiguration(
            sourceID: id,
            displayName: displayName,
            host: host,
            share: share,
            domain: domain,
            requiresEncryption: requiresEncryption
        )
        let credential = try SMBCredential(username: username, password: password)
        let replacementSource = makeSource(
            configuration: configuration,
            credential: credential,
            context: diagnosticContext
        )

        do {
            try await replacementSource.connect()
        } catch {
            await replacementSource.disconnect()
            throw error
        }

        let updatedStorage = SMBStorageSource.from(configuration: configuration)
        do {
            try await sourceStore.update(updatedStorage)
        } catch {
            await replacementSource.disconnect()
            throw SMBSourceUpdateError.changesNotSaved
        }

        do {
            try await credentialStore.save(
                sourceID: id,
                credential: credential,
                domain: configuration.domain
            )
        } catch {
            do {
                try await sourceStore.update(previousStorage)
            } catch {
                await replacementSource.disconnect()
                throw SMBSourceUpdateError.credentialRollbackFailed
            }
            await replacementSource.disconnect()
            throw SMBSourceUpdateError.changesNotSaved
        }

        let previousSource = sources[sourceIndex].source
        sources[sourceIndex] = ConnectedSource(
            id: configuration.sourceID,
            displayName: configuration.displayName,
            username: credential.username,
            source: replacementSource,
            configuration: configuration
        )
        sourceRevision &+= 1
        replaceConfigured(
            configuration: configuration,
            username: credential.username,
            state: .connected
        )
        await syncCoordinator?.enqueue(.upsertSource(updatedStorage.syncedSource))
        await previousSource.disconnect()
    }

    private func reconnectSMBSource(
        id: UUID,
        displayName: String,
        host: String,
        share: String,
        username: String,
        replacementPassword: String?,
        domain: String?,
        requiresEncryption: Bool
    ) async throws {
        let storedSources = try await sourceStore.load()
        guard let previousStorage = storedSources.first(where: { $0.id == id }) else {
            throw SMBSourceStoreError.sourceNotFound(id)
        }
        let existingCredential = try await credentialStore.load(sourceID: id)
        guard let password = replacementPassword ?? existingCredential?.credential.password else {
            throw MediaSourceError.authenticationFailed
        }
        let configuration = try SMBConnectionConfiguration(
            sourceID: id,
            displayName: displayName,
            host: host,
            share: share,
            domain: domain,
            requiresEncryption: requiresEncryption
        )
        let credential = try SMBCredential(username: username, password: password)
        let source = makeSource(
            configuration: configuration,
            credential: credential,
            context: diagnosticContext
        )
        do {
            try await source.connect()
        } catch {
            await source.disconnect()
            throw error
        }

        let updatedStorage = SMBStorageSource.from(configuration: configuration)
        do {
            try await sourceStore.update(updatedStorage)
            do {
                try await credentialStore.save(
                    sourceID: id,
                    credential: credential,
                    domain: configuration.domain
                )
            } catch {
                try? await sourceStore.update(previousStorage)
                throw error
            }
        } catch {
            await source.disconnect()
            throw error
        }

        sources.append(ConnectedSource(
            id: id,
            displayName: configuration.displayName,
            username: credential.username,
            source: source,
            configuration: configuration
        ))
        replaceConfigured(
            configuration: configuration,
            username: credential.username,
            state: .connected
        )
        sourceRevision &+= 1
        await syncCoordinator?.enqueue(.upsertSource(updatedStorage.syncedSource))
    }

    func removeSource(id: UUID) async {
        guard configuredSources.contains(where: { $0.id == id }) else { return }
        if let index = sources.firstIndex(where: { $0.id == id }) {
            let source = sources.remove(at: index)
            await source.source.disconnect()
        }
        try? await credentialStore.delete(sourceID: id)
        try? await sourceStore.remove(id: id)
        configuredSources.removeAll { $0.id == id }
        await syncCoordinator?.enqueue(.deleteSource(id: id, modifiedAt: Date()))
        sourceRevision &+= 1
    }

    func source(id: UUID?) -> ConnectedSource? {
        sources.first { $0.id == id }
    }

    func configuredSource(id: UUID?) -> ConfiguredSource? {
        configuredSources.first { $0.id == id }
    }

    func makePlaybackDiagnosticDependencies() -> PlaybackDiagnosticDependencies {
        PlaybackDiagnosticDependencies(
            recorder: diagnosticRecorder,
            context: DiagnosticContext(
                appRunID: diagnosticContext.appRunID,
                activityID: UUID(),
                operationID: UUID(),
                parentOperationID: diagnosticContext.operationID
            ),
            identityProvider: identityProvider
        )
    }

    var mediaLibrarySources: [MediaLibrarySource] {
        sources.map { connected in
            let source = connected.source
            return MediaLibrarySource(
                id: connected.id,
                displayName: connected.displayName
            ) { directory in
                try await source.list(directory: directory)
            }
        }
    }

    var mediaLibrarySourceSummaries: [MediaLibrarySourceSummary] {
        sources.map { connected in
            MediaLibrarySourceSummary(
                id: connected.id,
                displayName: connected.displayName
            )
        }
    }

    func smbURL(for sourceID: UUID, path: String) -> URL? {
        guard let connected = sources.first(where: { $0.id == sourceID }) else {
            return nil
        }
        let cfg = connected.configuration
        return URL(string: "smb://\(cfg.host)/\(cfg.share)\(path)")
    }

    func list(sourceID: UUID, directory path: String) async throws -> [MediaSourceItem] {
        guard let connected = sources.first(where: { $0.id == sourceID }) else {
            throw MediaSourceError.notConnected
        }
        return try await connected.source.list(directory: path)
    }

    private func makeSource(
        configuration: SMBConnectionConfiguration,
        credential: SMBCredential,
        context: DiagnosticContext
    ) -> any MediaSource {
        if let sourceFactory {
            return sourceFactory(configuration, credential)
        }
        let client = LibSMB2Client(
            configuration: configuration,
            credential: credential,
            diagnosticRecorder: diagnosticRecorder,
            diagnosticContext: context,
            identityProvider: identityProvider
        )
        return SMBMediaSource(
            configuration: configuration,
            client: client,
            diagnosticRecorder: diagnosticRecorder,
            diagnosticContext: context,
            identityProvider: identityProvider
        )
    }

    private func configuration(from stored: SMBStorageSource) throws -> SMBConnectionConfiguration {
        try SMBConnectionConfiguration(
            sourceID: stored.id,
            displayName: stored.displayName,
            host: stored.host,
            share: stored.share,
            domain: stored.domain,
            requiresEncryption: stored.requiresEncryption
        )
    }

    private func updateConfiguredState(
        id: UUID,
        username: String? = nil,
        state: SourceConnectionState
    ) {
        guard let index = configuredSources.firstIndex(where: { $0.id == id }) else { return }
        let current = configuredSources[index]
        configuredSources[index] = ConfiguredSource(
            id: current.id,
            displayName: current.displayName,
            username: username ?? current.username,
            configuration: current.configuration,
            connectionState: state
        )
    }

    private func replaceConfigured(
        configuration: SMBConnectionConfiguration,
        username: String?,
        state: SourceConnectionState
    ) {
        configuredSources.removeAll { $0.id == configuration.sourceID }
        configuredSources.append(ConfiguredSource(
            id: configuration.sourceID,
            displayName: configuration.displayName,
            username: username,
            configuration: configuration,
            connectionState: state
        ))
    }

    static func connectionErrorMessage(for error: Error) -> String {
        switch error {
        case SMBConfigurationError.emptyDisplayName:
            "Enter a source name."
        case SMBConfigurationError.emptyHost:
            "Enter a NAS host name or IP address."
        case SMBConfigurationError.invalidHost:
            "Enter only a host name or IP address, without a path or port."
        case SMBConfigurationError.emptyShare:
            "Enter an SMB share name."
        case SMBConfigurationError.invalidShare:
            "Enter a share name without folders."
        case SMBConfigurationError.emptyUsername:
            "Enter an SMB username."
        case SMBConfigurationError.invalidPath:
            "The SMB path is invalid."
        case MediaSourceError.authenticationFailed:
            "Authentication failed. Check the username, password, and domain."
        case MediaSourceError.unreachable:
            "The NAS could not be reached. Check the network and SMB settings."
        case MediaSourceError.notFound:
            "The SMB share could not be found."
        case is KeychainCredentialStoreError:
            "The credentials could not be saved securely."
        case SMBSourceUpdateError.changesNotSaved:
            "The changes could not be saved. Your previous source settings are still active."
        case SMBSourceUpdateError.credentialRollbackFailed:
            "The changes were not saved, and the previous credentials could not be restored."
        default:
            "The SMB source could not be connected."
        }
    }
}

private extension SMBStorageSource {
    var syncedSource: SyncedSMBSource {
        SyncedSMBSource(
            id: id,
            displayName: displayName,
            host: host,
            share: share,
            domain: domain,
            requiresEncryption: requiresEncryption,
            modifiedAt: modifiedAt
        )
    }
}

private extension SyncedSMBSource {
    var storageSource: SMBStorageSource {
        SMBStorageSource(
            id: id,
            displayName: displayName,
            host: host,
            share: share,
            domain: domain,
            requiresEncryption: requiresEncryption,
            modifiedAt: modifiedAt
        )
    }
}

private func finishAppSourceOperation(
    _ operation: DiagnosticOperation,
    error: Error,
    sourceID: UUID
) {
    if error is CancellationError {
        operation.end(
            outcome: .cancelled,
            payload: DiagnosticPayload(sourceID: sourceID)
        )
        return
    }
    let code: DiagnosticErrorCode
    switch error {
    case MediaSourceError.notConnected:
        code = .sourceNotConnected
    case MediaSourceError.authenticationFailed:
        code = .sourceAuthenticationFailed
    case MediaSourceError.unreachable:
        code = .sourceUnreachable
    case MediaSourceError.notFound:
        code = .sourceNotFound
    case MediaSourceError.invalidRead:
        code = .sourceInvalidRead
    case MediaSourceError.readFailed:
        code = .sourceReadFailed
    case MediaSourceError.remoteFileChanged:
        code = .sourceRemoteFileChanged
    case MediaSourceError.unsupported:
        code = .sourceUnsupported
    default:
        code = .sourceUnreachable
    }
    operation.end(
        outcome: .failure,
        payload: DiagnosticPayload(sourceID: sourceID),
        error: DiagnosticErrorDescriptor(code: code)
    )
}
