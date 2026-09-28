# Playback History Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make playback progress visible and actionable through Continue Watching and Recently Played sections in the macOS media library.

**Architecture:** Keep `PlaybackProgress` as the single latest-state record, extend the actor-backed manager and CloudSync mutation model with deletion, then expose a read-only progress snapshot from `AppModel`. Pure presentation helpers will join progress to scanned media and produce deterministic rows. SwiftUI will render the rows with native materials, keyboard focus, context menus, and confirmation for destructive actions.

**Tech Stack:** Swift 6, SwiftUI/AppKit, Swift Testing, Swift Package Manager, CloudKit sync abstractions already present in `CloudSyncKit`.

---

### Task 1: Add deletion semantics to the progress store and sync layer

**Files:**
- Modify: `app/Shared/Sources/CloudSyncKit/PlaybackProgressManager.swift`
- Modify: `app/Shared/Sources/CloudSyncKit/PlaybackProgressStore.swift`
- Modify: `app/Shared/Sources/CloudSyncKit/SyncCoordinator.swift`
- Modify: `app/Shared/Sources/CloudSyncKit/SyncModels.swift`
- Modify: `app/Shared/Tests/CloudSyncKitTests/PlaybackProgressManagerTests.swift`
- Modify: `app/Shared/Tests/CloudSyncKitTests/PlaybackProgressStoreTests.swift`
- Modify: `app/Shared/Tests/CloudSyncKitTests/SyncCoordinatorTests.swift`

- [ ] Write failing tests for removing one progress record, clearing all records, and emitting a deletion mutation.
- [ ] Run the focused CloudSyncKit tests and confirm they fail because the APIs/mutation are missing.
- [ ] Add `remove(mediaID:)` and `removeAll()` to `PlaybackProgressManaging`.
- [ ] Persist removals atomically and enqueue a `.deleteProgress(mediaID:sourceID:modifiedAt:)` mutation that can win conflict resolution by timestamp.
- [ ] Update CloudKit mapping and synchronization merge logic so deleted records do not reappear after a sync.
- [ ] Run the focused tests and then the full CloudSyncKit suite.
- [ ] Commit as `feat(sync): support deleting playback history`.

### Task 2: Add progress snapshots and deterministic presentation joins

**Files:**
- Modify: `app/macOS/Sources/PierPlayerApp/AppModel.swift`
- Modify: `app/macOS/Sources/PierPlayerApp/MediaLibraryPresentation.swift`
- Create: `app/macOS/Sources/PierPlayerApp/PlaybackHistoryPresentation.swift`
- Create: `app/macOS/Tests/PierPlayerAppTests/PlaybackHistoryPresentationTests.swift`

- [ ] Write failing tests for resolved continue items, completed recent items, modified-date ordering, duplicate progress IDs, and missing-media records.
- [ ] Run the focused presentation tests and confirm they fail.
- [ ] Add a `PlaybackHistorySnapshot` value type containing progress records and a refresh task in `AppModel`.
- [ ] Add pure helpers that resolve records by `MediaSyncIdentity`, keep missing records separate, exclude completed items from Continue Watching, and cap each row at eight.
- [ ] Add human-readable remaining-time/percentage formatting helpers with stable edge-case behavior.
- [ ] Run focused tests and commit as `feat(library): derive playback history sections`.

### Task 3: Wire media-library state and actions

**Files:**
- Modify: `app/macOS/Sources/PierPlayerApp/MediaLibraryView.swift`
- Modify: `app/macOS/Sources/PierPlayerApp/MediaLibraryCatalog.swift`
- Modify: `app/macOS/Sources/PierPlayerApp/MediaLibraryComponents.swift`
- Create: `app/macOS/Sources/PierPlayerApp/PlaybackHistoryComponents.swift`
- Modify: `app/macOS/Sources/PierPlayerApp/PierPlayerCommands.swift`
- Modify: `app/macOS/Tests/PierPlayerAppTests/UIRenderingTests.swift`

- [ ] Write failing rendering/state tests for section ordering, empty history, and action routing.
- [ ] Run the focused UI tests and confirm the expected failures.
- [ ] Load progress after source restoration and after each library scan; keep the snapshot independent from transient scan results.
- [ ] Add play actions for resume and replay, single-record removal, clear-all confirmation, and a refresh action that updates the visible snapshot.
- [ ] Render Continue Watching before Recently Added; render Recently Played only when it has resolved records; preserve existing search behavior.
- [ ] Add unavailable-record affordances and an empty-state action that returns to All Videos.
- [ ] Add accessible labels/hints, keyboard focus, context menus, Reduce Motion handling, and a toolbar/menu command for clearing history.
- [ ] Run focused UI tests and commit as `feat(macOS): add playback history home sections`.

### Task 4: Integrate, run, and manually verify

**Files:**
- Modify: `app/macOS/Sources/PierPlayerApp/MediaLibraryView.swift` as needed for integration fixes
- Modify: `app/macOS/Sources/PierPlayerApp/PierPlayerApp.swift` only if dependency injection needs adjustment
- Modify: `app/macOS/Sources/PierPlayerApp/VideoPlayerModel.swift` only if completion/resume edge cases are exposed

- [ ] Run `cd app && swift test`.
- [ ] Run `cd app && swift build -c release`.
- [ ] Run `cd app && scripts/check.sh`.
- [ ] Launch with `./app/script/build_and_run.sh --verify`.
- [ ] Manually verify: resume position, replay from beginning, completion moving out of Continue Watching, remove-one, clear-all confirmation, app relaunch persistence, source disconnect/missing file state, keyboard focus, and light/dark appearance.
- [ ] Inspect unified logs for crashes or uncaught task failures during the manual flow.
- [ ] Commit any integration fixes with a focused Conventional Commit and report verification commands/results.
