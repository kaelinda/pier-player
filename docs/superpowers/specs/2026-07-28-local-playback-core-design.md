# Local Playback Core Design

## Objective

Build Pier Player's first high-performance playback vertical slice for local files before connecting the pipeline to SMB. The milestone plays MKV and MP4 files containing H.264 or HEVC video and AAC audio, with play, pause, stop, and seek. It establishes measurable hardware-decoded playback rather than broad format compatibility.

This closes the largest current gap with Infuse: Pier Player has a persistent random-access SMB transport, bounded cache, playback state machine, and telemetry foundation, but no direct-play media pipeline. Infuse's durable advantage comes from reliable no-transcode playback, hardware decoding, correct timing, and Apple-native rendering. Library artwork, metadata scraping, subtitles, and additional sources cannot compensate for a missing playback core.

## Scope

The milestone includes:

- Pinned, reproducible, LGPL-compatible FFmpeg XCFrameworks for macOS and future iOS use.
- MKV and MP4 probing and demuxing.
- H.264 and HEVC hardware decoding through VideoToolbox.
- AAC decoding to Float32 PCM.
- Apple sample-buffer video and audio rendering under one synchronized timebase.
- Open, play, pause, stop, and generation-safe seek.
- Bounded packet and sample queues with backpressure.
- Local fixture generation, integration tests, performance reports, and lifecycle diagnostics.

The milestone excludes SMB AVIO integration, AC-3, subtitles, multiple selectable tracks, software video decode, HDR tuning, Dolby Vision, library metadata, and iOS UI. These are subsequent milestones after the local performance contract passes.

## Dependency And Licensing Strategy

FFmpeg is pinned to the official `n8.1.2` tag at commit `38b88335f99e76ed89ff3c93f877fdefce736c13` and built into auditable XCFrameworks. The build configuration disables GPL, nonfree, programs, documentation, network protocols, and software video decoders not required by this milestone. It enables `libavformat`, `libavcodec`, `libavutil`, and `libswresample` with the MOV/MP4 and Matroska demuxers, H.264/HEVC parsers and bitstream filters, and AAC decoding. The build script records configuration flags, toolchain, architectures, output hashes, and license files.

The installed Homebrew FFmpeg is not linked because its enabled components are not an acceptable production license baseline. Third-party opaque binary distributions are also excluded because their build flags and provenance cannot be verified.

## Module Architecture

### FFmpegKit

`FFmpegKit` owns native format contexts, codec parameters, packet lifetimes, stream probing, track selection, timestamp normalization, demux iteration, and seek. Its public API contains Swift value types and opaque lifecycle objects only. FFmpeg pointers never cross the module boundary.

FFmpeg runs on a dedicated serial executor. This prevents synchronous demux operations from blocking the main actor or Swift's cooperative executor and gives format-context lifetime one clear owner.

### VideoDecodeKit

`VideoDecodeKit` converts H.264/HEVC codec configuration into `CMVideoFormatDescription`, creates a VideoToolbox decompression session, submits compressed samples, and emits decoded `CVPixelBuffer` frames with presentation time and duration.

Session creation requests `kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder`. After creation, the module verifies `kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder`. A rejected hardware session or a false hardware property is a typed failure; the player does not silently trade performance, power, and thermals for compatibility.

### AudioDecodeKit

`AudioDecodeKit` decodes AAC through the pinned FFmpeg build and creates Float32 PCM `CMSampleBuffer` values. It preserves channel layout and timestamps and resamples only when the renderer's required format differs from the decoded format.

### RenderKit

`RenderKit` owns `AVSampleBufferDisplayLayer`, `AVSampleBufferAudioRenderer`, and one `AVSampleBufferRenderSynchronizer`. The synchronizer's timebase is the only playback clock. The renderer exposes queue readiness, flush, rate, current time, and bounded enqueue operations without exposing UI concerns.

### PlaybackCore And App Boundaries

`PlaybackCore` coordinates state, session IDs, seek generations, user intent, pipeline events, and typed failures. It does not own FFmpeg, VideoToolbox, AppKit, SwiftUI, or Core Animation implementation details.

`PierPlayerApp` selects a local file, hosts the display layer, renders state, and sends commands. It does not call native handles or mutate decoder queues.

## Data Flow And Backpressure

```text
Local MediaReadableFile
  -> bounded random reader
  -> FFmpeg demux executor
  -> bounded video/audio packet queues
  -> VideoToolbox and AAC decoder
  -> bounded video/PCM sample queues
  -> AVSampleBufferRenderSynchronizer
```

Every queue has byte, item, and timeline-duration limits. Producers suspend when their downstream high watermark is reached and resume at the low watermark. No loop polls for readiness, no queue grows without a bound, and no semaphore wait is unbounded.

Decoded video remains in `CVPixelBuffer` form. The production path does not convert frames to CPU RGB images. Packet and frame ownership is explicit so buffers cannot be released while native callbacks still reference them.

## Playback Behavior

Opening performs bounded probing, selects the first supported video and AAC tracks, creates decoder and renderer resources, and fills both render queues to a startup watermark. The synchronizer starts only after the startup watermark is met so audio and video begin together.

Pause sets the synchronizer rate to zero without discarding buffered samples. Resume restores the playback rate after confirming the queues can sustain playback. Buffer underrun also sets the rate to zero; playback resumes only after the recovery watermark is met.

Stop invalidates the active generation before releasing resources. Reopening always creates a new session ID and pipeline.

## Seek Contract

Every seek increments the session's generation and follows this order:

1. Preserve the requested post-seek play or pause intent.
2. Pause the render synchronizer.
3. Cancel demux and decode work for the previous generation.
4. Flush bounded packet queues, VideoToolbox, decoded sample queues, and renderers.
5. Ask FFmpeg to seek to the preceding keyframe.
6. Decode forward while discarding samples before the target timestamp.
7. Fill audio and video queues to the startup watermark.
8. Restore the preserved playback intent.

Every asynchronous result carries a session ID and generation. Results from an earlier session or generation are discarded at each boundary and cannot change current state.

## Time And Error Handling

Native time bases are converted with explicit rational arithmetic and overflow checks into `CMTime`. Missing PTS, duplicate DTS, and minor non-monotonic input use a bounded repair policy. Playback fails after a fixed consecutive-anomaly limit; it never skips packets forever.

Public errors are actionable and privacy-safe:

- Unsupported container, video codec, or audio codec.
- Hardware video decoding unavailable or rejected.
- Corrupt media or invalid timestamps.
- File read failure or remote identity change.
- Video or audio decode failure.
- Seek failure or superseded operation.

Raw native log strings, complete file paths, pointers, and credentials do not reach the UI or telemetry report.

## Lifecycle

Each open operation owns one `PlaybackPipeline`. Shutdown order is fixed:

```text
invalidate session and generation
-> stop synchronized timebase
-> cancel file reads and demux
-> drain and clear bounded queues
-> flush and destroy VideoToolbox
-> release audio and video renderers
-> release FFmpeg contexts
-> close the media file
```

Shutdown is idempotent. Native callbacks retain only explicit callback state, and callback state validates session and generation before touching pipeline resources.

## Performance Contract

All measurements use Release builds and versioned fixture hashes on the reference Mac:

- Local first frame at or below 1 second.
- Cache-hit seek at or below 300 ms.
- Local random seek P95 at or below 500 ms.
- 4K HEVC confirms VideoToolbox hardware decode with no software fallback.
- Packet, frame, PCM, and cache memory remain within configured bounds.
- A two-hour run has no persistent audio/video drift, queue growth, or material memory growth.
- Normal video output preserves `CVPixelBuffer` without a CPU RGB conversion.

Telemetry records probe time, first packet, first decoded video, first decoded audio, first presented frame, seek latency, dropped frames, decode failures, queue peaks, and memory peaks. A JSON report contains opaque fixture identifiers rather than file paths.

## Test Strategy

### Unit Tests

Test timestamp conversion, track selection, queue watermarks, backpressure transitions, seek generation rejection, anomaly limits, and resource shutdown order with deterministic fakes.

### Generated Fixtures

Repository scripts generate legally distributable short MKV and MP4 fixtures covering H.264, HEVC, AAC, B-frames, variable frame rate, different stream time bases, and an audio start offset. A manifest records SHA-256 hashes and expected probe metadata.

### Hardware Integration

On a real Mac, integration tests verify VideoToolbox session creation, hardware decode status, pixel formats, decoded timestamps, AAC continuity, pause/resume behavior, repeated seek, and resource teardown. Display smoothness and long-run synchronization require a real display and cannot be claimed from headless tests.

### Performance And Endurance

A command-line local playback probe produces the versioned JSON report. Release validation includes a fixed 4K HEVC sample, rapid repeated seeks, a two-hour loop, memory sampling, and queue peak checks.

## Acceptance Criteria

The milestone is complete when:

1. Fixed MKV and MP4 fixtures produce their expected stream metadata.
2. H.264 and HEVC fixtures decode through verified VideoToolbox hardware sessions.
3. AAC produces continuous timestamped PCM sample buffers.
4. Open, play, pause, stop, and repeated seek obey session and generation rules.
5. Automated tests, Debug and Release builds, license checks, and dependency hashes pass.
6. A local playback performance JSON report is reproducible.
7. Real-hardware results explicitly identify which performance and endurance targets passed or remain unverified.

After acceptance, the next design connects `StreamIOKit` to FFmpeg custom AVIO for SMB playback without changing demux, decode, render, or playback-state contracts.
