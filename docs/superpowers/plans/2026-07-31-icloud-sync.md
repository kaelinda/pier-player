# iCloud Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Synchronize non-secret SMB source configuration and opaque playback progress through the user's private CloudKit database while synchronizing credentials only through iCloud Keychain.

**Architecture:** Add a local-first `CloudSyncKit` target containing value models, persistence, reconciliation, and a transport protocol. Keep CloudKit behind a concrete adapter and keep all source/progress writes operational when iCloud is unavailable. Migrate the existing plaintext source JSON atomically before app integration.

**Tech Stack:** Swift 6, Swift Package Manager, Swift Testing, Foundation, CryptoKit, Security, CloudKit, SwiftUI

---

### Task 1: Remove plaintext source credentials with atomic migration

**Files:**
- Modify: `app/Shared/Sources/SMBSourceKit/SMBSourceStore.swift`
- Modify: `app/Shared/Sources/SMBSourceKit/SMBCredentialStore.swift`
- Modify: `app/Shared/Sources/SMBSourceKit/KeychainCredentialStore.swift`
- Modify: `app/Shared/Tests/SMBSourceKitTests/SMBSourceStoreTests.swift`
- Modify: `app/Shared/Tests/SMBSourceKitTests/KeychainCredentialStoreTests.swift`

- [x] **Step 1: Write failing migration and synchronizable-Keychain tests**

Add tests that write a legacy JSON array with `username` and `password`, invoke
`migrateCredentials(to:)`, and assert the rewritten JSON contains neither key.
Add a failing credential store and assert the legacy bytes remain unchanged.
Inspect saved Keychain attributes and assert `kSecAttrSynchronizable == true`.

- [x] **Step 2: Run focused tests and verify RED**

Run: `cd app && swift test --filter SMBSourceStoreTests && swift test --filter KeychainCredentialStoreTests`

Expected: FAIL because the migration API and synchronizable attributes do not exist.

- [x] **Step 3: Implement the non-secret model and migration**

Change `SMBStorageSource` to contain only:

```swift
public let id: UUID
public let displayName: String
public let host: String
public let share: String
public let domain: String?
public let requiresEncryption: Bool
public let modifiedAt: Date
```

Decode legacy credentials through a private `LegacySMBStorageSource`. Implement
`migrateCredentials(to:)` so every credential save succeeds before an atomic
non-secret rewrite. Add `replaceAll(_:)` for remote reconciliation. Configure
Keychain add/update/query/delete dictionaries with
`kSecAttrSynchronizable: kCFBooleanTrue` and replace the `ThisDeviceOnly`
accessibility class with `kSecAttrAccessibleAfterFirstUnlock`.

- [x] **Step 4: Run focused tests and verify GREEN**

Run: `cd app && swift test --filter SMBSourceStoreTests && swift test --filter KeychainCredentialStoreTests`

Expected: PASS.

- [x] **Step 5: Commit**

```bash
git add app/Shared/Sources/SMBSourceKit app/Shared/Tests/SMBSourceKitTests
git commit -m "fix(smb): migrate credentials out of source storage"
```

### Task 2: Add sync models, opaque identity, and local progress persistence

**Files:**
- Modify: `app/Package.swift`
- Create: `app/Shared/Sources/CloudSyncKit/SyncModels.swift`
- Create: `app/Shared/Sources/CloudSyncKit/PlaybackProgressStore.swift`
- Create: `app/Shared/Sources/CloudSyncKit/MediaSyncIdentity.swift`
- Create: `app/Shared/Tests/CloudSyncKitTests/SyncModelsTests.swift`
- Create: `app/Shared/Tests/CloudSyncKitTests/PlaybackProgressStoreTests.swift`

- [x] **Step 1: Write failing model, identity, and store tests**

Cover invalid non-finite values, the 95 percent completion threshold, positions
below five seconds, deterministic SHA-256 identity, identity changes for size or
modification changes, atomic round trips, corrupt-file isolation, and source-
scoped progress deletion.

- [x] **Step 2: Run focused tests and verify RED**

Run: `cd app && swift test --filter CloudSyncKitTests`

Expected: FAIL because the target and types are absent.

- [x] **Step 3: Implement minimal shared models**

Define `SyncedSMBSource`, `PlaybackProgress`, `SyncStatus`, and
`MediaSyncIdentity`. Use `CryptoKit.SHA256` over a length-delimited, versioned
canonical byte representation. Implement an actor-backed JSON progress store
whose default location is `Application Support/PierPlayer/sync-progress.json`.

- [x] **Step 4: Run focused tests and verify GREEN**

Run: `cd app && swift test --filter CloudSyncKitTests`

Expected: PASS.

- [x] **Step 5: Commit**

```bash
git add app/Package.swift app/Shared/Sources/CloudSyncKit app/Shared/Tests/CloudSyncKitTests
git commit -m "feat(sync): add source and progress models"
```

### Task 3: Implement local-first reconciliation and durable pending mutations

**Files:**
- Create: `app/Shared/Sources/CloudSyncKit/CloudSyncTransport.swift`
- Create: `app/Shared/Sources/CloudSyncKit/SyncStateStore.swift`
- Create: `app/Shared/Sources/CloudSyncKit/SyncCoordinator.swift`
- Create: `app/Shared/Tests/CloudSyncKitTests/SyncCoordinatorTests.swift`

- [x] **Step 1: Write failing reconciliation tests**

Use an in-memory transport to cover local add/update/delete, remote add/update/
delete, pending local edits winning fetched records, failed uploads surviving a
coordinator restart, retry convergence, and local-only behavior after account
or network failure.

- [x] **Step 2: Run focused tests and verify RED**

Run: `cd app && swift test --filter SyncCoordinatorTests`

Expected: FAIL because coordinator types are absent.

- [x] **Step 3: Implement the transport boundary and coordinator**

Use this protocol boundary:

```swift
public protocol CloudSyncTransport: Sendable {
    func accountAvailable() async -> Bool
    func fetchSnapshot() async throws -> CloudSyncSnapshot
    func save(_ mutations: [CloudSyncMutation]) async throws
}
```

Persist pending mutations before attempting transport work. Represent deletion
as a tombstone record. Fetch, preserve pending-local IDs, merge clean remote
records, upload pending mutations, and return a merged snapshot to callers.

- [x] **Step 4: Run focused tests and verify GREEN**

Run: `cd app && swift test --filter SyncCoordinatorTests`

Expected: PASS.

- [x] **Step 5: Commit**

```bash
git add app/Shared/Sources/CloudSyncKit app/Shared/Tests/CloudSyncKitTests
git commit -m "feat(sync): add local-first reconciliation"
```

### Task 4: Add the private CloudKit transport and capability template

**Files:**
- Create: `app/Shared/Sources/CloudSyncKit/CloudKitSyncTransport.swift`
- Create: `app/macOS/PierPlayerApp.entitlements`
- Create: `app/Shared/Tests/CloudSyncKitTests/CloudKitMappingTests.swift`
- Modify: `README.md`

- [x] **Step 1: Write failing CloudKit mapping tests**

Test record names/types, allowed source fields, absence of credential and path
fields, progress numeric validation, tombstones, and sanitized error mapping.

- [x] **Step 2: Run focused tests and verify RED**

Run: `cd app && swift test --filter CloudKitMappingTests`

Expected: FAIL because record mapping does not exist.

- [x] **Step 3: Implement the CloudKit adapter**

Use `CKContainer.default().privateCloudDatabase`. Map `SMBSource` and
`PlaybackProgress` records through internal pure mapping helpers. Fetch both
record types with paginated `CKQueryOperation`, save records with changed-key
policies, and map account/entitlement/network errors to typed sync failures.
Add an entitlement template for `iCloud.dev.pierplayer.app`. Document that live
sync requires an Apple Developer container and a signed Xcode app build.

- [x] **Step 4: Run focused tests and verify GREEN**

Run: `cd app && swift test --filter CloudKitMappingTests`

Expected: PASS without contacting CloudKit.

- [x] **Step 5: Commit**

```bash
git add app/Shared/Sources/CloudSyncKit app/Shared/Tests/CloudSyncKitTests app/macOS/PierPlayerApp.entitlements README.md
git commit -m "feat(sync): add private CloudKit transport"
```

### Task 5: Integrate synchronized sources and missing credentials into macOS

**Files:**
- Modify: `app/macOS/Sources/PierPlayerApp/AppModel.swift`
- Modify: `app/macOS/Sources/PierPlayerApp/PierPlayerApp.swift`
- Modify: `app/macOS/Sources/PierPlayerApp/RootView.swift`
- Modify: `app/macOS/Sources/PierPlayerApp/SourceManagementView.swift`
- Modify: `app/macOS/Tests/PierPlayerAppTests/SourceManagementTests.swift`
- Modify: `app/macOS/Tests/PierPlayerAppTests/UIRenderingTests.swift`

- [x] **Step 1: Write failing app integration tests**

Cover migration-before-restore, a synchronized source with no credential staying
visible as `needsCredential`, local add/update/delete queuing sync without
blocking on transport, and reconnect preserving the source UUID. Add one
offscreen render test for the missing-credential sidebar state.

- [x] **Step 2: Run focused tests and verify RED**

Run: `cd app && swift test --filter SourceManagementTests`

Expected: FAIL because source state and coordinator injection are absent.

- [x] **Step 3: Implement app source integration**

Represent configured sources separately from connected media sources. Restore
local data immediately, start source synchronization in a child task, and apply
remote changes through the source store. Display missing credentials with a
locked-drive icon and a reconnect command. All source mutations call the local
store first, enqueue sync second, and retain current rollback semantics.

- [x] **Step 4: Run focused and rendering tests**

Run: `cd app && swift test --filter SourceManagementTests && swift test --filter UIRenderingTests`

Expected: PASS.

- [x] **Step 5: Commit**

```bash
git add app/macOS/Sources/PierPlayerApp app/macOS/Tests/PierPlayerAppTests
git commit -m "feat(macOS): synchronize SMB sources"
```

### Task 6: Capture, restore, and synchronize playback progress

**Files:**
- Modify: `app/macOS/Sources/PierPlayerApp/VideoPlayerModel.swift`
- Modify: `app/macOS/Sources/PierPlayerApp/VideoPlayerSheet.swift`
- Modify: `app/macOS/Sources/PierPlayerApp/MediaLibraryView.swift`
- Modify: `app/macOS/Tests/PierPlayerAppTests/VideoPlayerModelTests.swift`

- [x] **Step 1: Write failing progress lifecycle tests**

Cover initial resume seek, no seek for completed or under-five-second progress,
15-second throttling, immediate pause/stop flush, playback-end completion, and
different remote metadata not reusing progress.

- [x] **Step 2: Run focused tests and verify RED**

Run: `cd app && swift test --filter VideoPlayerModelTests`

Expected: FAIL because progress dependencies and lifecycle hooks are absent.

- [x] **Step 3: Implement progress lifecycle**

Inject a `PlaybackProgressManaging` protocol and source UUID into
`VideoPlayerModel`. Load progress after metadata duration is known, issue one
seek before ordinary playback advances, periodically save while active, and
flush on pause, stop, and terminal state. Queue every committed progress record
for CloudKit synchronization outside the playback coordinator.

- [x] **Step 4: Run focused tests and verify GREEN**

Run: `cd app && swift test --filter VideoPlayerModelTests`

Expected: PASS.

- [x] **Step 5: Commit**

```bash
git add app/macOS/Sources/PierPlayerApp app/macOS/Tests/PierPlayerAppTests
git commit -m "feat(playback): sync resume progress"
```

### Task 7: Verify the complete feature and deployment boundary

**Files:**
- Modify: `docs/superpowers/specs/2026-07-31-icloud-sync-design.md` only if implementation details required correction
- Modify: `docs/superpowers/plans/2026-07-31-icloud-sync.md` to check completed steps

- [x] **Step 1: Run format and whitespace checks**

Run: `git diff --check`

Expected: no output.

- [x] **Step 2: Run the repository gate**

Run: `cd app && scripts/check.sh`

Expected: all Swift tests pass, Release build succeeds, and whitespace checks pass.

- [x] **Step 3: Inspect privacy-sensitive output**

Run: `rg -n 'password|username|path' app/Shared/Sources/CloudSyncKit app/macOS/PierPlayerApp.entitlements`

Expected: credential/path references appear only in validation or explicit
non-persistence boundaries; CloudKit record mappings contain none.

- [x] **Step 4: Record the live acceptance limitation**

Confirm the handoff states that two-device CloudKit acceptance remains pending
until `iCloud.dev.pierplayer.app` exists in the Apple Developer account and the
app is signed with the checked-in entitlements.

- [x] **Step 5: Commit final plan status or corrections**

```bash
git add docs/superpowers/specs/2026-07-31-icloud-sync-design.md docs/superpowers/plans/2026-07-31-icloud-sync.md
git commit -m "docs: record iCloud sync verification"
```

## Verification Record

- `app/scripts/check.sh` passes 256 Swift tests, the Release build, playback
  probes, diagnostics validation, and whitespace checks.
- The privacy scan confirms CloudKit records contain no username, password, or
  media path; raw paths are used only locally to derive opaque SHA-256 media IDs.
- Live two-device acceptance remains pending until `iCloud.dev.pierplayer.app`
  exists in the Apple Developer account and the app is signed with the checked-in
  entitlements.
