# Media Library Home Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a VidHub-inspired, real-data media library home that scans connected SMB sources within strict limits and keeps the existing file browser and player usable.

**Architecture:** Add a macOS-only breadth-first catalog scanner and observable catalog model, keeping SMB and playback APIs unchanged. Render the resulting in-memory snapshot through focused SwiftUI shelf, poster, source-card, and state views; route both sidebar and source cards through one typed root selection.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing, existing `MediaSourceKit` and `SMBSourceKit`, AppKit offscreen snapshots.

---

### Task 1: Bounded Media Library Scanner

**Files:**
- Create: `app/macOS/Sources/PierPlayerApp/MediaLibraryCatalog.swift`
- Create: `app/macOS/Tests/PierPlayerAppTests/MediaLibraryScannerTests.swift`

- [ ] **Step 1: Write failing traversal tests**

Add tests that construct `MediaLibrarySource` values with async directory-map closures. Cover supported-file filtering, breadth-first depth 3, the 200-video cap, retained partial results on a nested listing failure, and cancellation before another directory read.

```swift
@Test func scanStopsAtMaximumDepth() async throws {
    let source = MediaLibrarySource.fixture([
        "/": [.directory("one", path: "/one")],
        "/one": [.directory("two", path: "/one/two")],
        "/one/two": [.directory("three", path: "/one/two/three")],
        "/one/two/three": [
            .video("included.mp4", path: "/one/two/three/included.mp4"),
            .directory("four", path: "/one/two/three/four"),
        ],
        "/one/two/three/four": [.video("excluded.mp4", path: "/one/two/three/four/excluded.mp4")],
    ])

    let result = try await MediaLibraryScanner().scan(source: source)

    #expect(result.items.map(\.media.name) == ["included.mp4"])
}
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run: `swift test --filter MediaLibraryScannerTests`

Expected: FAIL because `MediaLibrarySource`, `MediaLibraryScanner`, and their scan result do not exist.

- [ ] **Step 3: Implement the minimal scanner contract**

Create these production types and a breadth-first traversal:

```swift
import Foundation
import MediaSourceKit

struct MediaLibrarySource: Sendable {
    let id: UUID
    let displayName: String
    let listDirectory: @Sendable (String) async throws -> [MediaSourceItem]
}

struct MediaLibrarySourceSummary: Identifiable, Equatable, Sendable {
    let id: UUID
    let displayName: String
}

struct MediaLibraryItem: Identifiable, Hashable, Sendable {
    let sourceID: UUID
    let sourceName: String
    let media: MediaSourceItem

    var id: String { sourceID.uuidString + ":" + media.path }
}

struct MediaLibraryScanLimits: Equatable, Sendable {
    var maximumDepth = 3
    var maximumVideoCount = 200
}

struct MediaLibraryScanFailure: Identifiable, Equatable, Sendable {
    let sourceID: UUID
    let sourceName: String
    var id: UUID { sourceID }
}

struct MediaLibraryScanResult: Equatable, Sendable {
    var items: [MediaLibraryItem]
    var failure: MediaLibraryScanFailure?
}

struct MediaLibraryScanner: Sendable {
    var limits = MediaLibraryScanLimits()

    func scan(source: MediaLibrarySource) async throws -> MediaLibraryScanResult {
        var queue = [(path: "/", depth: 0)]
        var cursor = 0
        var videos: [MediaLibraryItem] = []

        while cursor < queue.count, videos.count < limits.maximumVideoCount {
            try Task.checkCancellation()
            let directory = queue[cursor]
            cursor += 1

            let entries: [MediaSourceItem]
            do {
                entries = try await source.listDirectory(directory.path)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return MediaLibraryScanResult(
                    items: videos,
                    failure: MediaLibraryScanFailure(sourceID: source.id, sourceName: source.displayName)
                )
            }

            for entry in entries {
                try Task.checkCancellation()
                if entry.isSupportedVideo {
                    videos.append(MediaLibraryItem(sourceID: source.id, sourceName: source.displayName, media: entry))
                    if videos.count == limits.maximumVideoCount { break }
                } else if entry.kind == .directory, directory.depth < limits.maximumDepth {
                    queue.append((entry.path, directory.depth + 1))
                }
            }
        }

        return MediaLibraryScanResult(items: videos, failure: nil)
    }
}
```

- [ ] **Step 4: Run scanner tests and verify GREEN**

Run: `swift test --filter MediaLibraryScannerTests`

Expected: all scanner tests pass with no unexpected warnings.

- [ ] **Step 5: Commit the scanner increment**

```bash
git add app/macOS/Sources/PierPlayerApp/MediaLibraryCatalog.swift app/macOS/Tests/PierPlayerAppTests/MediaLibraryScannerTests.swift
git commit -m "feat(macOS): add bounded media scanner"
```

### Task 2: Presentation Projection And Stable Artwork

**Files:**
- Create: `app/macOS/Sources/PierPlayerApp/MediaLibraryPresentation.swift`
- Create: `app/macOS/Tests/PierPlayerAppTests/MediaLibraryPresentationTests.swift`

- [ ] **Step 1: Write failing projection tests**

Cover case-insensitive search across file and source names, extension-free display titles, recent ordering with nil dates last, alphabetical all-video ordering, and stable poster style selection.

```swift
@Test func searchMatchesTitleAndSourceNameCaseInsensitively() {
    let items = [
        MediaLibraryItem.fixture(name: "Arrival.mkv", sourceName: "Cinema"),
        MediaLibraryItem.fixture(name: "Holiday.mp4", sourceName: "Family NAS"),
    ]

    #expect(MediaLibraryPresentation.filtered(items, query: "ARR").map(\.media.name) == ["Arrival.mkv"])
    #expect(MediaLibraryPresentation.filtered(items, query: "family").map(\.media.name) == ["Holiday.mp4"])
}

@Test func posterStyleIsStableForTheSameIdentity() {
    let identity = "source:/Movies/Arrival.mkv"
    #expect(MediaLibraryPresentation.posterStyle(for: identity) == MediaLibraryPresentation.posterStyle(for: identity))
}
```

- [ ] **Step 2: Run projection tests and verify RED**

Run: `swift test --filter MediaLibraryPresentationTests`

Expected: FAIL because `MediaLibraryPresentation` and `MediaPosterStyle` do not exist.

- [ ] **Step 3: Implement pure presentation functions**

```swift
import Foundation

struct MediaPosterStyle: Equatable, Sendable {
    let paletteIndex: Int
    let symbolIndex: Int
}

enum MediaLibraryPresentation {
    static let paletteCount = 8
    static let symbolCount = 6

    static func filtered(_ items: [MediaLibraryItem], query: String) -> [MediaLibraryItem] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return items }
        return items.filter {
            $0.media.name.localizedCaseInsensitiveContains(term)
                || $0.sourceName.localizedCaseInsensitiveContains(term)
        }
    }

    static func displayTitle(for item: MediaLibraryItem) -> String {
        let title = (item.media.name as NSString).deletingPathExtension
        return title.isEmpty ? item.media.name : title
    }

    static func recentlyAdded(_ items: [MediaLibraryItem], limit: Int = 12) -> [MediaLibraryItem] {
        Array(items.sorted {
            switch ($0.media.modifiedAt, $1.media.modifiedAt) {
            case let (lhs?, rhs?): lhs > rhs
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): displayTitle(for: $0).localizedCaseInsensitiveCompare(displayTitle(for: $1)) == .orderedAscending
            }
        }.prefix(limit))
    }

    static func allVideos(_ items: [MediaLibraryItem]) -> [MediaLibraryItem] {
        items.sorted { displayTitle(for: $0).localizedCaseInsensitiveCompare(displayTitle(for: $1)) == .orderedAscending }
    }

    static func posterStyle(for identity: String) -> MediaPosterStyle {
        let hash = identity.utf8.reduce(UInt64(14_695_981_039_346_656_037)) {
            ($0 ^ UInt64($1)) &* 1_099_511_628_211
        }
        return MediaPosterStyle(
            paletteIndex: Int(hash % UInt64(paletteCount)),
            symbolIndex: Int((hash / UInt64(paletteCount)) % UInt64(symbolCount))
        )
    }
}
```

- [ ] **Step 4: Run projection tests and verify GREEN**

Run: `swift test --filter MediaLibraryPresentationTests`

Expected: all projection tests pass.

- [ ] **Step 5: Commit the presentation increment**

```bash
git add app/macOS/Sources/PierPlayerApp/MediaLibraryPresentation.swift app/macOS/Tests/PierPlayerAppTests/MediaLibraryPresentationTests.swift
git commit -m "feat(macOS): add media library projections"
```

### Task 3: Catalog Loading State

**Files:**
- Modify: `app/macOS/Sources/PierPlayerApp/MediaLibraryCatalog.swift`
- Modify: `app/macOS/Sources/PierPlayerApp/AppModel.swift`
- Create: `app/macOS/Tests/PierPlayerAppTests/MediaLibraryViewModelTests.swift`

- [ ] **Step 1: Write failing catalog-state tests**

Test that reloading combines two successful sources, publishes a sanitized failure for a failing source while retaining successful videos, and leaves loading state after cancellation.

```swift
@MainActor
@Test func reloadKeepsSuccessfulSourcesWhenAnotherSourceFails() async {
    let good = MediaLibrarySource.fixture(["/": [.video("Arrival.mkv", path: "/Arrival.mkv")]])
    let bad = MediaLibrarySource.failing(displayName: "Archive")
    let model = MediaLibraryViewModel()

    await model.reload(sources: [good, bad])

    #expect(model.snapshot.items.map(\.media.name) == ["Arrival.mkv"])
    #expect(model.snapshot.failures.map(\.sourceName) == ["Archive"])
    #expect(model.isLoading == false)
}
```

- [ ] **Step 2: Run catalog-state tests and verify RED**

Run: `swift test --filter MediaLibraryViewModelTests`

Expected: FAIL because `MediaLibraryViewModel` and `MediaLibrarySnapshot` do not exist.

- [ ] **Step 3: Implement catalog snapshots and two-source batches**

Append the observable model to `MediaLibraryCatalog.swift`:

```swift
import SwiftUI

struct MediaLibrarySnapshot: Equatable, Sendable {
    var items: [MediaLibraryItem] = []
    var failures: [MediaLibraryScanFailure] = []
}

@MainActor
final class MediaLibraryViewModel: ObservableObject {
    @Published private(set) var snapshot: MediaLibrarySnapshot
    @Published private(set) var isLoading = false
    private let scanner: MediaLibraryScanner

    init(scanner: MediaLibraryScanner = MediaLibraryScanner(), snapshot: MediaLibrarySnapshot = MediaLibrarySnapshot()) {
        self.scanner = scanner
        self.snapshot = snapshot
    }

    func reload(sources: [MediaLibrarySource]) async {
        isLoading = true
        snapshot = MediaLibrarySnapshot()
        defer { isLoading = false }

        for start in stride(from: 0, to: sources.count, by: 2) {
            guard !Task.isCancelled else { return }
            let end = min(start + 2, sources.count)
            let batch = Array(sources[start..<end])
            let scanner = scanner
            let results = await withTaskGroup(of: MediaLibraryScanResult?.self) { group in
                for source in batch {
                    group.addTask { try? await scanner.scan(source: source) }
                }
                return await group.reduce(into: []) { $0.append($1) }
            }
            guard !Task.isCancelled else { return }
            for result in results.compactMap({ $0 }) {
                snapshot.items.append(contentsOf: result.items)
                if let failure = result.failure { snapshot.failures.append(failure) }
            }
        }
    }
}
```

Expose the connected sources from `AppModel` without exposing native handles to the UI:

```swift
var mediaLibrarySources: [MediaLibrarySource] {
    sources.map { connected in
        let source = connected.source
        return MediaLibrarySource(id: connected.id, displayName: connected.displayName) { path in
            try await source.list(directory: path)
        }
    }
}

var mediaLibrarySourceSummaries: [MediaLibrarySourceSummary] {
    sources.map { MediaLibrarySourceSummary(id: $0.id, displayName: $0.displayName) }
}
```

- [ ] **Step 4: Run catalog-state tests and verify GREEN**

Run: `swift test --filter MediaLibraryViewModelTests`

Expected: all catalog-state tests pass.

- [ ] **Step 5: Commit the catalog-state increment**

```bash
git add app/macOS/Sources/PierPlayerApp/MediaLibraryCatalog.swift app/macOS/Sources/PierPlayerApp/AppModel.swift app/macOS/Tests/PierPlayerAppTests/MediaLibraryViewModelTests.swift
git commit -m "feat(macOS): load media library catalog"
```

### Task 4: Media Library SwiftUI And Root Navigation

**Files:**
- Create: `app/macOS/Sources/PierPlayerApp/MediaLibraryView.swift`
- Modify: `app/macOS/Sources/PierPlayerApp/RootView.swift`
- Modify: `app/macOS/Sources/PierPlayerApp/PierPlayerApp.swift`
- Modify: `app/macOS/Tests/PierPlayerAppTests/UIRenderingTests.swift`

- [ ] **Step 1: Write failing navigation and rendering tests**

Add a pure selection reconciliation test and offscreen render tests for populated media content at both target sizes.

```swift
@Test func removedSelectedSourceReturnsToLibrary() {
    let missing = UUID()
    #expect(SidebarDestination.source(missing).reconciled(with: []) == .library)
}

@MainActor
@Test func mediaLibraryRendersAtDefaultWindowSize() throws {
    let size = CGSize(width: 1120, height: 720)
    let image = try render(
        MediaLibraryContentView(
            snapshot: .fixture,
            sources: [MediaLibrarySourceSummary(id: UUID(), displayName: "Cinema")],
            isLoading: false,
            query: "",
            play: { _ in },
            openSource: { _ in },
            addSource: {}
        )
        .frame(width: size.width, height: size.height)
        .environment(\.colorScheme, .dark),
        at: size
    )
    #expect(image.size == size)
    #expect(image.tiffRepresentation?.isEmpty == false)
    try writeSnapshotIfRequested(image, name: "media-library-default")
}
```

- [ ] **Step 2: Run UI tests and verify RED**

Run: `swift test --filter 'removedSelectedSourceReturnsToLibrary|mediaLibraryRendersAtDefaultWindowSize'`

Expected: FAIL because the typed destination and media library content view do not exist.

- [ ] **Step 3: Implement the typed navigation shell**

In `RootView.swift`, replace source-only selection with:

```swift
enum SidebarDestination: Hashable {
    case library
    case source(UUID)

    func reconciled(with sourceIDs: [UUID]) -> SidebarDestination {
        guard case .source(let id) = self, !sourceIDs.contains(id) else { return self }
        return .library
    }
}

@State private var selection = SidebarDestination.library
```

Render Media Library in the first sidebar section, tag sources with `.source(source.id)`, keep the add/remove controls, and switch the detail between `MediaLibraryView` and the existing `SourceBrowserView`. Source removal reconciles selection back to `.library`.

- [ ] **Step 4: Implement focused media library views**

Create `MediaLibraryView.swift` with the following orchestration and rendering contract:

```swift
struct MediaLibraryView: View {
    @EnvironmentObject private var appModel: AppModel
    @Binding var selection: SidebarDestination
    let addSource: () -> Void
    @StateObject private var libraryModel = MediaLibraryViewModel()
    @State private var query = ""
    @State private var refreshGeneration = 0
    @State private var selectedItem: MediaLibraryItem?

    var body: some View {
        MediaLibraryContentView(
            snapshot: libraryModel.snapshot,
            sources: appModel.mediaLibrarySourceSummaries,
            isLoading: libraryModel.isLoading || appModel.isRestoring,
            query: query,
            play: { selectedItem = $0 },
            openSource: { selection = .source($0) },
            addSource: addSource
        )
        .navigationTitle("Media Library")
        .searchable(text: $query, placement: .toolbar, prompt: "Search Library")
        .toolbar {
            Button { refreshGeneration &+= 1 } label: { Image(systemName: "arrow.clockwise") }
                .help("Refresh Library")
                .disabled(libraryModel.isLoading)
        }
        .task(id: MediaLibraryLoadRequest(sourceIDs: appModel.sources.map(\.id), generation: refreshGeneration)) {
            await libraryModel.reload(sources: appModel.mediaLibrarySources)
        }
        .sheet(item: $selectedItem) { item in
            if let source = appModel.source(id: item.sourceID) {
                VideoPlayerSheet(item: item.media, source: source.source)
            }
        }
    }
}

private struct MediaLibraryLoadRequest: Equatable {
    let sourceIDs: [UUID]
    let generation: Int
}
```

`MediaLibraryContentView` accepts `snapshot`, `[MediaLibrarySourceSummary]`, `isLoading`, `query`, and its three callbacks. It owns no asynchronous work. It derives filtered, recent, and alphabetical arrays through `MediaLibraryPresentation`, then renders:

- `LibrarySectionHeader` with compact title and count.
- `RecentMediaCard` in a horizontal `LazyHStack`, fixed to 248 x 140.
- `PosterMediaCard` in a horizontal `LazyHStack`, fixed to 138 x 246 including labels and a 2:3 poster.
- `MediaSourceCard` in a horizontal `LazyHStack`, fixed to 220 x 78.
- `MediaArtwork` using eight varied two-color palettes and six SF Symbols indexed by `MediaPosterStyle`.
- `ContentUnavailableView` for no source, no video, and search-empty states.
- A compact warning row for sanitized per-source failures.

Use 6-point card corners, 24-point page insets, fixed aspect ratios, `.buttonStyle(.plain)`, one-line titles, source subtitles, combined accessibility labels, and no decorative outer cards around page sections.

- [ ] **Step 5: Apply the dark media workspace and run UI tests**

Add `.preferredColorScheme(.dark)` to the `RootView` in `PierPlayerApp.swift`, then run:

Run: `PIER_UI_SNAPSHOT_DIR=/tmp/pier-player-ui swift test --filter PierPlayerAppTests`

Expected: application, root, sheet, minimum media-library, and default media-library tests all pass and write nonempty PNG snapshots.

- [ ] **Step 6: Commit the SwiftUI increment**

```bash
git add app/macOS/Sources/PierPlayerApp/MediaLibraryView.swift app/macOS/Sources/PierPlayerApp/RootView.swift app/macOS/Sources/PierPlayerApp/PierPlayerApp.swift app/macOS/Tests/PierPlayerAppTests/UIRenderingTests.swift
git commit -m "feat(macOS): add media library home"
```

### Task 5: Full Verification And Visual Review

**Files:**
- Modify only files required by defects found during verification.

- [ ] **Step 1: Run focused tests and full checks**

```bash
swift test --filter PierPlayerAppTests
scripts/check.sh
git diff --check
```

Expected: all tests pass, Release build succeeds, and whitespace check is clean.

- [ ] **Step 2: Generate fresh UI snapshots**

```bash
SNAPSHOT_DIR=$(mktemp -d /tmp/pier-player-ui.XXXXXX)
PIER_UI_SNAPSHOT_DIR="$SNAPSHOT_DIR" swift test --filter 'rootViewRendersAtMinimumWindowSize|mediaLibraryRendersAtMinimumWindowSize|mediaLibraryRendersAtDefaultWindowSize'
```

Expected: `root-view.png`, `media-library-minimum.png`, and `media-library-default.png` are present and nonempty.

- [ ] **Step 3: Inspect layout and pixel content**

Open each image and verify the media library is nonblank, its selected sidebar item is visible, cards retain their aspect ratios, text does not overlap, minimum-size content remains usable, and the default viewport hints at the next section. Use a bitmap pixel scan to confirm each image has substantial non-background variation.

- [ ] **Step 4: Launch and exercise the application shell**

Run: `swift run PierPlayerApp`

Expected: the app opens as a foreground macOS window on Media Library; Add Source, source navigation, search, refresh, context removal, and empty/error states remain interactive. Close the launched process after evidence is captured.

- [ ] **Step 5: Review scope and commit any verification fixes**

```bash
git status --short
git diff --check
git add app/macOS/Sources/PierPlayerApp app/macOS/Tests/PierPlayerAppTests
git commit -m "fix(macOS): polish media library layout"
```

Skip the final commit if verification required no code changes. Confirm `.vscode/`, `.superpowers/`, `.build/`, snapshots, media, and credentials are absent from staged content.
