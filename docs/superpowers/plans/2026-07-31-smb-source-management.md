# SMB Source Management Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add safe information, editing, and removal actions for connected SMB sources in the macOS sidebar.

**Architecture:** Introduce small presentation models and native SwiftUI sheets around a shared SMB form. Inject media-source construction into `AppModel`, connect replacements before persistence, and use a monotonic revision to invalidate source-dependent views after mutations.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing, Swift Package Manager, MediaSourceKit, SMBSourceKit

---

### Task 1: Persist Source Replacements

**Files:**
- Modify: `app/Shared/Sources/SMBSourceKit/SMBSourceStore.swift`
- Create: `app/Shared/Tests/SMBSourceKitTests/SMBSourceStoreTests.swift`

- [x] **Step 1: Write failing store tests**

Cover replacement without reordering and rejection of an unknown UUID.

- [x] **Step 2: Run the focused test and verify red**

Run: `cd app && swift test --filter SMBSourceStoreTests`

Expected: failure because `SMBSourceStore.update` and the isolated store initializer do not exist.

- [x] **Step 3: Add minimal store update support**

Add `SMBSourceStoreError.sourceNotFound`, an internal `init(fileURL:)`, and `update(_:)` that replaces the matching item at its existing index.

- [ ] **Step 4: Verify the focused store tests pass**

Run: `cd app && swift test --filter SMBSourceStoreTests`

Expected: both tests pass.

### Task 2: Define Source Management Presentation

**Files:**
- Create: `app/macOS/Sources/PierPlayerApp/SourceManagementView.swift`
- Modify: `app/macOS/Sources/PierPlayerApp/AddSMBSourceView.swift`
- Modify: `app/macOS/Tests/PierPlayerAppTests/UIRenderingTests.swift`

- [x] **Step 1: Write failing presentation and rendering tests**

Assert the context action titles, derived address/domain/encryption copy, password-preserving edit draft, and fixed sheet render sizes.

- [x] **Step 2: Run tests and verify red**

Run: `cd app && swift test --filter sourceManagementPresentsCompleteActionsAndSafeEditDefaults`

Expected: compile failure because the presentation types and views do not exist.

- [ ] **Step 3: Implement presentation models and shared form**

Add `SourceManagementAction`, `SMBSourceDetails`, and `SMBSourceFormDraft`. Extract the grouped source, credentials, security, and inline error sections into a shared form used by add and edit sheets.

- [ ] **Step 4: Implement information and edit sheets**

Build native header, grouped content, keyboard actions, loading state, validation, inline errors, accessibility labels, and fixed 520 point sheet widths.

- [ ] **Step 5: Verify focused rendering tests pass**

Run: `cd app && PIER_WRITE_SNAPSHOTS=1 swift test --filter 'sourceInformationSheetRendersAtDesignedSize|editSourceSheetRendersAtDesignedSize'`

Expected: both snapshots render at their requested dimensions.

### Task 3: Replace Live Sources Atomically

**Files:**
- Modify: `app/macOS/Sources/PierPlayerApp/AppModel.swift`
- Create: `app/macOS/Tests/PierPlayerAppTests/SourceManagementTests.swift`

- [x] **Step 1: Write failing model tests**

Use an injected fake `MediaSource` and in-memory credential store to cover password preservation, connection replacement, disconnect timing, revision changes, and failed-edit isolation.

- [x] **Step 2: Run tests and verify red**

Run: `cd app && swift test --filter 'editingSourcePreservesPasswordAndReplacesTheLiveConnection|failedSourceEditKeepsTheExistingConnectionAndConfiguration'`

Expected: compile failure because model injection, username, revision, and update APIs do not exist.

- [ ] **Step 3: Add source construction injection and revision state**

Change `ConnectedSource.source` to `any MediaSource`, retain its username, route live and fake construction through one factory, and increment `sourceRevision` after add, update, and remove.

- [ ] **Step 4: Implement safe update sequencing**

Load the previous password, validate inputs, connect the replacement, persist credential and metadata with rollback, replace the connected source in place, then disconnect the previous source.

- [ ] **Step 5: Verify model tests pass**

Run: `cd app && swift test --filter 'editingSourcePreservesPasswordAndReplacesTheLiveConnection|failedSourceEditKeepsTheExistingConnectionAndConfiguration'`

Expected: both tests pass.

### Task 4: Wire Sidebar Actions and Reloads

**Files:**
- Modify: `app/macOS/Sources/PierPlayerApp/RootView.swift`
- Modify: `app/macOS/Sources/PierPlayerApp/SourceBrowserView.swift`
- Modify: `app/macOS/Sources/PierPlayerApp/MediaLibraryView.swift`
- Modify: `app/macOS/Tests/PierPlayerAppTests/UIRenderingTests.swift`

- [ ] **Step 1: Add sheet routing and context commands**

Pass information and edit callbacks into `RootSidebarContent`, render native labels and icons, and route the selected source details to the matching sheet.

- [ ] **Step 2: Invalidate source-dependent views**

Include `sourceRevision` in the source browser identity and media-library reload request while preserving the source UUID selection.

- [ ] **Step 3: Run focused app tests**

Run: `cd app && swift test --filter PierPlayerAppTests`

Expected: all app tests pass.

### Task 5: Verify and Deliver

**Files:**
- Verify all changed files and generated snapshots.

- [ ] **Step 1: Run the project quality gate**

Run: `cd app && scripts/check.sh`

Expected: all tests pass, the Release build succeeds, and whitespace checks are clean.

- [ ] **Step 2: Inspect both sheets and the context menu**

Launch `swift run PierPlayerApp`, confirm menu order, edit progress/error behavior, full content visibility, dark-mode contrast, and no password disclosure.

- [ ] **Step 3: Review the final diff**

Run: `git diff --check && git status --short && git diff --stat`

Expected: no whitespace errors and no unrelated paths staged.

- [ ] **Step 4: Commit, update from main, and verify again**

Use focused Conventional Commits, fetch `origin`, merge current `origin/main` if needed, and rerun `cd app && scripts/check.sh` after integration.

- [ ] **Step 5: Push and create a ready PR**

Push `codex/source-management` and create a PR targeting `main` with scope, tradeoffs, screenshots, and verification commands.
