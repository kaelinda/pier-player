# Repository Guidelines

## Project Structure & Module Organization

`Sources/` contains the active SwiftPM modules: media-source contracts, stream I/O, playback state, telemetry, and the macOS app shell. Tests mirror them under `Tests/<ModuleName>Tests/`. `app/macOS/` retains pre-package prototypes for reference; do not extend those files. Architecture and plans live under `docs/superpowers/`. Treat `data/` as ignored local test-data space; never commit copyrighted media or credentials.

## Build, Test, and Development Commands

Use Swift Package Manager from the repository root:

```bash
swift build                 # Build libraries and macOS executable
swift test                  # Run all Swift Testing suites
swift run PierPlayerApp     # Launch the foundation app shell
swift run SMBProbe --help   # Show the opt-in NAS diagnostic usage
scripts/check.sh            # Test, Release-build, and check whitespace
```

The package pins libsmb2 as an LGPL-2.1+ Git submodule. Initialize it with `git submodule update --init --recursive`. Do not use the GPL-enabled Homebrew FFmpeg as a production linkage.

## Coding Style & Naming Conventions

Follow Swift API Design Guidelines and use four-space indentation. Name types and protocols in `UpperCamelCase`; use `lowerCamelCase` for functions, properties, and enum cases. Prefer small, responsibility-focused files. Use `async/await`, actors, and `Sendable` boundaries for shared state. Keep C/FFmpeg and libsmb2 details behind Swift interfaces; UI code must not call native handles directly. Comments should explain concurrency, lifetime, or performance invariants rather than restate code.

## Testing Guidelines

Add behavior-focused Swift Testing cases under `Tests/<ModuleName>Tests/`, such as `staleSeekCompletionCannotChangeCurrentState`. Follow red-green-refactor and run the focused test before the full suite. Cover cache boundaries, EOF, cancellation, state transitions, timestamp conversion, and retry limits. Playback hot-path changes also require a Release benchmark report using the architecture's fixed media/network matrix.

## Commit & Pull Request Guidelines

Use focused, imperative Conventional Commit messages, for example `feat(stream-io): add aligned page cache`. Pull requests should explain scope and tradeoffs, link the relevant design section, list verification commands, and include before/after performance metrics for I/O, decode, rendering, or memory changes. Include screenshots only for visible UI changes.

## Security & Licensing

Store SMB secrets in Keychain and redact hosts and paths from logs. Keep FFmpeg builds LGPL-compatible and pinned; do not add GPL player dependencies to production targets. Review `docs/superpowers/specs/2026-07-28-nas-video-player-design.md` before changing architecture or supported formats.
