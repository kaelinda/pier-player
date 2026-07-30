import DiagnosticsKit
import Foundation
import Testing
@testable import PlaybackTelemetry

@Test func adapterPreservesEveryNumericMetricAndContextWithoutLabels() throws {
    let context = DiagnosticContext(
        appRunID: UUID(uuidString: "00000000-0000-0000-0000-000000000411")!,
        activityID: UUID(uuidString: "00000000-0000-0000-0000-000000000412")!,
        operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000413")!
    )
    let snapshot = PlaybackMetricSnapshot(
        timestamp: Date(timeIntervalSince1970: 10),
        networkBytesPerSecond: 1,
        readLatencyMilliseconds: 2,
        cacheHitRatio: 0.3,
        bufferedDurationSeconds: 4,
        compressedQueueDepth: 5,
        videoQueueDepth: 6,
        decodeLatencyMilliseconds: 7,
        presentedFrames: 8,
        droppedFrames: 9,
        stallCount: 10,
        residentBytes: 11
    )

    let metric = PlaybackDiagnosticAdapter.record(snapshot, context: context)

    #expect(metric.timestamp == snapshot.timestamp)
    #expect(metric.context == context)
    #expect(metric.networkBytesPerSecond == 1)
    #expect(metric.readLatencyMilliseconds == 2)
    #expect(metric.cacheHitRatio == 0.3)
    #expect(metric.bufferedDurationSeconds == 4)
    #expect(metric.compressedQueueDepth == 5)
    #expect(metric.videoQueueDepth == 6)
    #expect(metric.decodeLatencyMilliseconds == 7)
    #expect(metric.presentedFrames == 8)
    #expect(metric.droppedFrames == 9)
    #expect(metric.stallCount == 10)
    #expect(metric.residentBytes == 11)

    let json = String(
        decoding: try DiagnosticMetricRecordEncoder.encode(metric),
        as: UTF8.self
    ).lowercased()
    #expect(!json.contains("host"))
    #expect(!json.contains("path"))
    #expect(!json.contains("name"))
    #expect(!json.contains("environmentlabel"))
}
