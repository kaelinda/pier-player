#!/usr/bin/env bash
set -euo pipefail

swift test
swift build -c release
git diff --check
