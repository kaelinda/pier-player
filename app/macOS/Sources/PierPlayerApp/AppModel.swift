import MediaSourceKit
import PlaybackCore
import SMBSourceKit
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
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

    init(
        playbackSession: PlaybackSession = PlaybackSession(),
        credentialStore: any SMBCredentialStore = KeychainCredentialStore()
    ) {
        self.playbackSession = playbackSession
        self.credentialStore = credentialStore
        self.sourceStore = (try? SMBSourceStore()) ?? SMBSourceStore(fallback: ())
    }

    func restore() async {
        isRestoring = true
        defer { isRestoring = false }

        let logPath = FileManager.default.temporaryDirectory.appendingPathComponent("pier_restore.log")
        let logPrefix = "[restore]"

        func log(_ msg: String) {
            let line = "\(logPrefix) \(msg)\n"
            try? line.write(to: logPath, atomically: true, encoding: .utf8)
        }

        let storedSources: [SMBStorageSource]
        do {
            storedSources = try await sourceStore.load()
            log("loaded \(storedSources.count) sources from store")
        } catch {
            log("FAILED to load sources: \(error)")
            return
        }

        for stored in storedSources {
            do {
                try await restoreSource(stored, log: log)
            } catch {
                log("OUTER FAILURE for \(stored.displayName): \(type(of: error)) - \(error)")
            }
        }
    }

    private func restoreSource(_ stored: SMBStorageSource, log: (String) -> Void) async throws {
        log("attempting to restore: \(stored.displayName) id=\(stored.id)")
        log("creating credential from stored username=\(stored.username)")
        let credential = try SMBCredential(username: stored.username, password: stored.password)
        log("credential created")
        let configuration = try SMBConnectionConfiguration(
            sourceID: stored.id,
            displayName: stored.displayName,
            host: stored.host,
            share: stored.share,
            domain: stored.domain,
            requiresEncryption: stored.requiresEncryption
        )
        log("configuration created")
        let client = LibSMB2Client(configuration: configuration, credential: credential)
        let source = SMBMediaSource(configuration: configuration, client: client)
        log("connecting to SMB server...")
        try await source.connect()
        sources.append(ConnectedSource(
            id: configuration.sourceID,
            displayName: configuration.displayName,
            source: source,
            configuration: configuration
        ))
        log("connected to \(configuration.displayName)")
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
        let client = LibSMB2Client(configuration: configuration, credential: credential)
        let source = SMBMediaSource(configuration: configuration, client: client)

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
