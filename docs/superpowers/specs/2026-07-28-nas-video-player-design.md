# Pier Player: High-Performance NAS Playback Design

- **Date:** 2026-07-28
- **Status:** Approved design, pending written-spec review
- **Initial platform:** macOS
- **Future platform:** iOS/iPadOS

## 1. Purpose

Pier Player is an Apple-platform application for browsing and directly playing audio/video files stored on a NAS. The initial prototype focuses on playback technology rather than Infuse's business model, media-library presentation, or membership features.

The first milestone proves one narrow workflow:

1. Connect to an SMB share from macOS.
2. Browse folders and select a file.
3. Direct-play 4K H.264 or HEVC content in MKV or MP4.
4. Preserve HDR10 or HLG presentation where the display supports it.
5. Seek and recover from ordinary local-network interruptions without downloading or transcoding the complete file.

Playback efficiency is the primary product constraint. UI breadth is subordinate to sustained throughput, bounded resource use, low startup/seek latency, correct frame pacing, and hardware decode.

## 2. Decisions

- Develop the macOS prototype first, then port the shared core to iOS/iPadOS.
- Support SMB only in the first milestone.
- Target MKV and MP4 containers, H.264 and HEVC video, HDR10/HLG, and AAC/AC-3 audio.
- Deliver an SMB connection flow, file browser, and player. Do not build a media library in this milestone.
- Validate on both gigabit Ethernet and Wi-Fi 6.
- Build an owned playback core around FFmpeg demuxing, VideoToolbox decoding, and Apple sample-buffer renderers.
- Use third-party player projects only as external compatibility/performance references, not as production dependencies.
- Use one remote playback pipeline for both MKV and MP4 initially. A later capability router may send fully system-compatible local or HTTP assets to AVPlayer.

## 3. Scope

### 3.1 Included

- SMB connection using explicit host, share, username, password, and optional domain.
- Keychain-backed credential storage.
- Directory enumeration and file selection.
- Persistent, random-access SMB file handles.
- In-memory page cache, adaptive sequential prefetch, and seek-aware cancellation.
- FFmpeg media probing and demuxing through a custom AVIO context.
- Hardware-required H.264/HEVC decode through VideoToolbox.
- 8-bit NV12 and Apple's 10-bit bi-planar YCbCr output without CPU conversion to BGRA.
- HDR10/PQ and HLG metadata propagation to the system display path.
- AAC and AC-3 decode to PCM for system audio rendering.
- Pause, resume, seek, audio-track selection, and playback-position display.
- Recovery from short reads, connection loss, NAS sleep, network changes, and Mac sleep/wake.
- Structured performance metrics and repeatable regression reports.

### 3.2 Excluded

- NFS, WebDAV, FTP, UPnP/DLNA, cloud drives, Plex, Emby, and Jellyfin.
- Metadata scraping, poster walls, automatic series grouping, recommendations, and watch-history sync.
- Subtitles, playback speed, filters, image enhancement, frame interpolation, and software video decode.
- DTS, DTS-HD, TrueHD, Atmos passthrough, Blu-ray menus, BDMV, and ISO playback.
- Downloads, persistent disk cache, remote access outside the LAN, and server-side transcoding.
- Dolby Vision and HDR tone mapping for SDR-only displays.

These exclusions are deliberate. They keep performance measurements attributable to the SMB and playback pipeline.

## 4. Licensing Boundary

The prototype may initially be for personal use, but its architecture must not force a future commercial release to remain GPL-licensed.

- KSPlayer is currently GPL-3.0 unless separately licensed. It may be used as an external benchmark, but it must not be linked into Pier Player's production targets.
- AMSMB2 and its libsmb2 dependency are LGPL-2.1-family software, not MIT-only components. Distribution obligations must be reviewed before public release.
- FFmpeg must be built from a pinned source revision with an auditable LGPL-compatible configuration. GPL components and nonfree codec options are excluded.
- Apple frameworks provide video decode and presentation; Pier Player does not ship a separate H.264/HEVC video decoder in the initial design.
- Codec patent, trademark, and App Store compliance require a release review even when the corresponding source-code license permits distribution.

Third-party code is kept behind narrow internal interfaces so that an implementation can be replaced without changing the app or session model.

## 5. Architecture

```text
macOS SwiftUI App
        |
        v
PlaybackSession actor
        |
        +-- MediaSourceKit
        |     SMB connection, directory listing, credentials, file identity
        |
        +-- StreamIOKit
        |     random reads, page cache, prefetch, request merging, recovery
        |
        +-- DemuxKit
        |     FFmpeg AVIO, probing, MKV/MP4 demux, timestamp normalization
        |
        +-- VideoPipeline
        |     VideoToolbox -> CVPixelBuffer -> AVSampleBufferDisplayLayer
        |
        +-- AudioPipeline
        |     FFmpeg audio decode/resample -> PCM sample buffers
        |
        +-- RenderClock
        |     AVSampleBufferRenderSynchronizer + audio renderer
        |
        +-- PlaybackTelemetry
              signposts, live metric snapshots, session reports
```

The app shell depends on protocols exposed by the playback core. The core does not depend on SwiftUI, AppKit, or concrete screens. macOS and iOS share the source, cache, demux, decode, synchronization, state-machine, and telemetry modules. Platform targets own lifecycle, audio-session, window/view, background, and interaction behavior.

## 6. Module Responsibilities

### 6.1 MediaSourceKit

`MediaSourceKit` provides directory enumeration and byte-addressable file access. Its public contract describes source entries, stable file identity, file size, modification metadata, connection state, and random reads. It never exposes libsmb2 types to consumers.

The hot playback path wraps libsmb2 directly rather than repeatedly calling a convenience API that may open and close the remote file for every range request. A playback session keeps a context and file handle alive until close or recovery. Each SMB context is confined to its own serial executor because concurrent calls through one native context are not assumed safe.

### 6.2 StreamIOKit

`StreamIOKit` turns remote random reads into a bounded, seek-aware byte stream:

- Cache pages are aligned and sized between 1 and 2 MiB after benchmark validation.
- The cache starts with a 32 MiB prefetch window and may adapt between 16 and 128 MiB on macOS.
- The steady-state target is 8-15 seconds of buffered media. Under deteriorating throughput it may grow toward 30 seconds within the memory cap.
- High and low watermarks start and stop speculative reads.
- Adjacent and duplicate misses are merged.
- Small head and tail regions remain resident because container probing often alternates between them.
- At most two SMB read lanes exist per playing file: a foreground demand lane and a cancellable speculative lane. Each lane owns its native context and handle.
- Backpressure stops prefetch and demux when downstream queues reach their capacity.

The byte-read contract returns requested data, a short final read at EOF, or a typed error. It never returns fabricated zero-filled data and never blocks the main actor.

### 6.3 DemuxKit

`DemuxKit` owns the pinned FFmpeg integration. A custom AVIO context maps synchronous FFmpeg read/seek callbacks to `StreamIOKit`. FFmpeg runs on a dedicated executor, so a synchronous callback never blocks UI work.

The current semaphore bridge is only a prototype. The production bridge requires explicit cancellation, timeout, and session-generation handling so that a dead network request cannot hold the demux thread forever. FFmpeg performs probing and demuxing for both video and audio, plus the initial AAC/AC-3 audio decode. It must not select a software video decoder.

Demuxed timestamps are converted to one session timebase without losing the original presentation order. Codec configuration and stream metadata are converted into Core Media format descriptions.

### 6.4 VideoPipeline

The video pipeline converts compressed H.264/HEVC access units into Core Media sample buffers and submits them to a VideoToolbox decompression session. Hardware acceleration is required and verified at runtime. If the device cannot provide a supported hardware decoder, the session fails with a clear unsupported-format result.

Output remains in hardware-native bi-planar YCbCr:

- NV12 for supported 8-bit content.
- Apple's 10-bit bi-planar video-range YCbCr buffers for HEVC Main10 and HDR content.
- IOSurface and Metal compatibility are requested for each buffer pool.
- No persistent CPU-side full-frame copy, RGB conversion, or custom shader exists in the first milestone.

Decoded frames retain presentation timestamps. B-frame reordering is resolved by those timestamps, not callback order. Resolution, color format, or HDR-mode changes trigger an orderly decoder and renderer rebuild.

### 6.5 HDR Presentation

HDR correctness depends on preserving metadata across demux, format creation, decode, and presentation. The pipeline maps and verifies:

- BT.2020 color primaries.
- ST 2084/PQ or HLG transfer characteristics.
- BT.2020 YCbCr matrix and range.
- Mastering display color volume where present.
- Content light level information where present.
- 10-bit decoded pixel format.

The decoded pixel buffers are wrapped in timed sample buffers and enqueued to `AVSampleBufferDisplayLayer`. Extended dynamic range is enabled for a capable screen. Pier Player does not claim HDR correctness merely because a file decodes; diagnostics must confirm input metadata, output format, display capability, and renderer configuration.

When the active screen cannot present HDR, the prototype reports the limitation. SDR tone mapping is a later, separately tested subsystem.

### 6.6 AudioPipeline and RenderClock

The initial audio pipeline decodes AAC and AC-3 with the pinned FFmpeg build, resamples only when the device format requires it, and creates Float32 PCM Core Media sample buffers with an explicit channel layout.

`AVSampleBufferAudioRenderer` and `AVSampleBufferDisplayLayer` are coordinated by one `AVSampleBufferRenderSynchronizer`. Its timebase is the single master timeline, with audio and video samples scheduled against it. The playback core manages timestamp normalization, queue watermarks, discontinuities, and rate transitions; it does not implement a polling-based master clock.

Audio and video queues are bounded. A queue reaching its high watermark applies backpressure upstream. A queue falling below its safety watermark requests more demuxed data before a user-visible stall occurs.

### 6.7 PlaybackTelemetry

Telemetry is a core dependency rather than a debug-only afterthought. It provides:

- `os_signpost` intervals for connect, open, SMB read, cache lookup, demux, decode, enqueue, first frame, seek, recovery, and rebuffer.
- One-second metric snapshots covering throughput, read latency, cache hit rate, buffered duration, queue depth, decode latency, presented/dropped frames, stalls, memory, and relevant system load.
- A lightweight debug overlay.
- A JSON session summary suitable for regression comparison.

Passwords, complete SMB addresses, and complete file paths are never logged. Reports use stable, non-reversible source and file identifiers.

## 7. Playback Data Flow

Opening a file follows this sequence:

1. Resolve the selected source and credential reference.
2. Connect to the share and identify the file by path, size, and modification metadata.
3. Open persistent demand and prefetch handles.
4. Prime head/tail cache regions required for format probing.
5. Create the AVIO and FFmpeg format contexts.
6. Select supported video and audio tracks.
7. Create Core Media format descriptions and the VideoToolbox session.
8. Prebuffer compressed/decoded samples to the initial safety watermark.
9. Start the sample-buffer synchronizer and present the first frame.
10. Maintain the adaptive read window while bounded downstream queues consume data.

Closing invalidates the session generation first, stops the render clock, cancels I/O, flushes render/decode queues, closes native handles, and then releases FFmpeg contexts. This order prevents callbacks from reaching deallocated native resources.

## 8. Seek Design

Every seek increments a monotonically increasing generation:

1. Pause the synchronizer while preserving whether the user intended to remain paused or playing.
2. Invalidate old prefetch and pending decode results.
3. Flush VideoToolbox, display, audio, and bounded packet queues.
4. If the target is cached, serve it immediately; otherwise prioritize its aligned page and a small forward window.
5. Ask FFmpeg to seek to the appropriate preceding keyframe.
6. Demux/decode and discard presentation data before the requested timestamp.
7. Refill both render queues to the seek safety watermark.
8. Set the synchronizer timeline and restore the intended playback state.

Results tagged with an earlier generation are discarded at every asynchronous boundary. This supports repeated rapid seeks without old frames or I/O completing into the current timeline.

## 9. State Machine

```text
idle
 -> connecting
 -> opening
 -> buffering(initial)
 -> playing <-> paused
      |
      +-> seeking -> buffering(seek) -> playing/paused
      +-> reconnecting -> buffering(recovery) -> playing/paused
      +-> ended
      +-> failed
```

`PlaybackSession` is an actor and is the sole owner of state transitions. Native callbacks send typed events to the actor; they do not mutate session state directly. Commands that are invalid in the current state are rejected or normalized, never partially executed.

## 10. Failure and Recovery

- **Short SMB timeout:** Retry idempotent range reads while the existing buffer can sustain playback.
- **Buffer exhaustion:** Freeze the synchronizer at its exact timeline and enter `reconnecting`. Resume only after the recovery watermark is restored.
- **NAS sleep:** Use a longer, bounded reconnect window and surface a waking/reconnecting state.
- **Network path change:** Invalidate old SMB contexts, reconnect, reopen, and continue at the saved offset.
- **Mac sleep/wake:** Pause and save position before sleep. Recreate network, decode, and renderer resources after wake.
- **Remote file change:** Compare size and modification metadata after reopen. If they differ, invalidate cached pages and fail rather than combine versions.
- **Isolated corrupt packet:** Discard within a strict error budget and resume at a valid keyframe.
- **Sustained decode corruption:** Fail after the error budget is exceeded.
- **Stream-format change:** Rebuild the affected format description, decode session, and renderer queues.

Retries have both attempt and elapsed-time limits. No code path may spin forever, grow a queue without a bound, or permanently block the demux executor.

## 11. Performance Contract

The initial objective is not merely visible playback. A release build must demonstrate:

- VideoToolbox reports hardware-accelerated decode in use.
- Instruments shows no sustained full-frame CPU pixel copy or YCbCr-to-RGB conversion.
- 4K 60 fps steady-state dropped-frame rate remains below 0.1 percent after warm-up.
- When the NAS is awake, time from selection to first frame is at most 2 seconds on the reference local network.
- A cache-hit seek completes within 300 ms.
- Remote seek P95 completes within 1.5 seconds on the reference local network.
- Wi-Fi 6 sustained throughput remains at least 1.5 times the measured peak media bitrate; gigabit Ethernet should provide at least 2 times where the NAS disk can supply it.
- A two-hour playback test completes without observable audio/video drift, queue growth, or unbounded memory growth.
- Total application memory targets at most 320 MiB during the reference stream, including at most 128 MiB for SMB cache.
- A change that regresses an established metric by more than 10 percent blocks acceptance until explained or corrected.

Absolute CPU, GPU, decoder, and energy thresholds depend on the reference Mac, NAS, and display. Stage 1 records those devices and establishes a versioned baseline from the fixed reference streams. This is a defined calibration step, not an unspecified requirement.

## 12. Test Matrix

### 12.1 Media Fixtures

The fixed fixture set covers:

| Dimension | Required cases |
|---|---|
| Container | MKV, MP4, MP4 with `moov` at file end |
| Video | H.264 8-bit, HEVC Main, HEVC Main10 |
| Resolution | 1080p, 4K |
| Frame rate | 23.976, 24, 25, 30, 50, 59.94, 60 fps |
| Bitrate | 20, 50, 100 Mbps and peaks above 150 Mbps |
| Dynamic range | SDR, HDR10/PQ, HLG |
| Audio | AAC 2.0/5.1, AC-3 5.1 |
| Timing/error edges | Long GOP, B-frames, unusual timebase, corrupt packet, truncated file |

Fixtures must have known checksums and expected probe metadata. Synthetic fixtures may test failure paths; legally distributable samples are stored or generated for automated testing, while private real-world files remain outside the repository.

### 12.2 SMB and Network Cases

- SMB 2.1, 3.0, and 3.1.1 where the available servers support them.
- Required signing and transport encryption.
- Authenticated and guest shares.
- IP and hostname connections.
- Unicode paths and files larger than 4 GiB.
- Gigabit Ethernet and Wi-Fi 6.
- Controlled bandwidth, latency, jitter, and packet loss.
- NAS sleep/wake, SMB service restart, Wi-Fi handoff, and Mac sleep/wake.

The reference environment includes at least one real NAS and one reproducible Samba test server. Protocol features that the real NAS does not expose are exercised against the test server.

### 12.3 Verification Layers

- Unit tests validate cache boundaries, request merging, EOF behavior, timestamp conversion, generations, state transitions, and retry budgets.
- Deterministic fake sources inject latency, short reads, disconnects, changed file identities, and out-of-order completion.
- Integration tests run probing, demux, and seeking against local fixture files through the same random-read contract.
- Hardware tests verify VideoToolbox formats and HDR metadata on the reference Mac/display.
- End-to-end tests execute the fixed SMB/network matrix and compare JSON performance reports.
- Release performance runs use Time Profiler, System Trace, Allocations, and the relevant media/rendering instruments with detailed debug logging disabled.

## 13. Delivery Stages

### Stage 1: Reproducible Foundation (about 1 week)

Create the Xcode/Swift Package structure, macOS shell, pinned LGPL FFmpeg build, fixture manifest, metric schema, and local-file benchmark harness. Record the reference Mac, macOS version, display, NAS, storage, SMB settings, and network equipment. Exit when a release benchmark is reproducible and produces a versioned report.

### Stage 2: SMB Transport (about 2 weeks)

Implement direct libsmb2 connection, listing, identity, persistent random reads, typed errors, and a standalone throughput/seek benchmark. Exit when large offsets are correct and sustained reads exceed the reference stream's peak bitrate by the required safety margin.

### Stage 3: Local Playback Core (about 3 weeks)

Implement demux, timestamp normalization, VideoToolbox, PCM audio, sample-buffer synchronization, bounded queues, and HDR metadata using local fixtures. Exit after two-hour hardware-decoded playback without drift or resource growth.

### Stage 4: SMB Streaming Integration (about 3 weeks)

Implement the AVIO bridge, cache, adaptive prefetch, backpressure, seek generations, and metrics integration. Exit when Ethernet and Wi-Fi 6 tests meet startup, seek, stall, frame-drop, throughput, and memory contracts.

### Stage 5: Recovery and Optimization (about 2-3 weeks)

Implement bounded recovery for network and lifecycle faults. Use profiler evidence to remove avoidable copies, allocation churn, lock contention, and queue latency. Exit when the fault matrix passes and no known regression exceeds the performance budget.

### Stage 6: Usable macOS Prototype (about 1-2 weeks)

Finish SMB setup, Keychain use, file browsing, playback controls, audio-track selection, actionable errors, diagnostics export, and accessibility basics. Exit when a new user can connect, browse, play, seek, pause, recover, and export a performance report without developer intervention.

A credible single-engineer full-time estimate is 12-15 weeks. The estimate is a planning range, not a performance requirement.

## 14. iOS/iPadOS Follow-On

The iOS phase begins only after the macOS performance contract passes. It reuses the core modules and adds:

- `AVAudioSession` routing/interruption behavior.
- App foreground/background and device-lock policy.
- Touch-first browsing and playback controls.
- Memory-pressure handling and a smaller adaptive cache ceiling.
- Wi-Fi/cellular policy and local-network permission UX.
- Device-specific hardware/HDR capability tests.

The iOS port does not reopen the playback architecture unless measurements show an Apple-platform constraint that the shared interfaces cannot represent.

## 15. Existing Prototype Assessment

The existing files establish useful conceptual boundaries but are not a runnable or performance-ready implementation:

- `MediaSource.swift` provides the right source-agnostic direction, but recursive scanning and a broad extension list exceed the first milestone and should not drive the playback API.
- `SMBMediaSource.swift` uses range convenience reads that are acceptable for a skeleton but do not establish persistent-handle performance. Its licensing comment is inaccurate and must be corrected when implementation begins.
- `FFmpegAVIOBridge.swift` demonstrates the custom-AVIO connection, but contains a placeholder module import and an unbounded semaphore wait. Its lifetime, cancellation, error mapping, and concurrency behavior require redesign before use.
- No Xcode project, Swift package manifest, automated tests, reproducible FFmpeg build, or Git repository exists in the current directory.

Implementation should preserve the source/random-read abstraction while replacing prototype shortcuts through measured, test-first stages.

## 16. Acceptance of the Design

This design is accepted when the written specification accurately reflects the agreed scope and contains no unresolved architectural choice. Implementation planning begins only after written-spec review. The detailed plan will identify exact files, interfaces, tests, commands, and incremental commits for each delivery stage.
