# Local Diagnostics Toolkit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a bounded, privacy-safe local diagnostics toolkit and apply it to Pier Player's SMB resource access, stream reads, AVFoundation playback, and macOS Settings UI.

**Architecture:** A new Foundation-based `DiagnosticsKit` target owns typed events, correlation, a bounded emitter and flight recorder, JSONL persistence, retention, privacy audit, and `.pierdiag` export. Existing modules receive a `DiagnosticRecording` dependency and emit stable events without performing synchronous disk I/O; the macOS composition root owns one center and exposes summaries and controls to Settings.

**Tech Stack:** Swift 6, Swift Package Manager, Swift Testing, Foundation, CryptoKit, Security, OSLog, Network, AVFoundation, SwiftUI, AppKit.

---

## File Map

New diagnostics core files:

- `app/Shared/Sources/DiagnosticsKit/DiagnosticContext.swift`: correlation IDs.
- `app/Shared/Sources/DiagnosticsKit/DiagnosticEvent.swift`: versioned event envelope and privacy-safe payload enums.
- `app/Shared/Sources/DiagnosticsKit/DiagnosticRecording.swift`: recording protocol, no-op recorder, and bounded emitter.
- `app/Shared/Sources/DiagnosticsKit/DiagnosticFlightRecorder.swift`: time/byte-bounded pre-incident buffer.
- `app/Shared/Sources/DiagnosticsKit/DiagnosticStore.swift`: store protocol, summaries, and snapshot models.
- `app/Shared/Sources/DiagnosticsKit/FileDiagnosticStore.swift`: JSONL rolling files and retention.
- `app/Shared/Sources/DiagnosticsKit/DiagnosticIdentityProvider.swift`: Keychain-backed HMAC file identities.
- `app/Shared/Sources/DiagnosticsKit/DiagnosticPrivacyAudit.swift`: encoded-key and sensitive-value checks.
- `app/Shared/Sources/DiagnosticsKit/DiagnosticBundle.swift`: export package, integrity, and summary generation.
- `app/Shared/Sources/DiagnosticsKit/DiagnosticOSLogSink.swift`: privacy-qualified Logger and signpost mirror.
- `app/Shared/Sources/DiagnosticsKit/DiagnosticCenter.swift`: policy, routing, incidents, queries, and lifecycle.
- `app/Tools/DiagnosticsReport/main.swift`: validate and summarize `.pierdiag` packages.

New tests mirror each responsibility under
`app/Shared/Tests/DiagnosticsKitTests/`. Integration tests remain in their owning
module test targets. The macOS UI adds `DiagnosticsSettingsView.swift` and
`DiagnosticsViewModel.swift`; existing source/playback files receive narrowly
scoped recorder/context injection.

### Task 1: Package Target And Stable Event Schema

**Files:**
- Modify: `app/Package.swift`
- Create: `app/Shared/Sources/DiagnosticsKit/DiagnosticContext.swift`
- Create: `app/Shared/Sources/DiagnosticsKit/DiagnosticEvent.swift`
- Create: `app/Shared/Tests/DiagnosticsKitTests/DiagnosticEventTests.swift`

- [ ] **Step 1: Add a failing schema test**

Create a fixed context/event and assert schema 1, sorted ISO-8601 encoding, and
the absence of raw path/host fields:

```swift
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
```

- [ ] **Step 2: Register the target and verify RED**

Add `DiagnosticsKit` as a library/test target in `Package.swift`, initially with
an empty source directory, then run:

```bash
cd app
swift test --filter DiagnosticEventTests
```

Expected: compilation fails because the diagnostic schema types do not exist.

- [ ] **Step 3: Implement the context and event schema**

Define `DiagnosticContext` with `child(operationID:)`. Define raw-value Codable
enums for level, category, event name, phase, outcome, persistence, container,
playback state, and stable error codes. Implement a sparse `DiagnosticPayload`
whose only string is `fileID`; environment strings belong to the audited run
manifest, not event payloads. Add `DiagnosticMetricRecord`, containing the same
numeric fields as `PlaybackMetricSnapshot` plus `DiagnosticContext`, so the
telemetry adapter never passes arbitrary labels. `DiagnosticEventEncoder` uses
sorted keys, without-escaped-slashes, and ISO-8601 dates.

Required names include app launch/termination, source restore/add/remove/connect/
disconnect, SMB connect/list/stat/open/read/close, directory list, file open/close,
resource read/request, cache snapshot, playback prepare/ready/play/pause/seek/
stall/recover/end/fail/stop, dropped events, storage limit, and cleared history.

- [ ] **Step 4: Run the focused schema tests**

```bash
cd app
swift test --filter DiagnosticEventTests
```

Expected: PASS.

- [ ] **Step 5: Commit the schema**

```bash
git add app/Package.swift app/Shared/Sources/DiagnosticsKit app/Shared/Tests/DiagnosticsKitTests/DiagnosticEventTests.swift
git commit -m "feat(diagnostics): add typed event schema"
```

### Task 2: Bounded Non-Blocking Emission And Flight Recorder

**Files:**
- Create: `app/Shared/Sources/DiagnosticsKit/DiagnosticRecording.swift`
- Create: `app/Shared/Sources/DiagnosticsKit/DiagnosticFlightRecorder.swift`
- Create: `app/Shared/Tests/DiagnosticsKitTests/DiagnosticRecordingTests.swift`
- Create: `app/Shared/Tests/DiagnosticsKitTests/DiagnosticFlightRecorderTests.swift`

- [ ] **Step 1: Write failing emitter tests**

Test that essential and detailed lanes assign increasing sequence numbers, that a
full detailed lane increments a drop count without blocking, and that
`NoopDiagnosticRecorder` accepts events without retaining them. Use capacities 2
and deterministic events so saturation occurs immediately.

- [ ] **Step 2: Write failing flight-recorder tests**

Use encoded sizes and fixed timestamps to prove both eviction dimensions:

```swift
@Test func flightRecorderEvictsByAgeAndEncodedBytes() {
    var recorder = DiagnosticFlightRecorder(
        maximumAge: .seconds(120),
        maximumEncodedBytes: 100
    )
    recorder.append(firstEvent, encodedByteCount: 60)
    recorder.append(secondEvent, encodedByteCount: 60)
    #expect(recorder.events == [secondEvent])

    recorder.evict(olderThan: secondEvent.wallTime.addingTimeInterval(121))
    #expect(recorder.events.isEmpty)
}
```

- [ ] **Step 3: Run focused tests and verify RED**

```bash
cd app
swift test --filter DiagnosticRecordingTests
swift test --filter DiagnosticFlightRecorderTests
```

Expected: compilation fails for the missing recorder types.

- [ ] **Step 4: Implement the bounded emitter**

`DiagnosticRecording` is synchronous and non-throwing. `DiagnosticEmitter` owns
separate bounded `AsyncStream` lanes, protects sequence/drop counters with
`NSLock`, and reserves essential capacity so detailed pressure cannot consume it.
Expose `essentialEvents`, `detailedEvents`, and `takeDroppedCounts()` only to the
center. Never create a `Task` or perform file I/O in `record(_:)`.

- [ ] **Step 5: Implement the flight recorder**

Use an array plus byte total because the 8-MiB bound is small and deterministic.
Append then remove from the front until both age and byte constraints pass.
Expose `snapshot()` and `removeAll()`; do not encode events inside this type.

- [ ] **Step 6: Run focused tests and commit**

```bash
cd app
swift test --filter DiagnosticRecordingTests
swift test --filter DiagnosticFlightRecorderTests
```

Expected: PASS.

```bash
git add app/Shared/Sources/DiagnosticsKit app/Shared/Tests/DiagnosticsKitTests
git commit -m "feat(diagnostics): add bounded event capture"
```

### Task 3: Rolling JSONL Store And Retention

**Files:**
- Create: `app/Shared/Sources/DiagnosticsKit/DiagnosticStore.swift`
- Create: `app/Shared/Sources/DiagnosticsKit/FileDiagnosticStore.swift`
- Create: `app/Shared/Tests/DiagnosticsKitTests/FileDiagnosticStoreTests.swift`

- [ ] **Step 1: Write failing append/roll tests**

Create a temporary root and inject 100-byte segment/150-byte batch limits. Assert
that starting a run writes mode `0700`/`0600`, appending decodable JSONL rolls to a
second segment, `flush()` makes bytes visible, and `snapshot(runID:)` returns a
stable copy without closing the active run.

- [ ] **Step 2: Write failing retention tests**

Create manifests with fixed dates and byte sizes. Assert cleanup first deletes
runs older than seven days, then oldest closed runs to 100 MB, never deletes the
active run, and returns `.storageLimitReached` when the active run alone exceeds
the cap.

- [ ] **Step 3: Run the store tests and verify RED**

```bash
cd app
swift test --filter FileDiagnosticStoreTests
```

Expected: compilation fails for the missing store.

- [ ] **Step 4: Implement store models and JSONL persistence**

Define `DiagnosticRunEnvironment`, `DiagnosticRunManifest`,
`DiagnosticRunSummary`, `DiagnosticStoreSnapshot`, `DiagnosticRetentionResult`,
and the `DiagnosticStore` protocol. Environment fields are closed enums/numeric
values for app/build, OS, architecture, hardware class, memory pressure, thermal
state, power state, network availability, and interface type. Implement
`FileDiagnosticStore` as an actor with injected root, clock, segment size, batch
size, age limit, and storage limit. Use `FileHandle` append, atomic manifest/index
replacement, backup exclusion, POSIX permissions, and explicit close.

- [ ] **Step 5: Implement cleanup and write degradation**

Compute usage from exact file sizes. Delete expired closed runs, then oldest closed
runs. When only the active run remains over budget, reject detailed appends but
accept essential summary events. Store errors are typed and contain no paths in
their descriptions.

- [ ] **Step 6: Run focused tests and commit**

```bash
cd app
swift test --filter FileDiagnosticStoreTests
```

Expected: PASS.

```bash
git add app/Shared/Sources/DiagnosticsKit app/Shared/Tests/DiagnosticsKitTests/FileDiagnosticStoreTests.swift
git commit -m "feat(diagnostics): persist rolling local logs"
```

### Task 4: Opaque Identity And Privacy Audit

**Files:**
- Modify: `app/Package.swift`
- Create: `app/Shared/Sources/DiagnosticsKit/DiagnosticIdentityProvider.swift`
- Create: `app/Shared/Sources/DiagnosticsKit/DiagnosticPrivacyAudit.swift`
- Create: `app/Shared/Tests/DiagnosticsKitTests/DiagnosticIdentityTests.swift`
- Create: `app/Shared/Tests/DiagnosticsKitTests/DiagnosticPrivacyAuditTests.swift`

- [ ] **Step 1: Write failing identity tests**

Inject a fixed 32-byte key and verify the same length-prefixed source/path/size/
modification tuple produces the same 64-character lowercase HMAC, metadata changes
change the ID, and the output contains no input substring. Inject a failing key
store and verify the fallback returns a per-run UUID with `.transient` stability.

- [ ] **Step 2: Write failing privacy tests**

Encode valid events/manifests and malicious fixtures containing `smb://`, absolute
paths, `username`, `password`, `host`, `share`, and query credentials. Assert each
is rejected with a stable audit code and clean content passes.

- [ ] **Step 3: Run focused tests and verify RED**

```bash
cd app
swift test --filter DiagnosticIdentityTests
swift test --filter DiagnosticPrivacyAuditTests
```

Expected: missing identity/audit types.

- [ ] **Step 4: Implement identity derivation**

Use CryptoKit `HMAC<SHA256>` over a length-prefixed binary encoding. Define an
injectable `DiagnosticIdentityKeyStore`; the production implementation stores a
32-byte key in Keychain under a diagnostics-specific service/account. Link
Security and CryptoKit system frameworks without adding a package dependency.

- [ ] **Step 5: Implement the privacy audit**

Parse JSON with `JSONSerialization`, recursively reject forbidden key names, then
scan string leaves for SMB URLs, absolute POSIX paths, home-directory markers,
and credential-shaped URL authority/query content. Audit operates on export bytes
only and reports stable codes without echoing rejected values.

- [ ] **Step 6: Run tests and commit**

```bash
cd app
swift test --filter DiagnosticIdentityTests
swift test --filter DiagnosticPrivacyAuditTests
```

Expected: PASS.

```bash
git add app/Package.swift app/Shared/Sources/DiagnosticsKit app/Shared/Tests/DiagnosticsKitTests
git commit -m "feat(diagnostics): protect diagnostic identities"
```

### Task 5: Diagnostic Center, Policies, And Incident Capture

**Files:**
- Create: `app/Shared/Sources/DiagnosticsKit/DiagnosticCenter.swift`
- Create: `app/Shared/Sources/DiagnosticsKit/DiagnosticOSLogSink.swift`
- Create: `app/Shared/Tests/DiagnosticsKitTests/DiagnosticCenterTests.swift`
- Create: `app/Shared/Tests/DiagnosticsKitTests/DiagnosticOSLogSinkTests.swift`

- [ ] **Step 1: Write failing policy tests**

With an in-memory fake store and clock, assert Standard persists essential events
and buffers details; Detailed persists both; enabling Detailed expires after 30
minutes; relaunch starts Standard; and store failure changes center status without
throwing through `record(_:)`.

- [ ] **Step 2: Write failing incident tests**

Populate a two-minute flight window, record `.playbackFailed`, and assert the
prelude is persisted once, detailed follow-up lasts 30 seconds, equivalent
incidents within 60 seconds coalesce, and activity end closes capture early.

- [ ] **Step 3: Run tests and verify RED**

```bash
cd app
swift test --filter DiagnosticCenterTests
swift test --filter DiagnosticOSLogSinkTests
```

Expected: missing center types.

- [ ] **Step 4: Implement the OSLog/signpost mirror**

Wrap `Logger` and `OSSignposter` behind an injectable `DiagnosticSystemLogging`
protocol. Mirror essential event names, outcomes, durations, opaque IDs, and
numeric payload values with explicit `.public` privacy because upstream schema
has already excluded identifying strings. Keep interval states keyed by operation
ID under a lock; an end without a matching begin becomes an instant warning. Unit
tests use a recording fake and assert no payload field can supply a raw path.

- [ ] **Step 5: Implement `DiagnosticCenter`**

The actor owns an emitter, store, encoder, flight recorder, policy deadline,
incident windows, and an `AsyncStream<DiagnosticStatusSnapshot>`. `start()` begins
one drain task per emitter lane, opens the run, performs retention, and publishes
status. `stop()` drains, flushes, closes the run, and finishes status streams.

Route essential/detailed events according to policy. Every detailed event enters
the flight recorder. Trigger events persist a deduplicated prelude and follow-up.
Consume emitter drop counters into one essential `.eventsDropped` event without
feeding it back through the emitter. Mirror eligible operations to the injected
system logger/signposter after policy filtering and before disk persistence.

- [ ] **Step 6: Run tests and commit**

```bash
cd app
swift test --filter DiagnosticCenterTests
swift test --filter DiagnosticOSLogSinkTests
```

Expected: PASS.

```bash
git add app/Shared/Sources/DiagnosticsKit app/Shared/Tests/DiagnosticsKitTests/DiagnosticCenterTests.swift app/Shared/Tests/DiagnosticsKitTests/DiagnosticOSLogSinkTests.swift
git commit -m "feat(diagnostics): coordinate local capture policies"
```

### Task 6: Diagnostic Bundle And Report Tool

**Files:**
- Modify: `app/Package.swift`
- Create: `app/Shared/Sources/DiagnosticsKit/DiagnosticBundle.swift`
- Create: `app/Tools/DiagnosticsReport/main.swift`
- Create: `app/Shared/Tests/DiagnosticsKitTests/DiagnosticBundleTests.swift`

- [ ] **Step 1: Write failing bundle tests**

Build a fixed store snapshot and assert export creates manifest, events, metrics,
summary, and integrity entries; hashes match; privacy audit runs before final move;
and cancellation/error removes the temporary package without changing source logs.

- [ ] **Step 2: Register the executable and verify RED**

Add a `DiagnosticsReport` executable product/target depending on DiagnosticsKit.
Run:

```bash
cd app
swift test --filter DiagnosticBundleTests
swift run DiagnosticsReport --help
```

Expected: tests fail and the tool cannot build before bundle APIs exist.

- [ ] **Step 3: Implement bundle generation and parsing**

Use `FileWrapper(directoryWithFileWrappers:)` for `.pierdiag`. Generate a stable
summary with activity outcomes, errors, stalls, durations, bytes, cache ratios,
dropped events, and unmatched open operations. Hash all non-integrity entries with
SHA-256, audit every JSON/JSONL entry, and atomically move the completed package.

- [ ] **Step 4: Implement CLI arguments and output**

Support `<bundle>`, `--validate`, `--timeline`, `--generate-fixture <path>`, and
`--help`. Validation exits 0
only for valid schema, hashes, and privacy. Default output prints counts/errors/
slow operations/unclosed resources; timeline sorts by sequence. Invalid input
goes to standard error with exit code 2 and never prints rejected values.
Fixture generation creates one deterministic, privacy-safe incident bundle for
repository checks and never reads local diagnostics history.

- [ ] **Step 5: Run tests and CLI smoke check**

```bash
cd app
swift test --filter DiagnosticBundleTests
swift run DiagnosticsReport --help
```

Expected: PASS and usage text lists bundle summary, validation, timeline, and
fixture-generation forms.

- [ ] **Step 6: Commit bundle support**

```bash
git add app/Package.swift app/Shared/Sources/DiagnosticsKit app/Shared/Tests/DiagnosticsKitTests/DiagnosticBundleTests.swift app/Tools/DiagnosticsReport/main.swift
git commit -m "feat(diagnostics): export validated support bundles"
```

### Task 7: Instrument SMB And Stream Access

**Files:**
- Modify: `app/Package.swift`
- Modify: `app/Shared/Sources/SMBSourceKit/LibSMB2Client.swift`
- Modify: `app/Shared/Sources/SMBSourceKit/LibSMB2File.swift`
- Modify: `app/Shared/Sources/SMBSourceKit/SMBMediaSource.swift`
- Modify: `app/Shared/Sources/StreamIOKit/CachedMediaReader.swift`
- Modify: `app/Shared/Tests/SMBSourceKitTests/SMBMediaSourceTests.swift`
- Modify: `app/Shared/Tests/SMBSourceKitTests/LibSMB2ValidationTests.swift`
- Modify: `app/Shared/Tests/StreamIOKitTests/CachedMediaReaderTests.swift`

- [ ] **Step 1: Add failing correlated SMB tests**

Inject a `RecordingDiagnosticRecorder` and fixed context. Verify connect/list/open/
read/close success and mapped failures emit begin/end pairs with source/file opaque
IDs, lengths, outcomes, and no path-bearing payload. Assert repeated close emits
one close operation.

- [ ] **Step 2: Add failing stream tests**

Verify a cache hit emits no upstream-read event, a miss emits one parent logical
range and one child upstream read, short reads map to
`.streamUnexpectedShortRead`, cancellation maps to `.cancelled`, and a snapshot
contains hit/miss/upstream byte totals.

- [ ] **Step 3: Run focused tests and verify RED**

```bash
cd app
swift test --filter SMBMediaSourceTests
swift test --filter LibSMB2ValidationTests
swift test --filter CachedMediaReaderTests
```

Expected: initializer/API assertions fail before instrumentation exists.

- [ ] **Step 4: Add recorder dependencies and instrumentation**

Make `SMBSourceKit` and `StreamIOKit` depend on DiagnosticsKit. Add recorder/context
parameters with no-op defaults to preserve external callers. Measure with
`ContinuousClock`, map existing typed errors to diagnostic codes, and emit only
the allow-listed payload. Propagate file context into `SMBReadableFile` and
`LibSMB2File`; guard close evidence with the existing idempotent lifecycle.

- [ ] **Step 5: Run focused and module tests**

```bash
cd app
swift test --filter SMBSourceKitTests
swift test --filter StreamIOKitTests
```

Expected: PASS.

- [ ] **Step 6: Commit resource instrumentation**

```bash
git add app/Package.swift app/Shared/Sources/SMBSourceKit app/Shared/Sources/StreamIOKit app/Shared/Tests/SMBSourceKitTests app/Shared/Tests/StreamIOKitTests
git commit -m "feat(diagnostics): trace SMB and stream access"
```

### Task 8: Instrument Playback And Replace Temporary Restore Log

**Files:**
- Modify: `app/Package.swift`
- Modify: `app/Shared/Sources/PlaybackCore/PlaybackSession.swift`
- Create: `app/Shared/Sources/PlaybackTelemetry/PlaybackDiagnosticAdapter.swift`
- Modify: `app/macOS/Sources/PierPlayerApp/AppModel.swift`
- Modify: `app/macOS/Sources/PierPlayerApp/SourceBrowserView.swift`
- Modify: `app/macOS/Sources/PierPlayerApp/ProgressiveMediaLoader.swift`
- Modify: `app/macOS/Sources/PierPlayerApp/ProgressivePlaybackSession.swift`
- Modify: `app/Shared/Tests/PlaybackCoreTests/PlaybackSessionTests.swift`
- Create: `app/Shared/Tests/PlaybackTelemetryTests/PlaybackDiagnosticAdapterTests.swift`
- Modify: `app/macOS/Tests/PierPlayerAppTests/VideoPlayerModelTests.swift`
- Modify: `app/macOS/Tests/PierPlayerAppTests/ProgressiveMediaLoaderTests.swift`
- Modify: `app/macOS/Tests/PierPlayerAppTests/ProgressivePlaybackSessionTests.swift`

- [ ] **Step 1: Add failing playback-state tests**

Inject a recorder into `PlaybackSession`. Assert accepted transitions emit typed
old/new state and generation; rejected transitions emit a warning without raw
command strings; expected stop/cancellation is not a failure.

- [ ] **Step 2: Add failing AVFoundation/session tests**

Verify one playback activity contains file-open, resource-request parent, chunk
read children, play/stop, and file-close. Add deterministic player-state adapter
tests for ready, waiting longer than three seconds, three stalls in 60 seconds,
ended, and failed. Verify each loading request finishes or cancels once.

- [ ] **Step 3: Add failing restore privacy test**

Point temporary-directory access at a test directory, run source restoration, and
assert no `pier_restore.log` is created. Assert typed restore/connect events contain
no stored username, source display name, host, share, or path.

- [ ] **Step 4: Run focused tests and verify RED**

```bash
cd app
swift test --filter PlaybackSessionTests
swift test --filter VideoPlayerModelTests
swift test --filter ProgressiveMediaLoaderTests
swift test --filter ProgressivePlaybackSessionTests
```

Expected: instrumentation assertions fail and the temporary restore log test fails.

- [ ] **Step 5: Implement playback instrumentation**

Add DiagnosticsKit to PlaybackCore and PierPlayerApp dependencies. Inject recorder/
context with no-op defaults. Store one playback activity context in
`VideoPlayerModel`; pass it through the opened file, progressive loader, resource
loader, and playback session. Observe `AVPlayerItem.status`,
`AVPlayer.timeControlStatus`, and end/failure notifications with explicit token
ownership and teardown. Use monotonic timers for stall thresholds.

- [ ] **Step 6: Replace restore logging**

Delete the `pier_restore.log` closure from `AppModel`. Wrap load/restore/connect in
typed diagnostic operations, map errors to stable codes, and never place stored
configuration strings in payloads.

- [ ] **Step 7: Adapt existing performance snapshots**

Make `PlaybackTelemetry` depend on DiagnosticsKit and add
`PlaybackDiagnosticAdapter`. It converts every numeric
`PlaybackMetricSnapshot` field into the closed `DiagnosticMetricRecord` schema
with the playback activity ID; no environment label or media identifier string is
copied. Add tests proving all numeric fields and context survive conversion and
the encoded metric contains no host/path/name keys.

- [ ] **Step 8: Run focused tests and commit**

```bash
cd app
swift test --filter PlaybackCoreTests
swift test --filter PlaybackTelemetryTests
swift test --filter PierPlayerAppTests
```

Expected: PASS.

```bash
git add app/Package.swift app/Shared/Sources/PlaybackCore app/Shared/Sources/PlaybackTelemetry app/macOS/Sources/PierPlayerApp app/Shared/Tests/PlaybackCoreTests app/Shared/Tests/PlaybackTelemetryTests app/macOS/Tests/PierPlayerAppTests
git commit -m "feat(diagnostics): trace playback lifecycle"
```

### Task 9: Compose Runtime And Add Diagnostics Settings

**Files:**
- Modify: `app/macOS/Sources/PierPlayerApp/PierPlayerApp.swift`
- Modify: `app/macOS/Sources/PierPlayerApp/AppModel.swift`
- Create: `app/macOS/Sources/PierPlayerApp/DiagnosticEnvironmentMonitor.swift`
- Create: `app/macOS/Sources/PierPlayerApp/DiagnosticsViewModel.swift`
- Create: `app/macOS/Sources/PierPlayerApp/DiagnosticsSettingsView.swift`
- Modify: `app/macOS/Tests/PierPlayerAppTests/UIRenderingTests.swift`
- Create: `app/macOS/Tests/PierPlayerAppTests/DiagnosticsViewModelTests.swift`
- Create: `app/macOS/Tests/PierPlayerAppTests/DiagnosticEnvironmentMonitorTests.swift`

- [ ] **Step 1: Write failing view-model tests**

With a fake center client, verify status stream updates mode/remaining time/usage/
recent runs/warnings, toggling Detailed invokes a 30-minute request, clear deletes
only closed runs, and export passes selected run IDs to the save operation.

- [ ] **Step 2: Write failing rendering tests**

Offscreen-render Settings at 520x560 for empty Standard, active Detailed, incident,
and storage-warning states. Assert semantic labels for Detailed Diagnostics,
storage usage, recent sessions, Export, Reveal in Finder, and Clear History; run
pixel non-blank and clipping checks using the existing rendering helpers.

- [ ] **Step 3: Run focused tests and verify RED**

```bash
cd app
swift test --filter DiagnosticsViewModelTests
swift test --filter diagnosticsSettings
```

Expected: missing view/view-model types.

- [ ] **Step 4: Implement runtime composition**

Create `DiagnosticCenter`, file store, and identity provider once in the App
initializer. Inject the recorder into `AppModel`, start the center before restore,
and stop/flush from the app lifecycle. Add a SwiftUI `Settings` scene sharing the
same center and model.

- [ ] **Step 5: Implement privacy-safe environment monitoring**

Build the initial `DiagnosticRunEnvironment` from Bundle, ProcessInfo, Sysctl,
thermal/power state, and architecture. Observe NSWorkspace sleep/wake and an
injected Network-path adapter that exposes only available/unavailable and
ethernet/Wi-Fi/cellular/other. Emit typed changes; never read SSID, IP, DNS, peer,
or interface addresses. Tests drive fake sleep/wake/path inputs and assert the
exact closed-enum events.

- [ ] **Step 6: Implement the Settings UI**

Use one unframed settings layout: mode/status header, native Toggle, usage ProgressView,
single recent-session List, and icon/text command row. Use `square.and.arrow.up`,
`folder`, and `trash` system icons with tooltips/accessibility labels. Present
`fileExporter` for `.pierdiag` and confirmation before clearing. Do not display
host/source/file names or put cards inside cards.

- [ ] **Step 7: Run focused tests and commit**

```bash
cd app
swift test --filter DiagnosticsViewModelTests
swift test --filter DiagnosticEnvironmentMonitorTests
swift test --filter UIRenderingTests
```

Expected: PASS with nonblank unclipped Settings snapshots.

```bash
git add app/macOS/Sources/PierPlayerApp app/macOS/Tests/PierPlayerAppTests
git commit -m "feat(macOS): add local diagnostics settings"
```

### Task 10: Performance, Full Verification, And Documentation Alignment

**Files:**
- Create: `app/Shared/Tests/DiagnosticsKitTests/DiagnosticPerformanceTests.swift`
- Modify: `README.md`
- Modify: `app/scripts/check.sh`

- [ ] **Step 1: Add deterministic bounds/performance tests**

Emit 100,000 detailed events in Release through a saturated emitter, assert no
caller waits for file I/O, essential capacity remains available, dropped counts
are exact, and the flight recorder encoded bytes never exceed 8 MiB. Record P95
emission latency with `ContinuousClock` and assert it stays below 100 microseconds
on the reference Mac.

Run the performance test explicitly in Release:

```bash
cd app
swift test -c release --filter DiagnosticPerformanceTests
```

Expected: PASS with the measured P95 and maximum byte count printed as test
attachments or test diagnostics.

- [ ] **Step 2: Add repository gate checks**

Extend `scripts/check.sh` to call
`DiagnosticsReport --generate-fixture <temporary-path>`, run
`DiagnosticsReport --validate`, and scan generated JSON/JSONL for forbidden keys
and SMB/path fixtures. Keep the gate independent of real NAS credentials and
remove the temporary fixture through the script's existing trap-based cleanup.

- [ ] **Step 3: Update README diagnostics usage**

Document the Settings controls, 7-day/100-MB retention, 30-minute Detailed mode,
automatic two-minute incident prelude, export format, report command, and strict
exclusions. State that logs remain local until explicit export.

- [ ] **Step 4: Run the complete gate**

```bash
cd app
swift test
swift build -c release
swift run DiagnosticsReport --help
scripts/check.sh
```

Expected: all tests pass, Release build succeeds, generated bundle validates, and
whitespace/privacy/license/hash checks pass.

- [ ] **Step 5: Run static and Git checks**

```bash
git diff --check
git status --short
git log --oneline --decorate -12
```

Expected: only scoped diagnostics implementation/documentation changes remain and
there is no `.vscode/`, media, credential, generated bundle, or build output.

- [ ] **Step 6: Record Release matrix evidence**

Run the fixed local fixture baseline with diagnostics Standard and Detailed. Record
throughput, first-frame, seek, P95 emission latency, and peak resident memory in
the implementation summary. Standard must regress no more than 2%, Detailed no
more than 5%, and incremental diagnostics memory must remain at or below 12 MiB.

- [ ] **Step 7: Commit final verification changes**

```bash
git add README.md app/scripts/check.sh app/Shared/Tests/DiagnosticsKitTests/DiagnosticPerformanceTests.swift
git commit -m "test(diagnostics): enforce local logging bounds"
```

## Final Review Checklist

- [ ] Every resource/playback event uses an activity and operation context.
- [ ] No persisted/exported schema field can accept a raw path or unrestricted
      debug string.
- [ ] Standard, Detailed, and Incident policies have deterministic tests.
- [ ] Store, queue, ring, retry, incident, and retention limits are explicit.
- [ ] Expected cancellations are distinct from failures.
- [ ] File/read/player teardown remains idempotent and observable.
- [ ] Diagnostics failure cannot change source or playback outcomes.
- [ ] `.pierdiag` validation covers schema, integrity, and privacy.
- [ ] Settings UI is accessible, unclipped, and never reveals source/media names.
- [ ] Full test, Release, repository gate, and performance evidence is current.
