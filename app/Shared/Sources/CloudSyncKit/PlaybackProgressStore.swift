import Foundation

public actor PlaybackProgressStore: PlaybackProgressStoring {
    private let decoder = JSONDecoder()
    private let encoder: JSONEncoder
    private let fileURL: URL

    public init(storeName: String = "sync-progress") throws {
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

    public func load() throws -> [PlaybackProgress] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return (try? decoder.decode([PlaybackProgress].self, from: data)) ?? []
    }

    public func progress(mediaID: String) throws -> PlaybackProgress? {
        try load().first { $0.mediaID == mediaID }
    }

    func record(
        mediaID: String,
        sourceID: UUID,
        position: TimeInterval,
        duration: TimeInterval,
        modifiedAt: Date
    ) throws -> PlaybackProgress {
        var values = try load()
        let existingIndex = values.firstIndex { $0.mediaID == mediaID }
        let completionOverride = position < 5
            ? existingIndex.map { values[$0].isCompleted }
            : nil
        let progress = try PlaybackProgress(
            mediaID: mediaID,
            sourceID: sourceID,
            position: position,
            duration: duration,
            modifiedAt: modifiedAt,
            isCompleted: completionOverride
        )
        if let existingIndex {
            values[existingIndex] = progress
        } else {
            values.append(progress)
        }
        try save(values)
        return progress
    }

    public func upsert(_ progress: PlaybackProgress) throws {
        var values = try load()
        if let index = values.firstIndex(where: { $0.mediaID == progress.mediaID }) {
            values[index] = progress
        } else {
            values.append(progress)
        }
        try save(values)
    }

    public func removeAll(sourceID: UUID) throws {
        try save(try load().filter { $0.sourceID != sourceID })
    }

    public func replaceAll(_ values: [PlaybackProgress]) throws {
        try save(values)
    }

    public func restore(_ snapshot: [PlaybackProgress], sourceID: UUID) throws {
        let current = try load()
        try save(current.filter { $0.sourceID != sourceID } + snapshot)
    }

    private func save(_ values: [PlaybackProgress]) throws {
        let sorted = values.sorted { $0.mediaID < $1.mediaID }
        try encoder.encode(sorted).write(to: fileURL, options: .atomic)
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
