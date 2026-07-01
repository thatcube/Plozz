#!/usr/bin/env bash
#
# build-mpv-tvos.sh — produce libmpv + FFmpeg .xcframeworks for tvOS (Option A).
#
# STATUS: documented, validated build PATH for the dual-engine spike (P2). This
# wraps the maintained community project MPVKit (https://github.com/mpvkit/MPVKit),
# which is the current, real toolchain for cross-compiling mpv + FFmpeg for Apple
# platforms — including `tvos` (arm64 device) and `tvsimulator` slices — and
# packaging each library as an `.xcframework`. Building mpv+FFmpeg from scratch is
# a long (tens of minutes to hours), network- and toolchain-heavy operation, so
# this script is intentionally a thin, reproducible wrapper rather than a
# hand-rolled FFmpeg `./configure` (MPVKit already encodes the correct per-target
# flags). Run it on a Mac with Xcode + Homebrew when we actually adopt mpv.
#
# WHAT IT PRODUCES (under $OUT_DIR): Libmpv.xcframework plus the FFmpeg libraries
# (Libavcodec/Libavformat/Libavutil/Libavfilter/Libavdevice/Libswresample/
# Libswscale).xcframework, each with `appletvos` (arm64) + `appletvsimulator`
# (arm64+x86_64) slices. Point a SwiftPM `.binaryTarget` at the zipped results.
#
# LICENSING (App Store): MPVKit's DEFAULT build passes `--enable-nonfree`
# UNCONDITIONALLY, which makes every FFmpeg slice "nonfree and unredistributable"
# (CONFIG_NONFREE=1) — NOT App-Store-shippable. This script PATCHES MPVKit's
# FFmpeg configure to drop `--enable-nonfree` → `--disable-nonfree` (FFmpeg uses
# gnutls for TLS, not OpenSSL, so nonfree is unnecessary). It keeps
# `--enable-version3` and never passes `--enable-gpl`, yielding a decode-only
# build whose FFMPEG_LICENSE is "LGPL version 3 or later". See LGPL_COMPLIANCE.md.
#
# Usage:
#   tools/build-mpv-tvos.sh                 # build tvOS device + simulator (LGPL)
#   MPVKIT_REF=0.41.0-n8.1 tools/build-mpv-tvos.sh
#   OUT_DIR=/tmp/mpv-xcframeworks tools/build-mpv-tvos.sh
#
# Prereqs (install once):
#   xcode-select --install
#   brew install nasm pkg-config cmake meson ninja autoconf automake libtool
#
set -euo pipefail

MPVKIT_REPO="${MPVKIT_REPO:-https://github.com/mpvkit/MPVKit.git}"
# Pin to a known-good tag so builds are reproducible. 0.41.0-n8.1 == mpv 0.41.0
# + FFmpeg n8.1, the version validated in the P2 spike's Package.swift reference.
MPVKIT_REF="${MPVKIT_REF:-0.41.0-n8.1}"
# tvos = arm64 device slice; tvsimulator = arm64 + x86_64 simulator slice.
PLATFORMS="${PLATFORMS:-tvos,tvsimulator}"
WORK_DIR="${WORK_DIR:-$(mktemp -d -t mpvkit-build)}"
OUT_DIR="${OUT_DIR:-$(pwd)/dist/mpv-tvos}"

echo "==> MPVKit build for tvOS"
echo "    repo:      $MPVKIT_REPO @ $MPVKIT_REF"
echo "    platforms: $PLATFORMS"
echo "    work dir:  $WORK_DIR"
echo "    out dir:   $OUT_DIR"
echo "    license:   LGPL v3.0 (decode-only, GPL encoders NOT built)"

command -v xcodebuild >/dev/null || { echo "!! Xcode is required"; exit 1; }
command -v nasm >/dev/null || echo "!! 'nasm' missing — run: brew install nasm pkg-config cmake meson ninja"

echo "==> Cloning MPVKit (shallow)"
git clone --depth 1 --branch "$MPVKIT_REF" "$MPVKIT_REPO" "$WORK_DIR/MPVKit"
cd "$WORK_DIR/MPVKit"

# ---------------------------------------------------------------------------
# LGPL PATCH (Phase A): MPVKit hard-codes `--enable-nonfree` in its FFmpeg
# configure (Sources/BuildScripts/XCFrameworkBuild/main.swift), which taints the
# build as "nonfree and unredistributable". Flip it to `--disable-nonfree` so the
# result is genuinely LGPLv3 (decode-only). `--enable-version3` is left intact
# (→ LGPL v3) and `--enable-gpl` is never added. Verified after build:
#   FFMPEG_LICENSE == "LGPL version 3 or later", CONFIG_NONFREE 0, CONFIG_GPL 0.
# ---------------------------------------------------------------------------
FFMPEG_BUILD="Sources/BuildScripts/XCFrameworkBuild/main.swift"
echo "==> Patching out --enable-nonfree (LGPL-clean) in $FFMPEG_BUILD"
if grep -q '"--enable-cross-compile", "--enable-libxml2", "--enable-nonfree",' "$FFMPEG_BUILD"; then
  perl -0pi -e 's/"--enable-cross-compile", "--enable-libxml2", "--enable-nonfree",/"--enable-cross-compile", "--enable-libxml2", "--disable-nonfree",/' "$FFMPEG_BUILD"
elif grep -q -- '--disable-nonfree' "$FFMPEG_BUILD"; then
  echo "    (already patched)"
else
  echo "!! Could not find the --enable-nonfree flag to patch. MPVKit layout changed?"
  echo "   Inspect $FFMPEG_BUILD and ensure FFmpeg is configured --disable-nonfree."
  exit 1
fi
grep -n -- '--disable-nonfree\|--enable-gpl\|--enable-version3' "$FFMPEG_BUILD" || true

# MPVKit's `make build` runs its SwiftPM BuildScripts package, which:
#   * fetches + patches FFmpeg and mpv for the Apple SDKs,
#   * configures FFmpeg WITHOUT --enable-gpl (LGPL) for the requested platforms,
#   * builds libmpv (Metal/libplacebo render path) against that FFmpeg, and
#   * lipos per-arch static libs into .xcframeworks under ./dist.
# Passing `enable-gpl` here would flip it to GPL — we deliberately do NOT.
echo "==> Building (this can take a long time on first run)"
make build platform="$PLATFORMS"

echo "==> Collecting .xcframeworks into $OUT_DIR"
mkdir -p "$OUT_DIR"
# MPVKit emits zipped xcframeworks under dist/release (release) — copy whatever
# matches the LGPL (non -GPL) artifacts.
find dist -name '*.xcframework.zip' ! -name '*-GPL*' -exec cp -v {} "$OUT_DIR/" \; || true
find dist -name '*.xcframework' -maxdepth 3 ! -name '*-GPL*' -exec cp -Rv {} "$OUT_DIR/" \; 2>/dev/null || true

echo "==> Done. Artifacts in: $OUT_DIR"
echo "    Next: zip each .xcframework, run 'swift package compute-checksum',"
echo "    and reference them from a SwiftPM .binaryTarget."
