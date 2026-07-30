# Local Diagnostics Toolkit Design

**Date:** 2026-07-30
**Status:** Approved for implementation by user direction

## Purpose

Pier Player needs enough local evidence to reconstruct resource-access and
playback failures without attaching a debugger before the failure occurs. The
current `PlaybackTelemetry` target can encode performance snapshots, but it does
not collect behavior events or persist them. `AppModel.restore()` also writes an
ad hoc temporary log that overwrites earlier lines and includes identifying
values. It is not a suitable diagnostic boundary.

This design adds a reusable `DiagnosticsKit` module and applies it to source
restore, SMB access, stream reads, AVFoundation resource loading, playback state,
and resource teardown. Diagnostics remain local until the user explicitly
exports a privacy-checked bundle.

## Goals

- Preserve a correlated timeline across user intent, resource access, and
  playback.
- Keep lightweight diagnostics enabled by default.
- Capture the two minutes preceding an important failure even when detailed
  diagnostics were not enabled beforehand.
- Provide bounded retention, in-app controls, deterministic export, and a
  developer-readable report tool.
- Keep passwords, hosts, shares, usernames, source names, file names, and paths
  out of persisted and exported records.
- Make event recording non-blocking and non-fatal to playback behavior.

## Non-Goals

- Automated replay of user actions or network requests.
- Recording media bytes, decoded samples, screenshots, or packet payloads.
- Uploading diagnostics or integrating a remote observability service.
- Replacing Instruments, MetricKit, crash reporting, or the existing
  performance-report schema.
- Extending the unsupported container or playback-engine set.

## Approaches Considered

### Dedicated DiagnosticsKit Module (Selected)

Add a neutral module for typed events, correlation, privacy, buffering, local
storage, retention, and export. Source, stream, telemetry, and player modules
report through an injected protocol. This preserves module ownership and lets
future iOS, tvOS, FFmpeg, and VideoToolbox code use the same boundary.

### Extend PlaybackTelemetry Directly

This is initially smaller, but it makes resource browsing and SMB transport
depend on a playback-named module and mixes behavior history with sampled
performance data.

### Apple Unified Logging Only

`Logger` and `os_signpost` remain useful sinks, but they cannot implement the
product's deterministic retention, recent-session UI, or versioned diagnostic
bundle by themselves.

## Architecture

```text
macOS composition root
  -> DiagnosticCenter actor
       -> standard/detailed/incident policy
       -> two-minute bounded flight recorder
       -> rolling JSONL store
       -> Logger and os_signpost sink
       -> summaries and export

SMBSourceKit ---------+
StreamIOKit ----------+-> DiagnosticRecording
PlaybackCore ---------+
PlaybackTelemetry ----+
macOS AVFoundation ---+
```

`DiagnosticsKit` depends only on Apple system frameworks. It does not import SMB,
AVFoundation, SwiftUI, or concrete playback modules. Its public boundaries are:

- `DiagnosticRecording`: synchronous, non-throwing event emission.
- `DiagnosticCenter`: actor that owns policy, routing, storage, and lifecycle.
- `DiagnosticContext`: app-run, activity, operation, and parent-operation IDs.
- `DiagnosticEvent`: stable envelope with a typed, privacy-reviewed payload.
- `DiagnosticStore`: append, query, retention, and snapshot protocol.
- `DiagnosticIdentityProvider`: opaque source and file identity derivation.
- `NoopDiagnosticRecorder`: disabled, preview, and focused-test implementation.

The app creates one `DiagnosticCenter` and injects its recorder into participating
components. There is no global mutable logger. A session or resource loader owns
its `DiagnosticContext` explicitly because AVFoundation delegate queues cannot
reliably inherit task-local state.

`PlaybackTelemetry` remains responsible for one-second performance snapshots and
session aggregates. It adopts the shared context IDs, and export combines metrics
with the behavior timeline without changing `PlaybackSessionReport` schema 1.

## Event Envelope

Every encoded event contains:

```text
schemaVersion
sequence
wallTime
monotonicNanoseconds
level
category
eventName
appRunID
activityID
operationID
parentOperationID
phase
outcome
durationMilliseconds
payload
```

Durations use `ContinuousClock`; wall time is presentation metadata only. Begin
and end events share an operation ID. An unmatched begin event therefore remains
useful evidence after a crash or forced termination.

Event names and payloads are declared types with explicit encoders. Arbitrary
attribute dictionaries and free-form messages are not accepted. Error payloads
contain a stable domain/code, cancellation and retryability flags, and an optional
numeric native code. They never encode `String(describing:)`, localized native
text, native pointers, or raw FFmpeg/libsmb2 messages.

`withDiagnosticOperation` creates a child context and emits begin, success,
cancellation, or mapped failure with a duration. Recording failures never replace
or mask the operation's original result.

## Correlation Model

- `appRunID` changes at launch and correlates app lifecycle evidence.
- `activityID` groups one source restoration, scan, browser load, or playback.
- `operationID` identifies one connect, list, open, range, read, seek, or close.
- `parentOperationID` connects nested work, such as an AVFoundation range to its
  chunked SMB reads.
- The existing playback session ID and generation are safe typed payload values.
  Superseded generation results are recorded as discarded rather than failures.

## Events

### App And User Intent

- App launch, normal termination, sleep, wake, and diagnostic-mode changes.
- Source restore, add, remove, browser refresh, directory selection, media
  selection, playback dismissal, and explicit playback commands.
- These are domain actions, not a record of every pointer or keyboard event.

### Resource And SMB Access

- Connect, disconnect, list, stat, open, close, and stable failure codes.
- Directory results record entry counts and duration, not entry names or paths.
- File open records opaque file ID, an allow-listed container kind, exact byte
  size, and modification-presence, but not the modification timestamp. Unknown
  or malformed extensions map to `other` rather than becoming log strings.
- Reads record offset, requested/actual length, duration, EOF, cancellation, and
  mapped numeric error information.

### Stream And Cache

- Logical range begins/ends, page-cache hit/miss aggregates, upstream reads,
  request coalescing, short reads, EOF, cache clears, and resident-byte samples.
- Standard mode persists one-second aggregates and anomalies. Detailed and
  in-memory modes retain individual ranges and upstream reads.

### Playback

- Prepare, resource request, ready, play, pause, seek, wait/stall, recovery,
  ended, failure, stop, and teardown.
- AVPlayer item status, time-control status, waiting reason category, and loading
  request completion are mapped to stable values.
- First byte, ready-to-play, and first observed playback progress are intervals.
- Future FFmpeg and VideoToolbox integrations add probe, demux, decode, enqueue,
  first-frame, and renderer events through the same API.

### Environment

- App version/build, event schema, OS version, hardware model class, process
  architecture, memory pressure class, power/thermal state, network availability,
  and interface type.
- Network SSID, IP address, interface address, DNS data, and peer identity are not
  collected.

## Privacy And Identity

Persisted records prohibit:

- credentials, domains, usernames, hosts, shares, source display names;
- media names, directory names, paths, SMB URLs, and query strings;
- media bytes, native pointers, and unrestricted error/debug strings.

The stable source UUID is already opaque. File IDs use HMAC-SHA256 over a
length-prefixed canonical encoding of source UUID, normalized path, size, and
modification value with a per-install random key stored in Keychain. Only the HMAC
output is emitted. If the key is unavailable, the app uses a per-run random ID and
marks identity stability as `transient`; it never falls back to persisting the
path.

An export privacy audit rejects forbidden keys and scans string values for SMB
URLs, absolute paths, and credential-shaped content. Rejection is visible in the
diagnostics UI and never produces a partially exported bundle.

The existing `pier_restore.log` path and logging closure are removed. Source
restoration reports typed events through `DiagnosticsKit` instead.

## Recording Policy

Three policies share the same event model:

### Standard

Enabled by default. Persist app lifecycle, important actions, state transitions,
operation summaries, warnings, errors, and one-second metric aggregates. Detailed
events also enter the in-memory flight recorder but do not normally reach disk.

### Detailed

Enabled by the user for 30 minutes and reset to Standard at the next launch. All
privacy-safe detailed events and metric snapshots are persisted. The user can
stop it early. The remaining time is visible in Settings.

### Incident Capture

The flight recorder retains the latest two minutes and at most 8 MiB of encoded
events, whichever limit is reached first. A trigger freezes and persists that
prelude, then captures up to 30 seconds of follow-up activity or until the activity
ends.

Incident triggers are:

- playback failure;
- SMB interruption or exhausted recovery;
- unexpected EOF, short read, or changed remote identity;
- one wait/stall longer than three seconds, or three stalls within 60 seconds;
- event loss or failure to close a required resource.

Equivalent incidents within one activity and 60-second window are coalesced.

## Hot-Path And Failure Rules

`DiagnosticRecording.record(_:)` is synchronous, non-throwing, and never performs
disk I/O. A bounded emitter hands records to the center's drain task. When pressure
exceeds capacity it drops detailed events before essential events and later emits
one `diagnostics.events_dropped` summary. Critical failures are also mirrored to
OSLog.

Storage and export errors cannot fail source access or playback. If disk writes
fail, the center disables the disk sink for the run, retains the bounded in-memory
buffer, keeps critical OSLog output, and exposes a warning in Settings. It attempts
one cleanup and reopen for a full-volume error; it does not retry indefinitely or
log recursively.

## Local Storage And Retention

```text
Application Support/Pier Player/Diagnostics/v1/
  index.json
  runs/<appRunID>/
    manifest.json
    events-0001.jsonl
    metrics-0001.jsonl
```

The store appends batches every second or at 64 KiB, whichever comes first. It
flushes critical events, sleep/background transitions, and normal termination.
Files roll at 5 MiB. The directory uses mode `0700`, files use `0600`, and the tree
is excluded from system backup.

Retention deletes closed runs older than seven days, then deletes the oldest
closed runs until total storage is at or below 100 MB. The active run is never
deleted. If the active run alone reaches the limit, recording falls back to
standard summaries and emits `diagnostics.storage_limit_reached`. Cleanup runs at
launch, file roll, and after export, never for every event.

## Diagnostic Export

The user exports selected runs or incidents as a `.pierdiag` file package:

```text
manifest.json
events.jsonl
metrics.jsonl
summary.json
integrity.json
```

The manifest contains schema versions, app/build, privacy-safe environment data,
collection window, policy, opaque IDs, and dropped-event counts. Summary data
includes outcomes, error codes, stalls, operation latency distributions, bytes,
cache ratios, and resource-close status. `integrity.json` contains SHA-256 digests
for the other entries.

Export first flushes and snapshots the selected run under the store actor, then
performs the privacy audit and writes through `FileWrapper`. A failed or cancelled
export removes its temporary package and leaves source logs unchanged.

Add a `DiagnosticsReport` executable target:

```text
swift run DiagnosticsReport <bundle.pierdiag>
swift run DiagnosticsReport <bundle.pierdiag> --timeline
swift run DiagnosticsReport <bundle.pierdiag> --validate
```

It validates schema/integrity/privacy and prints a compact activity timeline,
errors, stalls, slow operations, dropped events, and unclosed resources. It never
needs SMB credentials or media access.

## macOS Diagnostics UI

Add a native SwiftUI `Settings` scene with a Diagnostics view. It presents:

- current Standard, Detailed, or Incident state;
- a Detailed Diagnostics toggle with remaining time;
- current disk usage and the seven-day/100-MB limits;
- recent runs and incidents with time, activity type, outcome, duration, container,
  size, and event count, but no file/source names;
- Export, Reveal in Finder, and Clear actions;
- persistent warnings for storage or privacy-audit failures.

Export uses the standard save panel. Clear requires destructive confirmation,
cancels no active playback, and deletes only closed runs. The current run remains
and receives a `diagnostics.user_cleared_history` event. UI state comes from an
async summary stream exposed by `DiagnosticCenter`; views do not read files
directly.

## Integration Boundaries

- `AppModel` records source restore/add/remove and receives one recorder.
- `SMBMediaSource`, `LibSMB2Client`, and readable files record connect/list/open,
  native access, read, disconnect, and close boundaries.
- `CachedMediaReader` records logical reads and publishes aggregate cache metrics;
  `PageCache` remains unaware of diagnostics.
- `PlaybackSession` records accepted and rejected transitions using typed states.
- `ProgressiveMediaResourceLoader` owns AVFoundation request contexts and records
  finish/cancel exactly once.
- `ProgressivePlaybackSession` observes player-item/time-control state and owns
  playback teardown evidence.
- The macOS composition root creates the center, injects it, starts retention, and
  adds the Settings scene.

## Testing

### DiagnosticsKit Unit Tests

- Stable schema-1 JSONL encoding and decoding.
- Parent/child correlation and begin/end duration behavior.
- Standard, Detailed, and Incident routing policies.
- Two-minute and 8-MiB flight-recorder eviction.
- Trigger coalescing and 30-second follow-up capture.
- File rolling, seven-day expiry, 100-MB cleanup, and active-run protection.
- Disk-full degradation and non-recursive error handling.
- HMAC stability, transient fallback, forbidden-field rejection, and failed-export
  cleanup.
- Bundle integrity and `DiagnosticsReport` validation.

### Integration Tests

- Source restore/connect/list/open/read/close success, cancellation, and failure
  produce one correlated sequence with no raw identifiers.
- Multi-chunk AVFoundation ranges preserve parent operations and bounded reads.
- Player status, stalls, seek replacement, dismissal, and teardown produce stable
  outcomes without treating expected cancellation as failure.
- Existing telemetry snapshots share playback context IDs.
- Settings rendering covers empty, recording, incident, storage-warning, export,
  and destructive-confirmation states.

### Performance And Safety

- Emission performs no synchronous file access and has Release-build P95 call-site
  latency below 100 microseconds on the reference Mac.
- The encoded flight recorder is at most 8 MiB and incremental resident memory is
  at most 12 MiB.
- Standard diagnostics regress fixed-matrix playback throughput, first-frame, and
  seek metrics by no more than two percent. Detailed mode may regress them by no
  more than five percent.
- Storage remains at or below 100 MB plus one pending 64-KiB batch.
- Diagnostics failures do not alter source, read, playback, cancellation, or close
  results.

## Verification

Follow red-green-refactor with focused target tests. Final verification runs:

```bash
cd app
swift test
swift build -c release
swift run DiagnosticsReport <generated-fixture.pierdiag> --validate
scripts/check.sh
git diff --check
```

Playback hot-path integration also requires the repository's fixed Release media
and network matrix, reporting standard/detailed overhead separately. Raw exported
fixtures are generated and contain no real NAS identifiers or copyrighted media.

## Acceptance Criteria

1. A source-to-playback activity can be reconstructed by correlation IDs from one
   locally persisted timeline.
2. Standard mode persists important events while keeping detailed evidence for the
   latest two minutes in bounded memory.
3. Defined failures automatically persist the pre-failure window without prior
   user action.
4. Settings can start/stop detailed capture, show usage and recent runs, export a
   selected diagnostic package, and clear closed history.
5. Exported packages pass integrity and privacy validation and contain none of the
   prohibited identity fields or media content.
6. Storage, memory, event queue, retry, and capture windows remain bounded.
7. Logging/storage/export failures never change playback behavior.
8. Focused tests, the full Swift suite, Release build, repository gate, privacy
   fixtures, and performance budgets pass.
