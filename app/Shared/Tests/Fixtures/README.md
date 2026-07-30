# Generated Media Fixtures

These files contain only short FFmpeg `testsrc2` patterns, generated 1 kHz sine
tones, and synthetic subtitle text. They contain no copyrighted media
or credentials.

Regenerate them from `app/` with:

```bash
scripts/generate-media-fixtures.sh
scripts/tests/media-fixtures-test.sh
```

The fixtures were authored with FFmpeg 7.1.1 and MKVToolNix 100.0 using the
exact commands in the generation script. MKVToolNix is an authoring-only GPL
tool; the application does not execute or link it. Playback tests consume the
files through the bundled LGPL FFmpeg 8.1.2 framework.

`video-h264-aac-zlib.mkv` contains zlib-compressed H.264 and AAC tracks inside
the Matroska container. It verifies ContentEncoding decompression through
probe, seek, decode, and clean EOF.

`video-h264-aac-large-attachment.mkv.zlib` expands to an MKV with a generated
6 MiB zero-filled attachment before the media packets. It exercises realistic
large Matroska headers without adding a multi-megabyte binary to Git.
