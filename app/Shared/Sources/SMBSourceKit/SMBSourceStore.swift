import Foundation

public enum SMBSourceStoreError: Error, Equatable, Sendable {
    case sourceNotFound(UUID)
}

public protocol SMBSourceStoring: Sendable {
    func load() async throws -> [SMBStorageSource]
    func add(_ source: SMBStorageSource) async throws
    func update(_ source: SMBStorageSource) async throws
    func remove(id: UUID) async throws
    func migrateCredentials(to credentialStore: any SMBCredentialStore) async throws
    func replaceAll(_ sources: [SMBStorageSource]) async throws
}

public extension SMBSourceStoring {
    func migrateCredentials(to credentialStore: any SMBCredentialStore) async throws {}

    func replaceAll(_ sources: [SMBStorageSource]) async throws {
        let existing = try await load()
        for source in existing where !sources.contains(where: { $0.id == source.id }) {
            try await remove(id: source.id)
        }
        for source in sources {
            if existing.contains(where: { $0.id == source.id }) {
                try await update(source)
            } else {
                try await add(source)
            }
        }
    }
}

/// Persisted non-secret SMB source configuration.
public struct SMBStorageSource: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let displayName: String
    public let host: String
    public let share: String
    public let domain: String?
    public let requiresEncryption: Bool
    public let modifiedAt: Date

    public init(
        id: UUID = UUID(),
        displayName: String,
        host: String,
        share: String,
        domain: String? = nil,
        requiresEncryption: Bool = false,
        modifiedAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.host = host
        self.share = share
        self.domain = domain
        self.requiresEncryption = requiresEncryption
        self.modifiedAt = modifiedAt
    }

    public static func from(
        configuration: SMBConnectionConfiguration,
        modifiedAt: Date = Date()
    ) -> SMBStorageSource {
        SMBStorageSource(
            id: configuration.sourceID,
            displayName: configuration.displayName,
            host: configuration.host,
            share: configuration.share,
            domain: configuration.domain,
            requiresEncryption: configuration.requiresEncryption,
            modifiedAt: modifiedAt
        )
    }
}

private struct LegacySMBStorageSource: Decodable {
    let id: UUID
    let displayName: String
    let host: String
    let share: String
    let username: String
    let password: String
    let domain: String?
    let requiresEncryption: Bool
}

/// Manages SMB source configurations persisted as JSON in Application Support.
/// Credentials are stored separately in the system Keychain.
public actor SMBSourceStore {
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let fileURL: URL

    /// Creates a store for the given store name, creating the directory if needed.
    public init(storeName: String = "sources") throws {
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()

        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let pierDir = appSupport.appendingPathComponent("PierPlayer", isDirectory: true)
        try FileManager.default.createDirectory(at: pierDir, withIntermediateDirectories: true)
        self.fileURL = pierDir.appendingPathComponent("\(storeName).json")
    }

    /// Fallback initializer that writes to /dev/null — only used when Application Support
    /// is inaccessible. Saves will silently no-op in that case.
    public init(fallback: ()) {
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.fileURL = URL(fileURLWithPath: "/dev/null")
    }

    init(fileURL: URL) {
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.fileURL = fileURL
    }

    /// Loads all stored source configurations, skipping entries that fail to decode.
    public func load() throws -> [SMBStorageSource] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }
        let data = try Data(contentsOf: fileURL)
        let allItems = try decoder.decode([SMBStorageSource].self, from: data)
        return allItems
    }

    /// Saves the list of source configurations, replacing any existing data.
    public func save(_ sources: [SMBStorageSource]) throws {
        let data = try encoder.encode(sources)
        try data.write(to: fileURL, options: .atomic)
    }

    /// Adds a new source configuration.
    public func add(_ source: SMBStorageSource) throws {
        var sources = (try? load()) ?? []
        sources.append(source)
        try save(sources)
    }

    /// Replaces an existing source configuration without changing its list position.
    public func update(_ source: SMBStorageSource) throws {
        var sources = try load()
        guard let index = sources.firstIndex(where: { $0.id == source.id }) else {
            throw SMBSourceStoreError.sourceNotFound(source.id)
        }
        sources[index] = source
        try save(sources)
    }

    /// Removes a source configuration by ID.
    public func remove(id: UUID) throws {
        var sources = (try? load()) ?? []
        sources.removeAll { $0.id == id }
        try save(sources)
    }

    public func replaceAll(_ sources: [SMBStorageSource]) throws {
        try save(sources)
    }

    public func migrateCredentials(
        to credentialStore: any SMBCredentialStore
    ) async throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let data = try Data(contentsOf: fileURL)
        if (try? decoder.decode([SMBStorageSource].self, from: data)) != nil {
            return
        }

        let legacySources = try decoder.decode([LegacySMBStorageSource].self, from: data)
        var migrated: [SMBStorageSource] = []
        migrated.reserveCapacity(legacySources.count)
        for source in legacySources {
            let credential = try SMBCredential(
                username: source.username,
                password: source.password
            )
            try await credentialStore.save(
                sourceID: source.id,
                credential: credential,
                domain: source.domain
            )
            migrated.append(SMBStorageSource(
                id: source.id,
                displayName: source.displayName,
                host: source.host,
                share: source.share,
                domain: source.domain,
                requiresEncryption: source.requiresEncryption
            ))
        }
        try save(migrated)
    }
}

extension SMBSourceStore: SMBSourceStoring {}
