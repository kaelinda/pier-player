#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$script_dir/.."

diagnostics_fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/pier-diagnostics-check.XXXXXX")"
diagnostics_fixture="$diagnostics_fixture_root/check.pierdiag"
cleanup() {
    rm -rf "$diagnostics_fixture_root"
}
trap cleanup EXIT

swift test
swift build -c release
swift run DiagnosticsReport --generate-fixture "$diagnostics_fixture"
swift run DiagnosticsReport "$diagnostics_fixture" --validate

diagnostics_file_count="$(find "$diagnostics_fixture" -maxdepth 1 -type f | wc -l | tr -d ' ')"
if [[ "$diagnostics_file_count" != "5" ]]; then
    echo "Expected five files in the generated diagnostics package" >&2
    exit 1
fi

if rg --line-number --ignore-case \
    --glob '*.json' \
    --glob '*.jsonl' \
    '"(credential|credentials|display[-_]?name|domain|file[-_]?name|file[-_]?path|host|hostname|password|path|query|share|share[-_]?name|source[-_]?name|url|username)"[[:space:]]*:' \
    "$diagnostics_fixture"; then
    echo "Generated diagnostics contain a forbidden key" >&2
    exit 1
fi

if rg --line-number --ignore-case \
    --glob '*.json' \
    --glob '*.jsonl' \
    'smb://|file://|/Users/|/Volumes/|~/|[A-Z]:\\\\|nas\.local|Movies/sample' \
    "$diagnostics_fixture"; then
    echo "Generated diagnostics contain an SMB or path fixture" >&2
    exit 1
fi

git diff --check
