# Pier Player Product Roadmap

Last updated: 2026-08-02

This document tracks product-level optimization work. Detailed architecture and
implementation plans remain under `docs/superpowers/`; this file records order,
status, dependencies, and acceptance criteria.

## Status

- `[x]` Complete and covered by the repository verification gate.
- `[-]` In progress or partially implemented.
- `[ ]` Not started.
- `[!]` Blocked by an external capability or release decision.

## P0: Safety And Data Integrity

- [x] Migrate SMB credentials out of Application Support JSON.
  - Non-secret source metadata remains in the source store.
  - Username, password, and credential domain are authoritative in Keychain.
  - Legacy records migrate before normal source restoration.
  - Implemented by `6859776` and covered by source-store and Keychain tests.
- [x] Make source removal transactional and user-confirmed.
  - Keep the live source connected until metadata and credential deletion succeed.
  - Restore credentials when metadata deletion fails.
  - Keep disconnected or credential-missing sources removable.
  - Present actionable failures without exposing private source details.
  - Implemented by the local audit-hardening commit based on `c7db378`.

## P1: Playback Continuity

- [-] Complete the end-to-end resume experience.
  - [x] Persist an opaque media ID, source ID, position, duration, completion state,
    and modification time.
  - [x] Throttle periodic writes and force a write on pause, close, and playback end.
  - [x] Resume only after five seconds and treat 95% playback as completed.
  - [x] Merge progress through the local-first CloudKit synchronization boundary.
  - [ ] Add a device-local played-only history store containing the opaque media ID,
    source ID, display metadata, relative path, file size, modification date, and last
    played date; never synchronize this file through CloudKit.
  - [ ] Add a **Continue Watching** shelf to Media Library.
  - [ ] Add a non-duplicating **Recently Played** shelf for completed and recent items.
  - [ ] Sort resumable items by most recently played.
  - [ ] Show stable progress indicators on continue-watching and library items.
  - [ ] Refresh the shelf immediately when the player closes or playback completes.
  - [ ] Exclude completed, missing, changed, and unresolvable media identities.
  - [ ] Force valid progress writes after successful seek, playback failure, app
    inactivity, and termination in addition to the existing pause/close/end triggers.
  - [ ] Keep a completed item watched when it is opened accidentally and stopped before
    five seconds; clear completion only after the new viewing passes five seconds.
  - [ ] Remove device-local history and progress when a source is explicitly removed.
  - [ ] Preserve current search, partial-scan, source-failure, and empty states.

Acceptance criteria:

- A video stopped between 5% and 95% appears in Continue Watching after the player
  closes and resumes at the saved position when selected.
- A video at or beyond 95% disappears from Continue Watching without deleting its
  completed history record.
- A changed file does not inherit progress from the prior file identity.
- A disconnected source does not crash or block the library; its unmatched progress
  stays stored for future reconciliation, appears as unavailable when local history can
  identify it, and routes the user to reconnect instead of attempting playback.
- Focused model and rendering tests pass at the minimum and default window sizes.

## P1: Persistent Media Library

- [ ] Replace process-only discovery results with a local persistent media index.
- [ ] Support incremental refresh for added, changed, and deleted remote files.
- [ ] Retain browsable metadata while a NAS is offline.
- [ ] Expose per-source refresh state, last successful scan, and bounded retry.
- [ ] Keep credentials, readable NAS paths, and private names out of diagnostics and
  CloudKit progress records.

Dependency: complete the playback-continuity presentation contract first so the
index schema can include stable progress joins without duplicating identity logic.

Acceptance criteria:

- A warm launch displays the last indexed library without waiting for a network scan.
- Refresh reads only the bounded directories needed to reconcile changes.
- Removing a source removes or tombstones its local index without affecting NAS files.

## P1: NAS Resilience

- [ ] Reconnect after sleep, wake, and network-interface changes.
- [ ] Provide an explicit reauthentication flow for expired credentials.
- [ ] Distinguish server offline, missing share, permission failure, and removed file.
- [ ] Apply bounded playback retry and resume from the last accepted position.
- [ ] Keep unavailable sources visible and manageable.

Acceptance criteria:

- Network interruption during playback either recovers within the retry budget or
  presents a typed, actionable failure.
- Recovery never duplicates playback sessions or leaks remote file handles.
- Diagnostics remain privacy-safe and correlate the interruption and recovery attempt.

## P2: Broad Format Playback

- [-] Maintain the owned FFmpeg/VideoToolbox playback path and LGPL-only boundary.
- [ ] Reconcile README format claims with the implemented decoder and subtitle paths.
- [ ] Complete the supported container, codec, audio-track, and subtitle matrix.
- [ ] Validate HDR, color-space, audio-output, seek, EOF, and corruption behavior.
- [ ] Publish Release benchmarks using the fixed media and network matrix.

Acceptance criteria:

- Every advertised format has a committed fixture or documented acceptance sample.
- Unsupported media fails before playback with a stable, user-facing explanation.
- Production linkage contains no GPL-enabled FFmpeg or GPL player dependency.

## P2: Cross-Device Continuity

- [-] Source metadata and playback progress have local-first CloudKit models.
- [ ] Validate the deployed private CloudKit schema with a signed application.
- [ ] Validate synchronizable Keychain credentials on two signed devices.
- [ ] Run conflict, deletion, offline-edit, and account-unavailable acceptance cases.
- [ ] Record two-device evidence before claiming live sync support.

External requirements:

- Signed Xcode application target and iCloud entitlements.
- Deployed private CloudKit schema.
- At least two devices using the same iCloud account and reachable test NAS.

## P2: Release Engineering

- [ ] Add or finalize the signed Xcode application target and sandbox entitlements.
- [ ] Define project-level licensing and redistribution terms.
- [ ] Add crash recovery and update-distribution strategy.
- [ ] Maintain a real Mac/NAS end-to-end acceptance matrix.
- [ ] Capture product context in `PRODUCT.md` and the visual system in `DESIGN.md`.
- [ ] Keep README current with shipped behavior and known limitations.

## Verification Gate

Every completed implementation item must run from `app/`:

```bash
scripts/check.sh
```

Playback hot-path changes also require the Release benchmark matrix documented in
`docs/benchmarks/reference-environment.md`. Visible UI changes require offscreen
rendering at supported window sizes and a real-window check when macOS permissions
allow it.
