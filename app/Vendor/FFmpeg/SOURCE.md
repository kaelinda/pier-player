# FFmpeg Source And Replacement

Pier Player uses FFmpeg 8.1.2 from:

`https://ffmpeg.org/releases/ffmpeg-8.1.2.tar.xz`

The expected SHA-256 is:

`464beb5e7bf0c311e68b45ae2f04e9cc2af88851abb4082231742a74d97b524c`

Run `scripts/build-ffmpeg.sh` from `app/` to download, verify, and rebuild the
macOS arm64/x86_64 dynamic XCFramework. The complete configure flags are written
to `BUILD-METADATA.txt` and checked by `scripts/verify-ffmpeg.sh`.

The framework is dynamically loaded by the application. A recipient may rebuild
FFmpeg or the project bridge, replace `PierFFmpeg.framework`, and re-sign the
application for local use. Pier Player does not impose restrictions against
reverse engineering performed to debug modifications to the LGPL library.

FFmpeg is Copyright (c) 2000-2026 the FFmpeg developers and is distributed under
the GNU Lesser General Public License version 2.1 or later under this build
configuration. See `LICENSES/FFmpeg-LGPL-2.1-or-later.txt`.
