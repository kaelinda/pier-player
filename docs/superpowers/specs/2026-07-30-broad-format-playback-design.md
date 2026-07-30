# Broad Format Playback Design

**Date:** 2026-07-30
**Status:** macOS implementation complete for the representative format matrix;
automated and short local Release verification complete; extended real-media and
SMB endurance validation remains open

## Purpose

Pier Player currently marks MKV files as supported but hands downloaded files to
`AVPlayer`. AVFoundation does not demux Matroska, so the visible capability and
the actual playback path disagree. This design replaces the format-dependent
`AVPlayer` path with one owned FFmpeg playback pipeline for the existing macOS
SMB experience.

The goal is broad, direct playback of common video containers and codecs without
requiring software installed by the user. The first implementation remains
macOS-only. iOS and tvOS can reuse the shared core later, but their application
shells and platform validation are outside this milestone.

This document extends
`2026-07-28-nas-video-player-design.md` and
`2026-07-28-local-playback-core-design.md`. Where the earlier local milestone
requires hardware-only H.264/HEVC and excludes subtitles, software video decode,
selectable tracks, and SMB AVIO, this design deliberately includes those
capabilities for the broad-format macOS milestone. The original lifetime,
bounded-resource, timing, telemetry, and licensing requirements remain in force.

## Implementation Evidence

Evidence recorded on 2026-07-30 establishes the following:

- The app no longer aggregates SMB files into `Data` or hands temporary files to
  `AVPlayer`. It opens one random-access media handle and passes it through the
  bounded cache and bundled FFmpeg custom AVIO pipeline.
- The pinned FFmpeg 8.1.2 framework reports LGPL 2.1-or-later configuration,
  passes forbidden-flag checks, and contains a universal macOS `arm64` and
  `x86_64` slice.
- Generated MKV H.264/AAC, MP4 H.264/AAC, WebM VP9/Opus, AVI MPEG-4/MP3, and
  MPEG-TS MPEG-2/AC-3 fixtures probe, seek, decode audio and video, maintain
  monotonic timestamps, and reach clean EOF through the streaming path.
- On the reference Apple M1 Pro Mac, short Release probes selected VideoToolbox
  for H.264 and VP9 and selected software decode for MPEG-4 Part 2 and MPEG-2.
- The macOS UI hosts `AVSampleBufferDisplayLayer`, exposes playback, seek,
  volume, mute, full-screen, audio-track, and subtitle controls, and passes
  offscreen layout checks at 760 by 520 and 1180 by 760 points.
- The repository gate passes 113 tests, Debug and Release builds, framework and
  fixture verification, two Release probes, and whitespace checks. The Release
  executable resolves PierFFmpeg through `@rpath` with `@loader_path` available.

The reference measurements and their limits are recorded in
`app/docs/benchmarks/broad-format-reference.json`. The evidence does not yet
establish HEVC, AV1, VP8, FLV, VOB, ASF, WMV, or every other enabled combination
with dedicated fixtures. It also does not establish two-hour stability, remote
SMB throughput, drift, or recovery behavior. The coordinator now reopens an
interrupted source with bounded attempts and elapsed time, rejects changed file
identities, and resumes from the frozen timeline; these paths are covered with
local deterministic files rather than a real NAS interruption. External
subtitle parsing and same-basename discovery are wired into the active macOS
player session and covered by tests.

## Product Scope

The milestone includes:

- Playback from the existing macOS SMB file browser.
- Direct random-access reads through `StreamIOKit`; the player must not download
  the complete media file before starting.
- FFmpeg probing and demuxing for common containers.
- VideoToolbox hardware decode when available and FFmpeg software decode as a
  fallback.
- PCM audio decode and Apple system audio rendering.
- Embedded and same-directory external text subtitles.
- Play, pause, seek, volume, full screen, audio-track selection,
  subtitle-track selection, and subtitle disable controls.
- Typed failures and bounded recovery for malformed media and interrupted SMB
  reads.

The milestone excludes DRM, Blu-ray menus, DVD menus, Dolby Vision proprietary
enhancement-layer processing, audio bitstream passthrough, full ASS effects
rendering, media-library metadata, and iOS or tvOS UI work.

## Supported Media Contract

The browser uses a known-extension set to identify likely video files, but an
extension is never proof that a file is playable. FFmpeg probes the bytes and
the player reports the actual container and selected streams. A known extension
with invalid contents fails with a typed probe error. Generic opening of unknown
extensions is outside this milestone.

The first release enables the LGPL-compatible FFmpeg demuxers and decoders
needed for these representative formats:

- Containers: Matroska/MKV, WebM, MP4, MOV, M4V, AVI, FLV, MPEG-TS, M2TS, MTS,
  MPEG-PS, VOB, Ogg/OGV, 3GP, ASF, and WMV.
- Video: H.264/AVC, HEVC/H.265, AV1, VP8, VP9, MPEG-1 Video, MPEG-2 Video,
  MPEG-4 Part 2, VC-1, and WMV video.
- Audio: AAC, MP3, AC-3, E-AC-3, Opus, Vorbis, FLAC, ALAC, PCM, and DTS.
- Text subtitles: SubRip/SRT, ASS/SSA, WebVTT, and text subtitle streams that
  FFmpeg can normalize into the same cue model.

This list is a verified compatibility target, not a promise that every possible
combination, profile, damaged file, or vendor extension will play. Track support
is decided from the codec parameters after probing. Unsupported secondary
subtitle tracks do not prevent audio/video playback. An unsupported selected
video stream is fatal; an absent audio stream is valid for silent video.

ASS and SSA support preserves cue text and timing. Complex positioning,
animation, karaoke, vector drawing, and font-attachment fidelity may be reduced
to plain styled text. Bitmap subtitles such as PGS are outside this milestone.

## Dependency And Licensing Strategy

Pier Player bundles a pinned, dynamically linked FFmpeg XCFramework for macOS.
It never locates or links a Homebrew FFmpeg installation at runtime. The build
configuration contains only LGPL-compatible FFmpeg components and excludes
`--enable-gpl`, `--enable-nonfree`, and GPL codec libraries such as x264 and
x265. Distribution preserves the user's ability to replace the LGPL library and
does not apply technical restrictions that prohibit reverse engineering for
debugging modifications to that library.

The repository records:

- The exact FFmpeg source version or commit.
- The source archive hash.
- The complete configure arguments for every architecture.
- The generated XCFramework hash.
- FFmpeg and enabled third-party license notices.
- The corresponding FFmpeg source and the material needed to rebuild or replace
  the bundled dynamic library, distributed in the release-compliance channel.
- A reproducible build script and an automated forbidden-flag check.

The XCFramework exposes FFmpeg through a SwiftPM binary target. A small C shim
wraps macros, callbacks, error conversion, and native ownership operations that
cannot be imported safely into Swift. FFmpeg pointers remain inside the native
integration module. Public interfaces use Swift value types and opaque session
objects.

## Architecture

The playback pipeline is:

```text
SMBMediaSource
  -> StreamIOKit bounded page cache
  -> synchronous FFmpeg custom AVIO on a dedicated executor
  -> bounded probe and demux session
  -> bounded audio, video, and subtitle packet queues
  -> hardware-first video decoder / software fallback
  -> PCM audio decoder and text subtitle decoder
  -> bounded timed sample and subtitle cue queues
  -> AVSampleBufferRenderSynchronizer
       +-> AVSampleBufferDisplayLayer
       +-> AVSampleBufferAudioRenderer
  -> macOS subtitle overlay and playback controls
```

### Native FFmpeg Integration

`FFmpegKit` owns format contexts, custom AVIO contexts, codec contexts, packets,
frames, stream metadata, timestamp normalization, seeking, and error strings.
All FFmpeg calls for one media session run on a dedicated serial executor. A
synchronous AVIO callback may block that executor while bridging to the bounded
async reader, but it must never block the main actor or Swift's cooperative
executor.

Probe work has explicit byte and elapsed-time limits. Stream metadata crosses
the module boundary as immutable, `Sendable` values. Packet and frame buffers
use explicit ownership wrappers; teardown invalidates callbacks before freeing
their native contexts.

### Video Decode

For every selected video stream, the decoder first tests whether VideoToolbox
supports the codec, profile, dimensions, and pixel format. When a hardware
session can be created, decoded `CVPixelBuffer` frames retain their presentation
timestamp, duration, color properties, and HDR metadata.

If hardware decode is unavailable or the stream is not compatible, FFmpeg opens
the enabled software decoder. Software frames are converted to a renderer-safe
pixel buffer format with bounded reusable pools. Conversion must preserve aspect
ratio, presentation timestamps, and available color metadata. A mid-stream
hardware decoder failure may fall back once to software after a controlled
flush; repeated decoder failures are fatal rather than an infinite retry loop.

Software decode makes compatibility broader, not performance universal. The UI
may report that software decode is active. In particular, smooth 4K AV1, VP9,
or other computationally expensive streams is measured per reference Mac and is
not guaranteed.

### Audio Decode

FFmpeg decodes the selected audio stream and converts it to timestamped PCM
sample buffers accepted by `AVSampleBufferAudioRenderer`. Resampling and channel
layout conversion occur only when the renderer cannot consume the decoded
format. Compressed audio bitstream passthrough is not provided.

Switching audio tracks preserves the current timeline, flushes only the affected
audio pipeline, seeks the new track to the current presentation time, refills
its safety watermark, and resumes the prior play or pause intent.

### Subtitle Decode

Embedded text packets and external subtitle files are normalized into immutable
cues with start time, end time, text, and a constrained style model. External
discovery matches the media basename and supported subtitle extensions in the
same SMB directory. Discovery failures do not prevent playback.

Subtitle selection is independent of the render synchronizer queues. The overlay
observes the synchronizer timeline, displays all active cues, and clears cues on
seek, track change, stop, and session replacement. Malformed individual cues are
skipped with bounded diagnostics; a broken subtitle track is disabled without
stopping audio/video.

### Render And Synchronization

`RenderKit` owns `AVSampleBufferDisplayLayer`,
`AVSampleBufferAudioRenderer`, and one
`AVSampleBufferRenderSynchronizer`. The synchronizer timebase is the only master
playback clock. Playback does not use a polling clock or independent audio and
video timers.

Each packet and sample queue has item, byte, and timeline-duration limits.
Producers suspend at a high watermark and resume at a low watermark. Startup and
recovery begin only after audio and video reach their applicable safety
watermarks. Silent video does not wait for audio. Backpressure propagates from
the renderers through decoding and demuxing to the remote reader.

## Session State And Commands

`PlaybackCore` remains the UI-independent coordinator. It owns the session ID,
seek generation, requested play/pause intent, selected tracks, public state, and
typed failure. It does not expose FFmpeg, Core Video, Core Media, or native
renderer handles to SwiftUI.

Opening follows this order:

1. Create a new session ID and open the SMB random-access file.
2. Create the cached reader and custom AVIO context.
3. Probe within the configured byte and time budgets.
4. Select the first supported video track and the preferred supported audio
   track, if present.
5. Discover embedded and same-directory external subtitle tracks.
6. Create video, audio, subtitle, and renderer resources.
7. Fill bounded queues to the startup watermarks.
8. Start the shared render timebase and present the first frame.

Pause sets the synchronizer rate to zero without dropping buffered samples.
Resume first confirms that the safety watermarks can sustain playback. A buffer
underrun freezes the exact timeline, enters buffering, and resumes only after the
recovery watermark is restored.

Every seek increments a monotonically increasing generation:

1. Preserve the requested post-seek play or pause intent.
2. Pause the synchronizer.
3. Cancel outstanding reads and decode work for the old generation.
4. Flush packet, decoded sample, subtitle, and renderer queues.
5. Ask FFmpeg to seek to the preceding usable keyframe.
6. Decode forward and discard samples before the target time.
7. Refill audio and video queues to their safety watermarks.
8. Set the synchronizer timeline and restore the requested intent.

Every asynchronous result carries its session ID and generation. Stale work is
discarded at each boundary and cannot mutate the current session.

Closing first invalidates the session, stops the render clock, and cancels I/O.
It then clears queues, invalidates hardware and software decoders, releases
renderers, closes FFmpeg contexts, and finally closes the media source handle.
This ordering prevents callbacks into released native state.

## macOS Application Integration

The existing `VideoPlayerModel` no longer downloads the complete file or creates
an `AVPlayer`. It adapts the playback core's state stream to SwiftUI and forwards
commands. The player view hosts the display layer and subtitle overlay while the
control surface provides:

- Play and pause.
- Current time, duration, and seek scrubber.
- Volume and mute.
- Full-screen entry and exit.
- Audio-track menu.
- Subtitle-track menu and Off selection.
- Buffering, software-decode, and actionable failure states.

The browser expands its likely-video extension set to the representative
containers in this design. A likely video that fails probing remains visible and
produces a clear error instead of silently doing nothing. Other regular files
remain visible but are not offered as videos. File names, SMB hosts, shares, and
paths are not emitted in telemetry or exported diagnostics.

## Failure And Recovery Rules

Failures identify their boundary: source open, network read, probe, demux, video
decode, audio decode, subtitle decode, or render. Native FFmpeg error codes are
translated into stable typed Swift errors with a redacted user-facing message
and an optional diagnostic code.

- Unsupported or encrypted required video stops the session.
- Missing audio is allowed; unsupported selected audio offers another supported
  track when one exists, otherwise playback may continue silently after an
  explicit notice.
- Subtitle discovery or decoding failure disables only that subtitle track.
- A transient SMB interruption freezes the timebase and retries with both
  attempt and elapsed-time limits.
- A changed remote file identity invalidates caches and fails the session rather
  than mixing bytes from two revisions.
- EOF drains queued samples before transitioning to ended.
- No path may retry forever, grow an unbounded queue, or wait forever on a
  synchronous bridge.

## Verification

### Automated Tests

Tests follow red-green-refactor and include:

- FFmpeg version, source hash, XCFramework hash, configure flags, architecture,
  and forbidden GPL/nonfree configuration checks.
- C shim error mapping and native lifetime behavior.
- Probe limits, container metadata, stream enumeration, codec mapping, and
  default track selection.
- Timestamp conversion, missing and negative timestamps, B-frame ordering,
  discontinuities, and EOF draining.
- Hardware selection, software fallback, renderer-safe pixel conversion, and
  a single bounded hardware-to-software failover.
- PCM continuity, channel layout conversion, and audio-track switching.
- Embedded and external subtitle discovery, cue timing, malformed cue skipping,
  seek clearing, track switching, and subtitle disable.
- Queue byte/item/duration limits, high/low watermarks, cancellation, and
  backpressure.
- Session and seek generation rejection, rapid repeated seeks, state
  transitions, recovery limits, and teardown order.
- Damaged media, unknown codecs, missing audio, subtitle failure, and simulated
  SMB interruption.

Small deterministic fixtures contain only generated visual and audio signals.
They cover representative MKV, WebM, MP4, AVI, and MPEG-TS paths and are either
reproducibly generated or checked in with provenance and hashes. No copyrighted
media or credentials enter the repository.

The standard verification sequence is:

```bash
cd app
swift test
swift build
swift build -c release
scripts/check.sh
```

### Runtime And Performance Evidence

Real-Mac validation records:

- MKV H.264 and HEVC VideoToolbox sessions with hardware acceleration confirmed.
- VP9 and AV1 software fallback behavior and achieved frame rate.
- Embedded and external subtitle selection and timing.
- Audio-track switching and audio/video synchronization.
- Repeated rapid seeks over local cache and SMB.
- Queue peaks, decoded frame drops, stalls, CPU, memory, and first-frame time.
- A two-hour run without persistent audio/video drift, unbounded queue growth,
  or material memory growth.

Playback hot-path results use the fixed media and network matrix from the parent
architecture. Headless tests cannot prove display smoothness, hardware decode,
HDR correctness, or long-run synchronization; those claims require the runtime
report.

## Acceptance Criteria

The milestone is complete when:

1. The app starts supported SMB media without first downloading the whole file.
2. Representative MKV, WebM, MP4, AVI, and MPEG-TS fixtures probe, demux, decode,
   and render with the expected tracks and timestamps.
3. H.264 and HEVC use verified VideoToolbox hardware sessions on the reference
   Mac, while at least VP9 and AV1 exercise the software fallback path.
4. The audio compatibility matrix produces continuous PCM and maintains sync.
5. Embedded and matching external text subtitles can be selected, disabled, and
   kept aligned through pause and repeated seek.
6. Playback controls and track menus operate through `PlaybackCore` without UI
   access to native handles.
7. Cancellation, EOF, failures, retries, and teardown obey their bounds and
   generation rules.
8. Automated tests, Debug and Release builds, license checks, and artifact hashes
   pass.
9. A real-hardware Release report states which performance and endurance targets
   passed and which remain unverified.
