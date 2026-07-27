# Reference Playback Environment

Record this sheet before accepting playback performance results. Create a dated copy for each reference environment and keep private network addresses out of the repository.

## Build

- Commit: record the full Git SHA
- Configuration: Release
- macOS and Xcode versions: record exact versions
- FFmpeg/libsmb2 revisions and build flags: record once integrated

## Client

- Mac model and chip: record the system report values
- Memory: record installed capacity
- Display model, connection, resolution, and refresh rate: record all active values
- HDR/EDR capability: record the system-reported capability

## NAS and SMB

- NAS model and OS: record model and exact firmware
- Storage layout: record disk type, array type, and filesystem
- SMB dialect, signing, and encryption: record negotiated values
- Test account: use an opaque label, never a username

## Network

- Mode: gigabit Ethernet or Wi-Fi 6
- Router/access point and firmware: record exact model and version
- Link speed, channel width, and signal level: record measured values
- Competing traffic: stop it or document it

## Fixture

- Opaque fixture ID and SHA-256: record both
- Container, codec, resolution, frame rate, HDR mode, and audio format: copy probe output
- Average and peak bitrate: record measured values
