import DiagnosticsKit
import Foundation
import Testing
@testable import PlaybackCore

@Test func openProgressesToInitialBufferingAndPlayback() async throws {
    let session = PlaybackSession()

    let token = try await session.open()
    #expect(await session.snapshot.state == .connecting)
    #expect(await session.connectionEstablished(token: token))
    #expect(await session.snapshot.state == .opening)
    #expect(await session.mediaOpened(token: token))
    #expect(await session.snapshot.state == .buffering(.initial))
    #expect(await session.bufferingCompleted(token: token))
    #expect(await session.snapshot.state == .playing)
}

@Test func pauseAndResumeUpdatePlaybackIntent() async throws {
    let session = PlaybackSession()
    let token = try await session.open()
    _ = await session.connectionEstablished(token: token)
    _ = await session.mediaOpened(token: token)
    _ = await session.bufferingCompleted(token: token)

    try await session.pause()
    #expect(await session.snapshot.state == .paused)
    #expect(await !session.snapshot.intendsToPlay)

    try await session.resume()
    #expect(await session.snapshot.state == .playing)
    #expect(await session.snapshot.intendsToPlay)
}

@Test func pauseDuringBufferingDefersPausedStateUntilBufferCompletes() async throws {
    let session = PlaybackSession()
    let token = try await session.open()
    _ = await session.connectionEstablished(token: token)
    _ = await session.mediaOpened(token: token)

    try await session.pause()

    #expect(await session.snapshot.state == .buffering(.initial))
    #expect(await !session.snapshot.intendsToPlay)
    #expect(await session.bufferingCompleted(token: token))
    #expect(await session.snapshot.state == .paused)
}

@Test func seekIncrementsGenerationAndPreservesPausedIntent() async throws {
    let session = PlaybackSession()
    let opening = try await session.open()
    _ = await session.connectionEstablished(token: opening)
    _ = await session.mediaOpened(token: opening)
    _ = await session.bufferingCompleted(token: opening)
    try await session.pause()

    let seek = try await session.seek(to: 42)

    #expect(seek.generation == opening.generation + 1)
    #expect(await session.snapshot.state == .buffering(.seek))
    #expect(await session.snapshot.position == 42)
    #expect(await !session.snapshot.intendsToPlay)
    #expect(await session.bufferingCompleted(token: seek))
    #expect(await session.snapshot.state == .paused)
}

@Test func staleSeekCompletionCannotChangeCurrentState() async throws {
    let session = PlaybackSession()
    let opening = try await session.open()
    _ = await session.connectionEstablished(token: opening)
    _ = await session.mediaOpened(token: opening)
    _ = await session.bufferingCompleted(token: opening)

    let firstSeek = try await session.seek(to: 10)
    let secondSeek = try await session.seek(to: 20)

    #expect(!(await session.bufferingCompleted(token: firstSeek)))
    #expect(await session.snapshot.position == 20)
    #expect(await session.snapshot.state == .buffering(.seek))
    #expect(await session.bufferingCompleted(token: secondSeek))
    #expect(await session.snapshot.state == .playing)
}

@Test func reconnectionInvalidatesPreviousOperations() async throws {
    let session = PlaybackSession()
    let opening = try await session.open()
    _ = await session.connectionEstablished(token: opening)
    _ = await session.mediaOpened(token: opening)
    _ = await session.bufferingCompleted(token: opening)

    let reconnect = try await session.beginReconnection()

    #expect(reconnect.generation == opening.generation + 1)
    #expect(await session.snapshot.state == .reconnecting)
    #expect(!(await session.mediaOpened(token: opening)))
    #expect(await session.connectionRecovered(token: reconnect))
    #expect(await session.snapshot.state == .buffering(.recovery))
    #expect(await session.bufferingCompleted(token: reconnect))
    #expect(await session.snapshot.state == .playing)
}

@Test func stopInvalidatesSessionAndOutstandingTokens() async throws {
    let session = PlaybackSession()
    let token = try await session.open()

    await session.stop()

    #expect(await session.snapshot.state == .idle)
    #expect(await session.snapshot.sessionID == nil)
    #expect(!(await session.connectionEstablished(token: token)))
}

@Test func openingWhileActiveIsRejected() async throws {
    let session = PlaybackSession()
    _ = try await session.open()

    await #expect(throws: PlaybackCommandError.self) {
        try await session.open()
    }
}

@Test func pauseWhileIdleIsRejected() async {
    let session = PlaybackSession()

    await #expect(throws: PlaybackCommandError.self) {
        try await session.pause()
    }
}

@Test func playbackTransitionsRecordTypedStateGenerationAndRejections() async throws {
    let recorder = PlaybackRecordingDiagnosticRecorder()
    let context = DiagnosticContext(
        appRunID: UUID(uuidString: "00000000-0000-0000-0000-000000000401")!,
        activityID: UUID(uuidString: "00000000-0000-0000-0000-000000000402")!,
        operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000403")!
    )
    let session = PlaybackSession(
        diagnosticRecorder: recorder,
        diagnosticContext: context
    )

    let opening = try await session.open()
    #expect(await session.connectionEstablished(token: opening))
    #expect(await session.mediaOpened(token: opening))
    #expect(await session.bufferingCompleted(token: opening))
    try await session.pause()
    try await session.resume()
    let firstSeek = try await session.seek(to: 10)
    _ = try await session.seek(to: 20)
    #expect(!(await session.bufferingCompleted(token: firstSeek)))
    await session.stop()

    let events = recorder.snapshot
    let opened = try #require(events.first {
        $0.name == .playbackPrepare && $0.outcome == .success
    })
    #expect(opened.payload.oldPlaybackState == .idle)
    #expect(opened.payload.newPlaybackState == .connecting)
    #expect(opened.payload.playbackGeneration == 0)
    #expect(opened.payload.playbackSessionID == opening.sessionID)

    let rejected = try #require(events.last { $0.outcome == .discarded })
    #expect(rejected.level == .warning)
    #expect(rejected.payload.playbackGeneration == 2)
    let stopped = try #require(events.last { $0.name == .playbackStop })
    #expect(stopped.outcome == .success)
    #expect(stopped.payload.newPlaybackState == .idle)

    let encoded = try events.map(DiagnosticEventEncoder.encode)
        .map { String(decoding: $0, as: UTF8.self) }
        .joined()
        .lowercased()
    #expect(!encoded.contains("\"command\""))
}

@Test func playbackFailureDoesNotPersistFreeFormMessage() async throws {
    let recorder = PlaybackRecordingDiagnosticRecorder()
    let session = PlaybackSession(diagnosticRecorder: recorder)
    _ = try await session.open()

    await session.fail("smb://private.example/Secret/customer.mkv")

    let failed = try #require(recorder.snapshot.last)
    #expect(failed.name == .playbackFailed)
    #expect(failed.outcome == .failure)
    #expect(failed.payload.newPlaybackState == .failed)
    #expect(failed.payload.error?.code == .playerFailed)
    let encoded = String(
        decoding: try DiagnosticEventEncoder.encode(failed),
        as: UTF8.self
    ).lowercased()
    #expect(!encoded.contains("private.example"))
    #expect(!encoded.contains("customer"))
}

private final class PlaybackRecordingDiagnosticRecorder: DiagnosticRecording, @unchecked Sendable {
    private let lock = NSLock()
    private var events: [DiagnosticEvent] = []

    var snapshot: [DiagnosticEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    func record(_ event: DiagnosticEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }
}
