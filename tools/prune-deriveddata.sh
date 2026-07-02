#!/usr/bin/env bash
#
# prune-deriveddata.sh — keep per-branch Xcode build data from piling up.
#
# WHY THIS EXISTS
#   Every Plozz worktree builds into the *shared* DerivedData root
#   (~/Library/Developer/Xcode/DerivedData) under its own "<name>-<hash>"
#   folder (~1.3 GB of Swift compilation output each). Nothing deletes those
#   when a branch/worktree is done, so they accumulate to many GB. This script
#   removes the stale ones safely.
#
# WHAT IS *NOT* TOUCHED (the expensive, shared, reusable stuff)
#   * ModuleCache.noindex — the Clang module cache, shared by every worktree.
#     Only trimmed when you pass --module-cache AND it exceeds the size limit.
#   * Any DerivedData folder modified in the last $ACTIVE_MIN minutes — assumed
#     to be an in-progress build (protects parallel agents).
#   (Historical: ~/Library/Caches/plozz-mpv/mpv was the retired mpv/FFmpeg codec
#    cache. mpv is gone; that cache is now an orphaned leftover this script never
#    touches — safe to delete by hand if you want the ~78 MB back.)
#
# MODES
#   (default)        Remove "orphaned" DerivedData: folders whose source
#                    worktree no longer exists on disk. Always safe.
#   --this           Remove DerivedData for the CURRENT worktree ($PWD). Use as
#                    the "branch is done" step right before deleting a worktree.
#   --worktree PATH  Remove DerivedData for the worktree at PATH.
#   --all            Remove every project DerivedData folder (full reset).
#                    Next build is a cold compile. Recently-active folders are
#                    still skipped.
#
# FLAGS
#   --module-cache   Also delete ModuleCache.noindex if it exceeds
#                    ${MODULE_CACHE_LIMIT_GB} GB (it rebuilds on next compile).
#   --dry-run        Print what would be deleted; delete nothing.
#   -h | --help      Show this help.
#
# EXAMPLES
#   tools/prune-deriveddata.sh                 # safe periodic cleanup
#   tools/prune-deriveddata.sh --dry-run       # preview the safe cleanup
#   tools/prune-deriveddata.sh --this          # before removing this worktree
#   tools/prune-deriveddata.sh --all --module-cache   # full reclaim
#
set -euo pipefail

DD="${DERIVED_DATA_DIR:-$HOME/Library/Developer/Xcode/DerivedData}"
ACTIVE_MIN="${ACTIVE_MIN:-15}"                       # skip dirs touched within N min
MODULE_CACHE_LIMIT_GB="${MODULE_CACHE_LIMIT_GB:-10}" # trim ModuleCache above this

MODE="orphans"
TARGET=""
DRY=0
TRIM_MODULE_CACHE=0

usage() { sed -n '2,46p' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --this)        MODE="worktree"; TARGET="$PWD" ;;
    --worktree)    MODE="worktree"; TARGET="${2:?--worktree needs a PATH}"; shift ;;
    --all)         MODE="all" ;;
    --orphans)     MODE="orphans" ;;
    --module-cache) TRIM_MODULE_CACHE=1 ;;
    --dry-run)     DRY=1 ;;
    -h|--help)     usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 1 ;;
  esac
  shift
done

[ -d "$DD" ] || { echo "No DerivedData dir at $DD — nothing to do."; exit 0; }

# Resolve a real absolute path (worktrees may be symlinked).
realpath_safe() { /usr/bin/python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$1" 2>/dev/null || echo "$1"; }
[ -n "$TARGET" ] && TARGET="$(realpath_safe "$TARGET")"

workspace_path_of() {  # echo the WorkspacePath recorded inside a DerivedData dir
  /usr/libexec/PlistBuddy -c 'Print :WorkspacePath' "$1/info.plist" 2>/dev/null || true
}

dir_recently_active() {  # 0 (true) if modified within ACTIVE_MIN minutes
  [ -n "$(find "$1" -maxdepth 0 -mmin -"$ACTIVE_MIN" 2>/dev/null)" ]
}

human() { du -sh "$1" 2>/dev/null | awk '{print $1}'; }

freed=0
deleted=0
remove_dir() {  # $1 = path, $2 = reason
  local d="$1" reason="$2"
  if dir_recently_active "$d"; then
    echo "skip  (active <${ACTIVE_MIN}m)  $(basename "$d")  [$reason]"
    return
  fi
  local sz; sz="$(human "$d")"
  if [ "$DRY" -eq 1 ]; then
    echo "would delete  $sz  $(basename "$d")  [$reason]"
  else
    rm -rf "$d" && echo "deleted  $sz  $(basename "$d")  [$reason]"
    deleted=$((deleted+1))
  fi
}

shopt -s nullglob
for d in "$DD"/*/; do
  d="${d%/}"
  base="$(basename "$d")"
  case "$base" in
    *.noindex) continue ;;   # ModuleCache/CompilationCache/SDKStatCaches handled separately
  esac
  wp="$(workspace_path_of "$d")"
  case "$MODE" in
    all)
      remove_dir "$d" "all"
      ;;
    orphans)
      if [ -n "$wp" ] && [ ! -e "$wp" ]; then
        remove_dir "$d" "orphan: $wp gone"
      fi
      ;;
    worktree)
      wpr="$(realpath_safe "$wp")"
      case "$wpr/" in
        "$TARGET"/*) remove_dir "$d" "worktree $TARGET" ;;
      esac
      ;;
  esac
done

if [ "$TRIM_MODULE_CACHE" -eq 1 ] && [ -d "$DD/ModuleCache.noindex" ]; then
  mc_kb="$(du -sk "$DD/ModuleCache.noindex" 2>/dev/null | awk '{print $1}')"
  limit_kb=$(( MODULE_CACHE_LIMIT_GB * 1024 * 1024 ))
  if [ "${mc_kb:-0}" -gt "$limit_kb" ]; then
    remove_dir "$DD/ModuleCache.noindex" "ModuleCache > ${MODULE_CACHE_LIMIT_GB}GB"
  else
    echo "ModuleCache.noindex under ${MODULE_CACHE_LIMIT_GB}GB ($(human "$DD/ModuleCache.noindex")) — kept."
  fi
fi

if [ "$DRY" -eq 1 ]; then
  echo "Dry run — nothing deleted."
else
  echo "Done. Removed $deleted DerivedData folder(s). Remaining: $(human "$DD")."
fi
