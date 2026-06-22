# mpv / FFmpeg tvOS build — VALIDATION RESULTS (P2 de-risk)

> Companion to `spikes/README.md` (Option A) and `tools/build-mpv-tvos.sh`.
> This file records an **actual run** of the pinned build on a dev Mac, proving
> the script produces valid, linkable `.xcframework`s for tvOS. It does **not**
> integrate mpv into the app.

## Verdict: ✅ BUILD SUCCEEDED — frameworks are well-formed and link end-to-end

`tools/build-mpv-tvos.sh` (MPVKit `0.41.0-n8.1` → mpv 0.41.0 + FFmpeg n8.1,
`make build platform=tvos,tvsimulator`, **no `--enable-gpl`**) ran to completion
and emitted all expected xcframeworks. A standalone tvOS `arm64` executable that
calls `mpv_create()` was linked against the built `libmpv` + FFmpeg + every
dependency static lib — **link succeeded**, `_mpv_create` resolves.

## Environment

- Machine: Apple Silicon Mac, macOS (Darwin), Xcode 27.0 (`Xcode-beta.app`),
  AppleTVOS 27.0 SDK.
- MPVKit ref (pinned, unchanged): `0.41.0-n8.1`.
- Build wall-clock: **~530 s (~8m50s)** for the script itself (FFmpeg + libmpv
  compile). Fast because MPVKit downloads **prebuilt** xcframeworks for the heavy
  deps (gnutls, dav1d, libplacebo, libass, MoltenVK, shaderc, …); only FFmpeg and
  libmpv are compiled locally. Plus ~5 min one-time Homebrew tool install.

## Host tools that had to be installed (one-time)

```
brew install nasm pkg-config cmake meson ninja autoconf automake libtool
```
(GNU `libtool` installs as `glibtool`; Homebrew prefixes it. The build worked with
`/opt/homebrew/opt/libtool/libexec/gnubin` on PATH.) Xcode + Homebrew were already
present. **No source patches were required** — the pinned script ran as-is.

## Emitted xcframeworks (LGPL/non-GPL artifacts)

Locally built and collected (each has a `tvos-arm64_arm64e` device slice +
`tvos-arm64_x86_64-simulator` slice):

| xcframework            | zip size | device-slice binary |
|------------------------|---------:|--------------------:|
| Libmpv.xcframework     |  4.5 MB  |  5.9 MB             |
| Libavcodec.xcframework | 17.0 MB  | 19.8 MB             |
| Libavformat.xcframework|  4.0 MB  |  4.7 MB             |
| Libswscale.xcframework |  2.2 MB  |  2.9 MB             |
| Libavutil.xcframework  |  2.2 MB  |  2.2 MB             |
| Libavfilter.xcframework|  1.7 MB  |  2.3 MB             |
| Libswresample.xcframework | 240 KB|  0.2 MB             |
| Libavdevice.xcframework|  32 KB   |  ~0                 |
| MoltenVK.xcframework   | (sep.)   | (Metal/Vulkan shim) |

**FFmpeg + libmpv device code ≈ 38 MB** (arm64 + arm64e, unstripped). A real
integration also vends the prebuilt dep xcframeworks MPVKit downloads
(libplacebo, dav1d, libass, gnutls, gmp, nettle, openssl, lcms2, libuavs3d,
libdovi, libbluray, libsmbclient, libuchardet, libunibreak, freetype, fribidi,
harfbuzz, shaderc) — comparable order of magnitude to the README's ~60–120 MB
estimate before App Store thinning.

## Well-formedness checks (all pass)

- `lipo -info` Libmpv **device**: `arm64 arm64e`; **simulator**: `x86_64 arm64`.
  FFmpeg libs (checked Libavcodec) identical slice layout.
- `Info.plist`: `LibraryIdentifier` = `tvos-arm64_arm64e` and
  `tvos-arm64_x86_64-simulator`; `SupportedPlatform = tvos`.
- `otool -l` device slice: `platform 3` (tvOS), `minos 14.0` — not a simulator
  binary mislabeled.
- `nm` device slice: `_mpv_create`, `_mpv_command`, `_mpv_command_node`, … are
  defined (`T`) and exported. Headers present: `client.h`, `render.h`,
  `render_gl.h`, `stream_cb.h`.
- **End-to-end link proof:** a tiny `t.c` calling `mpv_create()` +
  `mpv_client_api_version()` linked for `arm64-apple-tvos` against `libmpv.a` +
  all FFmpeg/dep `.a`s + system frameworks → **38 MB Mach-O arm64 executable**,
  `_mpv_create` present. Required system frameworks when linking by hand:
  `VideoToolbox AudioToolbox CoreMedia CoreVideo Metal MetalKit IOSurface
  AVFoundation CoreAudio CoreText CoreGraphics Security QuartzCore UIKit
  OpenGLES` (+ `-lc++ -lz -lbz2 -liconv -lxml2 -lresolv`). In a real SwiftPM
  integration MPVKit's `Package.swift` declares these `linkerSettings`
  automatically.

## ⚠️ Licensing caveat (important — contradicts the script comment)

The script/README say the default build is "LGPL v3.0". The **actual** FFmpeg
config produced on every slice is:

```
#define CONFIG_GPL    0      // good: no GPL
#define CONFIG_NONFREE 1     // <-- nonfree
#define FFMPEG_LICENSE "nonfree and unredistributable"
```

MPVKit passes `--enable-nonfree` **unconditionally** in its default (non-GPL)
config. `--enable-gpl` is correctly NOT set, but `--enable-nonfree` still makes
the FFmpeg build **"nonfree and unredistributable"** under FFmpeg's terms — which
is **not** App-Store-shippable as-is and is **not** the clean LGPLv3 the spike
assumed. Before adopting mpv we must customize MPVKit's FFmpeg `configure` to
drop `--enable-nonfree` (and remove whatever pulls it in — typically the OpenSSL
combo; gnutls is already enabled, so OpenSSL is likely droppable) to get a
genuinely redistributable LGPLv3 build. **This is a config change, not a
blocker.**

## Adoption difficulty for `EngineMPV` (recommendation)

**Building mpv is NOT the risk — it's easy and fast (~9 min, no patches).** The
remaining work to adopt libmpv behind the `VideoEngine` protocol is moderate:

1. **Fix licensing:** rebuild FFmpeg without `--enable-nonfree` (custom MPVKit
   config) and verify `FFMPEG_LICENSE` becomes `LGPL version 3 or later`. *(must-do)*
2. **Packaging:** either depend on the upstream `MPVKit` SwiftPM product, or zip
   + `swift package compute-checksum` our own ~10–20 `.binaryTarget`s and host
   them. Wrap in a Plozz `EngineMPV` module conforming to `VideoEngine`.
3. **Playback glue:** the real engineering is the mpv render loop (Metal
   `mpv_render_context` via `render.h`) + property/event wiring + audio routing —
   normal player work, independent of the build.

Net: the cross-compile toolchain is **de-risked and reproducible**. Keep the
spike's staging (VLCKit first, mpv later) — the only mpv-specific gotcha
surfaced here is the **nonfree FFmpeg default**, which must be corrected for the
App Store.

## Reproduce

```bash
brew install nasm pkg-config cmake meson ninja autoconf automake libtool
PATH="/opt/homebrew/opt/libtool/libexec/gnubin:$PATH" \
OUT_DIR=/tmp/mpv-out WORK_DIR=/tmp/mpv-work \
  tools/build-mpv-tvos.sh
# artifacts: $OUT_DIR/*.xcframework(.zip); lipo -info each device slice.
```
Built binaries are intentionally **not** committed (large); they live in a build
dir outside the repo and are regenerated by the script.
