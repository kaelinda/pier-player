# Product Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the macOS prototype safer to operate, clearer about bounded media discovery, easier to maintain visually, and accurate in its documentation without changing playback or storage architecture.

**Architecture:** Keep `AppModel`, SMB storage, and the FFmpeg playback boundary unchanged. Add the destructive-action confirmation at the SwiftUI shell, carry an explicit per-source scan-limit flag through `MediaLibraryScanResult` into an OR-aggregated `MediaLibrarySnapshot`, extract reusable media-library cards into a focused component file, and update README copy to match the implemented pipeline and credential storage.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing, Swift Package Manager, macOS 14.

---

### Task 1: Make media scan truncation explicit

**Files:**
- Modify: `app/macOS/Sources/PierPlayerApp/MediaLibraryCatalog.swift`
- Modify: `app/macOS/Tests/PierPlayerAppTests/MediaLibraryScannerTests.swift`
- Modify: `app/macOS/Tests/PierPlayerAppTests/MediaLibraryViewModelTests.swift`

- [ ] **Step 1: Add the result and snapshot data contract**

Add `didReachMaximumVideoCount: Bool` to `MediaLibraryScanResult` and
`MediaLibrarySnapshot`. Default both to `false` so existing fixtures remain
source-compatible. Preserve the meaning from the spec: the value is true only
after the scanner encounters a supported video that it must skip because the
maximum has already been reached.

- [ ] **Step 2: Update scanner traversal without false positives**

Change the scanner so it does not return immediately on the item that fills the
limit. It keeps scanning the current directory and queued directories until it
encounters the first additional supported video; then it returns the collected
items with `didReachMaximumVideoCount == true`. If traversal finishes exactly at
the limit, return false. Preserve cancellation, failure sanitization, breadth-
first traversal, and the existing limit values.

- [ ] **Step 3: Add focused scanner tests**

Extend `MediaLibraryScannerTests` with:

- exactly `maximumVideoCount` videos and no extra candidate returns false;
- an additional candidate in the same directory returns true and does not
  append the extra item;
- an additional candidate in a later directory returns true after that
  directory is listed;
- the existing 250-video case still reads only `/`, returns 200 items, and now
  asserts the true flag.

- [ ] **Step 4: Propagate and clear the aggregate flag**

When `MediaLibraryViewModel.reload` starts, clear the snapshot-level flag along
with stale items and failures. While source results arrive, OR each result's
flag into `snapshot.didReachMaximumVideoCount`. Keep the flag true when another
source fails, and clear it on the next reload even when the source list becomes
empty.

- [ ] **Step 5: Test reload clearing and mixed-source aggregation**

Add view-model tests that use two sources to verify one truncated result makes
the aggregate true even when the other source fails, and a subsequent reload
with an exact-limit source clears the previous true value. Run:

```bash
cd app
swift test --filter PierPlayerAppTests.MediaLibraryScannerTests
swift test --filter PierPlayerAppTests.MediaLibraryViewModelTests
```

Expected: all selected tests pass.

- [ ] **Step 6: Commit the scan contract**

```bash
git add app/macOS/Sources/PierPlayerApp/MediaLibraryCatalog.swift \
  app/macOS/Tests/PierPlayerAppTests/MediaLibraryScannerTests.swift \
  app/macOS/Tests/PierPlayerAppTests/MediaLibraryViewModelTests.swift
git commit -m "feat(media-library): expose scan limit feedback"
```

### Task 2: Surface bounded scanning and protect source removal

**Files:**
- Modify: `app/macOS/Sources/PierPlayerApp/RootView.swift`
- Modify: `app/macOS/Sources/PierPlayerApp/MediaLibraryView.swift`
- Modify: `app/macOS/Tests/PierPlayerAppTests/UIRenderingTests.swift`

- [ ] **Step 1: Add a pending-removal state to the root shell**

Add `@State private var sourcePendingRemoval: AppModel.ConfiguredSource?`.
Change the sidebar's destructive context-menu action to assign the selected
configured source instead of removing it immediately. Attach a
`confirmationDialog(item:)` to `RootView` with the source display name in the
title and a message explaining that only the local connection configuration is
removed; NAS files are untouched. The destructive confirmation must call the
existing `removeSource(id:)` helper.

- [ ] **Step 2: Preserve sidebar rendering and accessibility**

Keep the existing `RootSidebarContent` callback shape so the sidebar remains
previewable and testable. Add explicit labels for the confirmation dialog's
destructive action and cancel action through SwiftUI's standard dialog roles.

- [ ] **Step 3: Add the scan-limit notice**

In `MediaLibraryContentView`, render a warning notice only when
`snapshot.didReachMaximumVideoCount` is true and the trimmed search query is
empty. Use `MediaLibraryScanLimits()` as the single source for the displayed
depth and video-count values. The copy must say that the library reached the
configured video limit and that browsing the source can reveal more files.
Place it beside the existing failure notice without changing loading, empty,
search, or source-card behavior.

- [ ] **Step 4: Add pure presentation tests**

Add tests for the limit-notice copy/visibility contract and keep the existing
search composition test asserting that search results do not add a second
limit notice. Render the root sidebar and media library snapshots at their
existing sizes to catch layout regressions.

- [ ] **Step 5: Commit the interaction and status feedback**

```bash
git add app/macOS/Sources/PierPlayerApp/RootView.swift \
  app/macOS/Sources/PierPlayerApp/MediaLibraryView.swift \
  app/macOS/Tests/PierPlayerAppTests/UIRenderingTests.swift
git commit -m "feat(macOS): clarify source removal and scan limits"
```

### Task 3: Extract reusable media-library components and modernize copy

**Files:**
- Create: `app/macOS/Sources/PierPlayerApp/MediaLibraryComponents.swift`
- Modify: `app/macOS/Sources/PierPlayerApp/MediaLibraryView.swift`
- Modify: `app/macOS/Tests/PierPlayerAppTests/UIRenderingTests.swift`

- [ ] **Step 1: Move card and artwork types into a focused file**

Move `RecentMediaCard`, `PosterMediaCard`, `MediaSourceCard`,
`MediaCardButtonStyle`, and `MediaArtwork` from `MediaLibraryView.swift` into
`MediaLibraryComponents.swift`. Keep their private implementation details and
public behavior unchanged. Because Swift `private` is file-scoped, the three
card views and `MediaArtwork` must be internal (no access modifier) so
`MediaLibraryView.swift` can compose them; their stored implementation details
and helper properties can remain private. Import only the frameworks they need.

- [ ] **Step 2: Introduce shared media-library design constants**

Define a small internal `MediaLibraryDesign` namespace in the new file for the
existing card corner radius, recent-card width, source-card size, and common
hover animation duration. Use the constants in the extracted views and in the
remaining media-library status notice so this pass does not add another set of
magic values.

- [ ] **Step 3: Improve extension badge hierarchy**

Change the artwork extension badge from `caption2` to `caption` while retaining
its compact badge frame and contrast. Preserve the existing accessibility-hidden
artwork behavior and reduced-motion handling.

Expose a small internal presentation helper for the scan-limit notice (for
example, `MediaLibraryLimitNoticeCopy`) so its visibility rule and copy can be
asserted without rendering SwiftUI internals. The helper must return no notice
when a search query is active.

- [ ] **Step 4: Run UI-focused tests**

```bash
cd app
swift test --filter PierPlayerAppTests.UIRenderingTests
```

Expected: all rendering and presentation assertions pass.

- [ ] **Step 5: Commit the component extraction**

```bash
git add app/macOS/Sources/PierPlayerApp/MediaLibraryComponents.swift \
  app/macOS/Sources/PierPlayerApp/MediaLibraryView.swift \
  app/macOS/Tests/PierPlayerAppTests/UIRenderingTests.swift
git commit -m "refactor(macOS): split media library components"
```

### Task 4: Replace C-style playback time formatting

**Files:**
- Modify: `app/macOS/Sources/PierPlayerApp/PlaybackControlsView.swift`
- Modify: `app/macOS/Tests/PierPlayerAppTests/UIRenderingTests.swift`

- [ ] **Step 1: Replace `String(format:)` in the UI formatter**

Keep the existing invalid-input behavior and output contract. Add a private
two-digit Swift helper and use string interpolation for minutes and seconds,
preserving `0:00`, `1:05`, and `1:01:01` across hour boundaries.

- [ ] **Step 2: Cover edge values**

Extend the existing time-label test with zero, 59, 60, 3,599, 3,600, and a
fractional value to prove flooring and zero-padding remain stable.

- [ ] **Step 3: Commit the formatter change**

```bash
git add app/macOS/Sources/PierPlayerApp/PlaybackControlsView.swift \
  app/macOS/Tests/PierPlayerAppTests/UIRenderingTests.swift
git commit -m "refactor(macOS): modernize playback time labels"
```

### Task 5: Synchronize README with the implemented product

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Rewrite the capability paragraph**

Describe the current macOS app as using the implemented FFmpeg playback path
for the supported broad container set, with VideoToolbox when available,
audio-track selection, embedded/external text subtitle handling, and bounded
media-library scanning. Keep claims tied to the accepted broad-format design.

- [ ] **Step 2: State current limitations accurately**

Remove the stale claim that MKV, subtitles, track selection, and FFmpeg are
unsupported. State the remaining limitations: HDR/Dolby Vision correctness,
bitmap subtitles, metadata scraping, large-scale incremental indexing, and
the unimplemented iOS/tvOS shells.

- [ ] **Step 3: Correct the security notice**

Explain that current persisted source records contain non-secret connection
configuration only and that SMB credentials are stored in Keychain. Keep the
legacy migration and privacy-redaction expectations clear without claiming the
prototype is production-ready.

- [ ] **Step 4: Commit documentation**

```bash
git add README.md
git commit -m "docs: sync README with current playback capabilities"
```

### Task 6: Verify the finished change

**Files:**
- Inspect: `git diff`, `git status`
- Verify: all modified Swift sources and tests

- [ ] **Step 1: Run focused suites after all changes**

```bash
cd app
swift test --filter PierPlayerAppTests.MediaLibraryScannerTests
swift test --filter PierPlayerAppTests.MediaLibraryViewModelTests
swift test --filter PierPlayerAppTests.UIRenderingTests
```

Expected: all focused suites pass.

- [ ] **Step 2: Build the macOS package**

```bash
cd app
swift build
```

Expected: the package and `PierPlayerApp` executable build successfully.

- [ ] **Step 3: Run repository checks**

```bash
cd app
scripts/check.sh
```

Expected: tests, release build, and whitespace checks pass. If the environment
blocks SwiftPM cache access, rerun the same command with the approved elevated
permission and report that constraint.

- [ ] **Step 4: Inspect the final diff**

Confirm that only the intended source, test, README, spec, and plan files
changed. Confirm no files under `app/Vendor`, no credentials, and no `data/`
fixtures were modified.

- [ ] **Step 5: Commit any final verification-only fixes**

If verification reveals a real implementation issue, fix it in the relevant
task file, rerun the affected focused test, and create one final imperative
commit. Do not alter unrelated pre-existing untracked files.
