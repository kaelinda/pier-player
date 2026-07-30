#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
app_dir="$(cd "$script_dir/../.." && pwd)"
fixture_dir="$app_dir/Shared/Tests/Fixtures"

fail() {
    echo "media-fixtures-test: $*" >&2
    exit 1
}

command -v ffprobe >/dev/null || fail "ffprobe is required to validate authored fixtures"
command -v jq >/dev/null || fail "jq is required to validate authored fixtures"
[[ -f "$fixture_dir/SHA256SUMS" ]] || fail "missing Shared/Tests/Fixtures/SHA256SUMS"

(
    cd "$fixture_dir"
    shasum -a 256 -c SHA256SUMS >/dev/null
) || fail "fixture hash mismatch"

assert_media() {
    local name="$1"
    local expected_video="$2"
    local expected_audio="$3"
    local expected_subtitle="${4:-}"
    local file="$fixture_dir/$name"
    [[ -f "$file" ]] || fail "missing fixture: $name"

    local metadata
    metadata="$(ffprobe -v error -show_entries format=duration -show_entries stream=codec_type,codec_name -of json "$file")"
    local duration
    duration="$(jq -r '.format.duration | tonumber' <<<"$metadata")"
    awk -v value="$duration" 'BEGIN { exit !(value >= 1 && value <= 3) }' || {
        fail "$name duration is outside 1-3 seconds: $duration"
    }

    local video
    local audio
    local subtitle
    video="$(jq -r '.streams[] | select(.codec_type == "video") | .codec_name' <<<"$metadata" | head -n 1)"
    audio="$(jq -r '.streams[] | select(.codec_type == "audio") | .codec_name' <<<"$metadata" | head -n 1)"
    subtitle="$(jq -r '.streams[] | select(.codec_type == "subtitle") | .codec_name' <<<"$metadata" | head -n 1)"
    [[ "$video" == "$expected_video" ]] || fail "$name video codec: expected $expected_video, got $video"
    [[ "$audio" == "$expected_audio" ]] || fail "$name audio codec: expected $expected_audio, got $audio"
    [[ "$subtitle" == "$expected_subtitle" ]] || fail "$name subtitle codec: expected $expected_subtitle, got $subtitle"
}

assert_media video-h264-aac.mkv h264 aac
assert_media video-h264-aac.mp4 h264 aac
assert_media video-vp9-opus.webm vp9 opus
assert_media video-mpeg4-mp3.avi mpeg4 mp3
assert_media video-mpeg2-ac3.ts mpeg2video ac3
assert_media video-h264-aac-srt.mkv h264 aac subrip

for subtitle in video-h264-aac.en.srt video-h264-aac.ass; do
    [[ -s "$fixture_dir/$subtitle" ]] || fail "missing subtitle fixture: $subtitle"
done

echo "media-fixtures-test: passed"
