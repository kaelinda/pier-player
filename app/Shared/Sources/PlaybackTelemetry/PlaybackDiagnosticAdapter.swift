import DiagnosticsKit

public enum PlaybackDiagnosticAdapter {
    public static func record(
        _ snapshot: PlaybackMetricSnapshot,
        context: DiagnosticContext
    ) -> DiagnosticMetricRecord {
        DiagnosticMetricRecord(
            timestamp: snapshot.timestamp,
            context: context,
            networkBytesPerSecond: snapshot.networkBytesPerSecond,
            readLatencyMilliseconds: snapshot.readLatencyMilliseconds,
            cacheHitRatio: snapshot.cacheHitRatio,
            bufferedDurationSeconds: snapshot.bufferedDurationSeconds,
            compressedQueueDepth: snapshot.compressedQueueDepth,
            videoQueueDepth: snapshot.videoQueueDepth,
            decodeLatencyMilliseconds: snapshot.decodeLatencyMilliseconds,
            presentedFrames: snapshot.presentedFrames,
            droppedFrames: snapshot.droppedFrames,
            stallCount: snapshot.stallCount,
            residentBytes: snapshot.residentBytes
        )
    }
}
