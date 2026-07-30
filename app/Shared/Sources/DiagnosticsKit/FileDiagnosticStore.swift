import Foundation

public actor FileDiagnosticStore: DiagnosticStore {
    private enum RecordKind {
        case event
        case metric

        var prefix: String {
            switch self {
            case .event: "events"
            case .metric: "metrics"
            }
        }
    }

    private struct ActiveRun {
        var manifest: DiagnosticRunManifest
        let directory: URL
        var pendingEvents: [Data] = []
        var pendingEventBytes = 0
        var pendingMetrics: [Data] = []
        var pendingMetricBytes = 0
        var eventSegmentIndex = 0
        var eventSegmentBytes = 0
        var eventHandle: FileHandle?
        var metricSegmentIndex = 0
        var metricSegmentBytes = 0
        var metricHandle: FileHandle?
    }

    private let rootDirectory: URL
    private let runsDirectory: URL
    private let configuration: DiagnosticStoreConfiguration
    private let fileManager: FileManager
    private var activeRun: ActiveRun?

    public init(
        rootDirectory: URL,
        configuration: DiagnosticStoreConfiguration = DiagnosticStoreConfiguration(),
        fileManager: FileManager = .default
    ) {
        self.rootDirectory = rootDirectory
        self.runsDirectory = rootDirectory.appendingPathComponent("runs", isDirectory: true)
        self.configuration = configuration
        self.fileManager = fileManager
    }

    public func startRun(_ manifest: DiagnosticRunManifest) throws {
        guard activeRun == nil else { throw DiagnosticStoreError.activeRunExists }
        try prepareDirectories()

        let directory = runsDirectory.appendingPathComponent(
            manifest.runID.uuidString.lowercased(),
            isDirectory: true
        )
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        try setPermissions(0o700, at: directory)
        try writeManifest(manifest, to: directory)
        activeRun = ActiveRun(manifest: manifest, directory: directory)
        try writeIndex()
    }

    public func appendEvents(_ records: [Data]) throws {
        try append(records, kind: .event)
    }

    public func appendMetrics(_ records: [Data]) throws {
        try append(records, kind: .metric)
    }

    public func flush() throws {
        guard var run = activeRun else { return }
        try writePending(kind: .event, run: &run)
        try writePending(kind: .metric, run: &run)
        try run.eventHandle?.synchronize()
        try run.metricHandle?.synchronize()
        activeRun = run
    }

    public func closeRun(endedAt: Date) throws {
        guard var run = activeRun else { throw DiagnosticStoreError.noActiveRun }
        try writePending(kind: .event, run: &run)
        try writePending(kind: .metric, run: &run)
        try run.eventHandle?.close()
        try run.metricHandle?.close()
        run.eventHandle = nil
        run.metricHandle = nil
        run.manifest = run.manifest.ending(at: endedAt)
        try writeManifest(run.manifest, to: run.directory)
        activeRun = nil
        try writeIndex()
    }

    public func summaries() throws -> [DiagnosticRunSummary] {
        guard fileManager.fileExists(atPath: runsDirectory.path) else { return [] }
        return try runDirectories().compactMap { directory in
            guard let manifest = try? readManifest(from: directory) else { return nil }
            return DiagnosticRunSummary(
                runID: manifest.runID,
                startedAt: manifest.startedAt,
                endedAt: manifest.endedAt,
                policy: manifest.policy,
                byteCount: try directorySize(directory)
            )
        }.sorted { lhs, rhs in
            if lhs.startedAt == rhs.startedAt {
                return lhs.runID.uuidString < rhs.runID.uuidString
            }
            return lhs.startedAt < rhs.startedAt
        }
    }

    public func snapshot(runID: UUID) throws -> DiagnosticStoreSnapshot {
        if activeRun?.manifest.runID == runID {
            try flush()
        }
        let directory = runsDirectory.appendingPathComponent(
            runID.uuidString.lowercased(),
            isDirectory: true
        )
        guard fileManager.fileExists(atPath: directory.path) else {
            throw DiagnosticStoreError.runNotFound
        }
        let eventURLs = try segmentURLs(in: directory, prefix: RecordKind.event.prefix)
        let metricURLs = try segmentURLs(in: directory, prefix: RecordKind.metric.prefix)
        return DiagnosticStoreSnapshot(
            manifest: try readManifest(from: directory),
            eventSegments: try eventURLs.map { try Data(contentsOf: $0) },
            metricSegments: try metricURLs.map { try Data(contentsOf: $0) },
            eventSegmentURLs: eventURLs,
            metricSegmentURLs: metricURLs
        )
    }

    public func currentUsageBytes() throws -> Int64 {
        guard fileManager.fileExists(atPath: rootDirectory.path) else { return 0 }
        return try directorySize(rootDirectory)
    }

    public func enforceRetention(now: Date) throws -> DiagnosticRetentionResult {
        let activeRunID = activeRun?.manifest.runID
        var deletedRunIDs: [UUID] = []
        let expiry = now.addingTimeInterval(-configuration.maximumAge)
        var available = try summaries()

        for summary in available where summary.runID != activeRunID {
            guard let endedAt = summary.endedAt, endedAt < expiry else { continue }
            try deleteRun(summary.runID)
            deletedRunIDs.append(summary.runID)
        }

        var usage = try currentUsageBytes()
        if usage > configuration.maximumStorageBytes {
            available = try summaries()
            for summary in available where summary.runID != activeRunID && summary.endedAt != nil {
                guard usage > configuration.maximumStorageBytes else { break }
                try deleteRun(summary.runID)
                deletedRunIDs.append(summary.runID)
                usage = try currentUsageBytes()
            }
        }

        usage = try currentUsageBytes()
        try writeIndex()
        return DiagnosticRetentionResult(
            deletedRunIDs: deletedRunIDs,
            storageLimitReached: usage > configuration.maximumStorageBytes,
            totalBytes: usage
        )
    }

    public func clearClosedRuns() throws {
        let activeRunID = activeRun?.manifest.runID
        for summary in try summaries() where summary.runID != activeRunID && summary.endedAt != nil {
            try deleteRun(summary.runID)
        }
        try writeIndex()
    }

    private func append(_ records: [Data], kind: RecordKind) throws {
        guard var run = activeRun else { throw DiagnosticStoreError.noActiveRun }
        for record in records {
            guard !record.isEmpty, !record.contains(0x0A) else {
                throw DiagnosticStoreError.invalidRecord
            }
            switch kind {
            case .event:
                run.pendingEvents.append(record)
                run.pendingEventBytes += record.count + 1
                if run.pendingEventBytes >= configuration.maximumBatchBytes {
                    try writePending(kind: .event, run: &run)
                }
            case .metric:
                run.pendingMetrics.append(record)
                run.pendingMetricBytes += record.count + 1
                if run.pendingMetricBytes >= configuration.maximumBatchBytes {
                    try writePending(kind: .metric, run: &run)
                }
            }
        }
        activeRun = run
    }

    private func writePending(kind: RecordKind, run: inout ActiveRun) throws {
        let records: [Data]
        switch kind {
        case .event:
            records = run.pendingEvents
            run.pendingEvents.removeAll(keepingCapacity: true)
            run.pendingEventBytes = 0
        case .metric:
            records = run.pendingMetrics
            run.pendingMetrics.removeAll(keepingCapacity: true)
            run.pendingMetricBytes = 0
        }

        for record in records {
            var line = record
            line.append(0x0A)
            try write(line, kind: kind, run: &run)
        }
    }

    private func write(_ line: Data, kind: RecordKind, run: inout ActiveRun) throws {
        switch kind {
        case .event:
            if run.eventHandle == nil
                || (run.eventSegmentBytes > 0
                    && run.eventSegmentBytes + line.count > configuration.maximumSegmentBytes)
            {
                try run.eventHandle?.close()
                run.eventSegmentIndex += 1
                run.eventSegmentBytes = 0
                run.eventHandle = try openSegment(
                    kind: kind,
                    index: run.eventSegmentIndex,
                    directory: run.directory
                )
            }
            try run.eventHandle?.write(contentsOf: line)
            run.eventSegmentBytes += line.count
        case .metric:
            if run.metricHandle == nil
                || (run.metricSegmentBytes > 0
                    && run.metricSegmentBytes + line.count > configuration.maximumSegmentBytes)
            {
                try run.metricHandle?.close()
                run.metricSegmentIndex += 1
                run.metricSegmentBytes = 0
                run.metricHandle = try openSegment(
                    kind: kind,
                    index: run.metricSegmentIndex,
                    directory: run.directory
                )
            }
            try run.metricHandle?.write(contentsOf: line)
            run.metricSegmentBytes += line.count
        }
    }

    private func openSegment(kind: RecordKind, index: Int, directory: URL) throws -> FileHandle {
        let url = directory.appendingPathComponent(
            String(format: "%@-%04d.jsonl", kind.prefix, index)
        )
        guard fileManager.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try setPermissions(0o600, at: url)
        return try FileHandle(forWritingTo: url)
    }

    private func prepareDirectories() throws {
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: runsDirectory, withIntermediateDirectories: true)
        try setPermissions(0o700, at: rootDirectory)
        try setPermissions(0o700, at: runsDirectory)
        var root = rootDirectory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try root.setResourceValues(values)
    }

    private func writeManifest(_ manifest: DiagnosticRunManifest, to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let url = directory.appendingPathComponent("manifest.json")
        try encoder.encode(manifest).write(to: url, options: .atomic)
        try setPermissions(0o600, at: url)
    }

    private func readManifest(from directory: URL) throws -> DiagnosticRunManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            DiagnosticRunManifest.self,
            from: Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        )
    }

    private func writeIndex() throws {
        guard fileManager.fileExists(atPath: rootDirectory.path) else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let url = rootDirectory.appendingPathComponent("index.json")
        try encoder.encode(try summaries()).write(to: url, options: .atomic)
        try setPermissions(0o600, at: url)
    }

    private func runDirectories() throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: runsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }

    private func segmentURLs(in directory: URL, prefix: String) throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter {
            $0.lastPathComponent.hasPrefix(prefix + "-") && $0.pathExtension == "jsonl"
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func deleteRun(_ runID: UUID) throws {
        try fileManager.removeItem(at: runsDirectory.appendingPathComponent(
            runID.uuidString.lowercased(),
            isDirectory: true
        ))
    }

    private func directorySize(_ directory: URL) throws -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values.isRegularFile == true {
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }

    private func setPermissions(_ permissions: Int, at url: URL) throws {
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: permissions)],
            ofItemAtPath: url.path
        )
    }
}
