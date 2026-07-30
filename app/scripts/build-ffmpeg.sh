#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
app_dir="$(cd "$script_dir/.." && pwd)"
version="8.1.2"
source_name="ffmpeg-$version.tar.xz"
source_url="https://ffmpeg.org/releases/$source_name"
source_sha256="464beb5e7bf0c311e68b45ae2f04e9cc2af88851abb4082231742a74d97b524c"
deployment_target="14.0"
build_root="${PIER_FFMPEG_BUILD_DIR:-$app_dir/.build/ffmpeg}"
vendor_dir="$app_dir/Vendor/FFmpeg"
native_dir="$app_dir/Native/PierFFmpeg"
archive="$build_root/$source_name"
source_dir="$build_root/ffmpeg-$version"
framework_name="PierFFmpeg"
xcframework="$vendor_dir/$framework_name.xcframework"

configure_flags=(
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
    --enable-zlib
    --enable-bzlib
    --enable-videotoolbox
    --enable-audiotoolbox
)

log() {
    echo "build-ffmpeg: $*"
}

sha256() {
    shasum -a 256 "$1" | awk '{print $1}'
}

require_safe_build_root() {
    case "$build_root" in
        "$app_dir/.build/ffmpeg"|/tmp/pier-ffmpeg-build.*) ;;
        *)
            echo "build-ffmpeg: refusing unsafe build directory: $build_root" >&2
            exit 1
            ;;
    esac
}

require_safe_build_root
mkdir -p "$build_root" "$vendor_dir/LICENSES"

if [[ ! -f "$archive" ]]; then
    log "downloading $source_url"
    curl -fL "$source_url" -o "$archive"
fi

actual_source_sha256="$(sha256 "$archive")"
if [[ "$actual_source_sha256" != "$source_sha256" ]]; then
    echo "build-ffmpeg: source hash mismatch" >&2
    echo "expected: $source_sha256" >&2
    echo "actual:   $actual_source_sha256" >&2
    exit 1
fi

if [[ ! -x "$source_dir/configure" ]]; then
    log "extracting $source_name"
    tar -xf "$archive" -C "$build_root"
fi

jobs="$(sysctl -n hw.logicalcpu 2>/dev/null || echo 4)"
dylibs=()

for architecture in arm64 x86_64; do
    architecture_build="$build_root/build-$architecture"
    prefix="$build_root/prefix-$architecture"
    architecture_flags=(--arch="$architecture")
    if [[ "$architecture" == "x86_64" ]]; then
        architecture_flags+=(--disable-x86asm)
    fi

    if [[ "${PIER_FFMPEG_FORCE_REBUILD:-0}" == "1" || ! -f "$prefix/lib/libavformat.a" ]]; then
        rm -rf "$architecture_build" "$prefix"
        mkdir -p "$architecture_build"

        log "configuring $architecture"
        (
            cd "$architecture_build"
            "$source_dir/configure" \
                --prefix="$prefix" \
                --target-os=darwin \
                --cc="xcrun -sdk macosx clang -arch $architecture" \
                --extra-cflags="-mmacosx-version-min=$deployment_target" \
                --extra-ldflags="-mmacosx-version-min=$deployment_target" \
                "${configure_flags[@]}" \
                "${architecture_flags[@]}"
            make -j"$jobs"
            make install
        )
    else
        log "reusing FFmpeg libraries for $architecture"
    fi

    bridge_objects=()
    for source in "$native_dir"/src/*.c; do
        object="$architecture_build/$(basename "${source%.c}").o"
        xcrun -sdk macosx clang \
            -arch "$architecture" \
            -mmacosx-version-min="$deployment_target" \
            -std=c17 \
            -fPIC \
            -fvisibility=hidden \
            -I"$native_dir/include" \
            -I"$prefix/include" \
            -c "$source" \
            -o "$object"
        bridge_objects+=("$object")
    done

    dylib="$architecture_build/$framework_name"
    xcrun -sdk macosx clang \
        -arch "$architecture" \
        -mmacosx-version-min="$deployment_target" \
        -dynamiclib \
        -Wl,-install_name,"@rpath/$framework_name.framework/Versions/A/$framework_name" \
        -Wl,-compatibility_version,1.0.0 \
        -Wl,-current_version,"$version" \
        -Wl,-exported_symbols_list,"$native_dir/exports.txt" \
        "${bridge_objects[@]}" \
        -Wl,-force_load,"$prefix/lib/libavformat.a" \
        -Wl,-force_load,"$prefix/lib/libavcodec.a" \
        -Wl,-force_load,"$prefix/lib/libswresample.a" \
        -Wl,-force_load,"$prefix/lib/libswscale.a" \
        -Wl,-force_load,"$prefix/lib/libavutil.a" \
        -framework AudioToolbox \
        -framework VideoToolbox \
        -framework CoreFoundation \
        -framework CoreMedia \
        -framework CoreVideo \
        -framework CoreServices \
        -lz \
        -lbz2 \
        -lm \
        -o "$dylib"
    strip -x "$dylib"
    dylibs+=("$dylib")
done

framework_root="$build_root/$framework_name.framework"
rm -rf "$framework_root" "$xcframework"
mkdir -p \
    "$framework_root/Versions/A/Headers" \
    "$framework_root/Versions/A/Modules" \
    "$framework_root/Versions/A/Resources"

lipo -create "${dylibs[@]}" -output "$framework_root/Versions/A/$framework_name"
cp "$native_dir/include/PierFFmpeg.h" "$framework_root/Versions/A/Headers/"

cat > "$framework_root/Versions/A/Modules/module.modulemap" <<'MODULEMAP'
framework module PierFFmpeg {
    umbrella header "PierFFmpeg.h"
    export *
    module * { export * }
}
MODULEMAP

cat > "$framework_root/Versions/A/Resources/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>$framework_name</string>
    <key>CFBundleIdentifier</key><string>dev.pierplayer.PierFFmpeg</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>$framework_name</string>
    <key>CFBundlePackageType</key><string>FMWK</string>
    <key>CFBundleShortVersionString</key><string>$version</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>MinimumOSVersion</key><string>$deployment_target</string>
</dict>
</plist>
PLIST

ln -s A "$framework_root/Versions/Current"
ln -s Versions/Current/Headers "$framework_root/Headers"
ln -s Versions/Current/Modules "$framework_root/Modules"
ln -s Versions/Current/Resources "$framework_root/Resources"
ln -s Versions/Current/$framework_name "$framework_root/$framework_name"

xcodebuild -create-xcframework \
    -framework "$framework_root" \
    -output "$xcframework"

cp "$source_dir/COPYING.LGPLv2.1" \
    "$vendor_dir/LICENSES/FFmpeg-LGPL-2.1-or-later.txt"

configuration="${configure_flags[*]}"
cat > "$vendor_dir/BUILD-METADATA.txt" <<METADATA
FFMPEG_VERSION=$version
FFMPEG_SOURCE_URL=$source_url
FFMPEG_SOURCE_SHA256=$source_sha256
MACOS_DEPLOYMENT_TARGET=$deployment_target
ARCHITECTURES=arm64 x86_64
X86_64_EXTRA_FLAGS=--disable-x86asm
CONFIGURE_FLAGS=$configuration
METADATA

binary="$xcframework/macos-arm64_x86_64/$framework_name.framework/Versions/A/$framework_name"
cat > "$vendor_dir/SHA256SUMS" <<SUMS
$source_sha256  $source_name
$(sha256 "$binary")  PierFFmpeg.xcframework/macos-arm64_x86_64/PierFFmpeg.framework/Versions/A/PierFFmpeg
SUMS

log "built $xcframework"
