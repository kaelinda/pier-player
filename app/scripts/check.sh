#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$script_dir/.."

scripts/verify-ffmpeg.sh
swift test
swift build -c release
git diff --check
