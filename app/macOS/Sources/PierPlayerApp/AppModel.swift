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

    @Published private(set) var snapshot: PlaybackSnapshot = .idle
    @Published private(set) var sources: [ConnectedSource] = []
    @Published private(set) var isRestoring = true
    @Published private(set) var sourceRevision = 0

    let playbackSession: PlaybackSession
    private let credentialStore: any SMBCredentialStore
    private let sourceStore: any SMBSourceStoring
    private let diagnosticRecorder: any DiagnosticRecording
    private let diagnosticContext: DiagnosticContext
    private let identityProvider: (any DiagnosticIdentityProviding)?
    private let sourceFactory: SourceFactory?

    init(
        playbackSession: PlaybackSession = PlaybackSession(),
        credentialStore: any SMBCredentialStore = KeychainCredentialStore(),
        sourceStore: (any SMBSourceStoring)? = nil,
        diagnosticRecorder: any DiagnosticRecording = NoopDiagnosticRecorder(),
        diagnosticContext: DiagnosticContext? = nil,
        identityProvider: (any DiagnosticIdentityProviding)? = nil,
        sourceFactory: SourceFactory? = nil
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

        for stored in storedSources {
            let restoreOperation = DiagnosticOperation(
                recorder: diagnosticRecorder,
                parentContext: operation.context,
                name: .sourceRestore,
                payload: DiagnosticPayload(sourceID: stored.id),
                persistence: .essential
            )
            do {
                try await restoreSource(stored, context: restoreOperation.context)
                restoreOperation.end(
                    outcome: .success,
                    payload: DiagnosticPayload(sourceID: stored.id)
                )
            } catch {
                finishAppSourceOperation(
                    restoreOperation,
                    error: error,
                    sourceID: stored.id
                )
            }
        }
        operation.end(outcome: .success)
    }

    private func restoreSource(
        _ stored: SMBStorageSource,
        context: DiagnosticContext
    ) async throws {
        guard let storedCredential = try await credentialStore.load(sourceID: stored.id) else {
            throw MediaSourceError.notConnected
        }
        let credential = storedCredential.credential
        let configuration = try SMBConnectionConfiguration(
            sourceID: stored.id,
            displayName: stored.displayName,
            host: stored.host,
            share: stored.share,
            domain: stored.domain,
            requiresEncryption: stored.requiresEncryption
        )
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
            try await sourceStore.add(SMBStorageSource.from(configuration: configuration))
            sources.append(ConnectedSource(
                id: configuration.sourceID,
                displayName: configuration.displayName,
                username: credential.username,
                source: source,
                configuration: configuration
            ))
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
        guard let sourceIndex = sources.firstIndex(where: { $0.id == id }) else {
            throw SMBSourceStoreError.sourceNotFound(id)
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

        do {
            try await sourceStore.update(SMBStorageSource.from(
                configuration: configuration
            ))
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
        await previousSource.disconnect()
    }

    func removeSource(id: UUID) async {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        let source = sources[index]
        await source.source.disconnect()
        try? await credentialStore.delete(sourceID: id)
        try? await sourceStore.remove(id: id)
        sources.remove(at: index)
        sourceRevision &+= 1
    }

    func source(id: UUID?) -> ConnectedSource? {
        sources.first { $0.id == id }
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
