import Foundation
import Testing
@testable import DiagnosticsKit

@Test func eventEncodingIsStableAndPrivacyBounded() throws {
    let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let context = DiagnosticContext(
        appRunID: id,
        activityID: id,
        operationID: id,
        parentOperationID: nil
    )
    let event = DiagnosticEvent(
        sequence: 7,
        wallTime: Date(timeIntervalSince1970: 0),
        monotonicNanoseconds: 99,
        level: .info,
        name: .fileOpen,
        context: context,
        phase: .end,
        outcome: .success,
        durationMilliseconds: 12.5,
        payload: DiagnosticPayload(
            fileID: "opaque",
            container: .mp4,
            fileSize: 42
        ),
        persistence: .essential
    )

    let first = try DiagnosticEventEncoder.encode(event)
    let second = try DiagnosticEventEncoder.encode(event)
    let json = String(decoding: first, as: UTF8.self).lowercased()

    #expect(first == second)
    #expect(json.contains("\"schemaversion\":1"))
    #expect(json.contains("1970-01-01t00:00:00z"))
    #expect(!json.contains("path"))
    #expect(!json.contains("host"))
    #expect(!json.contains("username"))
    #expect(!json.contains("password"))
}

@Test func childContextRetainsActivityAndLinksParent() {
    let appRunID = UUID()
    let activityID = UUID()
    let parentOperationID = UUID()
    let childOperationID = UUID()
    let parent = DiagnosticContext(
        appRunID: appRunID,
        activityID: activityID,
        operationID: parentOperationID
    )

    let child = parent.child(operationID: childOperationID)

    #expect(child.appRunID == appRunID)
    #expect(child.activityID == activityID)
    #expect(child.operationID == childOperationID)
    #expect(child.parentOperationID == parentOperationID)
}

@Test func eventTaxonomyUsesStableCategories() {
    let expected: [(DiagnosticEventName, DiagnosticCategory)] = [
        (.appLaunch, .app),
        (.sourceRestore, .resource),
        (.smbRead, .resource),
        (.cacheSnapshot, .stream),
        (.playbackStall, .playback),
        (.networkChanged, .system),
        (.eventsDropped, .diagnostics),
        (.metricSnapshot, .telemetry),
    ]

    for (name, category) in expected {
        #expect(name.category == category)
    }
}

@Test func containerKindOnlyReturnsAllowListedValues() {
    #expect(DiagnosticContainerKind(fileName: "movie.MP4") == .mp4)
    #expect(DiagnosticContainerKind(fileName: "movie.m4v") == .m4v)
    #expect(DiagnosticContainerKind(fileName: "movie.mov") == .mov)
    #expect(DiagnosticContainerKind(fileName: "movie.mkv") == .mkv)
    #expect(DiagnosticContainerKind(fileName: "private.customer-name") == .other)
}

@Test func metricRecordContainsOnlyNumericSnapshotAndContext() throws {
    let id = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    let context = DiagnosticContext(
        appRunID: id,
        activityID: id,
        operationID: id
    )
    let record = DiagnosticMetricRecord(
        timestamp: Date(timeIntervalSince1970: 0),
        context: context,
        networkBytesPerSecond: 100,
        readLatencyMilliseconds: 2,
        cacheHitRatio: 0.75,
        bufferedDurationSeconds: 4,
        compressedQueueDepth: 5,
        videoQueueDepth: 6,
        decodeLatencyMilliseconds: 7,
        presentedFrames: 8,
        droppedFrames: 9,
        stallCount: 10,
        residentBytes: 11
    )

    let data = try DiagnosticMetricRecordEncoder.encode(record)
    let json = String(decoding: data, as: UTF8.self).lowercased()

    #expect(json.contains("\"networkbytespersecond\":100"))
    #expect(!json.contains("environmentlabel"))
    #expect(!json.contains("filename"))
    #expect(!json.contains("path"))
    #expect(!json.contains("host"))
}

@Test func errorPayloadUsesStableCodesWithoutFreeFormMessages() throws {
    let id = UUID()
    let event = DiagnosticEvent(
        sequence: 1,
        wallTime: Date(timeIntervalSince1970: 0),
        monotonicNanoseconds: 1,
        level: .error,
        name: .smbRead,
        context: DiagnosticContext(
            appRunID: id,
            activityID: id,
            operationID: id
        ),
        phase: .end,
        outcome: .failure,
        payload: DiagnosticPayload(
            sourceID: id,
            offset: 4096,
            requestedLength: 512,
            actualLength: 0,
            error: DiagnosticErrorDescriptor(
                code: .sourceReadFailed,
                isRetryable: true,
                nativeCode: 5
            )
        ),
        persistence: .essential
    )

    let json = String(
        decoding: try DiagnosticEventEncoder.encode(event),
        as: UTF8.self
    ).lowercased()

    #expect(json.contains("source_read_failed"))
    #expect(json.contains("\"nativecode\":5"))
    #expect(!json.contains("message"))
    #expect(!json.contains("details"))
    #expect(!json.contains("description"))
}
