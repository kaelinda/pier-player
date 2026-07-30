# Progressive AVFoundation Playback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Start AVFoundation-compatible SMB videos from bounded random-access reads instead of downloading the complete file before creating AVPlayer.

**Architecture:** A pure `ProgressiveMediaLoader` actor splits requested ranges into bounded reads from `MediaReadableFile`. An `AVAssetResourceLoaderDelegate` adapter answers AVFoundation content and data requests, while a retained `ProgressivePlaybackSession` owns the asset, player, loader, cancellation, and remote-file lifetime.

**Tech Stack:** Swift 6, Swift concurrency, AVFoundation/AVKit, SwiftUI, Swift Testing, Swift Package Manager

---

## File Map

- Create `app/macOS/Sources/PierPlayerApp/ProgressiveMediaLoader.swift`: bounded, cancellable, AVFoundation-independent range loading and typed errors.
- Create `app/macOS/Sources/PierPlayerApp/ProgressivePlaybackSession.swift`: supported-container mapping, AVAsset resource-loader adapter, request task tracking, AVPlayer ownership, and shutdown.
- Create `app/macOS/Tests/PierPlayerAppTests/ProgressiveMediaLoaderTests.swift`: deterministic range, EOF, cancellation, and close tests.
- Create `app/macOS/Tests/PierPlayerAppTests/ProgressivePlaybackSessionTests.swift`: current backend container capability tests.
- Create `app/macOS/Tests/PierPlayerAppTests/VideoPlayerModelTests.swift`: startup ownership and no-eager-read regression tests.
- Modify `app/macOS/Sources/PierPlayerApp/SourceBrowserView.swift`: replace whole-file temporary download with the retained progressive session and narrow clickable formats.
- Modify `app/macOS/Tests/PierPlayerAppTests/UIRenderingTests.swift`: keep the existing minimum-size render checks green after player state changes; no new snapshot is required because the player sheet layout remains structurally unchanged.

### Task 1: Bounded Range Loader

**Files:**
- Create: `app/macOS/Sources/PierPlayerApp/ProgressiveMediaLoader.swift`
- Create: `app/macOS/Tests/PierPlayerAppTests/ProgressiveMediaLoaderTests.swift`

- [ ] **Step 1: Write failing bounded-range tests**

Create a `@Suite struct ProgressiveMediaLoaderTests` with a deterministic
`RecordingReadableFile` actor implementing `MediaReadableFile`. Add tests with the
wished-for API:

```swift
@Test func largeRangeIsSplitIntoBoundedReads() async throws {
    let bytes = Data((0..<24).map { UInt8($0) })
    let file = RecordingReadableFile(bytes: bytes)
    let loader = try ProgressiveMediaLoader(file: file, maximumReadLength: 4)
    let sink = DataSink()

    try await loader.load(offset: 3, length: 13) { chunk in
        await sink.append(chunk)
    }

    #expect(await sink.data == bytes.subdata(in: 3..<16))
    #expect(await file.requests == [
        .init(offset: 3, length: 4),
        .init(offset: 7, length: 4),
        .init(offset: 11, length: 4),
        .init(offset: 15, length: 1),
    ])
}

@Test func finiteRangeIsClampedAtEndOfFile() async throws {
    let bytes = Data((0..<10).map { UInt8($0) })
    let file = RecordingReadableFile(bytes: bytes)
    let loader = try ProgressiveMediaLoader(file: file, maximumReadLength: 4)
    let sink = DataSink()

    try await loader.load(offset: 7, length: 20) { chunk in
        await sink.append(chunk)
    }

    #expect(await sink.data == bytes.subdata(in: 7..<10))
    #expect(await file.requests == [.init(offset: 7, length: 3)])
}

@Test func nilLengthReadsToKnownEndOfFile() async throws {
    let bytes = Data((0..<10).map { UInt8($0) })
    let file = RecordingReadableFile(bytes: bytes)
    let loader = try ProgressiveMediaLoader(file: file, maximumReadLength: 4)
    let sink = DataSink()

    try await loader.load(offset: 2, length: nil) { chunk in
        await sink.append(chunk)
    }

    #expect(await sink.data == bytes.subdata(in: 2..<10))
}
```

Also add tests that an invalid negative offset or non-positive finite length makes
zero upstream calls, an unexpected empty read before EOF throws
`ProgressiveMediaLoaderError.unexpectedEndOfFile`, a cancelled suspended read does
not emit data, and calling `close()` twice closes the upstream file once.

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
cd app
swift test --filter ProgressiveMediaLoaderTests
```

Expected: compilation fails because `ProgressiveMediaLoader` and `ProgressiveMediaLoaderError` do not exist.

- [ ] **Step 3: Implement the minimal range loader**

Implement this API in `ProgressiveMediaLoader.swift`:

```swift
import Foundation
import MediaSourceKit

enum ProgressiveMediaLoaderError: Error, Equatable {
    case invalidMaximumReadLength(Int)
    case invalidRange(offset: Int64, length: Int64?)
    case unexpectedEndOfFile(offset: Int64)
    case closed
}

actor ProgressiveMediaLoader {
    nonisolated let identity: MediaFileIdentity

    private let file: any MediaReadableFile
    private let maximumReadLength: Int
    private var isClosed = false

    init(file: any MediaReadableFile, maximumReadLength: Int = 512 * 1024) throws {
        guard maximumReadLength > 0 else {
            throw ProgressiveMediaLoaderError.invalidMaximumReadLength(maximumReadLength)
        }
        self.file = file
        self.identity = file.identity
        self.maximumReadLength = maximumReadLength
    }

    func load(
        offset: Int64,
        length: Int64?,
        consume: @Sendable (Data) async throws -> Void
    ) async throws {
        guard !isClosed else { throw ProgressiveMediaLoaderError.closed }
        guard offset >= 0 else {
            throw ProgressiveMediaLoaderError.invalidRange(offset: offset, length: length)
        }
        if let length, length <= 0 {
            throw ProgressiveMediaLoaderError.invalidRange(offset: offset, length: length)
        }
        guard offset < identity.size else { return }

        let requestedEnd = try endOffset(start: offset, length: length)
        let end = min(identity.size, requestedEnd)
        var cursor = offset

        while cursor < end {
            try Task.checkCancellation()
            guard !isClosed else { throw ProgressiveMediaLoaderError.closed }
            let count = Int(min(Int64(maximumReadLength), end - cursor))
            let data = try await file.read(at: cursor, length: count)
            try Task.checkCancellation()
            guard !data.isEmpty else {
                throw ProgressiveMediaLoaderError.unexpectedEndOfFile(offset: cursor)
            }
            let accepted = data.prefix(count)
            try await consume(Data(accepted))
            cursor += Int64(accepted.count)
        }
    }

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        await file.close()
    }
}
```

Implement `endOffset(start:length:)` with `addingReportingOverflow`; `nil` returns `identity.size`, and overflow throws `invalidRange`. Do not use force unwrap in the final implementation.

- [ ] **Step 4: Run focused tests and verify GREEN**

Run `swift test --filter ProgressiveMediaLoaderTests` from `app/`.

Expected: all loader tests pass and every recorded read length is at most the configured cap.

- [ ] **Step 5: Commit the loader**

```bash
git add app/macOS/Sources/PierPlayerApp/ProgressiveMediaLoader.swift \
  app/macOS/Tests/PierPlayerAppTests/ProgressiveMediaLoaderTests.swift
git commit -m "feat(playback): add bounded progressive range loader"
```

### Task 2: AVFoundation Resource Adapter

**Files:**
- Create: `app/macOS/Sources/PierPlayerApp/ProgressivePlaybackSession.swift`
- Create: `app/macOS/Tests/PierPlayerAppTests/ProgressivePlaybackSessionTests.swift`

- [ ] **Step 1: Write failing current-backend capability tests**

```swift
@Test(arguments: ["movie.mp4", "MOVIE.M4V", "clip.mov"])
func avFoundationPlaybackAcceptsSupportedContainers(_ fileName: String) {
    #expect(AVFoundationMediaType(fileName: fileName) != nil)
}

@Test(arguments: ["movie.mkv", "movie.webm", "movie", "movie.mp4.exe"])
func avFoundationPlaybackRejectsUnsupportedContainers(_ fileName: String) {
    #expect(AVFoundationMediaType(fileName: fileName) == nil)
}
```

Also assert that each supported media type provides a non-empty AVFoundation content type and a private asset URL whose path ends in the normalized original extension but contains no source path.

- [ ] **Step 2: Run the focused tests and verify RED**

Run `swift test --filter ProgressivePlaybackSessionTests`.

Expected: compilation fails because `AVFoundationMediaType` is missing.

- [ ] **Step 3: Implement media types and the resource-loader adapter**

Create `AVFoundationMediaType` with only `.mp4`, `.m4v`, and `.mov`. Map them to `AVFileType.mp4.rawValue`, `AVFileType.m4v.rawValue`, and `AVFileType.mov.rawValue`.

Implement `ProgressiveMediaResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable` with:

```swift
func resourceLoader(
    _ resourceLoader: AVAssetResourceLoader,
    shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
) -> Bool

func resourceLoader(
    _ resourceLoader: AVAssetResourceLoader,
    didCancel loadingRequest: AVAssetResourceLoadingRequest
)

func close() async
```

The delegate must populate `contentLength`, `contentType`, and
`isByteRangeAccessSupported`. For data requests, calculate the start as
`max(requestedOffset, currentOffset)`. Pass `nil` length when
`requestsAllDataToEndOfResource` is true; otherwise pass the unfulfilled portion
of the original finite range. Respond with each emitted chunk immediately.

Wrap each non-Sendable loading request in a private `@unchecked Sendable` operation
object. Store operations by `ObjectIdentifier` before starting their task so a
fast completion cannot leave stale bookkeeping. The operation serializes
`respond`, success, failure, and cancellation and guarantees a request is finished
at most once. Cancellation marks the operation cancelled and cancels its task
without reporting a playback failure.

- [ ] **Step 4: Implement retained playback-session ownership**

Add a `@MainActor final class ProgressivePlaybackSession` that retains:

```swift
let player: AVPlayer
let asset: AVURLAsset
private let resourceLoader: ProgressiveMediaResourceLoader
private var isStopped = false
```

Its initializer validates the file name, creates `ProgressiveMediaLoader`, creates
the private `AVURLAsset`, installs the delegate before constructing `AVPlayerItem`,
and builds the player. `play()` calls `player.play()`. `stop()` is idempotent and
performs `player.pause()`, `asset.cancelLoading()`, then `await resourceLoader.close()`.

- [ ] **Step 5: Run focused tests and full compilation**

Run:

```bash
swift test --filter ProgressivePlaybackSessionTests
swift build
```

Expected: capability tests pass and Swift 6 reports no sendability errors in the
AVFoundation delegate/task bridge.

- [ ] **Step 6: Commit the adapter**

```bash
git add app/macOS/Sources/PierPlayerApp/ProgressivePlaybackSession.swift \
  app/macOS/Tests/PierPlayerAppTests/ProgressivePlaybackSessionTests.swift
git commit -m "feat(playback): bridge SMB ranges into AVFoundation"
```

### Task 3: Replace Whole-File Download In The Player UI

**Files:**
- Modify: `app/macOS/Sources/PierPlayerApp/SourceBrowserView.swift:1-78`
- Modify: `app/macOS/Sources/PierPlayerApp/SourceBrowserView.swift:197-219`
- Modify: `app/macOS/Sources/PierPlayerApp/SourceBrowserView.swift:298-320`
- Modify: `app/macOS/Sources/PierPlayerApp/SourceBrowserView.swift:323-483`
- Create: `app/macOS/Tests/PierPlayerAppTests/VideoPlayerModelTests.swift`

- [ ] **Step 1: Add a failing startup ownership regression test**

In `VideoPlayerModelTests.swift`, create a fake media source, readable file, and
playback session against the wished-for injectable model API. Write this behavior
test before adding the production protocol or factory:

```swift
@MainActor
@Test func startTransfersTheOpenFileWithoutEagerReads() async throws {
    let file = RecordingReadableFile(bytes: Data(repeating: 1, count: 8 * 1024 * 1024))
    let source = FakeMediaSource(file: file)
    let session = FakeVideoPlaybackSession()
    let model = VideoPlayerModel(item: fixtureItem, source: source) { openedFile, fileName in
        #expect(openedFile.identity == file.identity)
        #expect(fileName == fixtureItem.name)
        return session
    }

    await model.start()

    #expect(await file.readRequests.isEmpty)
    #expect(session.playCount == 1)
    #expect(model.player === session.player)
    #expect(model.phase == .playing)
}
```

Add a second test that `stop()` clears the published player and calls the fake
session's idempotent stop once. The fakes must implement the real protocols rather
than inspecting production source text.

- [ ] **Step 2: Run the regression test and verify RED**

Run `swift test --filter VideoPlayerModelTests`.

Expected: compilation fails because `VideoPlayerModel` has no injectable session
factory and still exposes only the whole-file download path.

- [ ] **Step 3: Replace `VideoPlayerModel` ownership and phases**

Generalize the model's source field to `any MediaSource`. Introduce an internal
`@MainActor VideoPlaybackSession` protocol and a factory closure whose production
default constructs `ProgressivePlaybackSession`. Make the concrete session conform
to the protocol, then change the model to retain the protocol existential and expose
its player:

```swift
@Published private(set) var phase: Phase = .preparing
@Published private(set) var player: AVPlayer?

enum Phase: Equatable {
    case preparing
    case playing
    case failed(String)
}

private var playbackSession: (any VideoPlaybackSession)?
```

`start()` opens the remote file, constructs the session, checks cancellation,
publishes its player, starts playback, and enters `.playing`. If construction fails
before ownership transfers, close the opened file. If cancellation or failure
occurs after session creation, stop that session. Add async `stop()` that clears UI
ownership first and then awaits the session's idempotent stop.

- [ ] **Step 4: Update browser gating and sheet lifecycle**

Replace all clickable/icon/label checks based on `item.isSupportedVideo` with a
private `isPlayableVideo(_:)` helper that requires a file item and a non-nil
`AVFoundationMediaType(fileName:)`. MKV rows must render as ordinary non-clickable
files.

Replace download-progress UI with a compact `Preparing Video` progress state.
Pass the retained `AVPlayer` into `VideoPlayerView`, update an existing view's
player when identity changes, and clear it during dismantle. Change sheet teardown
to:

```swift
.onDisappear {
    Task {
        await playerModel.stop()
    }
}
```

- [ ] **Step 5: Run focused and UI tests and verify GREEN**

Run:

```bash
swift test --filter ProgressivePlaybackSessionTests
swift test --filter VideoPlayerModelTests
swift test
```

Expected: the startup ownership regression passes, current backend formats are
correct, the model does not eagerly read, and both existing offscreen UI rendering
tests pass.

- [ ] **Step 6: Commit the UI integration**

```bash
git add app/macOS/Sources/PierPlayerApp/SourceBrowserView.swift \
  app/macOS/Tests/PierPlayerAppTests/VideoPlayerModelTests.swift
git commit -m "feat(macOS): start supported SMB videos progressively"
```

### Task 4: Verification And Performance Evidence

**Files:**
- Modify only if a verification failure exposes a defect in files already owned by this plan.

- [ ] **Step 1: Run complete repository verification**

From `app/`, run:

```bash
swift test
swift build -c release
scripts/check.sh
```

Expected: all Swift Testing tests pass, the macOS executable builds in Release,
and the repository script reports tests, Release build, and whitespace checks as
successful.

- [ ] **Step 2: Run a bounded-read benchmark harness**

Use a Release test filter for `largeRangeIsSplitIntoBoundedReads` and record that a
multi-chunk logical range never produces an upstream read over the configured cap:

```bash
swift test -c release --filter largeRangeIsSplitIntoBoundedReads
```

Expected: the test passes. This proves the allocation/read bound, not NAS speed or
first-frame latency.

- [ ] **Step 3: Review scope and diff hygiene**

Run:

```bash
git diff --check main...HEAD
git status --short
git diff --stat main...HEAD
git log --oneline main..HEAD
```

Confirm no `.vscode`, media, credentials, generated fixtures, build products, or
unrelated broad-format implementation changes are included.

- [ ] **Step 4: Commit any verification-only corrections**

If and only if the previous steps required a correction to files in this plan,
stage those exact files and commit with:

```bash
git commit -m "fix(playback): harden progressive loading lifecycle"
```

Otherwise leave the verified implementation commits unchanged.
