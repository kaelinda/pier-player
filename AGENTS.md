# Repository Guidelines

## Project Structure & Module Organization

`app/macOS/` contains the current Swift playback prototypes: the source abstraction, SMB adapter, and FFmpeg AVIO bridge. Keep platform-neutral playback code independent of SwiftUI/AppKit so it can later move into shared Swift packages for macOS and iOS. `docs/prd/` holds early requirements, `docs/analazy/` contains Infuse research, and `docs/superpowers/specs/` contains the approved architecture. Treat `data/` as local test-data space; do not commit copyrighted media or credentials.

## Build, Test, and Development Commands

This repository does not yet contain a `Package.swift`, `.xcodeproj`, test target, or reproducible FFmpeg build. Do not claim a successful application build until those are added. Useful current checks are:

```bash
rg --files                         # Inspect the repository surface
swiftc -parse app/macOS/MediaSource.swift
rg -n "TODO|FIXME" app docs       # Find known prototype gaps
```

When build tooling is introduced, document the exact `swift build`, `swift test`, or `xcodebuild` commands here in the same change.

## Coding Style & Naming Conventions

Follow Swift API Design Guidelines and use four-space indentation. Name types and protocols in `UpperCamelCase`; use `lowerCamelCase` for functions, properties, and enum cases. Prefer small, responsibility-focused files. Use `async/await`, actors, and `Sendable` boundaries for shared state. Keep C/FFmpeg and libsmb2 details behind Swift interfaces; UI code must not call native handles directly. Comments should explain concurrency, lifetime, or performance invariants rather than restate code.

## Testing Guidelines

Add tests under `Tests/<ModuleName>Tests/` when the package structure is created, with behavior-focused names such as `testSeekDiscardsPreviousGeneration`. Cover cache boundaries, EOF, cancellation, state transitions, timestamp conversion, and retry limits. Playback hot-path changes also require a Release-mode benchmark report using the fixed media/network matrix in the architecture specification. Never replace deterministic fixtures with private NAS media.

## Commit & Pull Request Guidelines

No Git history exists in this directory, so there is no established convention to preserve. After repository initialization, use focused, imperative Conventional Commit messages, for example `feat(stream-io): add aligned page cache`. Pull requests should explain scope and tradeoffs, link the relevant design section, list verification commands, and include before/after performance metrics for I/O, decode, rendering, or memory changes. Include screenshots only for visible UI changes.

## Security & Licensing

Store SMB secrets in Keychain and redact hosts and paths from logs. Keep FFmpeg builds LGPL-compatible and pinned; do not add GPL player dependencies to production targets. Review `docs/superpowers/specs/2026-07-28-nas-video-player-design.md` before changing architecture or supported formats.
