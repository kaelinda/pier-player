# Progressive AVFoundation Playback Design

**Date:** 2026-07-30
**Status:** Superseded by the completed broad-format FFmpeg playback pipeline

This document records the temporary AVFoundation bridge that landed on `main`.
The bridge implementation was removed when the broad-format pipeline was merged
because the latter streams MP4, M4V, MOV, MKV, and the wider supported format
matrix through one owned playback path.

## Purpose

Pier Player currently reads an entire SMB video into one `Data`, writes that data
to a temporary file, and only then creates an `AVPlayer`. Startup time therefore
scales with the complete file size and peak memory can approach the file size.

This exploration replaces that path for AVFoundation-compatible containers with
bounded random-access loading. Playback may begin after AVPlayer has requested
only the metadata and initial media ranges it needs. The complete remote file is
never accumulated in memory or copied to a temporary file.

This is a deliberately narrow bridge to the owned FFmpeg pipeline specified in
`2026-07-30-broad-format-playback-design.md`. It improves large MP4, M4V, and MOV
startup now without claiming MKV support or duplicating demux, decode, render, and
track-selection work planned for FFmpeg.

## Approaches Considered

### AVAssetResourceLoader Bridge (Selected)

Create an `AVURLAsset` with a private URL scheme and answer AVFoundation byte-range
requests from the existing `MediaReadableFile` contract. This has no new binary or
network dependency, preserves AVPlayer controls, supports random seeks, and keeps
each allocation within an explicit chunk limit.

### Local HTTP Range Proxy

Expose the remote file through a loopback HTTP server and let AVPlayer issue range
requests. This would have similar format support, but would add HTTP parsing, port
ownership, local-server security, and another lifecycle boundary without improving
the playback result.

### Complete FFmpeg Pipeline

Implement custom AVIO, demux, decode, synchronized rendering, and track controls.
This is the long-term cross-container solution, but the repository does not yet
contain the pinned FFmpeg artifacts or those production modules. It remains the
separate broad-format milestone.

## Scope

Included:

- macOS playback from the existing SMB browser.
- MP4, M4V, and MOV containers supported by AVFoundation.
- Lazy random-access reads through `MediaReadableFile`.
- A fixed maximum upstream read size of 512 KiB.
- Byte-range requests, reads to EOF, cancellation, seek-driven request replacement,
  and deterministic file closure.
- AVPlayer's existing playback, seek, volume, and full-screen controls.
- Unit tests proving bounded reads, offsets, EOF behavior, cancellation, and close.

Excluded:

- MKV and other containers that AVFoundation cannot demux.
- FFmpeg, software decode, custom audio/video renderers, subtitle handling, and
  selectable tracks.
- Persistent downloads or disk cache.
- Claims about HDR, first-frame latency, or real-NAS throughput without hardware
  measurements.

The browser must not present MKV as playable through this bridge. The extension set
can expand again when the FFmpeg pipeline becomes the selected playback backend.

## Architecture

```text
VideoPlayerModel
  -> open MediaReadableFile
  -> ProgressivePlaybackSession
       -> AVURLAsset(private scheme)
       -> AVAssetResourceLoader delegate
            -> ProgressiveMediaLoader actor
                 -> MediaReadableFile.read(offset, <= 512 KiB)
       -> AVPlayerItem
       -> AVPlayerView
```

`ProgressiveMediaLoader` is independent of AVFoundation request objects. It accepts
an offset and an optional requested length, emits ordered `Data` chunks, and owns
the readable file's close boundary. Its actor isolation serializes state changes
while the concrete SMB file preserves its own native connection isolation.

`ProgressiveMediaResourceLoader` adapts AVFoundation content-information and data
requests to that actor. It tracks one task per loading request, finishes each request
exactly once, and cancels the corresponding task when AVFoundation cancels a range.

`ProgressivePlaybackSession` retains the asset, loader delegate, player item, and
player together. Stopping pauses playback, cancels resource loading, closes the
remote file, and then releases the session from the view model.

## Data Flow

1. The user selects an AVFoundation-compatible video.
2. `VideoPlayerModel` opens one persistent SMB readable file.
3. The session creates a private asset URL that keeps only the original extension.
4. AVFoundation asks for content length/type and one or more byte ranges.
5. The loader clamps every range to the known file size.
6. Each range is read sequentially in chunks no larger than 512 KiB and immediately
   passed to AVFoundation.
7. AVPlayer may begin decoding and presenting before later ranges are requested.
8. A seek cancels obsolete requests and issues new random-access requests.
9. Closing the sheet cancels all pending loads and closes the remote file once.

There is no whole-file `Data`, growing temporary file, or speculative read beyond
the range AVFoundation requested. Existing `StreamIOKit` caching remains available
for the later FFmpeg integration; this bridge stays minimal and lets AVFoundation
drive demand.

## Bounds And Invariants

- `maximumReadLength` is 512 KiB in production.
- Every call to `MediaReadableFile.read` is positive, within the file, and no larger
  than `maximumReadLength`.
- A finite range never emits bytes beyond the requested end or file EOF.
- A request to EOF stops on the known identity size or an upstream empty read.
- An unexpected empty read before the expected end fails rather than loops.
- Cancellation is checked before every upstream read and after every suspension.
- `close()` is idempotent, cancels active work, and closes the file exactly once.
- AVFoundation loading requests are finished exactly once with success or error.

## Error Handling

Invalid offsets and lengths fail before reaching SMB. An empty upstream read before
the requested end becomes a typed unexpected-EOF failure. SMB errors propagate to
the AVFoundation loading request and then to the player item. Cancellation is not
shown as playback failure when the sheet is closing or AVPlayer replaces a range.

If opening or session construction fails after obtaining the remote file, the file
is closed before the UI enters a failed state. Failure text remains privacy-safe and
does not expose credentials or native pointers.

## Testing And Verification

Tests use a deterministic fake `MediaReadableFile` and verify:

- a multi-megabyte request is split into chunks no larger than the configured cap;
- finite unaligned ranges return exactly the requested bytes in order;
- requests extending past EOF return only available bytes;
- reads-to-EOF stop at the file size;
- cancellation prevents remaining upstream reads;
- early empty reads fail without spinning;
- repeated close calls close the upstream file once;
- the browser only marks MP4, M4V, and MOV as playable in this backend.

Repository verification runs `swift test`, `swift build -c release`,
`scripts/check.sh`, and `git diff --check`. A local generated MP4 smoke test should
confirm AVPlayer requests only a subset of a large sparse fixture before becoming
ready. Real first-frame and seek targets remain unverified until tested against the
reference NAS and network matrix.

## Acceptance Criteria

1. Selecting a supported large SMB video creates an AVPlayer without downloading
   or writing the complete file first.
2. Automated tests prove the 512 KiB per-read bound and correct range/EOF behavior.
3. Dismissing or replacing playback cancels work and closes the remote file once.
4. MP4, M4V, and MOV remain selectable; MKV is visibly unsupported by this backend.
5. Debug tests, Release build, repository checks, and whitespace validation pass.
6. The result is explicitly described as an AVFoundation bridge, not completion of
   the broad-format FFmpeg milestone.
