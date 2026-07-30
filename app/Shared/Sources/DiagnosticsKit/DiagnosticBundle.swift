import CryptoKit
import Foundation

public struct DiagnosticBundleManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let generatedAt: Date
    public let runs: [DiagnosticRunManifest]

    public init(generatedAt: Date, runs: [DiagnosticRunManifest]) {
        self.schemaVersion = 1
        self.generatedAt = generatedAt
        self.runs = runs
    }
}

public struct DiagnosticBundleErrorCount: Codable, Equatable, Sendable {
    public let code: DiagnosticErrorCode
    public let count: Int

    public init(code: DiagnosticErrorCode, count: Int) {
        self.code = code
        self.count = count
    }
}

public struct DiagnosticBundleSlowOperation: Codable, Equatable, Sendable {
    public let name: DiagnosticEventName
    public let operationID: UUID
    public let durationMilliseconds: Double

    public init(
        name: DiagnosticEventName,
        operationID: UUID,
        durationMilliseconds: Double
    ) {
        self.name = name
        self.operationID = operationID
        self.durationMilliseconds = durationMilliseconds
    }
}

public struct DiagnosticBundleActivitySummary: Codable, Equatable, Sendable {
    public let activityID: UUID
    public let eventCount: Int
    public let startedAt: Date
    public let endedAt: Date
    public let outcome: DiagnosticOutcome?

    public init(
        activityID: UUID,
        eventCount: Int,
        startedAt: Date,
        endedAt: Date,
        outcome: DiagnosticOutcome?
    ) {
        self.activityID = activityID
        self.eventCount = eventCount
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.outcome = outcome
    }
}

public struct DiagnosticBundleSummary: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let runCount: Int
    public let eventCount: Int
    public let metricCount: Int
    public let successCount: Int
    public let failureCount: Int
    public let cancelledCount: Int
    public let discardedCount: Int
    public let stallCount: Int
    public let requestedBytes: UInt64
    public let actualBytes: UInt64
    public let droppedEssentialEvents: UInt64
    public let droppedDetailedEvents: UInt64
    public let averageCacheHitRatio: Double?
    public let unmatchedOperationCount: Int
    public let unclosedResourceCount: Int
    public let errors: [DiagnosticBundleErrorCount]
    public let slowOperations: [DiagnosticBundleSlowOperation]
    public let activities: [DiagnosticBundleActivitySummary]

    public init(
        runCount: Int,
        eventCount: Int,
        metricCount: Int,
        successCount: Int,
        failureCount: Int,
        cancelledCount: Int,
        discardedCount: Int,
        stallCount: Int,
        requestedBytes: UInt64,
        actualBytes: UInt64,
        droppedEssentialEvents: UInt64,
        droppedDetailedEvents: UInt64,
        averageCacheHitRatio: Double?,
        unmatchedOperationCount: Int,
        unclosedResourceCount: Int,
        errors: [DiagnosticBundleErrorCount],
        slowOperations: [DiagnosticBundleSlowOperation],
        activities: [DiagnosticBundleActivitySummary]
    ) {
        self.schemaVersion = 1
        self.runCount = runCount
        self.eventCount = eventCount
        self.metricCount = metricCount
        self.successCount = successCount
        self.failureCount = failureCount
        self.cancelledCount = cancelledCount
        self.discardedCount = discardedCount
        self.stallCount = stallCount
        self.requestedBytes = requestedBytes
        self.actualBytes = actualBytes
        self.droppedEssentialEvents = droppedEssentialEvents
        self.droppedDetailedEvents = droppedDetailedEvents
        self.averageCacheHitRatio = averageCacheHitRatio
        self.unmatchedOperationCount = unmatchedOperationCount
        self.unclosedResourceCount = unclosedResourceCount
        self.errors = errors
        self.slowOperations = slowOperations
        self.activities = activities
    }
}

public struct DiagnosticBundleIntegrityEntry: Codable, Equatable, Sendable {
    public let name: String
    public let sha256: String
    public let byteCount: Int

    public init(name: String, sha256: String, byteCount: Int) {
        self.name = name
        self.sha256 = sha256
        self.byteCount = byteCount
    }
}

public struct DiagnosticBundleIntegrity: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let entries: [DiagnosticBundleIntegrityEntry]

    public init(entries: [DiagnosticBundleIntegrityEntry]) {
        self.schemaVersion = 1
        self.entries = entries
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public struct ValidatedDiagnosticBundle: Equatable, Sendable {
    public let url: URL
    public let manifest: DiagnosticBundleManifest
    public let events: [DiagnosticEvent]
    public let metrics: [DiagnosticMetricRecord]
    public let summary: DiagnosticBundleSummary
    public let integrity: DiagnosticBundleIntegrity

    public init(
        url: URL,
        manifest: DiagnosticBundleManifest,
        events: [DiagnosticEvent],
        metrics: [DiagnosticMetricRecord],
        summary: DiagnosticBundleSummary,
        integrity: DiagnosticBundleIntegrity
    ) {
        self.url = url
        self.manifest = manifest
        self.events = events
        self.metrics = metrics
        self.summary = summary
        self.integrity = integrity
    }
}

public enum DiagnosticBundleError: Error, Equatable, Sendable {
    case destinationExists
    case invalidPackage
    case missingEntry
    case invalidSchema
    case integrityMismatch
    case summaryMismatch
}

public struct DiagnosticBundleExporter: @unchecked Sendable {
    private let fileManager: FileManager
    private let now: @Sendable () -> Date
    private let cancellationCheck: @Sendable () throws -> Void

    public init(now: @escaping @Sendable () -> Date = Date.init) {
        self.init(
            fileManager: .default,
            now: now,
            cancellationCheck: Task.checkCancellation
        )
    }

    init(
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = Date.init,
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) {
        self.fileManager = fileManager
        self.now = now
        self.cancellationCheck = cancellationCheck
    }

    @discardableResult
    public func export(
        snapshots: [DiagnosticStoreSnapshot],
        to destination: URL
    ) async throws -> ValidatedDiagnosticBundle {
        guard !snapshots.isEmpty else { throw DiagnosticBundleError.invalidPackage }
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw DiagnosticBundleError.destinationExists
        }

        let orderedSnapshots = snapshots.sorted(by: snapshotOrder)
        let eventsData = Self.combine(orderedSnapshots.flatMap(\.eventSegments))
        let metricsData = Self.combine(orderedSnapshots.flatMap(\.metricSegments))
        let events: [DiagnosticEvent] = try Self.decodeJSONLines(eventsData)
        let metrics: [DiagnosticMetricRecord] = try Self.decodeJSONLines(metricsData)
        let manifest = DiagnosticBundleManifest(
            generatedAt: now(),
            runs: orderedSnapshots.map(\.manifest)
        )
        let summary = DiagnosticBundleSummaryBuilder.make(
            runCount: orderedSnapshots.count,
            events: events,
            metrics: metrics
        )

        var entries = [
            DiagnosticBundleFiles.manifest: try Self.encode(manifest),
            DiagnosticBundleFiles.events: eventsData,
            DiagnosticBundleFiles.metrics: metricsData,
            DiagnosticBundleFiles.summary: try Self.encode(summary),
        ]
        for data in entries.values where !data.isEmpty {
            try DiagnosticPrivacyAudit.validate(data)
        }

        let integrity = DiagnosticBundleIntegrity(entries: entries.keys.sorted().map { name in
            let data = entries[name]!
            return DiagnosticBundleIntegrityEntry(
                name: name,
                sha256: DiagnosticBundleIntegrity.sha256Hex(data),
                byteCount: data.count
            )
        })
        let integrityData = try Self.encode(integrity)
        try DiagnosticPrivacyAudit.validate(integrityData)
        entries[DiagnosticBundleFiles.integrity] = integrityData

        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporary = parent.appendingPathComponent(
            ".\(destination.lastPathComponent).tmp-\(UUID().uuidString)",
            isDirectory: true
        )

        do {
            let wrappers = entries.mapValues(FileWrapper.init(regularFileWithContents:))
            let package = FileWrapper(directoryWithFileWrappers: wrappers)
            try package.write(to: temporary, options: .atomic, originalContentsURL: nil)
            try Self.securePermissions(at: temporary, files: entries.keys, fileManager: fileManager)
            try cancellationCheck()
            try fileManager.moveItem(at: temporary, to: destination)
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }

        return try DiagnosticBundleReader.validate(at: destination)
    }

    private func snapshotOrder(
        _ lhs: DiagnosticStoreSnapshot,
        _ rhs: DiagnosticStoreSnapshot
    ) -> Bool {
        if lhs.manifest.startedAt == rhs.manifest.startedAt {
            return lhs.manifest.runID.uuidString < rhs.manifest.runID.uuidString
        }
        return lhs.manifest.startedAt < rhs.manifest.startedAt
    }

    private static func combine(_ segments: [Data]) -> Data {
        var result = Data()
        for segment in segments {
            for line in segment.split(whereSeparator: { $0 == 0x0A || $0 == 0x0D }) {
                result.append(contentsOf: line)
                result.append(0x0A)
            }
        }
        return result
    }

    private static func decodeJSONLines<Value: Decodable>(_ data: Data) throws -> [Value] {
        let decoder = diagnosticJSONDecoder()
        return try data
            .split(whereSeparator: { $0 == 0x0A || $0 == 0x0D })
            .map { try decoder.decode(Value.self, from: Data($0)) }
    }

    private static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        try diagnosticJSONEncoder().encode(value)
    }

    private static func securePermissions(
        at directory: URL,
        files: Dictionary<String, Data>.Keys,
        fileManager: FileManager
    ) throws {
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: directory.path
        )
        for name in files {
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: directory.appendingPathComponent(name).path
            )
        }
    }
}

public enum DiagnosticBundleReader {
    public static func validate(at url: URL) throws -> ValidatedDiagnosticBundle {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw DiagnosticBundleError.invalidPackage
        }
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: url.path))
        guard names == DiagnosticBundleFiles.all else {
            throw DiagnosticBundleError.missingEntry
        }

        let data = try Dictionary(uniqueKeysWithValues: names.map { name in
            (name, try Data(contentsOf: url.appendingPathComponent(name)))
        })
        let decoder = diagnosticJSONDecoder()
        let integrity = try decoder.decode(
            DiagnosticBundleIntegrity.self,
            from: data[DiagnosticBundleFiles.integrity]!
        )
        guard integrity.schemaVersion == 1,
              Set(integrity.entries.map(\.name)) == DiagnosticBundleFiles.hashed,
              integrity.entries.count == DiagnosticBundleFiles.hashed.count
        else {
            throw DiagnosticBundleError.invalidSchema
        }

        for entry in integrity.entries {
            guard let entryData = data[entry.name],
                  entry.byteCount == entryData.count,
                  entry.sha256 == DiagnosticBundleIntegrity.sha256Hex(entryData)
            else {
                throw DiagnosticBundleError.integrityMismatch
            }
        }
        for entryData in data.values where !entryData.isEmpty {
            try DiagnosticPrivacyAudit.validate(entryData)
        }

        let manifest = try decoder.decode(
            DiagnosticBundleManifest.self,
            from: data[DiagnosticBundleFiles.manifest]!
        )
        let summary = try decoder.decode(
            DiagnosticBundleSummary.self,
            from: data[DiagnosticBundleFiles.summary]!
        )
        let events: [DiagnosticEvent] = try decodeJSONLines(data[DiagnosticBundleFiles.events]!)
        let metrics: [DiagnosticMetricRecord] = try decodeJSONLines(data[DiagnosticBundleFiles.metrics]!)
        guard manifest.schemaVersion == 1,
              !manifest.runs.isEmpty,
              manifest.runs.allSatisfy({ $0.schemaVersion == 1 }),
              events.allSatisfy({ $0.schemaVersion == 1 }),
              metrics.allSatisfy({ $0.schemaVersion == 1 }),
              summary.schemaVersion == 1
        else {
            throw DiagnosticBundleError.invalidSchema
        }

        let expectedSummary = DiagnosticBundleSummaryBuilder.make(
            runCount: manifest.runs.count,
            events: events,
            metrics: metrics
        )
        guard summary == expectedSummary else {
            throw DiagnosticBundleError.summaryMismatch
        }
        return ValidatedDiagnosticBundle(
            url: url,
            manifest: manifest,
            events: events,
            metrics: metrics,
            summary: summary,
            integrity: integrity
        )
    }

    private static func decodeJSONLines<Value: Decodable>(_ data: Data) throws -> [Value] {
        let decoder = diagnosticJSONDecoder()
        do {
            return try data
                .split(whereSeparator: { $0 == 0x0A || $0 == 0x0D })
                .map { try decoder.decode(Value.self, from: Data($0)) }
        } catch {
            throw DiagnosticBundleError.invalidSchema
        }
    }
}

private enum DiagnosticBundleFiles {
    static let manifest = "manifest.json"
    static let events = "events.jsonl"
    static let metrics = "metrics.jsonl"
    static let summary = "summary.json"
    static let integrity = "integrity.json"
    static let hashed: Set<String> = [manifest, events, metrics, summary]
    static let all = hashed.union([integrity])
}

private enum DiagnosticBundleSummaryBuilder {
    private struct ActivityAccumulator {
        var eventCount = 0
        var startedAt: Date
        var endedAt: Date
        var outcome: DiagnosticOutcome?
    }

    static func make(
        runCount: Int,
        events: [DiagnosticEvent],
        metrics: [DiagnosticMetricRecord]
    ) -> DiagnosticBundleSummary {
        var successCount = 0
        var failureCount = 0
        var cancelledCount = 0
        var discardedCount = 0
        var stallCount = 0
        var requestedBytes: UInt64 = 0
        var actualBytes: UInt64 = 0
        var droppedEssentialEvents: UInt64 = 0
        var droppedDetailedEvents: UInt64 = 0
        var errorCounts: [DiagnosticErrorCode: Int] = [:]
        var openOperations: Set<UUID> = []
        var openResources: Set<String> = []
        var slowOperations: [DiagnosticBundleSlowOperation] = []
        var activities: [UUID: ActivityAccumulator] = [:]

        for event in events {
            switch event.outcome {
            case .success: successCount += 1
            case .failure: failureCount += 1
            case .cancelled: cancelledCount += 1
            case .discarded: discardedCount += 1
            case nil: break
            }
            if event.name == .playbackStall {
                stallCount += 1
            }
            requestedBytes = adding(requestedBytes, event.payload.requestedLength)
            actualBytes = adding(actualBytes, event.payload.actualLength)
            droppedEssentialEvents &+= event.payload.droppedEssentialEvents ?? 0
            droppedDetailedEvents &+= event.payload.droppedDetailedEvents ?? 0
            if let code = event.payload.error?.code {
                errorCounts[code, default: 0] += 1
            }
            switch event.phase {
            case .begin:
                openOperations.insert(event.context.operationID)
            case .end:
                openOperations.remove(event.context.operationID)
            case .instant:
                break
            }
            if event.name == .fileOpen,
               event.outcome == .success,
               let fileID = event.payload.fileID
            {
                openResources.insert(fileID)
            }
            if event.name == .fileClose, let fileID = event.payload.fileID {
                openResources.remove(fileID)
            }
            if let duration = event.durationMilliseconds {
                slowOperations.append(DiagnosticBundleSlowOperation(
                    name: event.name,
                    operationID: event.context.operationID,
                    durationMilliseconds: duration
                ))
            }

            let activityID = event.context.activityID
            var activity = activities[activityID] ?? ActivityAccumulator(
                startedAt: event.wallTime,
                endedAt: event.wallTime
            )
            activity.eventCount += 1
            activity.startedAt = min(activity.startedAt, event.wallTime)
            activity.endedAt = max(activity.endedAt, event.wallTime)
            if event.outcome == .failure || activity.outcome != .failure {
                activity.outcome = event.outcome ?? activity.outcome
            }
            activities[activityID] = activity
        }

        slowOperations.sort {
            if $0.durationMilliseconds == $1.durationMilliseconds {
                return $0.operationID.uuidString < $1.operationID.uuidString
            }
            return $0.durationMilliseconds > $1.durationMilliseconds
        }
        let cacheHitRatio = metrics.isEmpty
            ? nil
            : metrics.reduce(0) { $0 + $1.cacheHitRatio } / Double(metrics.count)
        return DiagnosticBundleSummary(
            runCount: runCount,
            eventCount: events.count,
            metricCount: metrics.count,
            successCount: successCount,
            failureCount: failureCount,
            cancelledCount: cancelledCount,
            discardedCount: discardedCount,
            stallCount: stallCount,
            requestedBytes: requestedBytes,
            actualBytes: actualBytes,
            droppedEssentialEvents: droppedEssentialEvents,
            droppedDetailedEvents: droppedDetailedEvents,
            averageCacheHitRatio: cacheHitRatio,
            unmatchedOperationCount: openOperations.count,
            unclosedResourceCount: openResources.count,
            errors: errorCounts.map {
                DiagnosticBundleErrorCount(code: $0.key, count: $0.value)
            }.sorted { $0.code.rawValue < $1.code.rawValue },
            slowOperations: Array(slowOperations.prefix(10)),
            activities: activities.map {
                DiagnosticBundleActivitySummary(
                    activityID: $0.key,
                    eventCount: $0.value.eventCount,
                    startedAt: $0.value.startedAt,
                    endedAt: $0.value.endedAt,
                    outcome: $0.value.outcome
                )
            }.sorted { $0.activityID.uuidString < $1.activityID.uuidString }
        )
    }

    private static func adding(_ value: UInt64, _ increment: Int?) -> UInt64 {
        guard let increment, increment > 0 else { return value }
        return value &+ UInt64(increment)
    }
}

private func diagnosticJSONEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
}

private func diagnosticJSONDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
}
