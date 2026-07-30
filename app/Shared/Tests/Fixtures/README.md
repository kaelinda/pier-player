# Generated Media Fixtures

These files contain only short FFmpeg `testsrc2` patterns, generated 1 kHz sine
tones, and synthetic subtitle text. They contain no copyrighted media
or credentials.

Regenerate them from `app/` with:

```bash
scripts/generate-media-fixtures.sh
scripts/tests/media-fixtures-test.sh
```

The fixtures were authored with FFmpeg 7.1.1 using the exact commands in the
generation script. The application and its tests do not execute or link that
host FFmpeg; playback tests consume the files through the bundled LGPL FFmpeg
8.1.2 framework.
