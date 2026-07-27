import Foundation

public struct PlaybackSessionReport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let sessionID: UUID
    public let sourceID: UUID
    public let fileID: UUID
    public let environmentLabel: String
    public let startedAt: Date
    public let endedAt: Date
    public let snapshots: [PlaybackMetricSnapshot]

    public init(
        sessionID: UUID,
        sourceID: UUID,
        fileID: UUID,
        environmentLabel: String,
        startedAt: Date,
        endedAt: Date,
        snapshots: [PlaybackMetricSnapshot]
    ) {
        self.schemaVersion = 1
        self.sessionID = sessionID
        self.sourceID = sourceID
        self.fileID = fileID
        self.environmentLabel = environmentLabel
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.snapshots = snapshots
    }

    public var averageNetworkBytesPerSecond: Double {
        guard !snapshots.isEmpty else { return 0 }
        let total = snapshots.reduce(0) { $0 + $1.networkBytesPerSecond }
        return total / Double(snapshots.count)
    }

    public var maximumResidentBytes: UInt64 {
        snapshots.map(\.residentBytes).max() ?? 0
    }

    public var totalStallCount: UInt64 {
        snapshots.map(\.stallCount).max() ?? 0
    }
}

public enum PlaybackSessionReportEncoder {
    public static func encode(_ report: PlaybackSessionReport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(report)
    }
}
