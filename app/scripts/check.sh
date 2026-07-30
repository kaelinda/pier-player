#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$script_dir/.."

scripts/verify-ffmpeg.sh
scripts/tests/ffmpeg-build-config-test.sh
scripts/tests/media-fixtures-test.sh
swift test
swift build -c release
swift run -c release PlaybackProbe \
    Shared/Tests/Fixtures/video-h264-aac.mkv \
    --seek 1 --frames 24 >/dev/null
swift run -c release PlaybackProbe \
    Shared/Tests/Fixtures/video-vp9-opus.webm \
    --frames 24 >/dev/null
git diff --check
