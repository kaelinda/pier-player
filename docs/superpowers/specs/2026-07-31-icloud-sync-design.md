# iCloud Configuration and Playback Progress Sync Design

## 1. Goal

Pier Player will synchronize reusable SMB source configuration and playback
progress across Apple devices signed into the same iCloud account. Credentials
will synchronize only through iCloud Keychain. The feature is local-first:
missing entitlements, no iCloud account, network loss, quota errors, and
CloudKit outages must never prevent local source management or playback.

The first client integration is macOS. Data models and synchronization logic
live under `app/Shared/` so future iOS and tvOS shells can reuse them without
depending on SwiftUI or AppKit.

## 2. Scope

### 2.1 Synchronized data

- SMB source UUID, display name, host, share, optional domain, and encryption
  requirement.
- SMB username and password, stored as one synchronizable Keychain item keyed
  by the source UUID.
- Playback position, duration, completion state, and update time for an opaque
  media identity.

### 2.2 Device-local data

- Diagnostics events, reports, and privacy keys.
- Media-library scan results, generated presentation data, and caches.
- Active playback sessions, transient failures, and current UI navigation.
- Native SMB handles, network state, and performance telemetry.

## 3. Security and Privacy Boundary

CloudKit uses the user's private database. A source record may contain the
connection host and share because another device needs those values to connect,
but it must never contain a username, password, Keychain payload, or complete
media path.

Credentials use a generic-password Keychain item with the existing opaque
source UUID as its account. The item sets `kSecAttrSynchronizable` to true and
uses an accessibility class compatible with synchronization. The current
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` value is deliberately
replaced because `ThisDeviceOnly` items cannot synchronize.

The existing Application Support JSON format contains plaintext username and
password fields. Migration decodes that legacy format, saves each credential
to Keychain, writes a new non-secret source file atomically, and only then
removes the legacy secret fields. If Keychain persistence fails, migration
leaves the legacy file intact and reports a sanitized local error so no
credential is lost.

A playback record uses a SHA-256 digest of a versioned canonical representation
of source UUID, normalized path, size, and modification date. Only the digest is
stored in CloudKit. Changing the remote file metadata intentionally creates a
new identity and prevents a stale position from being applied to replacement
content.

## 4. Architecture

```text
macOS AppModel / VideoPlayerModel
          |
          +-- SMBSourceStore -------- local non-secret source snapshot
          +-- KeychainCredentialStore iCloud Keychain credentials
          +-- PlaybackProgressStore -- local progress snapshot
          |
          +-- SyncCoordinator actor
                    |
                    +-- CloudSyncTransport protocol
                    |       |
                    |       +-- CloudKit private database adapter
                    |
                    +-- pending mutations + server change token
```

`CloudSyncKit` is a new shared SwiftPM target. It owns sync-safe record types,
opaque media identity generation, local progress persistence, pending mutation
tracking, conflict policy, and the transport protocol. The concrete CloudKit
adapter is compiled only on Apple platforms where CloudKit is available.

The app reads and writes local stores directly. `SyncCoordinator` observes
committed local mutations, uploads them opportunistically, fetches remote
changes at launch and activation, and merges accepted records back into local
stores. CloudKit is never placed on the playback hot path.

## 5. Data Model

### 5.1 SMB source record

CloudKit record type: `SMBSource`

| Field | Type | Rule |
| --- | --- | --- |
| record name | UUID string | Same stable ID on every device |
| schemaVersion | Int64 | Starts at 1 |
| displayName | String | Trimmed, non-empty |
| host | String | Existing normalized host |
| share | String | Existing normalized share |
| domain | String? | Trimmed; absent when empty |
| requiresEncryption | Int64 | 0 or 1 |
| clientModifiedAt | Date | Ordering hint and testable local metadata |

CloudKit server metadata remains the authority for accepted record versions.
The local source snapshot keeps `clientModifiedAt` and a pending mutation state
but never persists credential fields.

### 5.2 Playback progress record

CloudKit record type: `PlaybackProgress`

| Field | Type | Rule |
| --- | --- | --- |
| record name | opaque SHA-256 hex | Versioned media identity |
| schemaVersion | Int64 | Starts at 1 |
| sourceID | UUID string | Enables source-scoped cleanup without a path |
| position | Double | Finite, at least zero |
| duration | Double | Finite, greater than zero |
| completed | Int64 | 0 or 1 |
| clientModifiedAt | Date | Local ordering hint |

Progress is saved at most once per 15 seconds during playback and immediately
on pause, player close, application deactivation/termination, and playback end.
At or beyond 95 percent, the record is completed and its effective resume
position is zero. Positions below five seconds are also treated as zero to
avoid offering a meaningless resume.

## 6. Merge and Deletion Rules

- The local write commits first and enqueues a mutation in the same actor
  operation.
- A successful CloudKit save replaces local server metadata and clears that
  pending mutation.
- If CloudKit reports a server-record conflict, a still-pending local edit is
  retried against the current server change tag. Thus the last mutation that
  CloudKit successfully accepts wins without trusting device clock accuracy.
- A fetched server record replaces a clean local record. It does not overwrite
  a newer pending local mutation.
- Source deletion creates a local tombstone and disconnects the active source.
  The tombstone remains until CloudKit accepts the delete, preventing a fetch
  from resurrecting the source.
- Remote deletion removes the local non-secret source and local progress for
  that source. Keychain deletion is best-effort because a synchronizable
  credential may arrive or disappear independently.
- Progress conflicts use the same pending-local rule. When neither side is
  pending, the most recently accepted CloudKit record wins.

## 7. Missing Credentials and Source Restoration

The app must retain every valid synchronized source even if the credential is
not yet present. Source presentation therefore distinguishes `connecting`,
`connected`, `needsCredential`, and sanitized `unavailable` states.

At restore time the app loads the non-secret source list, queries Keychain, and
connects only records with a credential. A missing credential shows a reconnect
action that opens the existing source form with non-secret fields populated and
requires a username and password. Saving the form updates Keychain and retries
the connection without changing the source UUID.

## 8. CloudKit Availability and Error Handling

Sync status is one of `localOnly`, `syncing`, `upToDate`, `accountUnavailable`,
or `temporarilyUnavailable`. It may be shown in source settings, but ordinary
playback errors must not be replaced by sync errors.

Retryable CloudKit errors retain pending mutations and use bounded exponential
backoff with system retry hints. Account and entitlement errors switch to local
operation until the next activation/account-change event. Validation errors
quarantine only the invalid record and never erase a valid local record.

No CloudKit error description, host, share, username, password, or media path is
written to diagnostics. Diagnostics use stable error categories and opaque
source or record IDs consistent with the existing privacy contract.

## 9. App Packaging and Deployment

CloudKit and synchronizable Keychain require a stable application identifier,
code signing, iCloud capabilities, and an Apple Developer CloudKit container.
The repository will include an entitlement template naming
`iCloud.dev.pierplayer.app`, but `swift run PierPlayerApp` cannot prove live
CloudKit synchronization because a raw SwiftPM executable does not provide the
production signing configuration.

The production macOS app must be built through Xcode with:

- bundle identifier `dev.pierplayer.app`;
- iCloud capability with CloudKit enabled;
- container `iCloud.dev.pierplayer.app`;
- Keychain Sharing capability when required by the selected signing profile;
- the private database development schema deployed before multi-device tests.

Until those external resources exist, automated tests use an in-memory
transport and the app degrades to local-only mode. Code completion must not be
reported as live cross-device acceptance.

## 10. Testing and Acceptance

Unit tests cover:

- legacy plaintext migration succeeds atomically and removes secret JSON fields;
- failed Keychain migration preserves the legacy file;
- synchronizable Keychain query attributes and missing-item behavior;
- source/progress validation and deterministic opaque media identities;
- pending-local, server-update, conflict-retry, and tombstone merges;
- corrupt local snapshots and corrupt remote records remain isolated;
- progress throttling, pause/close flushing, completion threshold, and file
  replacement identity;
- missing credentials keep a synchronized source visible and reconnectable;
- unavailable iCloud never blocks local source edits or playback startup.

The repository gate remains `app/scripts/check.sh`. Live acceptance additionally
uses two signed Apple devices on the same iCloud account to verify source add,
edit, delete, credential arrival or re-entry, progress resume, offline edits,
and conflict convergence. No test writes persistent business data to a user's
production CloudKit container.

## 11. Delivery Order

1. Remove plaintext credential persistence through a backward-compatible,
   atomic migration.
2. Add `CloudSyncKit` models, local stores, merge engine, and fake transport.
3. Add the CloudKit private-database adapter and entitlement template.
4. Integrate source synchronization and missing-credential presentation.
5. Integrate progress capture and resume.
6. Run the full gate and document the external signed-device acceptance gap.

