# Pier Player

Pier Player is a macOS-first SwiftUI prototype for browsing and progressively
playing video files stored on an SMB share. It connects directly to a NAS with
`libsmb2`, builds a lightweight media view from the remote directory tree, and
feeds supported files to AVFoundation through byte-range requests instead of
downloading the entire file first.

> Pier Player is under active development and is not ready for production use.

## Current Capabilities

The current `main` branch provides:

- A native macOS 14+ application built with SwiftUI.
- Direct SMB connections using a host, share, username, password, optional
  domain, and optional encryption requirement.
- Persisted sources, automatic reconnection, hierarchical file browsing, and
  source removal.
- A media library view with bounded scanning, search, recently added videos,
  and direct access to each connected source.
- Progressive playback of `.mp4`, `.m4v`, and `.mov` files through
  `AVAssetResourceLoader` and `AVPlayer`.
- Shared source, cache, playback-state, and telemetry foundations for later
  Apple-platform clients.
- Privacy-bounded local diagnostics for resource access and playback behavior,
  with an in-app Settings view and explicit support-bundle export.
- An opt-in `SMBProbe` command for NAS connectivity and throughput checks.

The current player does **not** yet support MKV, AVI, MPEG-TS, WebM, subtitles,
track selection, or the planned FFmpeg/VideoToolbox playback pipeline. Codec
support inside the accepted containers is determined by AVFoundation. The iOS
and tvOS clients are placeholders and are not included in the package.

## Requirements

- macOS 14 or later
- Xcode with a Swift 6 toolchain
- An SMB share reachable from the Mac
- Git submodule support

## Quick Start

Clone the repository with its pinned `libsmb2` submodule:

```bash
git clone --recurse-submodules git@github.com:kaelinda/pier-player.git
cd pier-player/app
swift run PierPlayerApp
```

For an existing clone, initialize the native dependency before building:

```bash
git submodule update --init --recursive
cd app
swift run PierPlayerApp
```

When the app opens:

1. Select the add-source button in the sidebar.
2. Enter a display name, NAS host or IP address, share name, and SMB credentials.
3. Enable **Require SMB encryption** only when the server supports it.
4. Connect, then browse the source or select a supported video from the media
   library.

Enter the host separately from the share. For example, use `nas.local` as the
host and `Media` as the share, not `smb://nas.local/Media` in either field.

## Security Notice

Do not use production credentials with the current prototype. Although the app
writes credentials to the macOS Keychain, the persisted source record currently
also includes the username and password in plaintext at:

```text
~/Library/Application Support/PierPlayer/sources.json
```

That duplicate plaintext storage must be removed before the application is
considered safe for general use or distribution. Logs and bug reports must also
redact SMB hosts, paths, usernames, and passwords.

## iCloud Sync Setup

Source configuration and opaque playback progress can use the user's private
CloudKit database. SMB credentials use iCloud Keychain and are never written to
CloudKit. The app remains local-only when iCloud is unavailable.

Live cross-device sync requires a signed Xcode app build with bundle identifier
`dev.pierplayer.app`, the checked-in `app/macOS/PierPlayerApp.entitlements`, and
CloudKit container `iCloud.dev.pierplayer.app` enabled in the Apple Developer
account. `swift run PierPlayerApp` does not provide those production signing
capabilities and therefore cannot prove live CloudKit synchronization.

## Local Diagnostics

Open **Settings > Diagnostics** to inspect local diagnostic status and recent
sessions. Standard mode is enabled by default and records important resource,
stream, playback, lifecycle, and failure events. Detailed Diagnostics records
the full privacy-safe event stream for 30 minutes and can be stopped early.

Defined playback, SMB, EOF, stall, event-loss, and close failures automatically
capture the preceding two minutes from the bounded in-memory flight recorder,
then retain up to 30 seconds of follow-up evidence. On-disk runs are retained for
seven days and capped at 100 MiB; cleanup never deletes the active run.

Diagnostics remain on this Mac until **Export** is selected. An exported
`.pierdiag` package contains exactly `manifest.json`, `events.jsonl`,
`metrics.jsonl`, `summary.json`, and `integrity.json`. Validate or inspect it
without NAS access:

```bash
cd app
swift run DiagnosticsReport /path/to/support.pierdiag --validate
swift run DiagnosticsReport /path/to/support.pierdiag --timeline
```

Persisted and exported records exclude credentials, domains, usernames, hosts,
shares, source display names, media and directory names, paths, SMB URLs, query
strings, media bytes, native pointers, and unrestricted native error messages.
Source IDs are opaque UUIDs and file identities are HMAC-derived with a
per-install Keychain key. Every export passes an integrity and privacy audit
before it is made available to save.

## SMB Diagnostics

`SMBProbe` checks a connection without launching the UI. It can also read a
bounded prefix of a remote file and report cache and throughput metrics.

```bash
cd app
PIER_SMB_HOST=nas.local \
PIER_SMB_SHARE=Media \
PIER_SMB_USER=player \
PIER_SMB_FILE=/Movies/sample.mp4 \
swift run -c release SMBProbe
```

The password is requested interactively without echo. `PIER_SMB_FILE` is
optional; omit it to test only connection and root-directory listing. See all
options with:

```bash
cd app
swift run SMBProbe --help
```

Reference environment and measurement guidance live in
[`docs/benchmarks/`](docs/benchmarks/).

## Project Structure

All build commands run from `app/`.

| Path | Responsibility |
| --- | --- |
| `app/Shared/Sources/CloudSyncKit/` | Local-first CloudKit synchronization for non-secret sources and playback progress |
| `app/Shared/Sources/DiagnosticsKit/` | Typed local events, bounded capture, retention, privacy audit, and export |
| `app/Shared/Sources/MediaSourceKit/` | Source-neutral directory listing, file identity, and random-access file contracts |
| `app/Shared/Sources/SMBSourceKit/` | `libsmb2` integration, SMB configuration, credentials, and persisted sources |
| `app/Shared/Sources/StreamIOKit/` | Bounded page cache and range-reader metrics |
| `app/Shared/Sources/PlaybackCore/` | Playback state and session transitions |
| `app/Shared/Sources/PlaybackTelemetry/` | Playback metric snapshots and reports |
| `app/macOS/` | Implemented SwiftUI application and macOS tests |
| `app/iOS/`, `app/tvOS/` | Reserved platform-client directories; not implemented yet |
| `app/Tools/SMBProbe/` | Opt-in SMB connectivity and throughput diagnostic |
| `app/Tools/DiagnosticsReport/` | Offline validation and reporting for exported `.pierdiag` packages |
| `app/Vendor/libsmb2/` | Pinned native SMB dependency submodule |
| `docs/superpowers/` | Accepted designs and implementation plans |

Files in `app/macOS/Legacy/` are historical prototypes and must not be extended.
Use `data/` only for ignored local fixtures; never commit copyrighted media,
credentials, or private NAS details.

## Development

From `app/`:

```bash
swift build                 # Build libraries and the macOS executable
swift test                  # Run all Swift Testing suites
swift run PierPlayerApp     # Launch the macOS app
swift run SMBProbe --help   # Show diagnostic options
swift run DiagnosticsReport --help # Show support-bundle options
scripts/check.sh            # Test, Release-build, and check whitespace
```

Add shared tests under `app/Shared/Tests/<ModuleName>Tests/` and macOS tests under
`app/macOS/Tests/`. Playback hot-path changes should include Release measurements
against the fixed media and network matrix documented in
[`docs/benchmarks/reference-environment.md`](docs/benchmarks/reference-environment.md).

## Architecture and Roadmap

The accepted architecture keeps network sources behind random-access byte-range
interfaces so browsing and playback code do not depend on native SMB handles.
The current AVFoundation bridge is an incremental playback path; the broader
owned playback engine remains a separate milestone.

- [NAS playback architecture](docs/superpowers/specs/2026-07-28-nas-video-player-design.md)
- [Progressive AVFoundation playback](docs/superpowers/specs/2026-07-30-progressive-avfoundation-playback-design.md)
- [Media library home](docs/superpowers/specs/2026-07-30-media-library-home-design.md)
- [Broad-format playback design](docs/superpowers/specs/2026-07-30-broad-format-playback-design.md)
- [Local diagnostics toolkit](docs/superpowers/specs/2026-07-30-local-diagnostics-toolkit-design.md)

The broad-format design requires a pinned, LGPL-compatible FFmpeg build. Do not
add GPL player dependencies or link a GPL-enabled Homebrew FFmpeg build into a
production target.

## Contributing

Read [`AGENTS.md`](AGENTS.md) before making changes. Keep commits focused, use
imperative Conventional Commit messages, run the focused test first, and finish
with `app/scripts/check.sh`.

## Licensing

This repository does not currently declare a project-level license. Do not assume
permission to redistribute the Pier Player source or binaries without one.

The vendored `libsmb2` library code is licensed under LGPL-2.1-or-later; its
examples use the 2-Clause BSD license. See `app/Vendor/libsmb2/COPYING` after
initializing the submodule. Any future FFmpeg distribution must preserve the
LGPL-only boundary and include the required notices and replacement materials.
