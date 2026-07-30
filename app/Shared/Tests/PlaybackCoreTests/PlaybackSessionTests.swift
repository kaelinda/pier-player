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

    let reconnect = try await session.beginReconnection(at: 42)

    #expect(reconnect.generation == opening.generation + 1)
    #expect(await session.snapshot.state == .reconnecting)
    #expect(await session.snapshot.position == 42)
    #expect(!(await session.mediaOpened(token: opening)))
    #expect(await session.connectionRecovered(token: reconnect))
    #expect(await session.snapshot.state == .buffering(.recovery))
    #expect(await session.bufferingCompleted(token: reconnect))
    #expect(await session.snapshot.state == .playing)
}

@Test func underrunBuffersWithoutInvalidatingActiveGeneration() async throws {
    let session = PlaybackSession()
    let token = try await session.open()
    _ = await session.connectionEstablished(token: token)
    _ = await session.mediaOpened(token: token)
    _ = await session.bufferingCompleted(token: token)

    #expect(await session.beginRebuffering(token: token, at: 0.5))
    #expect(await session.snapshot.generation == token.generation)
    #expect(await session.snapshot.state == .buffering(.underrun))
    #expect(await session.snapshot.position == 0.5)
    #expect(await session.bufferingCompleted(token: token))
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
