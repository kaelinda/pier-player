# Pier Player Playback Continuity Design

- **Date:** 2026-08-03
- **Status:** Approved for automatic execution
- **Platform:** macOS

## 1. Goal

Turn the existing opaque resume-progress foundation into a visible, dependable
playback-continuity experience. Media Library should help a user resume unfinished
videos, recognize recently played or completed videos, and understand when history
belongs to an unavailable source without weakening the existing privacy boundary.

## 2. Existing Foundation

The current implementation already:

- derives a stable opaque media ID from source UUID, normalized path, size, and
  modification time;
- stores position, duration, completion state, and modification time locally;
- synchronizes only opaque progress through the CloudKit private database;
- throttles periodic saves to 15 seconds and force-saves on pause, close, and end;
- resumes after five seconds and treats 95% as completed.

The missing layer is presentation metadata and lifecycle coordination. An opaque
CloudKit record cannot provide a title or playable path when a device has not seen
that file locally.

## 3. Chosen Architecture

Use two stores with deliberately different privacy boundaries:

1. **Synced playback progress** remains in `CloudSyncKit`. It contains only opaque
   media ID, source ID, numeric progress, completion, and timestamps.
2. **Device-local played history** records only media the user actually opened on
   this device. It contains the media ID plus source display name, file name,
   relative path, file size, modification time, and last-played timestamp.

The history store is not a general media index and is never synchronized. Media
Library joins the current scan, local history, and synced progress by media ID.

Rejected alternatives:

- A live-scan-only join is smaller but loses history whenever a NAS is unavailable.
- A persistent full-library catalog offers more offline browsing but introduces a
  much larger indexing and reconciliation subsystem. It remains a later roadmap item.

## 4. Progress Semantics

- Positions below five seconds are not resumable.
- `position / duration >= 0.95` is completed, including exactly 95%.
- Completed videos do not appear in Continue Watching.
- Reopening a completed video and stopping before five seconds keeps it completed.
- Rewatching beyond five seconds clears completion and makes it resumable again.
- Ratios are finite and clamped to `0...1`.
- File size or modification-time changes produce a different media ID, preventing
  stale progress from attaching to replacement media.

Periodic writes remain throttled. Valid progress is force-saved on pause, successful
seek, close, playback end, terminal playback failure, scene deactivation, and app
termination.

## 5. Local History

`PlaybackHistoryEntry` contains:

- opaque media ID;
- source UUID and source display name;
- media file name and normalized relative path;
- size and modification time;
- last-played timestamp.

`PlaybackHistoryStore` is an actor backed by atomically written JSON under
Application Support/PierPlayer. Corrupt JSON is isolated as an empty history. A
successful player start upserts history; a failed open does not. Playing a replacement
at the same source/path removes the previous identity. Explicit source removal deletes
that source's local history and progress.

## 6. Media Library Presentation

The default unfiltered order is:

1. Continue Watching, when non-empty;
2. Recently Played, when non-empty;
3. Recently Added;
4. All Videos;
5. File Sources.

Continue Watching contains at most 12 non-completed items, newest first. Recently
Played contains at most 12 items not already shown in Continue Watching. Completed
items use a Watched badge. Other items show a compact progress bar and percentage.

When a history entry belongs to a configured but disconnected source, it remains
visible with an Unavailable label. Activating it routes to the existing reconnect flow
instead of attempting playback. Opaque progress received from another device cannot
be shown until a local scan or local history resolves its title; that is intentional.

Search remains focused on the current scanned library and does not create duplicate
continuity shelves. Partial scan failures retain successful content and history.

## 7. Privacy

- CloudKit, pending mutations, diagnostics, OSLog, and exported support bundles never
  receive media names or paths.
- The local history file may contain a relative SMB path and display metadata because
  it never leaves the device.
- Credentials, host, share, domain, and unrestricted errors are forbidden from the
  history file.
- User-facing and diagnostic errors never echo the stored relative path.

## 8. Lifecycle And Refresh

Media Library loads continuity after launch and refreshes it after CloudKit merge,
source changes, and player dismissal. It does not need live updates behind the player.

Scene deactivation requests a forced save from the active player. Application
termination performs the same flush before diagnostics stop. If no valid media ID or
duration exists, these triggers are no-ops.

## 9. Verification

Automated coverage includes:

- completion and rewatch thresholds;
- history round-trip, corruption isolation, replacement, sorting, and source cleanup;
- scan/history/progress joins, limits, deduplication, progress clamping, and unavailable
  projection;
- player history capture and every force-save trigger;
- source removal cleanup;
- SwiftUI rendering at 820x560 and 1120x720 with Continue Watching, Watched, and
  Unavailable fixtures plus accessibility labels.

Finish with `scripts/check.sh`, `git diff --check`, dark/light snapshots, and a
real-window smoke check when macOS foreground permissions permit it.
