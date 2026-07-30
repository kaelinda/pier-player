import Foundation

public enum DiagnosticCollectionPolicy: String, Codable, Equatable, Sendable {
    case standard
    case detailed
    case incident
}

public enum DiagnosticArchitecture: String, Codable, Equatable, Sendable {
    case arm64
    case x86_64
    case other
}

public enum DiagnosticHardwareClass: String, Codable, Equatable, Sendable {
    case mac
    case iPhone
    case iPad
    case appleTV
    case other
}

public enum DiagnosticNetworkAvailability: String, Codable, Equatable, Sendable {
    case available
    case unavailable
    case unknown
}

public enum DiagnosticNetworkInterface: String, Codable, Equatable, Sendable {
    case ethernet
    case wifi
    case cellular
    case other
    case none
}

public struct DiagnosticRunEnvironment: Codable, Equatable, Sendable {
    public let appVersion: String
    public let appBuild: String
    public let osVersion: String
    public let architecture: DiagnosticArchitecture
    public let hardwareClass: DiagnosticHardwareClass
    public let networkAvailability: DiagnosticNetworkAvailability
    public let networkInterface: DiagnosticNetworkInterface

    public init(
        appVersion: String,
        appBuild: String,
        osVersion: String,
        architecture: DiagnosticArchitecture,
        hardwareClass: DiagnosticHardwareClass,
        networkAvailability: DiagnosticNetworkAvailability,
        networkInterface: DiagnosticNetworkInterface
    ) {
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.osVersion = osVersion
        self.architecture = architecture
        self.hardwareClass = hardwareClass
        self.networkAvailability = networkAvailability
        self.networkInterface = networkInterface
    }
}

public struct DiagnosticRunManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let runID: UUID
    public let startedAt: Date
    public let endedAt: Date?
    public let policy: DiagnosticCollectionPolicy
    public let environment: DiagnosticRunEnvironment

    public init(
        runID: UUID,
        startedAt: Date,
        endedAt: Date? = nil,
        policy: DiagnosticCollectionPolicy,
        environment: DiagnosticRunEnvironment
    ) {
        self.schemaVersion = 1
        self.runID = runID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.policy = policy
        self.environment = environment
    }

    func ending(at date: Date) -> DiagnosticRunManifest {
        DiagnosticRunManifest(
            runID: runID,
            startedAt: startedAt,
            endedAt: date,
            policy: policy,
            environment: environment
        )
    }
}

public struct DiagnosticRunSummary: Codable, Equatable, Sendable {
    public let runID: UUID
    public let startedAt: Date
    public let endedAt: Date?
    public let policy: DiagnosticCollectionPolicy
    public let byteCount: Int64

    public init(
        runID: UUID,
        startedAt: Date,
        endedAt: Date?,
        policy: DiagnosticCollectionPolicy,
        byteCount: Int64
    ) {
        self.runID = runID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.policy = policy
        self.byteCount = byteCount
    }
}

public struct DiagnosticStoreSnapshot: Sendable {
    public let manifest: DiagnosticRunManifest
    public let eventSegments: [Data]
    public let metricSegments: [Data]
    public let eventSegmentURLs: [URL]
    public let metricSegmentURLs: [URL]

    public init(
        manifest: DiagnosticRunManifest,
        eventSegments: [Data],
        metricSegments: [Data],
        eventSegmentURLs: [URL],
        metricSegmentURLs: [URL]
    ) {
        self.manifest = manifest
        self.eventSegments = eventSegments
        self.metricSegments = metricSegments
        self.eventSegmentURLs = eventSegmentURLs
        self.metricSegmentURLs = metricSegmentURLs
    }
}

public struct DiagnosticRetentionResult: Equatable, Sendable {
    public let deletedRunIDs: [UUID]
    public let storageLimitReached: Bool
    public let totalBytes: Int64

    public init(deletedRunIDs: [UUID], storageLimitReached: Bool, totalBytes: Int64) {
        self.deletedRunIDs = deletedRunIDs
        self.storageLimitReached = storageLimitReached
        self.totalBytes = totalBytes
    }
}

public struct DiagnosticStoreConfiguration: Equatable, Sendable {
    public let maximumSegmentBytes: Int
    public let maximumBatchBytes: Int
    public let maximumAge: TimeInterval
    public let maximumStorageBytes: Int64

    public init(
        maximumSegmentBytes: Int = 5 * 1_024 * 1_024,
        maximumBatchBytes: Int = 64 * 1_024,
        maximumAge: TimeInterval = 7 * 24 * 60 * 60,
        maximumStorageBytes: Int64 = 100 * 1_024 * 1_024
    ) {
        precondition(maximumSegmentBytes > 0)
        precondition(maximumBatchBytes > 0)
        precondition(maximumAge > 0)
        precondition(maximumStorageBytes > 0)
        self.maximumSegmentBytes = maximumSegmentBytes
        self.maximumBatchBytes = maximumBatchBytes
        self.maximumAge = maximumAge
        self.maximumStorageBytes = maximumStorageBytes
    }
}

public enum DiagnosticStoreError: Error, Equatable, Sendable {
    case activeRunExists
    case noActiveRun
    case runNotFound
    case invalidRecord
}

public protocol DiagnosticStore: Sendable {
    func startRun(_ manifest: DiagnosticRunManifest) async throws
    func appendEvents(_ records: [Data]) async throws
    func appendMetrics(_ records: [Data]) async throws
    func flush() async throws
    func closeRun(endedAt: Date) async throws
    func summaries() async throws -> [DiagnosticRunSummary]
    func snapshot(runID: UUID) async throws -> DiagnosticStoreSnapshot
    func currentUsageBytes() async throws -> Int64
    func enforceRetention(now: Date) async throws -> DiagnosticRetentionResult
    func clearClosedRuns() async throws
}
