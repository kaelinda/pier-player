#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
app_dir="$(cd "$script_dir/../.." && pwd)"
metadata="$app_dir/Vendor/FFmpeg/BUILD-METADATA.txt"
framework="$app_dir/Vendor/FFmpeg/PierFFmpeg.xcframework/macos-arm64_x86_64/PierFFmpeg.framework/Versions/A/PierFFmpeg"

fail() {
    echo "ffmpeg-build-config-test: $*" >&2
    exit 1
}

require_file() {
    [[ -f "$1" ]] || fail "missing file: ${1#$app_dir/}"
}

require_line() {
    local expected="$1"
    local file="$2"
    grep -Fqx -- "$expected" "$file" || fail "missing metadata line: $expected"
}

require_file "$metadata"
require_file "$app_dir/Vendor/FFmpeg/SHA256SUMS"
require_file "$app_dir/Vendor/FFmpeg/SOURCE.md"
require_file "$app_dir/Vendor/FFmpeg/LICENSES/FFmpeg-LGPL-2.1-or-later.txt"
require_file "$framework"
require_file "$app_dir/scripts/build-ffmpeg.sh"
require_file "$app_dir/scripts/verify-ffmpeg.sh"

require_line "FFMPEG_VERSION=8.1.2" "$metadata"
require_line "FFMPEG_SOURCE_SHA256=464beb5e7bf0c311e68b45ae2f04e9cc2af88851abb4082231742a74d97b524c" "$metadata"
require_line "MACOS_DEPLOYMENT_TARGET=14.0" "$metadata"
require_line "ARCHITECTURES=arm64 x86_64" "$metadata"

required_flags=(
    --disable-autodetect
    --disable-programs
    --disable-doc
    --disable-debug
    --disable-avdevice
    --disable-avfilter
    --disable-network
    --disable-encoders
    --disable-muxers
    --disable-filters
    --disable-devices
    --enable-pic
    --enable-static
    --disable-shared
    --enable-videotoolbox
    --enable-audiotoolbox
)

for flag in "${required_flags[@]}"; do
    grep -Fq -- "$flag" "$metadata" || fail "missing configure flag: $flag"
done

for forbidden in --enable-gpl --enable-nonfree --enable-libx264 --enable-libx265; do
    if grep -Fq -- "$forbidden" "$metadata"; then
        fail "forbidden configure flag: $forbidden"
    fi
done

architectures="$(lipo -archs "$framework")"
[[ "$architectures" == *arm64* ]] || fail "framework is missing arm64"
[[ "$architectures" == *x86_64* ]] || fail "framework is missing x86_64"

install_name="$(otool -D "$framework" | tail -n 1 | tr -d '[:space:]')"
[[ "$install_name" == "@rpath/PierFFmpeg.framework/Versions/A/PierFFmpeg" ]] || {
    fail "unexpected install name: $install_name"
}

"$app_dir/scripts/verify-ffmpeg.sh"
echo "ffmpeg-build-config-test: passed"
