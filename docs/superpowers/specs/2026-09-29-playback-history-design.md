# Pier Player Playback History Design

## Goal

Turn the existing persisted playback progress into a first-class macOS library experience. The home screen should make it fast to resume unfinished videos while retaining a compact list of recently played videos, including completed items.

## Scope

- Add a **Continue Watching** section above the existing library sections.
- Add a **Recently Played** section for completed and recently opened items.
- Keep the existing **Recently Added**, **All Videos**, and **File Sources** sections.
- Reuse `PlaybackProgress` as the source of truth; do not introduce an event-log database.
- Add remove-one and clear-all history actions, with confirmation for clear-all.
- Preserve records when a NAS is temporarily offline or a scanned file disappears; show an unavailable card without exposing the opaque media hash or a stale path.
- Keep progress synchronized through the existing `PlaybackProgressManager` and CloudKit coordinator.

## Product Behavior

### Continue Watching

Show only records with `isDeleted == false`, `isCompleted == false`, `effectiveResumePosition > 0`, and a matching scanned media item. Sort by `modifiedAt` descending and use `mediaID` as a deterministic tie-breaker; cap the row at eight cards. Each card shows title, source, progress, percentage, and remaining time. Clicking the card resumes from `effectiveResumePosition`. The context menu provides **Play from Beginning** and **Remove from History**.

### Recently Played

Show the latest eight active progress records, including completed records, short/incomplete records that are not eligible for resume, and records whose media is currently unavailable. Sort by `modifiedAt` descending with `mediaID` as a tie-breaker. Resolved completed cards use **Replay** as their primary action; resolved unfinished records use **Continue**; unavailable cards are remove-only. A record appears in only one row: Continue Watching contains only resolved resumable records, while Recently Played contains every other active record.

### Record Management

Expose a toolbar/menu action to clear all playback history. Require a destructive confirmation dialog. Removing a single record creates a local tombstone and enqueues a CloudKit deletion mutation. Clear All applies the same tombstones to every record currently known after the last successful sync; if the account is offline, the local clear succeeds and the mutations remain queued for retry. Existing records for missing media remain stored and are displayed in an unavailable state until the user removes them.

## Data and API Changes

- Extend `PlaybackProgressManaging` with `remove(mediaID:)` and `removeAll()`.
- Add an `isDeleted` soft-tombstone field to `PlaybackProgress`, preserving backward-compatible decoding of existing JSON.
- Add a `.deleteProgress(PlaybackProgress)` CloudSync mutation. Tombstones participate in modified-date merge resolution and are filtered from active UI results; CloudKit keeps the tombstone record so another device cannot resurrect an older progress record.
- Add an AppModel snapshot of playback progress and an async refresh/remove API for the library.
- Add pure presentation helpers that join progress records to `MediaLibraryItem` values and return continue/recent collections; Recently Played must include active records without a matching item.
- Add a player resume policy (`automatic` or `fromBeginning`) so replay never seeks to an old saved position.
- Keep all progress operations actor-isolated and make UI-facing snapshots `Sendable`, `Equatable`, and deterministic.

## Visual and Accessibility Direction

Use native SwiftUI materials, SF Symbols, one system accent color, and compact horizontal cards. Avoid gradients, heavy custom chrome, and decorative poster treatments that compete with the content. Progress uses a thin accent bar with a readable percentage and time label. Cards expose an accessible combined label and hint, support keyboard focus, and include VoiceOver labels for unavailable and destructive actions. Unavailable cards use the configured source display name when available and generic copy otherwise; they never render a path or opaque media ID. Respect Reduce Motion.

## States and Verification

Cover empty, loading, unavailable, completed, partially watched, source-disconnected, no-scanned-items-with-history, and clear-all confirmation states. Add CloudSyncKit unit tests for tombstone persistence, active lookup filtering, delete-vs-upsert merge resolution, offline retry, and mutation generation; presentation tests for deterministic joining/sorting/deduplication; player tests for replay-from-beginning; and SwiftUI rendering tests for section visibility. Run focused tests, `swift test`, `swift build -c release`, and `scripts/check.sh`. Launch the app and verify resume, replay, remove-one, clear-all, app relaunch persistence, and offline/missing-file behavior manually.
