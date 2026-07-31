# SMB Source Management Design

## Goal

Let a macOS user inspect and edit a connected NAS source from its sidebar context menu without exposing its password or interrupting the current connection when validation fails.

## Product Direction

This is a targeted evolution of the existing native SwiftUI workspace. Preserve the system font, teal operational accent, compact sidebar rows, grouped forms, and system light/dark behavior. Use native context-menu commands and separate sheets rather than adding permanent controls to every source row.

Design dials for this operational surface are `DESIGN_VARIANCE: 3`, `MOTION_INTENSITY: 2`, and `VISUAL_DENSITY: 6`. Interaction feedback comes from native menu, sheet, focus, progress, disabled, and error states. No decorative animation is required.

## Interaction

The source context menu contains, in order:

1. `Get Info`
2. `Edit Source`
3. A separator
4. `Remove Source` as a destructive command

`Get Info` opens a read-only 520 by 430 point sheet. It shows the display name, complete SMB address, username, domain state, encryption state, and source identifier. It never shows or implies the stored password.

`Edit Source` opens a 520 by 590 point sheet. It reuses the add-source field structure for name, host, share, username, password, domain, and encryption. The password starts empty; leaving it empty preserves the current password. Saving shows in-place progress, prevents dismissal, and reports a contextual inline error without closing the sheet.

## Update Semantics

Editing preserves the source UUID and sidebar position. The model creates and connects a replacement source before changing Keychain or source metadata. A connection failure disconnects only the replacement and leaves the live source unchanged.

After connection succeeds, the model writes the replacement credential and metadata. If the metadata write fails, it restores the previous credential before returning the error. Only after persistence succeeds does it replace the in-memory source, increment the source revision, and disconnect the old source.

Add, edit, and remove each increment the source revision. Source browsing and media-library scanning include that revision in their reload identities so an edited connection cannot leave stale file data visible.

## Boundaries

- Keep the existing immediate remove behavior.
- Do not add a starting-path field because the current source model is rooted at the SMB share.
- Do not change the current persistence format or address the separate plaintext migration issue in this feature.
- Do not change playback, scanning limits, or supported media formats.

## Verification

- Store tests cover in-place replacement and unknown IDs.
- App-model tests cover password preservation, successful live replacement, and failure isolation.
- Rendering tests cover action copy and both sheet dimensions.
- Run focused tests, all SwiftPM tests, Release build and whitespace checks.
- Inspect rendered sheets in dark mode and exercise the context menu in the running application.
