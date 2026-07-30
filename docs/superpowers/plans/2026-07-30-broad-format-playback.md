# Broad Format Playback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the macOS app's AVPlayer/temp-download path with a bundled LGPL FFmpeg pipeline that directly plays common SMB video containers, uses VideoToolbox when available, falls back to software decode, renders synchronized PCM/video samples, and supports embedded and external text subtitles.

**Architecture:** Build a reproducible macOS universal dynamic `PierFFmpeg.xcframework` from FFmpeg 8.1.2 and a narrow project-owned C ABI. `FFmpegKit` bridges the synchronous native pipeline to the existing bounded async SMB reader, `RenderKit` owns Apple sample-buffer renderers and the shared timebase, `SubtitleKit` normalizes text cues, and `PlaybackCore` coordinates state, generations, tracks, bounded queues, and commands without exposing native handles to SwiftUI.

**Tech Stack:** Swift 6.3, SwiftPM, Swift Testing, C17, FFmpeg 8.1.2 (LGPL-2.1-or-later configuration), VideoToolbox, CoreVideo, CoreMedia, AVFoundation, AVKit, SwiftUI

---

## File Map

- `app/scripts/build-ffmpeg.sh`: download, verify, configure, build, link, and package the universal dynamic framework.
- `app/scripts/verify-ffmpeg.sh`: verify version, hash, architectures, install name, dynamic dependencies, exports, configure flags, and forbidden GPL/nonfree markers.
- `app/scripts/tests/ffmpeg-build-config-test.sh`: executable contract tests for supply-chain and license configuration.
- `app/Native/PierFFmpeg/include/PierFFmpeg.h`: stable C ABI visible to Swift.
- `app/Native/PierFFmpeg/src/*.c`: FFmpeg ownership, AVIO, probe, decode, conversion, seek, and subtitle implementation.
- `app/Native/PierFFmpeg/exports.txt`: exported C symbols; raw FFmpeg symbols remain hidden.
- `app/Vendor/FFmpeg/`: checked-in XCFramework, notices, source/build metadata, and checksums.
- `app/Shared/Sources/FFmpegKit/`: Swift values and synchronous-to-async media-reader bridge.
- `app/Shared/Sources/RenderKit/`: sample construction, renderer ownership, shared timebase, and bounded enqueue readiness.
- `app/Shared/Sources/SubtitleKit/`: subtitle cues, external subtitle discovery, and SRT/WebVTT/ASS normalization.
- `app/Shared/Sources/PlaybackCore/`: playback coordinator, commands, state snapshots, track selection, queues, and generation-safe decode lifecycle.
- `app/macOS/Sources/PierPlayerApp/`: player model, display-layer host, subtitle overlay, and controls.
- `app/Shared/Tests/Fixtures/`: small generated, non-copyrighted media and subtitle fixtures with hashes.
- `app/Tools/PlaybackProbe/`: command-line local-file probe and decode report used for runtime verification.

### Task 1: Reproducible LGPL FFmpeg Framework

**Files:**
- Create: `app/scripts/tests/ffmpeg-build-config-test.sh`
- Create: `app/scripts/build-ffmpeg.sh`
- Create: `app/scripts/verify-ffmpeg.sh`
- Create: `app/Native/PierFFmpeg/include/PierFFmpeg.h`
- Create: `app/Native/PierFFmpeg/src/PierFFmpegVersion.c`
- Create: `app/Native/PierFFmpeg/exports.txt`
- Create: `app/Vendor/FFmpeg/BUILD-METADATA.txt`
- Create: `app/Vendor/FFmpeg/LICENSES/FFmpeg-LGPL-2.1-or-later.txt`
- Create: `app/Vendor/FFmpeg/SOURCE.md`
- Create: `app/Vendor/FFmpeg/SHA256SUMS`
- Create: `app/Vendor/FFmpeg/PierFFmpeg.xcframework/`
- Modify: `app/scripts/check.sh`

- [ ] **Step 1: Write the failing supply-chain test**

The shell test must require FFmpeg `8.1.2`, source SHA-256
`464beb5e7bf0c311e68b45ae2f04e9cc2af88851abb4082231742a74d97b524c`, macOS
`arm64` and `x86_64` slices, a dynamic install name under
`@rpath/PierFFmpeg.framework`, and these configuration properties:

```bash
required_flags=(
  --disable-autodetect --disable-programs --disable-doc --disable-debug
  --disable-avdevice --disable-avfilter --disable-network --disable-encoders
  --disable-muxers --disable-filters --disable-devices --enable-pic
  --enable-static --disable-shared --enable-videotoolbox --enable-audiotoolbox
)
forbidden_patterns=(--enable-gpl --enable-nonfree --enable-libx264 --enable-libx265)
```

Run: `app/scripts/tests/ffmpeg-build-config-test.sh`

Expected: FAIL because the build metadata, framework, and verification script do not exist.

- [ ] **Step 2: Add the minimal native version ABI and build script**

Expose only project-owned symbols:

```c
const char *ppff_version(void);
const char *ppff_configuration(void);
const char *ppff_license(void);
```

The build script downloads the pinned archive from `https://ffmpeg.org/releases/ffmpeg-8.1.2.tar.xz`, verifies the hash before extraction, builds arm64 and x86_64 with macOS 14 as the deployment target, compiles the project C sources for each architecture, and links the five static FFmpeg libraries into one dynamic framework. Use `-force_load` per archive and an exported-symbols list; set the install name to `@rpath/PierFFmpeg.framework/Versions/A/PierFFmpeg`. Create a universal framework with `lipo`, then create the XCFramework with `xcodebuild -create-xcframework`.

- [ ] **Step 3: Record LGPL compliance material**

Copy FFmpeg's unmodified LGPL notice, record the exact source URL/hash/configure command, and explain how to rebuild and replace the dynamic framework. Do not include Homebrew paths or host-specific flags in checked-in metadata.

- [ ] **Step 4: Build and verify GREEN**

Run:

```bash
cd app
scripts/build-ffmpeg.sh
scripts/verify-ffmpeg.sh
scripts/tests/ffmpeg-build-config-test.sh
```

Expected: version is 8.1.2, both architectures are present, license reports LGPL 2.1 or later, no forbidden configuration appears, all dependencies are Apple system frameworks/libraries, and only `ppff_*` entry points are exported.

- [ ] **Step 5: Extend the repository check and commit**

Add `scripts/verify-ffmpeg.sh` before Swift builds in `scripts/check.sh`.

```bash
git add app/scripts app/Native/PierFFmpeg app/Vendor/FFmpeg
git commit -m "build(ffmpeg): add pinned LGPL framework"
```

### Task 2: SwiftPM FFmpeg Module And Format Contract

**Files:**
- Modify: `app/Package.swift`
- Modify: `app/Shared/Sources/MediaSourceKit/MediaSourceItem.swift`
- Modify: `app/Shared/Tests/MediaSourceKitTests/MediaSourceItemTests.swift`
- Create: `app/Shared/Sources/FFmpegKit/FFmpegRuntime.swift`
- Create: `app/Shared/Sources/FFmpegKit/FFmpegError.swift`
- Create: `app/Shared/Tests/FFmpegKitTests/FFmpegRuntimeTests.swift`

- [ ] **Step 1: Write failing runtime and extension tests**

Require `FFmpegRuntime.version == "8.1.2"`, an LGPL license string, no GPL/nonfree configure marker, and case-insensitive browser recognition for:

```swift
["mkv", "webm", "mp4", "mov", "m4v", "avi", "flv", "ts", "m2ts",
 "mts", "mpeg", "mpg", "vob", "ogv", "3gp", "asf", "wmv"]
```

Continue to reject directories and non-media files.

Run: `swift test --filter 'FFmpegRuntimeTests|MediaSourceItemTests'`

Expected: FAIL because `FFmpegRuntime` and the broader extension contract are absent.

- [ ] **Step 2: Add target graph and runtime wrapper**

Add local binary target `PierFFmpeg`, library target/product `FFmpegKit`, and `FFmpegKitTests`. The wrapper converts nullable C strings into stable Swift values and throws `FFmpegError.invalidRuntimeMetadata` instead of force-unwrapping.

- [ ] **Step 3: Implement the extension contract and verify GREEN**

Run: `swift test --filter 'FFmpegRuntimeTests|MediaSourceItemTests'`

Expected: all runtime and extension tests pass, and `swift build` embeds the dynamic framework.

- [ ] **Step 4: Commit**

```bash
git add app/Package.swift app/Shared/Sources/MediaSourceKit app/Shared/Sources/FFmpegKit app/Shared/Tests/MediaSourceKitTests app/Shared/Tests/FFmpegKitTests
git commit -m "feat(media): add broad format runtime contract"
```

### Task 3: Deterministic Media Fixtures

**Files:**
- Create: `app/scripts/generate-media-fixtures.sh`
- Create: `app/Shared/Tests/Fixtures/README.md`
- Create: `app/Shared/Tests/Fixtures/SHA256SUMS`
- Create: `app/Shared/Tests/Fixtures/video-h264-aac.mkv`
- Create: `app/Shared/Tests/Fixtures/video-h264-aac.mp4`
- Create: `app/Shared/Tests/Fixtures/video-vp9-opus.webm`
- Create: `app/Shared/Tests/Fixtures/video-mpeg4-mp3.avi`
- Create: `app/Shared/Tests/Fixtures/video-mpeg2-ac3.ts`
- Create: `app/Shared/Tests/Fixtures/video-h264-aac.en.srt`
- Create: `app/Shared/Tests/Fixtures/video-h264-aac.ass`
- Create: `app/scripts/tests/media-fixtures-test.sh`

- [ ] **Step 1: Write the failing fixture contract test**

Require every fixture hash, duration between one and three seconds, generated color bars/tone only, and the expected container/video/audio codec tuple. The test may use host `ffprobe` for fixture authoring validation, but application builds and tests must not link or execute host FFmpeg.

Run: `app/scripts/tests/media-fixtures-test.sh`

Expected: FAIL because fixtures and hashes are missing.

- [ ] **Step 2: Add reproducible generation**

Generate a 320x180, 24 fps test pattern and 48 kHz sine tone. Use the host tool only to produce deterministic test assets. Store the exact commands and host FFmpeg version in the fixture README; fixtures contain no copyrighted media.

- [ ] **Step 3: Verify and commit**

Run: `app/scripts/tests/media-fixtures-test.sh`

Expected: every hash and codec tuple passes.

```bash
git add app/scripts app/Shared/Tests/Fixtures
git commit -m "test(media): add generated format fixtures"
```

### Task 4: Native AVIO Probe And Stream Metadata

**Files:**
- Modify: `app/Native/PierFFmpeg/include/PierFFmpeg.h`
- Create: `app/Native/PierFFmpeg/src/PierFFmpegInternal.h`
- Create: `app/Native/PierFFmpeg/src/PierFFmpegIO.c`
- Create: `app/Native/PierFFmpeg/src/PierFFmpegSession.c`
- Modify: `app/Native/PierFFmpeg/exports.txt`
- Create: `app/Shared/Sources/FFmpegKit/MediaMetadata.swift`
- Create: `app/Shared/Sources/FFmpegKit/FFmpegIOBridge.swift`
- Create: `app/Shared/Sources/FFmpegKit/FFmpegSession.swift`
- Create: `app/Shared/Tests/FFmpegKitTests/FFmpegProbeTests.swift`
- Modify: `app/Package.swift`

- [ ] **Step 1: Write failing custom-AVIO probe tests**

Load MKV, MP4, WebM, AVI, and TS fixture bytes through an in-memory implementation of the same random-read callback contract used by SMB. Assert container name, duration, seekability, track kind, codec ID/name, dimensions, sample rate, channel count, language/title metadata, and default-track selection. Add malformed bytes, byte-budget exhaustion, elapsed-time interruption, invalid seek, and repeated close coverage.

Run: `swift test --filter FFmpegProbeTests`

Expected: FAIL because the session and metadata API are absent.

- [ ] **Step 2: Add the stable C session ABI**

Define opaque `PPFFSession`, callbacks, and value-only metadata:

```c
typedef int (*PPFFReadCallback)(void *opaque, uint8_t *buffer, int size);
typedef int64_t (*PPFFSeekCallback)(void *opaque, int64_t offset, int whence);
typedef int (*PPFFInterruptCallback)(void *opaque);

PPFFSession *ppff_session_open(PPFFIOCallbacks callbacks,
                               PPFFProbeLimits limits,
                               PPFFError *error);
int ppff_session_stream_count(const PPFFSession *session);
int ppff_session_stream_info(const PPFFSession *session, int index,
                             PPFFStreamInfo *info);
void ppff_session_close(PPFFSession **session);
```

Create the `AVIOContext` with `av_malloc`, set `AVFMT_FLAG_CUSTOM_IO`, apply probe-size/analyze-duration limits, install the interrupt callback, and call `avformat_find_stream_info`. All failure paths free the AVIO buffer, format context, dictionaries, and copied error text exactly once.

- [ ] **Step 3: Add the Swift callback owner**

`FFmpegIOBridge` is `@unchecked Sendable`, owns the callback context for exactly the native session lifetime, serializes position updates, clamps reads to known size, maps EOF to zero, maps failures to FFmpeg I/O errors, handles `AVSEEK_SIZE`, and supports cancellation. No callback captures a temporary Swift pointer.

- [ ] **Step 4: Rebuild framework and verify GREEN**

Run:

```bash
cd app
scripts/build-ffmpeg.sh
scripts/verify-ffmpeg.sh
swift test --filter FFmpegProbeTests
```

Expected: all five containers probe through custom AVIO and all failure/lifetime tests pass.

- [ ] **Step 5: Commit**

```bash
git add app/Native/PierFFmpeg app/Vendor/FFmpeg app/Shared/Sources/FFmpegKit app/Shared/Tests/FFmpegKitTests app/Package.swift
git commit -m "feat(ffmpeg): probe media through custom AVIO"
```

### Task 5: Hardware-First Video And PCM Audio Decode

**Files:**
- Modify: `app/Native/PierFFmpeg/include/PierFFmpeg.h`
- Create: `app/Native/PierFFmpeg/src/PierFFmpegDecode.c`
- Create: `app/Native/PierFFmpeg/src/PierFFmpegVideo.c`
- Create: `app/Native/PierFFmpeg/src/PierFFmpegAudio.c`
- Modify: `app/Native/PierFFmpeg/src/PierFFmpegSession.c`
- Modify: `app/Native/PierFFmpeg/exports.txt`
- Create: `app/Shared/Sources/FFmpegKit/DecodedSample.swift`
- Modify: `app/Shared/Sources/FFmpegKit/FFmpegSession.swift`
- Create: `app/Shared/Tests/FFmpegKitTests/FFmpegDecodeTests.swift`

- [ ] **Step 1: Write failing decode tests**

For representative fixtures, require monotonic presentation timestamps after reordering, positive frame durations, retained `CVPixelBuffer` output, continuous stereo Float32 PCM at 48 kHz, clean EOF draining, cancellation, decoder-mode reporting, and no output after close. Verify H.264 attempts VideoToolbox and that an injected hardware-open failure falls back exactly once to software.

Run: `swift test --filter FFmpegDecodeTests`

Expected: FAIL because decoded sample APIs are missing.

- [ ] **Step 2: Implement video decoder selection and output**

Use `avcodec_get_hw_config` and a VideoToolbox hardware device when compatible. Retain hardware `CVPixelBuffer` frames before returning them. For software frames, use a bounded reusable Core Video pool and `sws_scale` into BGRA while preserving presentation timestamp, duration, aspect ratio, and available color properties. Expose `.videoToolbox` or `.software` in stream state. A runtime hardware failure performs one controlled flush/reopen in software mode.

- [ ] **Step 3: Implement normalized PCM audio**

Decode all enabled audio codecs through FFmpeg. Configure `SwrContext` with `swr_alloc_set_opts2` to output packed stereo Float32 at 48 kHz, preserve the input PTS as the first output sample time, and derive subsequent duration from sample count. Return owned bytes that remain valid until `ppff_sample_release`.

- [ ] **Step 4: Implement bounded demux/decode iteration**

`ppff_session_read_next` first drains pending decoder frames, then reads packets and routes only selected streams. At EOF send one null packet per decoder, drain all frames, then return a stable EOF event. Packet/frame ownership is released on every continue/error branch.

- [ ] **Step 5: Rebuild and verify GREEN**

Run:

```bash
cd app
scripts/build-ffmpeg.sh
swift test --filter FFmpegDecodeTests
```

Expected: all decode, hardware-selection, software-fallback, timestamp, EOF, and ownership tests pass.

- [ ] **Step 6: Commit**

```bash
git add app/Native/PierFFmpeg app/Vendor/FFmpeg app/Shared/Sources/FFmpegKit app/Shared/Tests/FFmpegKitTests
git commit -m "feat(ffmpeg): decode video and PCM audio"
```

### Task 6: Seek, Track Selection, And Async SMB Bridge

**Files:**
- Modify: `app/Native/PierFFmpeg/include/PierFFmpeg.h`
- Modify: `app/Native/PierFFmpeg/src/PierFFmpegSession.c`
- Modify: `app/Native/PierFFmpeg/src/PierFFmpegDecode.c`
- Modify: `app/Native/PierFFmpeg/exports.txt`
- Modify: `app/Shared/Sources/FFmpegKit/FFmpegIOBridge.swift`
- Modify: `app/Shared/Sources/FFmpegKit/FFmpegSession.swift`
- Create: `app/Shared/Sources/FFmpegKit/BlockingMediaReader.swift`
- Create: `app/Shared/Tests/FFmpegKitTests/FFmpegSeekTests.swift`
- Create: `app/Shared/Tests/FFmpegKitTests/BlockingMediaReaderTests.swift`

- [ ] **Step 1: Write failing seek and bridge tests**

Prove cached actor-backed reads are bridged without blocking the main actor, same-position callback reads coalesce upstream, read timeout/cancellation map correctly, `AVSEEK_SIZE` returns identity size, and close wakes a blocked callback. Prove seek flushes packets/frames, lands on or after the requested timestamp after keyframe preroll, increments generation, rejects stale samples, and preserves requested play/pause intent. Prove selecting a new supported audio track seeks it to the current timeline.

Run: `swift test --filter 'BlockingMediaReaderTests|FFmpegSeekTests'`

Expected: FAIL because the blocking bridge and native seek/selection entry points are absent.

- [ ] **Step 2: Implement the bounded async-to-sync reader**

Run each FFmpeg session on a dedicated serial dispatch queue. The callback starts a Swift task against `CachedMediaReader`, waits only on that dedicated queue with a fixed timeout, copies bytes into FFmpeg's buffer, and responds to cancellation. Store completion under a lock so timeout and late completion cannot double-resume or access freed memory.

- [ ] **Step 3: Implement native seek and selection**

Expose:

```c
int ppff_session_seek(PPFFSession *session, int64_t microseconds, PPFFError *error);
int ppff_session_select_audio(PPFFSession *session, int stream_index,
                              int64_t microseconds, PPFFError *error);
int ppff_session_select_subtitle(PPFFSession *session, int stream_index,
                                 PPFFError *error);
```

Seek with `avformat_seek_file` to a preceding keyframe, flush codec buffers and resamplers, reset EOF/drain flags, and discard decoded samples before the target. Reject invalid or unsupported stream indices before changing current selection.

- [ ] **Step 4: Rebuild and verify GREEN**

Run: `scripts/build-ffmpeg.sh && swift test --filter 'BlockingMediaReaderTests|FFmpegSeekTests'`

Expected: bridge lifecycle, cancellation, repeated seek, stale-generation, and track-switch tests pass.

- [ ] **Step 5: Commit**

```bash
git add app/Native/PierFFmpeg app/Vendor/FFmpeg app/Shared/Sources/FFmpegKit app/Shared/Tests/FFmpegKitTests
git commit -m "feat(ffmpeg): add generation-safe seek and track selection"
```

### Task 7: Synchronized Apple Render Pipeline

**Files:**
- Modify: `app/Package.swift`
- Create: `app/Shared/Sources/RenderKit/MediaSampleFactory.swift`
- Create: `app/Shared/Sources/RenderKit/SampleBufferRenderer.swift`
- Create: `app/Shared/Sources/RenderKit/RenderState.swift`
- Create: `app/Shared/Tests/RenderKitTests/MediaSampleFactoryTests.swift`
- Create: `app/Shared/Tests/RenderKitTests/SampleBufferRendererTests.swift`

- [ ] **Step 1: Write failing sample and renderer tests**

Require video `CMSampleBuffer` creation from retained pixel buffers, stereo Float32 audio sample creation with exact PTS/duration/sample count, rejection of mismatched byte counts, one shared synchronizer timebase, pause/resume rate changes, flush/reset, readiness callbacks, and bounded pending-duration accounting.

Run: `swift test --filter 'MediaSampleFactoryTests|SampleBufferRendererTests'`

Expected: FAIL because `RenderKit` does not exist.

- [ ] **Step 2: Implement Core Media sample factories**

Use `CMVideoFormatDescriptionCreateForImageBuffer` and `CMSampleBufferCreateReadyWithImageBuffer` for video. Build an `AudioStreamBasicDescription` for native-endian packed Float32 stereo at 48 kHz, copy PCM into a `CMBlockBuffer`, and create a ready audio sample with correct timing and sample count. Never reference temporary `Data` storage after the factory returns.

- [ ] **Step 3: Implement the renderer owner**

`@MainActor SampleBufferRenderer` owns one display layer, one audio renderer, and one `AVSampleBufferRenderSynchronizer`. It starts at rate 0, begins only when applicable startup watermarks are met, freezes on underrun, exposes current timeline time, flushes both renderers on seek, and never polls for queue readiness.

- [ ] **Step 4: Verify GREEN and commit**

Run: `swift test --filter 'MediaSampleFactoryTests|SampleBufferRendererTests'`

```bash
git add app/Package.swift app/Shared/Sources/RenderKit app/Shared/Tests/RenderKitTests
git commit -m "feat(render): synchronize audio and video samples"
```

### Task 8: Text Subtitle Pipeline

**Files:**
- Modify: `app/Package.swift`
- Create: `app/Shared/Sources/SubtitleKit/SubtitleCue.swift`
- Create: `app/Shared/Sources/SubtitleKit/SubtitleParser.swift`
- Create: `app/Shared/Sources/SubtitleKit/ExternalSubtitleDiscovery.swift`
- Create: `app/Shared/Sources/SubtitleKit/SubtitleTimeline.swift`
- Create: `app/Shared/Tests/SubtitleKitTests/SubtitleParserTests.swift`
- Create: `app/Shared/Tests/SubtitleKitTests/ExternalSubtitleDiscoveryTests.swift`
- Modify: `app/Native/PierFFmpeg/include/PierFFmpeg.h`
- Modify: `app/Native/PierFFmpeg/src/PierFFmpegDecode.c`
- Modify: `app/Shared/Sources/FFmpegKit/DecodedSample.swift`

- [ ] **Step 1: Write failing parser, discovery, and timeline tests**

Cover LF/CRLF SRT, WebVTT headers/settings, ASS dialogue fields containing commas, style-tag stripping, overlapping cues, malformed cue skipping with a limit, UTF-8 BOM, matching same-basename files case-insensitively, unrelated subtitle rejection, an 8 MiB external-file cap, seek clearing, selection changes, and Off state.

Run: `swift test --filter 'SubtitleParserTests|ExternalSubtitleDiscoveryTests'`

Expected: FAIL because subtitle types do not exist.

- [ ] **Step 2: Implement external subtitle normalization**

Expose immutable `SubtitleCue(startTime:endTime:text:)` values. Parsers return sorted cues and bounded warnings. Discovery lists the video's SMB directory, matches the basename plus optional language suffix, opens only selected files, enforces the size cap before reading, and closes handles on every path.

- [ ] **Step 3: Add embedded text subtitle events**

Decode selected SRT/ASS/SSA/WebVTT/mov_text packets through FFmpeg, normalize their text and start/end times into the same Swift cue model, and treat malformed or unsupported subtitle streams as nonfatal.

- [ ] **Step 4: Rebuild, verify GREEN, and commit**

Run: `scripts/build-ffmpeg.sh && swift test --filter 'SubtitleParserTests|ExternalSubtitleDiscoveryTests|FFmpegDecodeTests'`

```bash
git add app/Package.swift app/Native/PierFFmpeg app/Vendor/FFmpeg app/Shared/Sources/FFmpegKit app/Shared/Sources/SubtitleKit app/Shared/Tests
git commit -m "feat(subtitles): add embedded and external text cues"
```

### Task 9: Bounded Playback Coordinator

**Files:**
- Modify: `app/Package.swift`
- Modify: `app/Shared/Sources/PlaybackCore/PlaybackState.swift`
- Modify: `app/Shared/Sources/PlaybackCore/PlaybackSession.swift`
- Create: `app/Shared/Sources/PlaybackCore/PlaybackCoordinator.swift`
- Create: `app/Shared/Sources/PlaybackCore/PlaybackTrack.swift`
- Create: `app/Shared/Sources/PlaybackCore/BoundedMediaQueue.swift`
- Create: `app/Shared/Sources/PlaybackCore/PlaybackFailure.swift`
- Create: `app/Shared/Tests/PlaybackCoreTests/BoundedMediaQueueTests.swift`
- Create: `app/Shared/Tests/PlaybackCoreTests/PlaybackCoordinatorTests.swift`

- [ ] **Step 1: Write failing queue and coordinator tests**

Cover byte/item/duration high and low watermarks, producer suspension and cancellation, silent video startup, audio/video startup readiness, pause/resume intent, EOF drain to ended, rapid repeated seek, old-session and old-generation sample rejection, audio/subtitle selection, one bounded hardware fallback, SMB retry attempt/elapsed limits, changed identity failure, and teardown order.

Run: `swift test --filter 'BoundedMediaQueueTests|PlaybackCoordinatorTests'`

Expected: FAIL because the queue and coordinator are absent.

- [ ] **Step 2: Implement bounded queues**

The queue actor tracks item count, owned bytes, and media duration. `enqueue` suspends at the high watermark, resumes producers only below the low watermark, and wakes all waiters with `CancellationError` on clear/close. Queue limits are explicit configuration values and no continuation can be resumed twice.

- [ ] **Step 3: Implement the coordinator lifecycle**

Open the source handle, cached reader, native session, decoders, subtitle discovery, and renderer in the design order. Decode on a dedicated task, enqueue only current session/generation samples, and publish immutable snapshots/tracks through `AsyncStream`. Stop invalidates tokens before cancelling reads and tears down in the specified order.

- [ ] **Step 4: Implement commands and recovery**

Pause/resume controls the shared renderer timebase. Seek increments generation, cancels old work, flushes every queue/decoder/renderer, prerolls, refills safety watermarks, and restores intent. Audio/subtitle changes operate at the current timeline. SMB recovery freezes time and has both attempt and elapsed-time limits.

- [ ] **Step 5: Verify GREEN and commit**

Run: `swift test --filter 'BoundedMediaQueueTests|PlaybackCoordinatorTests|PlaybackSessionTests'`

```bash
git add app/Package.swift app/Shared/Sources/PlaybackCore app/Shared/Tests/PlaybackCoreTests
git commit -m "feat(playback): coordinate bounded FFmpeg pipeline"
```

### Task 10: macOS Player UI Integration

**Files:**
- Split/Modify: `app/macOS/Sources/PierPlayerApp/SourceBrowserView.swift`
- Create: `app/macOS/Sources/PierPlayerApp/VideoPlayerModel.swift`
- Create: `app/macOS/Sources/PierPlayerApp/VideoPlayerSheet.swift`
- Create: `app/macOS/Sources/PierPlayerApp/VideoSurfaceView.swift`
- Create: `app/macOS/Sources/PierPlayerApp/PlaybackControlsView.swift`
- Create: `app/macOS/Sources/PierPlayerApp/SubtitleOverlayView.swift`
- Create: `app/macOS/Tests/PierPlayerAppTests/VideoPlayerModelTests.swift`
- Modify: `app/macOS/Tests/PierPlayerAppTests/UIRenderingTests.swift`

- [ ] **Step 1: Write failing model and rendering tests**

Require that opening a video does not aggregate/download the complete file, model state follows coordinator snapshots, close cancels and tears down, seek commands are debounced only while scrubbing, audio/subtitle menus reflect tracks, subtitle Off works, and player states render at minimum/wide sizes without overlap. Include long file/track names and software-decode/buffering/error badges.

Run: `swift test --filter 'VideoPlayerModelTests|UIRenderingTests'`

Expected: FAIL because the new model and views are absent.

- [ ] **Step 2: Replace the AVPlayer/temp-file model**

Delete the `Data` aggregation, temporary file, `AVPlayer`, and `AVPlayerView` path. `VideoPlayerModel` owns a coordinator, consumes its state stream on the main actor, forwards commands, and calls stop on disappearance/deinit.

- [ ] **Step 3: Host renderer and complete controls**

Use `NSViewRepresentable` to host the display layer without exposing it to other UI. Overlay subtitles above the video and controls below it. Provide symbol buttons for play/pause, mute, and full screen with tooltips/accessibility labels; use a slider for seek/volume and menus for audio/subtitle tracks. Keep dimensions stable across state changes.

- [ ] **Step 4: Verify GREEN and commit**

Run:

```bash
swift test --filter 'VideoPlayerModelTests|UIRenderingTests'
swift build
```

```bash
git add app/macOS app/Shared/Sources/MediaSourceKit
git commit -m "feat(macOS): play broad formats through FFmpeg"
```

### Task 11: Playback Probe And Compatibility Verification

**Files:**
- Modify: `app/Package.swift`
- Create: `app/Tools/PlaybackProbe/main.swift`
- Create: `app/Shared/Tests/FFmpegKitTests/FormatCompatibilityTests.swift`
- Create: `app/docs/benchmarks/broad-format-reference.json`
- Modify: `app/scripts/check.sh`

- [ ] **Step 1: Write the failing compatibility matrix test**

For every committed fixture, assert expected container, selected streams, decoder mode, positive video/audio samples, monotonic timestamps, seek completion, and clean EOF. The test must use the bundled framework and custom AVIO, never host FFmpeg.

Run: `swift test --filter FormatCompatibilityTests`

Expected: FAIL until the matrix and probe are complete.

- [ ] **Step 2: Add a local playback probe**

`PlaybackProbe <path> [--seek <seconds>] [--frames <count>]` reads a local file through a `MediaReadableFile` adapter, exercises the same cache/custom-AVIO/decode path, and emits redacted, versioned JSON containing hashes/opaque IDs, metadata, decoder mode, first-sample times, sample counts, seek latency, queue peaks, and errors. It never emits the input path.

- [ ] **Step 3: Generate runtime evidence**

Run the probe in Release against MKV H.264/AAC, WebM VP9/Opus, AVI MPEG-4/MP3, and TS MPEG-2/AC-3. Confirm VideoToolbox for H.264 on the reference Mac and software decode for at least one unsupported hardware path. Record actual measurements without claiming display smoothness or long-run SMB behavior from the short local fixtures.

- [ ] **Step 4: Extend the full gate and commit**

Add shell fixture checks and focused Release probe invocations to `scripts/check.sh` before `git diff --check`.

```bash
git add app/Package.swift app/Tools/PlaybackProbe app/Shared/Tests/FFmpegKitTests app/docs/benchmarks app/scripts/check.sh
git commit -m "test(playback): verify broad format compatibility"
```

### Task 12: Full Verification, Documentation, Commit, And Push

**Files:**
- Modify only when verification exposes a defect.
- Update: `docs/superpowers/specs/2026-07-30-broad-format-playback-design.md` status after evidence is complete.

- [ ] **Step 1: Run focused native and compatibility gates**

```bash
cd app
scripts/verify-ffmpeg.sh
scripts/tests/ffmpeg-build-config-test.sh
scripts/tests/media-fixtures-test.sh
swift test --filter 'FFmpegKitTests|RenderKitTests|SubtitleKitTests|PlaybackCoreTests|PierPlayerAppTests'
swift run -c release PlaybackProbe Shared/Tests/Fixtures/video-h264-aac.mkv --seek 1 --frames 24
swift run -c release PlaybackProbe Shared/Tests/Fixtures/video-vp9-opus.webm --frames 24
```

Expected: all gates pass and both probes produce valid redacted JSON.

- [ ] **Step 2: Run the complete repository gate**

```bash
cd app
swift test
swift build
swift build -c release
scripts/check.sh
```

Expected: all tests pass, Debug and Release builds succeed, FFmpeg/license/fixture checks pass, and whitespace is clean.

- [ ] **Step 3: Inspect packaging and repository state**

Confirm the app executable resolves `PierFFmpeg` from its bundle/rpath, the XCFramework has arm64 and x86_64, no build/temp/media credentials are tracked, `.vscode/` remains outside the feature branch, and `git diff --check` is clean.

- [ ] **Step 4: Commit any final verification-only changes**

```bash
git add docs/superpowers/specs/2026-07-30-broad-format-playback-design.md app/docs/benchmarks/broad-format-reference.json
git commit -m "chore(playback): finalize format verification"
```

Skip this commit when the worktree is already clean.

- [ ] **Step 5: Push the verified feature branch**

```bash
git push -u origin codex/broad-format-playback
```

Expected: remote tracking is established and the remote branch head matches local `HEAD`.
