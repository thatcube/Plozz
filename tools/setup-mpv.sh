#!/usr/bin/env bash
#
# setup-mpv.sh — make the CURRENT worktree buildable with EngineMPV in seconds.
#
# EngineMPV's libmpv + FFmpeg xcframeworks (Frameworks/mpv/, ~78 MB, 8 frameworks)
# are large, LGPL-clean local binaries that are gitignored and NEVER committed
# (see .gitignore / NOTICE.md). So a freshly created worktree or any
# branch that merged main can't build mpv until those binaries are present.
#
# This script populates Frameworks/mpv/ from a shared on-disk CACHE using an
# APFS clone (copy-on-write: instant, ~0 extra disk). The expensive ~9-minute
# tools/build-mpv-tvos.sh rebuild happens at most ONCE per machine (to seed the
# cache); every worktree after that is set up in well under a second.
#
#   Usage:
#     tools/setup-mpv.sh           # clone from cache (default; instant on APFS)
#     tools/setup-mpv.sh --symlink # symlink to the cache instead of cloning
#     tools/setup-mpv.sh --copy    # force a full byte copy (cross-volume safe)
#     tools/setup-mpv.sh --refresh # re-seed the cache from this worktree's frameworks
#
# Cache location: $PLOZZ_MPV_CACHE (default: ~/Library/Caches/plozz-mpv/mpv).
#
# Resolution order when the cache is empty (each seeds the cache for next time):
#   1. A sibling worktree that already has Frameworks/mpv staged.
#   2. tools/stage-mpv-frameworks.sh (unzips existing build zips).
#   3. tools/build-mpv-tvos.sh + stage (the slow ~9-min path; last resort).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$REPO_ROOT/Frameworks/mpv"
CACHE="${PLOZZ_MPV_CACHE:-$HOME/Library/Caches/plozz-mpv/mpv}"
FRAMEWORKS=(Libmpv Libavcodec Libavdevice Libavfilter Libavformat Libavutil Libswresample Libswscale)

MODE="clone"
case "${1:-}" in
  --symlink) MODE="symlink" ;;
  --copy)    MODE="copy" ;;
  --clone|"") MODE="clone" ;;
  --refresh) MODE="refresh" ;;
  *) echo "Unknown option: $1" >&2; exit 2 ;;
esac

# True if $1 contains all 8 xcframeworks (a usable staging dir).
have_all() {
  local base="$1"
  [[ -d "$base" ]] || return 1
  for fw in "${FRAMEWORKS[@]}"; do
    [[ -e "$base/$fw.xcframework/Info.plist" ]] || return 1
  done
  return 0
}

seed_cache_from() {
  local src="$1"
  echo "==> Seeding cache from: $src"
  rm -rf "$CACHE"
  mkdir -p "$(dirname "$CACHE")"
  cp -Rc "$src" "$CACHE" 2>/dev/null || cp -R "$src" "$CACHE"
}

# --refresh: re-seed the shared cache from this worktree's current frameworks.
if [[ "$MODE" == "refresh" ]]; then
  if ! have_all "$DEST"; then
    echo "!! Frameworks/mpv is not fully staged here, nothing to refresh from." >&2
    exit 1
  fi
  seed_cache_from "$DEST"
  echo "✓ Cache refreshed at $CACHE"
  exit 0
fi

# 0. Already good in this worktree? Done.
if have_all "$DEST"; then
  echo "✓ Frameworks/mpv already present — nothing to do."
  exit 0
fi

# 1. Make sure the shared cache is populated (do the expensive work at most once).
if ! have_all "$CACHE"; then
  echo "==> mpv cache is empty ($CACHE)"

  # 1a. Borrow from a sibling worktree that already staged them.
  SIBLING=""
  while IFS= read -r d; do
    if have_all "$d"; then SIBLING="$d"; break; fi
  done < <(find "$REPO_ROOT/.." -maxdepth 4 -type d -path '*/Frameworks/mpv' 2>/dev/null)

  if [[ -n "$SIBLING" ]]; then
    seed_cache_from "$SIBLING"
  else
    # 1b. Stage from existing build zips (fast), then 1c. full build (slow).
    echo "==> No sibling has them; staging from build zips…"
    if ! "$REPO_ROOT/tools/stage-mpv-frameworks.sh"; then
      echo "==> No zips found; building from source (~9 min, one time only)…"
      "$REPO_ROOT/tools/build-mpv-tvos.sh"
      "$REPO_ROOT/tools/stage-mpv-frameworks.sh"
    fi
    if ! have_all "$DEST"; then
      echo "!! Staging did not produce all frameworks in $DEST" >&2
      exit 1
    fi
    seed_cache_from "$DEST"
    echo "✓ Frameworks/mpv staged and cache seeded."
    exit 0
  fi
fi

# 2. Populate this worktree from the cache.
echo "==> Populating Frameworks/mpv from cache ($MODE)"
mkdir -p "$DEST"
rm -rf "$DEST"

case "$MODE" in
  symlink)
    ln -s "$CACHE" "$DEST"
    ;;
  copy)
    cp -R "$CACHE" "$DEST"
    ;;
  clone)
    # APFS copy-on-write clone: instant, ~0 extra disk. Falls back to a real
    # copy on non-APFS / cross-volume targets.
    cp -Rc "$CACHE" "$DEST" 2>/dev/null || cp -R "$CACHE" "$DEST"
    ;;
esac

if have_all "$DEST"; then
  echo "✓ Frameworks/mpv ready (${MODE}) — this worktree can now build EngineMPV."
else
  echo "!! Something went wrong; $DEST is incomplete." >&2
  exit 1
fi
