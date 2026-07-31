import Foundation

public actor SyncStateStore {
    private let decoder = JSONDecoder()
    private let encoder: JSONEncoder
    private let fileURL: URL

    public init(storeName: String = "sync-state") throws {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = appSupport.appendingPathComponent("PierPlayer", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.fileURL = directory.appendingPathComponent("\(storeName).json")
        self.encoder = Self.makeEncoder()
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
        self.encoder = Self.makeEncoder()
    }

    public func pendingMutations() throws -> [CloudSyncMutation] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return (try? decoder.decode([CloudSyncMutation].self, from: data)) ?? []
    }

    public func enqueue(_ mutation: CloudSyncMutation) throws {
        var mutations = try pendingMutations()
        mutations.removeAll { $0.key == mutation.key }
        mutations.append(mutation)
        try save(mutations)
    }

    public func remove(_ uploaded: [CloudSyncMutation]) throws {
        let keys = Set(uploaded.map(\.key))
        try save(try pendingMutations().filter { !keys.contains($0.key) })
    }

    private func save(_ mutations: [CloudSyncMutation]) throws {
        try encoder.encode(mutations).write(to: fileURL, options: .atomic)
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
