import Foundation
import Testing
@testable import DiagnosticsKit

@Test func bundleExportCreatesValidatedPrivacySafePackage() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appendingPathComponent("support.pierdiag", isDirectory: true)
    let snapshot = try fixedSnapshot()
    let exporter = DiagnosticBundleExporter(
        now: { Date(timeIntervalSince1970: 20) }
    )

    let result = try await exporter.export(snapshots: [snapshot], to: destination)

    #expect(result.url == destination)
    #expect(Set(try FileManager.default.contentsOfDirectory(atPath: destination.path)) == [
        "events.jsonl",
        "integrity.json",
        "manifest.json",
        "metrics.jsonl",
        "summary.json",
    ])

    let bundle = try DiagnosticBundleReader.validate(at: destination)
    #expect(bundle.manifest.runs == [snapshot.manifest])
    #expect(bundle.events.map(\.sequence) == [1, 2, 3, 4])
    #expect(bundle.metrics.count == 1)
    #expect(bundle.summary.runCount == 1)
    #expect(bundle.summary.eventCount == 4)
    #expect(bundle.summary.metricCount == 1)
    #expect(bundle.summary.failureCount == 1)
    #expect(bundle.summary.stallCount == 1)
    #expect(bundle.summary.actualBytes == 24)
    #expect(bundle.summary.droppedDetailedEvents == 2)
    #expect(bundle.summary.unmatchedOperationCount == 1)

    for entry in bundle.integrity.entries {
        let data = try Data(contentsOf: destination.appendingPathComponent(entry.name))
        #expect(entry.sha256 == DiagnosticBundleIntegrity.sha256Hex(data))
        #expect(entry.byteCount == data.count)
    }
}

@Test func bundleValidationRejectsTampering() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appendingPathComponent("support.pierdiag", isDirectory: true)
    try await DiagnosticBundleExporter().export(
        snapshots: [try fixedSnapshot()],
        to: destination
    )
    try Data("{\"schemaVersion\":1}".utf8).write(
        to: destination.appendingPathComponent("summary.json"),
        options: .atomic
    )

    #expect(throws: DiagnosticBundleError.integrityMismatch) {
        try DiagnosticBundleReader.validate(at: destination)
    }
}

@Test func failedPrivacyAuditRemovesTemporaryPackageAndPreservesSnapshot() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appendingPathComponent("support.pierdiag", isDirectory: true)
    let safeSnapshot = try fixedSnapshot()
    let unsafeSnapshot = DiagnosticStoreSnapshot(
        manifest: DiagnosticRunManifest(
            runID: safeSnapshot.manifest.runID,
            startedAt: safeSnapshot.manifest.startedAt,
            policy: .standard,
            environment: DiagnosticRunEnvironment(
                appVersion: "1.0",
                appBuild: "1",
                osVersion: "smb://private.example/Media",
                architecture: .arm64,
                hardwareClass: .mac,
                networkAvailability: .available,
                networkInterface: .wifi
            )
        ),
        eventSegments: safeSnapshot.eventSegments,
        metricSegments: safeSnapshot.metricSegments,
        eventSegmentURLs: safeSnapshot.eventSegmentURLs,
        metricSegmentURLs: safeSnapshot.metricSegmentURLs
    )
    let originalEvents = unsafeSnapshot.eventSegments

    await #expect(throws: DiagnosticPrivacyViolation.self) {
        try await DiagnosticBundleExporter().export(
            snapshots: [unsafeSnapshot],
            to: destination
        )
    }

    #expect(!FileManager.default.fileExists(atPath: destination.path))
    #expect(unsafeSnapshot.eventSegments == originalEvents)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
}

@Test func cancelledExportRemovesTemporaryPackage() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appendingPathComponent("support.pierdiag", isDirectory: true)
    let exporter = DiagnosticBundleExporter(
        cancellationCheck: { throw CancellationError() }
    )

    await #expect(throws: CancellationError.self) {
        try await exporter.export(snapshots: [try fixedSnapshot()], to: destination)
    }

    #expect(!FileManager.default.fileExists(atPath: destination.path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
}

private func fixedSnapshot() throws -> DiagnosticStoreSnapshot {
    let runID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
    let activityID = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
    let openOperationID = UUID(uuidString: "00000000-0000-0000-0000-000000000103")!
    let stallOperationID = UUID(uuidString: "00000000-0000-0000-0000-000000000104")!
    let events = [
        bundleEvent(
            sequence: 1,
            name: .fileOpen,
            context: DiagnosticContext(
                appRunID: runID,
                activityID: activityID,
                operationID: openOperationID
            ),
            phase: .begin,
            persistence: .essential
        ),
        bundleEvent(
            sequence: 2,
            name: .resourceRead,
            context: DiagnosticContext(
                appRunID: runID,
                activityID: activityID,
                operationID: UUID(),
                parentOperationID: openOperationID
            ),
            phase: .end,
            outcome: .success,
            durationMilliseconds: 12,
            payload: DiagnosticPayload(requestedLength: 32, actualLength: 24),
            persistence: .detailed
        ),
        bundleEvent(
            sequence: 3,
            name: .playbackStall,
            context: DiagnosticContext(
                appRunID: runID,
                activityID: activityID,
                operationID: stallOperationID
            ),
            phase: .instant,
            outcome: .failure,
            durationMilliseconds: 3_500,
            payload: DiagnosticPayload(
                error: DiagnosticErrorDescriptor(code: .playerFailed)
            ),
            persistence: .essential
        ),
        bundleEvent(
            sequence: 4,
            name: .eventsDropped,
            context: DiagnosticContext(
                appRunID: runID,
                activityID: activityID,
                operationID: UUID()
            ),
            phase: .instant,
            payload: DiagnosticPayload(
                droppedEssentialEvents: 0,
                droppedDetailedEvents: 2
            ),
            persistence: .essential
        ),
    ]
    let metric = DiagnosticMetricRecord(
        timestamp: Date(timeIntervalSince1970: 13),
        context: DiagnosticContext(
            appRunID: runID,
            activityID: activityID,
            operationID: UUID()
        ),
        networkBytesPerSecond: 1_024,
        readLatencyMilliseconds: 10,
        cacheHitRatio: 0.5,
        bufferedDurationSeconds: 4,
        compressedQueueDepth: 2,
        videoQueueDepth: 3,
        decodeLatencyMilliseconds: 5,
        presentedFrames: 60,
        droppedFrames: 1,
        stallCount: 1,
        residentBytes: 4_096
    )

    return DiagnosticStoreSnapshot(
        manifest: DiagnosticRunManifest(
            runID: runID,
            startedAt: Date(timeIntervalSince1970: 10),
            endedAt: Date(timeIntervalSince1970: 20),
            policy: .incident,
            environment: DiagnosticRunEnvironment(
                appVersion: "1.0",
                appBuild: "1",
                osVersion: "macOS 14.0",
                architecture: .arm64,
                hardwareClass: .mac,
                networkAvailability: .available,
                networkInterface: .wifi
            )
        ),
        eventSegments: [try jsonLines(events, encode: DiagnosticEventEncoder.encode)],
        metricSegments: [try jsonLines([metric], encode: DiagnosticMetricRecordEncoder.encode)],
        eventSegmentURLs: [],
        metricSegmentURLs: []
    )
}

private func bundleEvent(
    sequence: UInt64,
    name: DiagnosticEventName,
    context: DiagnosticContext,
    phase: DiagnosticPhase,
    outcome: DiagnosticOutcome? = nil,
    durationMilliseconds: Double? = nil,
    payload: DiagnosticPayload = DiagnosticPayload(),
    persistence: DiagnosticPersistence
) -> DiagnosticEvent {
    DiagnosticEvent(
        sequence: sequence,
        wallTime: Date(timeIntervalSince1970: Double(sequence + 10)),
        monotonicNanoseconds: sequence * 1_000_000_000,
        level: outcome == .failure ? .error : .info,
        name: name,
        context: context,
        phase: phase,
        outcome: outcome,
        durationMilliseconds: durationMilliseconds,
        payload: payload,
        persistence: persistence
    )
}

private func jsonLines<Value>(
    _ values: [Value],
    encode: (Value) throws -> Data
) throws -> Data {
    var output = Data()
    for value in values {
        output.append(try encode(value))
        output.append(0x0A)
    }
    return output
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url
}
