import Foundation

enum PlaybackHistoryEntryError: Error, Equatable, Sendable {
    case invalidMediaID
    case invalidPath
}

struct PlaybackHistoryEntry: Codable, Equatable, Identifiable, Sendable {
    let mediaID: String
    let sourceID: UUID
    let sourceDisplayName: String
    let fileName: String
    let path: String
    let size: Int64
    let modifiedAt: Date?
    let lastPlayedAt: Date

    var id: String { mediaID }

    init(
        mediaID: String,
        sourceID: UUID,
        sourceDisplayName: String,
        fileName: String,
        path: String,
        size: Int64,
        modifiedAt: Date?,
        lastPlayedAt: Date = Date()
    ) throws {
        guard mediaID.count == 64, mediaID.allSatisfy(\.isHexDigit) else {
            throw PlaybackHistoryEntryError.invalidMediaID
        }
        self.mediaID = mediaID.lowercased()
        self.sourceID = sourceID
        self.sourceDisplayName = sourceDisplayName
        self.fileName = fileName
        self.path = try Self.normalize(path)
        self.size = size
        self.modifiedAt = modifiedAt
        self.lastPlayedAt = lastPlayedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            mediaID: values.decode(String.self, forKey: .mediaID),
            sourceID: values.decode(UUID.self, forKey: .sourceID),
            sourceDisplayName: values.decode(String.self, forKey: .sourceDisplayName),
            fileName: values.decode(String.self, forKey: .fileName),
            path: values.decode(String.self, forKey: .path),
            size: values.decode(Int64.self, forKey: .size),
            modifiedAt: values.decodeIfPresent(Date.self, forKey: .modifiedAt),
            lastPlayedAt: values.decode(Date.self, forKey: .lastPlayedAt)
        )
    }

    private static func normalize(_ path: String) throws -> String {
        guard !path.contains("\\"),
              !path.contains("\0"),
              !path.hasPrefix("//"),
              let urlComponents = URLComponents(string: path),
              urlComponents.scheme == nil,
              urlComponents.host == nil else {
            throw PlaybackHistoryEntryError.invalidPath
        }

        var components: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                throw PlaybackHistoryEntryError.invalidPath
            default:
                components.append(component)
            }
        }
        return components.isEmpty ? "/" : "/" + components.joined(separator: "/")
    }
}

protocol PlaybackHistoryStoring: Sendable {
    func upsert(_ entry: PlaybackHistoryEntry) async throws
    func load() async throws -> [PlaybackHistoryEntry]
    func removeAll(sourceID: UUID) async throws
}

actor PlaybackHistoryStore: PlaybackHistoryStoring {
    private let decoder = JSONDecoder()
    private let encoder: JSONEncoder
    private let fileURL: URL

    init() throws {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        self.fileURL = appSupport
            .appendingPathComponent("PierPlayer", isDirectory: true)
            .appendingPathComponent("playback-history.json")
        self.encoder = Self.makeEncoder()
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
        self.encoder = Self.makeEncoder()
    }

    func load() throws -> [PlaybackHistoryEntry] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        guard let entries = try? decoder.decode([PlaybackHistoryEntry].self, from: data) else {
            return []
        }
        return entries.sorted(by: Self.isLoadedBefore)
    }

    func upsert(_ entry: PlaybackHistoryEntry) throws {
        var entries = try load()
        entries.removeAll {
            $0.mediaID == entry.mediaID
                || ($0.sourceID == entry.sourceID && $0.path == entry.path)
        }
        entries.append(entry)
        try save(entries)
    }

    func removeAll(sourceID: UUID) throws {
        try save(try load().filter { $0.sourceID != sourceID })
    }

    private func save(_ entries: [PlaybackHistoryEntry]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(entries.sorted(by: Self.isPersistedBefore))
        try data.write(to: fileURL, options: .atomic)
    }

    private static func isLoadedBefore(
        _ lhs: PlaybackHistoryEntry,
        _ rhs: PlaybackHistoryEntry
    ) -> Bool {
        if lhs.lastPlayedAt != rhs.lastPlayedAt {
            return lhs.lastPlayedAt > rhs.lastPlayedAt
        }
        return isPersistedBefore(lhs, rhs)
    }

    private static func isPersistedBefore(
        _ lhs: PlaybackHistoryEntry,
        _ rhs: PlaybackHistoryEntry
    ) -> Bool {
        let lhsSourceID = lhs.sourceID.uuidString.lowercased()
        let rhsSourceID = rhs.sourceID.uuidString.lowercased()
        if lhsSourceID != rhsSourceID { return lhsSourceID < rhsSourceID }
        if lhs.path != rhs.path { return lhs.path < rhs.path }
        return lhs.mediaID < rhs.mediaID
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
