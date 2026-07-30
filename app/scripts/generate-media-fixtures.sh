#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
app_dir="$(cd "$script_dir/.." && pwd)"
fixture_dir="$app_dir/Shared/Tests/Fixtures"

command -v ffmpeg >/dev/null || {
    echo "generate-media-fixtures: ffmpeg is required for fixture authoring" >&2
    exit 1
}

mkdir -p "$fixture_dir"

video_source="testsrc2=size=320x180:rate=24:duration=2"
audio_source="sine=frequency=1000:sample_rate=48000:duration=2"
common=(
    -hide_banner
    -loglevel error
    -y
    -f lavfi -i "$video_source"
    -f lavfi -i "$audio_source"
    -map_metadata -1
    -shortest
)

ffmpeg "${common[@]}" \
    -c:v libx264 -preset ultrafast -pix_fmt yuv420p -g 24 -keyint_min 24 -sc_threshold 0 \
    -c:a aac -b:a 96k \
    "$fixture_dir/video-h264-aac.mkv"

ffmpeg "${common[@]}" \
    -c:v libx264 -preset ultrafast -pix_fmt yuv420p -g 24 -keyint_min 24 -sc_threshold 0 \
    -c:a aac -b:a 96k -movflags +faststart \
    "$fixture_dir/video-h264-aac.mp4"

ffmpeg "${common[@]}" \
    -c:v libvpx-vp9 -deadline good -cpu-used 4 -row-mt 1 -pix_fmt yuv420p -g 24 \
    -c:a libopus -b:a 96k \
    "$fixture_dir/video-vp9-opus.webm"

ffmpeg "${common[@]}" \
    -c:v mpeg4 -q:v 5 -pix_fmt yuv420p -g 24 \
    -c:a libmp3lame -b:a 96k \
    "$fixture_dir/video-mpeg4-mp3.avi"

ffmpeg "${common[@]}" \
    -c:v mpeg2video -q:v 5 -pix_fmt yuv420p -g 24 \
    -c:a ac3 -b:a 192k -f mpegts \
    "$fixture_dir/video-mpeg2-ac3.ts"

ffmpeg -hide_banner -loglevel error -y \
    -i "$fixture_dir/video-h264-aac.mkv" \
    -i "$fixture_dir/video-h264-aac.en.srt" \
    -map 0:v -map 0:a -map 1:0 \
    -c copy -c:s srt \
    -metadata:s:s:0 language=eng -disposition:s:0 default \
    "$fixture_dir/video-h264-aac-srt.mkv"

(
    cd "$fixture_dir"
    shasum -a 256 \
        video-h264-aac.mkv \
        video-h264-aac.mp4 \
        video-vp9-opus.webm \
        video-mpeg4-mp3.avi \
        video-mpeg2-ac3.ts \
        video-h264-aac-srt.mkv \
        video-h264-aac.en.srt \
        video-h264-aac.ass \
        > SHA256SUMS
)

echo "generate-media-fixtures: wrote fixtures to $fixture_dir"
