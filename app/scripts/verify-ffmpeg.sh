#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
app_dir="$(cd "$script_dir/.." && pwd)"
vendor_dir="$app_dir/Vendor/FFmpeg"
metadata="$vendor_dir/BUILD-METADATA.txt"
framework="$vendor_dir/PierFFmpeg.xcframework/macos-arm64_x86_64/PierFFmpeg.framework"
binary="$framework/Versions/A/PierFFmpeg"

fail() {
    echo "verify-ffmpeg: $*" >&2
    exit 1
}

for file in "$metadata" "$binary" "$vendor_dir/SHA256SUMS"; do
    [[ -f "$file" ]] || fail "missing ${file#$app_dir/}"
done

grep -Fqx 'FFMPEG_VERSION=8.1.2' "$metadata" || fail "unexpected FFmpeg version"
grep -Fqx 'FFMPEG_SOURCE_SHA256=464beb5e7bf0c311e68b45ae2f04e9cc2af88851abb4082231742a74d97b524c' "$metadata" || {
    fail "unexpected source hash"
}

for forbidden in --enable-gpl --enable-nonfree --enable-libx264 --enable-libx265; do
    if grep -Fq -- "$forbidden" "$metadata"; then
        fail "forbidden configure flag: $forbidden"
    fi
done

architectures="$(lipo -archs "$binary")"
[[ "$architectures" == *arm64* && "$architectures" == *x86_64* ]] || {
    fail "expected arm64 and x86_64, got: $architectures"
}

install_name="$(otool -D "$binary" | tail -n 1 | tr -d '[:space:]')"
[[ "$install_name" == '@rpath/PierFFmpeg.framework/Versions/A/PierFFmpeg' ]] || {
    fail "unexpected install name: $install_name"
}

while IFS= read -r dependency; do
    case "$dependency" in
        "$binary"|@rpath/PierFFmpeg.framework/*|/System/Library/*|/usr/lib/*) ;;
        *) fail "unexpected dynamic dependency: $dependency" ;;
    esac
done < <(otool -L "$binary" | tail -n +2 | sed 's/^[[:space:]]*//' | awk '{print $1}')

unexpected_exports="$(
    nm -gU "$binary" \
        | awk '{print $NF}' \
        | grep -v '^_ppff_' \
        || true
)"
[[ -z "$unexpected_exports" ]] || fail "unexpected exported symbols: $unexpected_exports"

for symbol in _ppff_version _ppff_configuration _ppff_license; do
    nm -gU "$binary" | awk '{print $NF}' | grep -Fqx "$symbol" || fail "missing export: $symbol"
done

expected_binary_hash="$(awk '$2 ~ /PierFFmpeg\.xcframework/ {print $1}' "$vendor_dir/SHA256SUMS")"
actual_binary_hash="$(shasum -a 256 "$binary" | awk '{print $1}')"
[[ -n "$expected_binary_hash" && "$actual_binary_hash" == "$expected_binary_hash" ]] || {
    fail "framework hash mismatch"
}

runtime_dir="$(mktemp -d /tmp/pier-ffmpeg-verify.XXXXXX)"
trap 'rm -rf "$runtime_dir"' EXIT
cat > "$runtime_dir/main.c" <<'SOURCE'
#include <stdio.h>
#include <PierFFmpeg/PierFFmpeg.h>

int main(void) {
    puts(ppff_version());
    puts(ppff_license());
    puts(ppff_configuration());
    return 0;
}
SOURCE

framework_parent="$(dirname "$framework")"
xcrun -sdk macosx clang \
    -F"$framework_parent" \
    "$runtime_dir/main.c" \
    -framework PierFFmpeg \
    -Wl,-rpath,"$framework_parent" \
    -o "$runtime_dir/verify-runtime"
runtime_output="$("$runtime_dir/verify-runtime")"
runtime_version="$(sed -n '1p' <<<"$runtime_output")"
runtime_license="$(sed -n '2p' <<<"$runtime_output")"
runtime_configuration="$(sed -n '3p' <<<"$runtime_output")"

[[ "$runtime_version" == '8.1.2' ]] || fail "unexpected runtime version: $runtime_version"
[[ "$runtime_license" == 'LGPL version 2.1 or later' ]] || {
    fail "unexpected runtime license: $runtime_license"
}
for forbidden in --enable-gpl --enable-nonfree --enable-libx264 --enable-libx265; do
    [[ "$runtime_configuration" != *"$forbidden"* ]] || fail "runtime contains forbidden flag: $forbidden"
done

echo "verify-ffmpeg: passed ($architectures, $actual_binary_hash)"
