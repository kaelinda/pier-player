# Pier Player Playback History Design

## Goal

Turn the existing persisted playback progress into a first-class macOS library experience. The home screen should make it fast to resume unfinished videos while retaining a compact list of recently played videos, including completed items.

## Scope

- Add a **Continue Watching** section above the existing library sections.
- Add a **Recently Played** section for completed and recently opened items.
- Keep the existing **Recently Added**, **All Videos**, and **File Sources** sections.
- Reuse `PlaybackProgress` as the source of truth; do not introduce an event-log database.
- Add remove-one and clear-all history actions, with confirmation for clear-all.
- Preserve records when a NAS is temporarily offline or a scanned file disappears; show unavailable records only when they cannot be resolved to a current media item.
- Keep progress synchronized through the existing `PlaybackProgressManager` and CloudKit coordinator.

## Product Behavior

### Continue Watching

Show only records with `isCompleted == false` and a matching scanned media item. Sort by `modifiedAt` descending and cap the row at eight cards. Each card shows title, source, progress, percentage, and remaining time. Clicking the card resumes from `effectiveResumePosition`. The context menu provides **Play from Beginning** and **Remove from History**.

### Recently Played

Show the latest eight resolved progress records, including completed records, sorted by `modifiedAt` descending. Completed cards use **Replay** as their primary action; unfinished records use **Continue**. A record appears in only one row: unfinished records stay in Continue Watching, while Recently Played is reserved for completed items and the latest records not eligible for resume.

### Record Management

Expose a toolbar/menu action to clear all playback history. Require a destructive confirmation dialog. Removing a single record deletes it locally and enqueues a CloudKit deletion mutation. Existing records for missing media remain stored and are displayed in an unavailable state until the user removes them.

## Data and API Changes

- Extend `PlaybackProgressManaging` with `remove(mediaID:)` and `removeAll()`.
- Add a `.deleteProgress` CloudSync mutation and map it through the existing sync coordinator.
- Add an AppModel snapshot of playback progress and an async refresh/remove API for the library.
- Add pure presentation helpers that join progress records to `MediaLibraryItem` values and return continue/recent collections.
- Keep all progress operations actor-isolated and make UI-facing snapshots `Sendable`, `Equatable`, and deterministic.

## Visual and Accessibility Direction

Use native SwiftUI materials, SF Symbols, one system accent color, and compact horizontal cards. Avoid gradients, heavy custom chrome, and decorative poster treatments that compete with the content. Progress uses a thin accent bar with a readable percentage and time label. Cards expose an accessible combined label and hint, support keyboard focus, and include VoiceOver labels for unavailable and destructive actions. Respect Reduce Motion.

## States and Verification

Cover empty, loading, unavailable, completed, partially watched, source-disconnected, and clear-all confirmation states. Add CloudSyncKit unit tests for deletion persistence and mutation generation, presentation tests for deterministic joining/sorting/deduplication, and SwiftUI rendering tests for section visibility. Run focused tests, `swift test`, `swift build -c release`, and `scripts/check.sh`. Launch the app and verify resume, replay, remove-one, clear-all, and offline/missing-file behavior manually.
