#!/usr/bin/env bash
#
# stage-mpv-frameworks.sh — stage the LGPL-clean FFmpeg + libmpv xcframeworks that
# EngineMPV's local-path `.binaryTarget`s reference (Frameworks/mpv/).
#
# These binaries are large and are NOT committed (see .gitignore). Run this once
# after building them with tools/build-mpv-tvos.sh so `xcodebuild`/SwiftPM can
# resolve EngineMPV. The remaining dependency xcframeworks (gnutls, MoltenVK,
# libplacebo, …) are pulled by URL by SwiftPM and don't need staging.
#
# Usage:
#   # 1. Build the LGPL-clean xcframeworks (≈9 min), producing the release zips:
#   tools/build-mpv-tvos.sh
#   # 2. Stage them into Frameworks/mpv/ from the build's release dir:
#   MPV_RELEASE_DIR=/path/to/MPVKit/dist/release tools/stage-mpv-frameworks.sh
#
# If MPV_RELEASE_DIR is unset, this looks for the most recent
# */dist/release/*.xcframework.zip under $TMPDIR and the repo's dist/.
#
# NOTE: build-mpv-tvos.sh MUST have been run with the `--disable-nonfree` patch
# (no `--enable-nonfree`, no `--enable-gpl`) so the FFmpeg slices are
# "LGPL version 3 or later". See NOTICE.md.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$REPO_ROOT/Frameworks/mpv"
FRAMEWORKS=(Libmpv Libavcodec Libavdevice Libavfilter Libavformat Libavutil Libswresample Libswscale)

RELEASE_DIR="${MPV_RELEASE_DIR:-}"
if [[ -z "$RELEASE_DIR" ]]; then
  # Best-effort discovery of a release dir containing the zips.
  RELEASE_DIR="$(find "${TMPDIR:-/tmp}" "$REPO_ROOT/dist" -type f -name 'Libmpv.xcframework.zip' 2>/dev/null \
    | head -1 | xargs -I{} dirname {} || true)"
fi

if [[ -z "$RELEASE_DIR" || ! -d "$RELEASE_DIR" ]]; then
  echo "!! Could not locate the build's release dir with the xcframework zips."
  echo "   Set MPV_RELEASE_DIR=/path/to/MPVKit/dist/release and re-run."
  exit 1
fi

echo "==> Staging LGPL-clean xcframeworks"
echo "    from: $RELEASE_DIR"
echo "    to:   $DEST"
mkdir -p "$DEST"

for fw in "${FRAMEWORKS[@]}"; do
  zip="$RELEASE_DIR/$fw.xcframework.zip"
  if [[ ! -f "$zip" ]]; then
    echo "!! Missing $zip — did tools/build-mpv-tvos.sh complete?"
    exit 1
  fi
  rm -rf "$DEST/$fw.xcframework"
  unzip -q -o "$zip" -d "$DEST"
  echo "    staged $fw.xcframework"
done

# Sanity: confirm the FFmpeg license is LGPL (not nonfree/GPL) in a built slice.
CFG="$(find "$DEST/Libavformat.xcframework" -name config.h | head -1 || true)"
if [[ -n "$CFG" ]]; then
  echo "==> FFmpeg license check ($CFG):"
  grep -E 'FFMPEG_LICENSE|CONFIG_NONFREE|CONFIG_GPL ' "$CFG" || true
fi

echo "==> Done. EngineMPV can now be built:"
echo "    xcodegen generate && env -u GIT_CONFIG_COUNT -u GIT_CONFIG_KEY_0 -u GIT_CONFIG_VALUE_0 \\"
echo "      xcodebuild build -project Plozz.xcodeproj -scheme EngineMPVProbe \\"
echo "      -destination 'generic/platform=tvOS Simulator' CODE_SIGNING_ALLOWED=NO"
