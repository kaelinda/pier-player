# Native SMB Source Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Connect Pier Player to SMB shares, browse directories, and expose persistent random-access file handles backed directly by pinned libsmb2 source.

**Architecture:** Build libsmb2 as an internal SwiftPM C target from a pinned Git submodule. Keep C pointers inside serial-executor native objects, expose only `MediaSourceKit` contracts, and inject an SMB client protocol for deterministic tests. Store passwords in Keychain and keep them out of source configuration and logs.

**Tech Stack:** Swift 6, Swift Package Manager, Swift Testing, libsmb2, Security/Keychain, SwiftUI

---

## File Map

- `Vendor/libsmb2`: pinned upstream LGPL-2.1+ Git submodule.
- `Package.swift`: `CLibSMB2`, `SMBSourceKit`, tests, and `SMBProbe` targets.
- `Sources/SMBSourceKit/SMBConnectionConfiguration.swift`: validated non-secret settings and path normalization.
- `Sources/SMBSourceKit/SMBCredential.swift`: in-memory credentials only.
- `Sources/SMBSourceKit/SMBClient.swift`: injectable client and file contracts.
- `Sources/SMBSourceKit/SMBMediaSource.swift`: `MediaSource` adapter.
- `Sources/SMBSourceKit/LibSMB2Client.swift`: context, directory, stat, and error mapping.
- `Sources/SMBSourceKit/LibSMB2File.swift`: persistent `smb2fh` and positional reads.
- `Sources/SMBSourceKit/KeychainCredentialStore.swift`: credential persistence.
- `Sources/SMBProbe/main.swift`: opt-in NAS diagnostic.
- `Sources/PierPlayerApp/`: source form and connection state.
- `Tests/SMBSourceKitTests/`: validation, source, credential, and lifecycle tests.

### Task 1: Pin and Compile libsmb2

**Files:**
- Create: `.gitmodules`
- Create: `Vendor/libsmb2` gitlink
- Modify: `Package.swift`
- Create: `Sources/SMBSourceKit/Module.swift`
- Create: `Tests/SMBSourceKitTests/ModuleSmokeTests.swift`

- [x] **Step 1: Add pinned upstream source**

Run:

```bash
git submodule add https://github.com/sahlberg/libsmb2.git Vendor/libsmb2
git -C Vendor/libsmb2 checkout aedafb2c8742c83188e27841e270fdaad6035d41
```

Expected: `Vendor/libsmb2` is a gitlink at the audited commit.

- [x] **Step 2: Add C and Swift targets**

Define `CLibSMB2` using `Vendor/libsmb2/lib`, public headers under `include`, Apple config headers, `_U_`, and `HAVE_CONFIG_H=1`. Define `SMBSourceKit` depending on `MediaSourceKit` and `CLibSMB2`, plus `SMBSourceKitTests`.

- [x] **Step 3: Add import smoke test**

Assert `SMBSourceKitModule.name == "SMBSourceKit"` and compile `import SMB2` in the module marker. The pinned upstream module map exports that name even though the SwiftPM target is called `CLibSMB2`.

- [x] **Step 4: Verify baseline**

Run: `swift test --filter smbSourceKitModuleLoads`

Expected: C sources compile and the smoke test passes.

- [x] **Step 5: Commit**

```bash
git add .gitmodules Vendor/libsmb2 Package.swift Sources/SMBSourceKit Tests/SMBSourceKitTests
git commit -m "build: pin libsmb2 source dependency"
```

### Task 2: Connection Configuration and Paths

**Files:**
- Create: `Sources/SMBSourceKit/SMBConnectionConfiguration.swift`
- Create: `Sources/SMBSourceKit/SMBCredential.swift`
- Create: `Sources/SMBSourceKit/SMBPath.swift`
- Create: `Tests/SMBSourceKitTests/SMBConnectionConfigurationTests.swift`

- [x] **Step 1: Write failing validation tests**

Cover hostname trimming, optional `smb://` removal, rejection of paths/ports embedded in host, share trimming, empty host/share/username rejection, domain normalization, encryption preservation, root path `/`, relative child paths, and rejection of `..` traversal.

- [x] **Step 2: Verify RED**

Run: `swift test --filter SMBConnectionConfigurationTests`

Expected: compile failure because configuration types are missing.

- [x] **Step 3: Implement value types**

`SMBConnectionConfiguration` contains source ID, display name, host, share, optional domain, and encryption flag. It contains no password. `SMBCredential` contains username/password in memory and does not conform to Codable. `SMBPath` emits normalized absolute paths accepted by libsmb2.

- [x] **Step 4: Verify GREEN**

Run: `swift test --filter SMBConnectionConfigurationTests`

Expected: all validation and path tests pass.

- [x] **Step 5: Commit**

```bash
git add Sources/SMBSourceKit Tests/SMBSourceKitTests
git commit -m "feat(smb): add validated connection settings"
```

### Task 3: Source Behavior Through an Injectable Client

**Files:**
- Create: `Sources/SMBSourceKit/SMBClient.swift`
- Create: `Sources/SMBSourceKit/SMBMediaSource.swift`
- Create: `Tests/SMBSourceKitTests/SMBMediaSourceTests.swift`

- [x] **Step 1: Write failing source tests**

Use an actor fake to prove connect/disconnect delegation, sorted directory mapping, file identity mapping, hidden dot-entry filtering, open-before-connect rejection, error mapping, and the returned file's random-read behavior.

- [x] **Step 2: Verify RED**

Run: `swift test --filter SMBMediaSourceTests`

Expected: compile failure because client/source types are missing.

- [x] **Step 3: Implement contracts and adapter**

Define `SMBClient`, `SMBClientFile`, `SMBDirectoryEntry`, and `SMBClientError`. `SMBMediaSource` is an actor conforming to `MediaSource`; it maps client errors without leaking host, share, username, or native error strings that may contain credentials.

- [x] **Step 4: Verify GREEN**

Run: `swift test --filter SMBMediaSourceTests`

Expected: all source behavior tests pass.

- [x] **Step 5: Commit**

```bash
git add Sources/SMBSourceKit Tests/SMBSourceKitTests
git commit -m "feat(smb): add media source adapter"
```

### Task 4: Native Persistent Context and File Handle

**Files:**
- Create: `Sources/SMBSourceKit/LibSMB2Error.swift`
- Create: `Sources/SMBSourceKit/LibSMB2Client.swift`
- Create: `Sources/SMBSourceKit/LibSMB2File.swift`
- Create: `Tests/SMBSourceKitTests/LibSMB2ValidationTests.swift`

- [x] **Step 1: Write failing boundary tests**

Test that native construction rejects invalid config before allocating a context, reads reject negative offsets/non-positive lengths/lengths above `UInt32.max`, EOF returns empty without calling C, and close is idempotent. Use an internal native API seam for lifecycle counters; do not require a NAS.

- [x] **Step 2: Verify RED**

Run: `swift test --filter LibSMB2ValidationTests`

Expected: compile failure because native types are missing.

- [x] **Step 3: Implement native client**

Create one libsmb2 context per `LibSMB2Client`, confined to a serial queue. Configure user, password, domain, signing, and optional seal before `smb2_connect_share`. Implement `smb2_opendir/readdir/closedir`, `smb2_stat`, and typed error conversion.

- [x] **Step 4: Implement persistent file**

Opening a file creates a separate connected context and one `smb2fh`. `read(at:length:)` calls positional `smb2_pread` on that handle. `close` calls `smb2_close`, disconnects, destroys the context, and can be repeated safely.

- [x] **Step 5: Verify GREEN**

Run: `swift test --filter LibSMB2ValidationTests`

Expected: lifecycle and validation tests pass without a NAS.

- [x] **Step 6: Commit**

```bash
git add Sources/SMBSourceKit Tests/SMBSourceKitTests
git commit -m "feat(smb): add persistent libsmb2 handles"
```

### Task 5: Keychain Credential Store

**Files:**
- Create: `Sources/SMBSourceKit/SMBCredentialStore.swift`
- Create: `Sources/SMBSourceKit/KeychainCredentialStore.swift`
- Create: `Tests/SMBSourceKitTests/KeychainCredentialStoreTests.swift`

- [x] **Step 1: Write failing credential tests**

Using a unique service name, verify save/load/update/delete, missing credential behavior, source-ID account keys, and cleanup. Inspect stored attributes to ensure host/share are not stored in the password payload.

- [x] **Step 2: Verify RED**

Run: `swift test --filter KeychainCredentialStoreTests`

Expected: compile failure because the store is missing.

- [x] **Step 3: Implement Security-framework store**

Persist username/domain as encoded metadata and password as Keychain secret data under an opaque source UUID. Use `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`; never use UserDefaults or CloudKit in this stage.

- [x] **Step 4: Verify GREEN**

Run: `swift test --filter KeychainCredentialStoreTests`

Expected: tests pass and remove their scoped Keychain items.

- [x] **Step 5: Commit**

```bash
git add Sources/SMBSourceKit Tests/SMBSourceKitTests Package.swift
git commit -m "feat(smb): store credentials in Keychain"
```

### Task 6: App Connection Form and Source List

**Files:**
- Modify: `Package.swift`
- Modify: `Sources/PierPlayerApp/AppModel.swift`
- Modify: `Sources/PierPlayerApp/RootView.swift`
- Create: `Sources/PierPlayerApp/AddSMBSourceView.swift`

- [x] **Step 1: Establish build RED**

Reference `AddSMBSourceView` and `SMBSourceKit` from the app before adding target dependency and view.

Run: `swift build --target PierPlayerApp`

Expected: compile failure for the missing view/module dependency.

- [x] **Step 2: Implement source workflow**

Add a modal form for display name, host, share, username, password, optional domain, and encryption. Validate before connect, store credentials only after successful connection, show actionable errors, and render connected sources in the sidebar. Do not persist non-secret source records beyond process lifetime in this stage.

- [x] **Step 3: Verify builds**

Run: `swift build --target PierPlayerApp` and `swift build -c release`

Expected: both succeed.

- [x] **Step 4: Commit**

```bash
git add Package.swift Sources/PierPlayerApp
git commit -m "feat(app): add SMB connection workflow"
```

### Task 7: SMB Diagnostic Command and Documentation

**Files:**
- Modify: `Package.swift`
- Create: `Sources/SMBProbe/main.swift`
- Create: `docs/benchmarks/smb-probe.md`
- Modify: `AGENTS.md`

- [x] **Step 1: Add diagnostic executable**

Read host/share/user/domain/encryption and optional file path from `PIER_SMB_*` environment variables. Read the password interactively without echo. List the root; when a file is supplied, perform aligned sequential reads through `CachedMediaReader` and print bytes, elapsed time, MiB/s, cache metrics, and no credentials.

- [x] **Step 2: Document exact use**

Document environment variables, interactive password behavior, example command, expected output fields, and how to record results in the reference environment sheet.

- [x] **Step 3: Verify help path without NAS**

Run: `swift run SMBProbe --help`

Expected: usage text and exit code 0 without reading credentials.

- [x] **Step 4: Commit**

```bash
git add Package.swift Sources/SMBProbe docs/benchmarks/smb-probe.md AGENTS.md
git commit -m "feat(smb): add NAS probe command"
```

### Task 8: Full Verification

**Files:**
- Modify only if verification exposes a defect.

- [x] **Step 1: Run all automated gates**

Run: `scripts/check.sh`

Expected: all tests pass, Release build succeeds, and whitespace check passes.

- [x] **Step 2: Repeat concurrency tests**

Run: `for run in 1 2 3 4 5; do swift test --skip-build >/dev/null || exit 1; done`

Expected: five successful runs.

- [x] **Step 3: Audit dependency and license state**

Run: `git submodule status`, `swift package show-dependencies`, and `rg -n "GPL|LGPL" Vendor/libsmb2/LICENCE* docs AGENTS.md`.

Expected: libsmb2 is pinned, LGPL terms are documented, and no GPL player dependency is present.

- [x] **Step 4: Commit plan completion**

Mark completed checkboxes and commit this plan.

```bash
git add docs/superpowers/plans/2026-07-28-smb-source.md
git commit -m "docs: add native SMB source plan"
```
