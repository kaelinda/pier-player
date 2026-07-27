import Foundation
import Testing
@testable import PlaybackTelemetry

private func snapshot(
    at timestamp: TimeInterval,
    throughput: Double,
    stalls: UInt64,
    residentBytes: UInt64
) -> PlaybackMetricSnapshot {
    PlaybackMetricSnapshot(
        timestamp: Date(timeIntervalSince1970: timestamp),
        networkBytesPerSecond: throughput,
        readLatencyMilliseconds: 2.5,
        cacheHitRatio: 0.75,
        bufferedDurationSeconds: 12,
        compressedQueueDepth: 8,
        videoQueueDepth: 4,
        decodeLatencyMilliseconds: 1.5,
        presentedFrames: 100,
        droppedFrames: 1,
        stallCount: stalls,
        residentBytes: residentBytes
    )
}

@Test func reportAggregatesPerformanceSnapshots() {
    let report = PlaybackSessionReport(
        sessionID: UUID(),
        sourceID: UUID(),
        fileID: UUID(),
        environmentLabel: "mac-studio-wifi6",
        startedAt: Date(timeIntervalSince1970: 0),
        endedAt: Date(timeIntervalSince1970: 2),
        snapshots: [
            snapshot(at: 1, throughput: 100, stalls: 1, residentBytes: 1_000),
            snapshot(at: 2, throughput: 300, stalls: 2, residentBytes: 2_000),
        ]
    )

    #expect(report.averageNetworkBytesPerSecond == 200)
    #expect(report.maximumResidentBytes == 2_000)
    #expect(report.totalStallCount == 2)
}

@Test func reportEncodingUsesStableSortedISO8601JSON() throws {
    let fixedID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let report = PlaybackSessionReport(
        sessionID: fixedID,
        sourceID: fixedID,
        fileID: fixedID,
        environmentLabel: "reference",
        startedAt: Date(timeIntervalSince1970: 0),
        endedAt: Date(timeIntervalSince1970: 1),
        snapshots: []
    )

    let first = try PlaybackSessionReportEncoder.encode(report)
    let second = try PlaybackSessionReportEncoder.encode(report)
    let json = String(decoding: first, as: UTF8.self)

    #expect(first == second)
    #expect(json.contains("1970-01-01T00:00:00Z"))
    #expect(json.contains("\"schemaVersion\":1"))
}

@Test func reportContainsOnlyOpaqueMediaIdentifiers() throws {
    let report = PlaybackSessionReport(
        sessionID: UUID(),
        sourceID: UUID(),
        fileID: UUID(),
        environmentLabel: "reference",
        startedAt: Date(timeIntervalSince1970: 0),
        endedAt: Date(timeIntervalSince1970: 1),
        snapshots: []
    )

    let json = String(
        decoding: try PlaybackSessionReportEncoder.encode(report),
        as: UTF8.self
    ).lowercased()

    #expect(!json.contains("hostname"))
    #expect(!json.contains("path"))
    #expect(!json.contains("username"))
    #expect(!json.contains("password"))
}
