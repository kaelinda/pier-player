import DiagnosticsKit
import MediaSourceKit
import PlaybackCore
import SMBSourceKit
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    struct PlaybackDiagnosticDependencies {
        let recorder: any DiagnosticRecording
        let context: DiagnosticContext
        let identityProvider: (any DiagnosticIdentityProviding)?
    }

    struct ConnectedSource: Identifiable {
        let id: UUID
        let displayName: String
        let source: SMBMediaSource
        let configuration: SMBConnectionConfiguration
    }

    @Published private(set) var snapshot: PlaybackSnapshot = .idle
    @Published private(set) var sources: [ConnectedSource] = []
    @Published private(set) var isRestoring = true

    let playbackSession: PlaybackSession
    private let credentialStore: any SMBCredentialStore
    private let sourceStore: SMBSourceStore
    private let diagnosticRecorder: any DiagnosticRecording
    private let diagnosticContext: DiagnosticContext
    private let identityProvider: (any DiagnosticIdentityProviding)?

    init(
        playbackSession: PlaybackSession = PlaybackSession(),
        credentialStore: any SMBCredentialStore = KeychainCredentialStore(),
        sourceStore: SMBSourceStore? = nil,
        diagnosticRecorder: any DiagnosticRecording = NoopDiagnosticRecorder(),
        diagnosticContext: DiagnosticContext? = nil,
        identityProvider: (any DiagnosticIdentityProviding)? = nil
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
        let credential = try SMBCredential(username: stored.username, password: stored.password)
        let configuration = try SMBConnectionConfiguration(
            sourceID: stored.id,
            displayName: stored.displayName,
            host: stored.host,
            share: stored.share,
            domain: stored.domain,
            requiresEncryption: stored.requiresEncryption
        )
        let client = LibSMB2Client(
            configuration: configuration,
            credential: credential,
            diagnosticRecorder: diagnosticRecorder,
            diagnosticContext: context,
            identityProvider: identityProvider
        )
        let source = SMBMediaSource(
            configuration: configuration,
            client: client,
            diagnosticRecorder: diagnosticRecorder,
            diagnosticContext: context,
            identityProvider: identityProvider
        )
        try await source.connect()
        sources.append(ConnectedSource(
            id: configuration.sourceID,
            displayName: configuration.displayName,
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
        let client = LibSMB2Client(
            configuration: configuration,
            credential: credential,
            diagnosticRecorder: diagnosticRecorder,
            diagnosticContext: diagnosticContext,
            identityProvider: identityProvider
        )
        let source = SMBMediaSource(
            configuration: configuration,
            client: client,
            diagnosticRecorder: diagnosticRecorder,
            diagnosticContext: diagnosticContext,
            identityProvider: identityProvider
        )

        do {
            try await source.connect()
            try await credentialStore.save(
                sourceID: configuration.sourceID,
                credential: credential,
                domain: configuration.domain
            )
            try await sourceStore.add(SMBStorageSource.from(configuration: configuration, credential: credential))
            sources.append(ConnectedSource(
                id: configuration.sourceID,
                displayName: configuration.displayName,
                source: source,
                configuration: configuration
            ))
        } catch {
            await source.disconnect()
            throw error
        }
    }

    func removeSource(id: UUID) async {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        let source = sources[index]
        await source.source.disconnect()
        try? await credentialStore.delete(sourceID: id)
        try? await sourceStore.remove(id: id)
        sources.remove(at: index)
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
