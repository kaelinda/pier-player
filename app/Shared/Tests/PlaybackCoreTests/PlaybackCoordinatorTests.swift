import Foundation
import MediaSourceKit
import RenderKit
import Testing
@testable import PlaybackCore

@MainActor
@Test func coordinatorPlaysSeeksWithPausedIntentAndExposesTracks() async throws {
    let file = try PlaybackTestFile(fixture: "video-h264-aac-srt.mkv")
    let renderer = SampleBufferRenderer(maximumPendingDuration: 3)
    let coordinator = PlaybackCoordinator(
        renderer: renderer,
        configuration: .test
    )

    try await coordinator.start(file: file)
    try await waitForCoordinator(coordinator) {
        $0.state == .playing
    }
    let opened = await coordinator.snapshot
    #expect(opened.duration >= 1)
    #expect(opened.tracks.contains { $0.kind == .audio })
    #expect(opened.tracks.contains { $0.kind == .subtitle })
    #expect(opened.videoDecoderMode != .none)

    try await coordinator.pause()
    #expect(await coordinator.snapshot.state == .paused)
    let generation = try await coordinator.seek(to: 1)
    try await waitForCoordinator(coordinator) {
        $0.generation == generation && $0.state == .paused
    }
    #expect(await coordinator.snapshot.position >= 1)

    try await coordinator.resume()
    #expect(await coordinator.snapshot.intendsToPlay)
    await coordinator.stop()
    #expect(await coordinator.snapshot.state == .idle)
    #expect(file.closeCount == 1)
}

@MainActor
@Test func coordinatorDrainsEOFAndRejectsStaleRapidSeekWork() async throws {
    let file = try PlaybackTestFile(fixture: "video-h264-aac.mkv")
    let renderer = SampleBufferRenderer(maximumPendingDuration: 3)
    let coordinator = PlaybackCoordinator(
        renderer: renderer,
        configuration: .test
    )

    try await coordinator.start(file: file)
    try await waitForCoordinator(coordinator) { $0.state == .playing }
    async let first = coordinator.seek(to: 0.25)
    async let second = coordinator.seek(to: 1)
    _ = try? await first
    let latestGeneration = try await second
    try await waitForCoordinator(coordinator, timeout: 4) {
        $0.state == .ended
    }
    let ended = await coordinator.snapshot
    #expect(ended.generation >= latestGeneration)
    #expect(ended.state == .ended)
    await coordinator.stop()
    #expect(file.closeCount == 1)
}

@MainActor
private func waitForCoordinator(
    _ coordinator: PlaybackCoordinator,
    timeout: TimeInterval = 2,
    predicate: (PlaybackCoordinatorSnapshot) -> Bool
) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while ProcessInfo.processInfo.systemUptime < deadline {
        if predicate(await coordinator.snapshot) { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("timed out waiting for coordinator state: \(await coordinator.snapshot)")
}

private final class PlaybackTestFile: MediaReadableFile, @unchecked Sendable {
    let identity: MediaFileIdentity
    private let data: Data
    private let lock = NSLock()
    private var closes = 0

    var closeCount: Int { lock.withLock { closes } }

    init(fixture: String) throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(fixture)
        self.data = try Data(contentsOf: url)
        self.identity = MediaFileIdentity(
            sourceID: UUID(),
            path: "/\(fixture)",
            size: Int64(data.count),
            modifiedAt: nil
        )
    }

    func read(at offset: Int64, length: Int) async throws -> Data {
        guard offset >= 0, length > 0, offset < identity.size else { return Data() }
        let start = Int(offset)
        let end = min(start + length, data.count)
        return data.subdata(in: start..<end)
    }

    func close() async {
        lock.withLock { closes += 1 }
    }
}
