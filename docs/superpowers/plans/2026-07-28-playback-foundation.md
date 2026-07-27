# Playback Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Create a runnable macOS Swift package with tested source contracts, bounded page caching, coalesced random reads, seek generations, and performance reports.

**Architecture:** Keep source access, stream buffering, playback state, telemetry, and SwiftUI in separate targets. Build pure-Swift boundaries first so later libsmb2, FFmpeg, and VideoToolbox adapters can be integrated and measured independently.

**Tech Stack:** Swift 6.0, Swift Package Manager, Swift Testing, SwiftUI, Foundation

---

## File Map

- `Package.swift`: products, target graph, and macOS deployment target.
- `Sources/MediaSourceKit/`: source entries, file identity, errors, and random-access protocols.
- `Sources/StreamIOKit/`: aligned pages, bounded LRU cache, coalesced reads, and stream metrics.
- `Sources/PlaybackCore/`: playback phases, session IDs, and seek generations.
- `Sources/PlaybackTelemetry/`: Codable snapshots and session report encoding.
- `Sources/PierPlayerApp/`: minimal macOS SwiftUI executable proving module wiring.
- `Tests/*Tests/`: behavior and concurrency coverage.
- `scripts/check.sh`: reproducible local verification.
- `docs/benchmarks/reference-environment.md`: required performance-baseline fields.

### Task 1: Swift Package Skeleton

**Files:**
- Create: `Package.swift`
- Create: `.gitignore`
- Create: `Sources/PierPlayerApp/PierPlayerApp.swift`
- Create: `Sources/PierPlayerApp/RootView.swift`
- Create: `Sources/MediaSourceKit/Module.swift`
- Create: `Sources/StreamIOKit/Module.swift`
- Create: `Sources/PlaybackCore/Module.swift`
- Create: `Sources/PlaybackTelemetry/Module.swift`
- Create: `Tests/MediaSourceKitTests/ModuleSmokeTests.swift`
- Create: `Tests/StreamIOKitTests/ModuleSmokeTests.swift`
- Create: `Tests/PlaybackCoreTests/ModuleSmokeTests.swift`
- Create: `Tests/PlaybackTelemetryTests/ModuleSmokeTests.swift`
- Create: `scripts/check.sh`

- [x] **Step 1: Define the package graph**

Create library targets `MediaSourceKit`, `StreamIOKit`, `PlaybackCore`, and `PlaybackTelemetry`, plus executable target `PierPlayerApp`. Set macOS 14 as the package minimum and add matching test targets. Add a minimal public module marker and import smoke test to each library so SwiftPM has a valid clean baseline before behavior tests are introduced.

- [x] **Step 2: Add a minimal executable shell**

Use `@main struct PierPlayerApp: App` with a `WindowGroup` containing `RootView`. The view displays the product name and the current foundation status without importing native playback dependencies.

- [x] **Step 3: Add the verification script**

```bash
#!/usr/bin/env bash
set -euo pipefail
swift test
swift build -c release
git diff --check
```

- [x] **Step 4: Verify the empty graph builds**

Run: `swift build`

Expected: build succeeds for all empty library targets and the app executable.

- [x] **Step 5: Commit**

```bash
git add Package.swift .gitignore Sources Tests scripts/check.sh
git commit -m "build: add Swift package foundation"
```

### Task 2: Media Source Contracts

**Files:**
- Create: `Sources/MediaSourceKit/MediaSourceItem.swift`
- Create: `Sources/MediaSourceKit/MediaFileIdentity.swift`
- Create: `Sources/MediaSourceKit/MediaSourceError.swift`
- Create: `Sources/MediaSourceKit/MediaSource.swift`
- Create: `Tests/MediaSourceKitTests/MediaSourceItemTests.swift`

- [x] **Step 1: Write failing model tests**

Test that video detection accepts `MKV` and `mp4`, rejects directories and unsupported extensions, and that file identity changes when size or modification date changes.

- [x] **Step 2: Verify RED**

Run: `swift test --filter MediaSourceItemTests`

Expected: compile failure because the MediaSourceKit types do not exist.

- [x] **Step 3: Implement minimal contracts**

Define Sendable value types and these protocols:

```swift
public protocol MediaReadableFile: Sendable {
    var identity: MediaFileIdentity { get }
    func read(at offset: Int64, length: Int) async throws -> Data
    func close() async
}

public protocol MediaSource: Sendable {
    var id: UUID { get }
    var displayName: String { get }
    func connect() async throws
    func disconnect() async
    func list(directory path: String) async throws -> [MediaSourceItem]
    func open(file path: String) async throws -> any MediaReadableFile
}
```

Restrict first-milestone video extensions to `mkv`, `mp4`, `m4v`, and `mov`.

- [x] **Step 4: Verify GREEN**

Run: `swift test --filter MediaSourceItemTests`

Expected: all MediaSourceItem tests pass.

- [x] **Step 5: Commit**

```bash
git add Sources/MediaSourceKit Tests/MediaSourceKitTests
git commit -m "feat(media-source): define random access contracts"
```

### Task 3: Bounded Aligned Page Cache

**Files:**
- Create: `Sources/StreamIOKit/ByteRange.swift`
- Create: `Sources/StreamIOKit/PageCache.swift`
- Create: `Tests/StreamIOKitTests/PageCacheTests.swift`

- [x] **Step 1: Write failing cache tests**

Cover aligned insertion, reads spanning two pages, misses when any page is absent, LRU eviction, replacement without double-counting bytes, invalid ranges, and a capacity smaller than one page.

- [x] **Step 2: Verify RED**

Run: `swift test --filter PageCacheTests`

Expected: compile failure because `PageCache` is missing.

- [x] **Step 3: Implement the actor**

```swift
public actor PageCache {
    public init(pageSize: Int, capacityBytes: Int)
    public func data(at offset: Int64, length: Int) throws -> Data?
    public func insert(page data: Data, at alignedOffset: Int64) throws
    public func removeAll()
    public var residentByteCount: Int { get }
}
```

Use an access counter for deterministic LRU eviction. Reject negative offsets, non-positive lengths, unaligned inserts, oversized pages, and impossible capacity configurations with typed errors.

- [x] **Step 4: Verify GREEN**

Run: `swift test --filter PageCacheTests`

Expected: all PageCache tests pass.

- [x] **Step 5: Commit**

```bash
git add Sources/StreamIOKit Tests/StreamIOKitTests
git commit -m "feat(stream-io): add bounded page cache"
```

### Task 4: Coalesced Cached Reader

**Files:**
- Create: `Sources/StreamIOKit/CachedMediaReader.swift`
- Create: `Sources/StreamIOKit/StreamMetrics.swift`
- Create: `Tests/StreamIOKitTests/CachedMediaReaderTests.swift`

- [x] **Step 1: Write failing asynchronous tests**

Use a deterministic counting reader. Prove that concurrent requests for the same page produce one upstream read, cache hits avoid new reads, cross-page requests concatenate correctly, EOF returns a short read, invalid ranges fail before upstream access, and `removeAllCachedData` forces a subsequent miss.

- [x] **Step 2: Verify RED**

Run: `swift test --filter CachedMediaReaderTests`

Expected: compile failure because `CachedMediaReader` is missing.

- [x] **Step 3: Implement minimal coalescing**

`CachedMediaReader` is an actor containing a `PageCache`, an upstream `MediaReadableFile`, and `[Int64: Task<Data, Error>]` keyed by aligned page offset. Demand reads load only missing pages; simultaneous demand for the same page awaits the same task. Clamp the last page to file size and expose hit, miss, upstream-read, and upstream-byte counters.

- [x] **Step 4: Verify GREEN and concurrency stability**

Run: `swift test --filter CachedMediaReaderTests`

Expected: all tests pass repeatedly without races.

- [x] **Step 5: Commit**

```bash
git add Sources/StreamIOKit Tests/StreamIOKitTests
git commit -m "feat(stream-io): coalesce cached range reads"
```

### Task 5: Playback Session State and Seek Generations

**Files:**
- Create: `Sources/PlaybackCore/PlaybackState.swift`
- Create: `Sources/PlaybackCore/PlaybackSession.swift`
- Create: `Tests/PlaybackCoreTests/PlaybackSessionTests.swift`

- [x] **Step 1: Write failing state tests**

Cover open-to-buffering, start playing, pause/resume intent, seek generation increments, stale completion rejection, current completion transition, reconnect/recover, stop invalidation, and invalid command errors.

- [x] **Step 2: Verify RED**

Run: `swift test --filter PlaybackSessionTests`

Expected: compile failure because playback session types are missing.

- [x] **Step 3: Implement the state actor**

Expose immutable `PlaybackSnapshot` values instead of state mutation. Each open creates a UUID session ID. Each seek increments `UInt64 generation`; asynchronous completions must present their session ID and generation and are ignored when stale.

- [x] **Step 4: Verify GREEN**

Run: `swift test --filter PlaybackSessionTests`

Expected: all state and generation tests pass.

- [x] **Step 5: Commit**

```bash
git add Sources/PlaybackCore Tests/PlaybackCoreTests
git commit -m "feat(playback): add session state machine"
```

### Task 6: Telemetry Session Reports

**Files:**
- Create: `Sources/PlaybackTelemetry/PlaybackMetricSnapshot.swift`
- Create: `Sources/PlaybackTelemetry/PlaybackSessionReport.swift`
- Create: `Tests/PlaybackTelemetryTests/PlaybackSessionReportTests.swift`

- [x] **Step 1: Write failing encoding tests**

Prove stable ISO-8601 JSON encoding, metric aggregation, and that reports contain opaque source/file IDs but no host, path, username, or password fields.

- [x] **Step 2: Verify RED**

Run: `swift test --filter PlaybackSessionReportTests`

Expected: compile failure because report types are missing.

- [x] **Step 3: Implement Codable report types**

Snapshots include throughput, read latency, cache hit ratio, buffered seconds, queue depths, decode latency, presented/dropped frames, stall count, and resident bytes. Reports include schema version, timestamps, opaque IDs, environment label, and snapshots.

- [x] **Step 4: Verify GREEN**

Run: `swift test --filter PlaybackSessionReportTests`

Expected: all telemetry tests pass.

- [x] **Step 5: Commit**

```bash
git add Sources/PlaybackTelemetry Tests/PlaybackTelemetryTests
git commit -m "feat(telemetry): add playback session reports"
```

### Task 7: App Wiring and Benchmark Template

**Files:**
- Modify: `Sources/PierPlayerApp/RootView.swift`
- Create: `Sources/PierPlayerApp/AppModel.swift`
- Create: `docs/benchmarks/reference-environment.md`
- Modify: `AGENTS.md`

- [x] **Step 1: Add a module-wiring test through the executable build**

Build the app target before imports are added and confirm the new AppModel reference fails.

- [x] **Step 2: Implement the app model and quiet workbench shell**

Expose the current `PlaybackSnapshot` through `@MainActor AppModel`. Present a compact sidebar/content layout with an empty source state and disabled playback controls. Do not imply SMB or decode is already implemented.

- [x] **Step 3: Add the reference environment template**

Document fields for Mac model, OS, display/EDR, NAS, disks, SMB dialect/signing/encryption, network equipment, fixture checksum, and Release build commit.

- [x] **Step 4: Update contributor commands**

Replace the “no package” warning in `AGENTS.md` with `swift build`, `swift test`, `swift run PierPlayerApp`, and `scripts/check.sh`.

- [x] **Step 5: Verify build**

Run: `swift build` and `swift build -c release`

Expected: both app builds succeed.

- [x] **Step 6: Commit**

```bash
git add Sources/PierPlayerApp docs/benchmarks AGENTS.md
git commit -m "feat(app): wire playback foundation shell"
```

### Task 8: Full Verification

**Files:**
- Modify only if verification exposes a defect.

- [x] **Step 1: Run the complete gate**

Run: `scripts/check.sh`

Expected: all tests pass, Release build succeeds, and `git diff --check` is clean.

- [x] **Step 2: Run tests repeatedly**

Run: `for run in 1 2 3 4 5; do swift test >/dev/null || exit 1; done`

Expected: five successful runs, guarding the coalescing tests against timing flakes.

- [x] **Step 3: Inspect dependency and license surface**

Run: `swift package show-dependencies`

Expected: no external dependencies in this foundation plan.

- [x] **Step 4: Review repository state**

Run: `git status --short` and `git log --oneline --decorate -8`

Expected: only the plan file remains uncommitted if task commits followed the plan.

- [x] **Step 5: Commit the plan and verification updates**

```bash
git add docs/superpowers/plans/2026-07-28-playback-foundation.md
git commit -m "docs: add playback foundation plan"
```
