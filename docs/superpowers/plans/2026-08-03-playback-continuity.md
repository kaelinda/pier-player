# Playback Continuity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Continue Watching, Recently Played, watched state, offline played history,
and complete lifecycle persistence on top of the existing opaque synced progress.

**Architecture:** Keep privacy-safe progress in CloudSyncKit and add a macOS-only,
device-local played-history store. A pure presentation layer joins scan items, history,
configured-source availability, and progress before SwiftUI renders continuity shelves.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing, actors, atomic JSON persistence,
CloudKit-backed CloudSyncKit.

---

### Task 1: Progress Rewatch Semantics And Source Cleanup

**Files:**
- Modify: `app/Shared/Sources/CloudSyncKit/PlaybackProgressManager.swift`
- Modify: `app/Shared/Sources/CloudSyncKit/PlaybackProgressStore.swift`
- Test: `app/Shared/Tests/CloudSyncKitTests/PlaybackProgressManagerTests.swift`
- Test: `app/Shared/Tests/CloudSyncKitTests/PlaybackProgressStoreTests.swift`

- [ ] Write a failing manager test proving a completed record remains completed below
  five seconds and becomes incomplete after the new viewing reaches five seconds.
- [ ] Run `swift test --filter PlaybackProgressManagerTests` and verify the new test fails.
- [ ] Merge the prior completion flag into new records below five seconds; otherwise use
  the existing 95% calculation.
- [ ] Add `removeAll(sourceID:)` to `PlaybackProgressManaging` and its manager.
- [ ] Write and pass a focused source-removal manager test.
- [ ] Run both CloudSyncKit progress test files and commit.

### Task 2: Device-Local Played History

**Files:**
- Create: `app/macOS/Sources/PierPlayerApp/PlaybackHistoryStore.swift`
- Create: `app/macOS/Tests/PierPlayerAppTests/PlaybackHistoryStoreTests.swift`

- [ ] Write failing tests for atomic round-trip, newest-first ordering, corrupt-file
  isolation, same-source/path replacement, and source cleanup.
- [ ] Run `swift test --filter PlaybackHistoryStoreTests` and verify failures are caused
  by the missing production types.
- [ ] Implement `PlaybackHistoryEntry`, `PlaybackHistoryStoring`, and actor-backed
  `PlaybackHistoryStore` with an injectable file URL for tests.
- [ ] Ensure encoded JSON contains local path metadata but no credential, host, share,
  or domain fields.
- [ ] Run the focused suite and commit.

### Task 3: Continuity Projection

**Files:**
- Modify: `app/macOS/Sources/PierPlayerApp/MediaLibraryPresentation.swift`
- Test: `app/macOS/Tests/PierPlayerAppTests/MediaLibraryPresentationTests.swift`

- [ ] Write failing tests that construct scanned media, history, progress, and source
  availability fixtures.
- [ ] Cover Continue Watching filtering/order/limit, Recently Played deduplication,
  completion, clamped ratios, replacement identity, unavailable history, and stable ties.
- [ ] Run the focused tests and verify RED.
- [ ] Implement immutable continuity item/snapshot projection types and pure functions.
- [ ] Run focused tests and commit.

### Task 4: Player History And Lifecycle Capture

**Files:**
- Modify: `app/macOS/Sources/PierPlayerApp/VideoPlayerModel.swift`
- Modify: `app/macOS/Sources/PierPlayerApp/VideoPlayerSheet.swift`
- Test: `app/macOS/Tests/PierPlayerAppTests/VideoPlayerModelTests.swift`

- [ ] Write failing tests for history after successful start, no history after failed
  open, forced saves after seek/failure/inactivity, and idempotent close/end behavior.
- [ ] Run `swift test --filter VideoPlayerModelTests` and verify RED.
- [ ] Inject `PlaybackHistoryStoring`, record only after coordinator start succeeds, and
  expose a force-persist lifecycle method.
- [ ] Force-save after successful seek and terminal failure; keep invalid-duration cases
  as no-ops.
- [ ] Run focused tests and commit.

### Task 5: Application Ownership And Cleanup

**Files:**
- Modify: `app/macOS/Sources/PierPlayerApp/AppModel.swift`
- Modify: `app/macOS/Sources/PierPlayerApp/PierPlayerApp.swift`
- Modify: `app/macOS/Tests/PierPlayerAppTests/SourceManagementTests.swift`
- Modify: `app/macOS/Tests/PierPlayerAppTests/ApplicationActivationTests.swift`

- [ ] Write failing tests that explicit source removal clears progress and local history.
- [ ] Add one app-owned history store and pass it through playback dependencies.
- [ ] Publish a continuity revision after sync, source changes, and player dismissal.
- [ ] Wire scene inactivity and termination to an active-player force flush without
  blocking normal diagnostics cleanup indefinitely.
- [ ] Run focused tests and commit.

### Task 6: Media Library UI

**Files:**
- Modify: `app/macOS/Sources/PierPlayerApp/MediaLibraryView.swift`
- Modify: `app/macOS/Tests/PierPlayerAppTests/UIRenderingTests.swift`

- [ ] Write failing rendering/presentation tests for conditional Continue Watching and
  Recently Played shelves, progress, Watched, and Unavailable labels.
- [ ] Add stable fixed-format card geometry and accessibility values.
- [ ] Route available items to playback and unavailable items to source reconnect.
- [ ] Refresh continuity after player dismissal without restarting an active scan.
- [ ] Render 820x560 and 1120x720 fixtures in light and dark appearances.
- [ ] Run focused UI tests and commit.

### Task 7: Integration And Verification

**Files:**
- Modify: `README.md`
- Modify: `docs/product-roadmap.md`

- [ ] Update shipped playback, subtitle, credential, and continuity claims.
- [ ] Mark only verified roadmap checkboxes complete.
- [ ] Run focused suites for CloudSyncKit, history, presentation, player, source removal,
  activation, and UI rendering.
- [ ] Run `scripts/check.sh` from `app/` and require zero failures.
- [ ] Run `git diff --check` and inspect the full branch diff.
- [ ] Request spec-compliance and code-quality reviews; resolve every finding.
