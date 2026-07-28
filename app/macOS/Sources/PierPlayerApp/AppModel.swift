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
        let rootItems: [MediaSourceItem]
    }

    @Published private(set) var snapshot: PlaybackSnapshot = .idle
    @Published private(set) var sources: [ConnectedSource] = []

    let playbackSession: PlaybackSession
    private let credentialStore: any SMBCredentialStore

    init(
        playbackSession: PlaybackSession = PlaybackSession(),
        credentialStore: any SMBCredentialStore = KeychainCredentialStore()
    ) {
        self.playbackSession = playbackSession
        self.credentialStore = credentialStore
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
            let rootItems = try await source.list(directory: "/")
            try await credentialStore.save(
                sourceID: configuration.sourceID,
                credential: credential,
                domain: configuration.domain
            )
            sources.append(ConnectedSource(
                id: configuration.sourceID,
                displayName: configuration.displayName,
                source: source,
                rootItems: rootItems
            ))
        } catch {
            await source.disconnect()
            throw error
        }
    }

    func source(id: UUID?) -> ConnectedSource? {
        sources.first { $0.id == id }
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
