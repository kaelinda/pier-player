# Pier Player Media Library Home Design

- **Date:** 2026-07-30
- **Status:** Approved for automatic execution
- **Platform:** macOS
- **Reference:** VidHub's compact sidebar and media-shelf hierarchy

## 1. Goal

Add a media-first home screen to the existing macOS application. The screen should carry the compact density, dark content surfaces, horizontal media shelves, search placement, and source-oriented sidebar hierarchy visible in the supplied VidHub reference while remaining honest about Pier Player's current capabilities.

The home screen uses real connected SMB data. It must not ship demo titles, scraped artwork, inert favorites, fake resume progress, or other controls without backing behavior.

## 2. Scope

### Included

- Make Media Library the default destination at launch.
- Keep each connected SMB source as a direct sidebar destination.
- Scan connected sources in the background with explicit limits.
- Show Recently Added, All Videos, and File Sources sections.
- Filter discovered videos with toolbar search.
- Generate deterministic, cinema-like placeholder artwork from file identity without reading video bytes.
- Open discovered videos through the existing player sheet.
- Support loading, partial-error, empty, no-source, refresh, and cancellation states.
- Preserve the current add/remove source and hierarchical file browser workflows.

### Excluded

- Persistent media indexing or an on-disk catalog database.
- Poster or metadata downloads.
- Video-frame thumbnail extraction.
- Favorites, watched state, resume history, playlists, ratings, and genre filters.
- Changes to playback buffering, demuxing, decoding, credentials, or source persistence.
- Recursive folder presentation inside the home screen.

## 3. Chosen Direction

Three directions were considered:

1. **Direct VidHub replica:** closest visual match, but it would expose unsupported navigation and empty feature shells.
2. **Real media shelves:** adapts the reference hierarchy to real SMB content and existing playback. This is the selected direction.
3. **Source dashboard:** simplest and cheapest to load, but it keeps files rather than media as the primary visual signal.

The selected design preserves the useful patterns from the reference without copying its brand, content, or unsupported behavior.

## 4. Navigation And Layout

`RootView` continues to use `NavigationSplitView`.

The sidebar has two groups:

- **Library:** a selected-by-default Media Library row.
- **File Sources:** connected SMB sources, with their existing removal context menu.

The bottom source-status and add-source control remain available. Source restoration must not replace the selected Media Library destination.

The media library detail uses a vertically scrolling page with compact horizontal sections:

- **Recently Added:** up to 12 videos sorted by modification date, newest first. Items without dates follow dated items.
- **All Videos:** the full in-memory result, sorted by display name.
- **File Sources:** connected source cards that navigate to the source browser.

The toolbar includes search and refresh controls. Search filters video titles and source names in memory and does not trigger new network reads.

At the application's 820 x 560 minimum size, cards remain within fixed responsive bounds and sections scroll horizontally rather than squeezing labels. At the default 1120 x 720 size, the composition should show the current shelf plus a clear hint of the next section.

## 5. Catalog Model

Add a macOS-only catalog layer because this is presentation-oriented discovery, not the cross-platform playback contract.

### `MediaLibraryItem`

Contains the source ID, source display name, and existing `MediaSourceItem`. Its stable identity combines source ID and normalized path so identical paths on different sources do not collide.

### `MediaLibraryScanLimits`

Defaults:

- Root directory depth is 0.
- Descend through directories up to depth 3.
- Collect at most 200 supported videos per source.

### `MediaLibraryScanner`

Performs breadth-first directory traversal. It accepts an asynchronous directory-listing closure so boundary, ordering, cancellation, and error behavior can be tested without a live NAS.

The scanner checks cancellation before each directory read and while processing entries. It never opens media files. A directory listing failure ends only that source's scan and retains videos already found for that source.

### `MediaLibraryViewModel`

Runs source scans with at most two sources active at once. It publishes one snapshot containing discovered items, per-source errors, and loading state. Refresh cancels the previous generation before starting another. Results live only for the process lifetime.

## 6. Artwork

Artwork is generated locally from stable file identity:

- A deterministic hash selects one of several deliberately varied color pairs and SF Symbols.
- A 2:3 poster uses a solid base, one geometric color field, a centered media symbol, a small extension label, and the title below the poster.
- Landscape emphasis cards use the same identity and palette without introducing a separate asset pipeline.

Artwork must remain stable across launches and must not use Swift's randomized `Hasher` output.

## 7. Interaction And Data Flow

1. The application restores connected sources as it does today.
2. The Media Library view observes the source IDs and starts a new scan generation when they change.
3. Each source is traversed within the configured limits.
4. Partial results are published as source scans finish.
5. Search derives filtered shelves from the current snapshot.
6. Selecting a video presents the existing `VideoPlayerSheet` with the matching `SMBMediaSource`.
7. Selecting a source card or sidebar source opens the existing `SourceBrowserView` at `/`.

## 8. States And Errors

- **Restoring:** show a compact centered progress state while stored sources are being restored.
- **No sources:** show a direct Add Source action.
- **Scanning with no results:** show progress without resizing the page shell.
- **Partial failure:** keep successful content visible and show a compact warning naming the affected source, without exposing hosts or paths.
- **No videos:** explain that no supported videos were found within the scan boundary and retain source navigation.
- **Search empty:** show a local no-results state and preserve the search field.

Refresh is disabled while the active generation is running. Leaving the home screen cancels active work. Returning may trigger a fresh in-memory scan.

## 9. Testing And Verification

Follow red-green-refactor for behavior changes.

Automated coverage:

- Breadth-first traversal respects maximum depth.
- Each source stops after 200 collected videos.
- Unsupported files are excluded.
- Directory errors retain partial results and identify the affected source.
- Cancellation stops additional directory reads.
- Stable artwork selection is deterministic.
- Search matches title and source name case-insensitively.
- Root view and media library render at minimum and default window sizes.

Verification:

- Run focused macOS application tests after each red-green cycle.
- Run `swift test` and `scripts/check.sh` from `app/`.
- Generate offscreen snapshots at 820 x 560 and 1120 x 720.
- Inspect snapshots for nonblank content, clipping, overlap, truncation, sidebar selection, card aspect ratios, and visible next-section context.
- Launch the application shell and capture an on-screen screenshot when the environment permits.

## 10. Delivery

Implement on `codex/media-library-home`. Keep `.vscode/`, generated visual-companion files, build products, credentials, and media files out of commits. Use focused Conventional Commits and leave integration or PR delivery for the user's final choice.
