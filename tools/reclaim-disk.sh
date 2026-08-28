#!/usr/bin/env bash
#
# reclaim-disk.sh — daily, safe reclaim of rebuildable Xcode/Swift build data
# across ALL of my tvOS/iOS apps (Plozz, Mozz, Twozz) that share one machine.
#
# WHY
#   Every branch/worktree builds into caches that nothing ever cleans up:
#     * ~/Library/Developer/Xcode/DerivedData        (per-worktree, ~2-5 GB each)
#     * <worktree>/.build                            (SwiftPM output, up to ~11 GB)
#     * ~/Library/Developer/XcodeBuildMCP/workspaces (a 2nd DerivedData root)
#   With ~240 worktrees this silently grows to hundreds of GB. Everything this
#   script deletes is a BUILD CACHE that rebuilds on the next compile. It never
#   deletes source code, worktrees, commits, or uncommitted edits.
#
# SAFETY MODEL
#   * A cache is only removed if its SOURCE worktree has been idle >= --days days
#     (default 4) OR the worktree is gone entirely. "Idle" = no source file
#     modified in that window (uncommitted edits count as activity).
#   * Apply runs are single-instance and wait for an Apple-build quiet window.
#     xcodebuild and independent/orphaned build-service/compiler processes are
#     detected directly; every destructive phase and path is rechecked.
#   * Recently modified cache directories are still skipped as extra evidence,
#     but directory mtime is not treated as proof that no build is active.
#   * --dry-run shows exactly what would be freed and deletes nothing.
#
# WHAT IT DOES (in order)
#   1. DerivedData: orphaned + idle folders (via prune-deriveddata.sh --stale-days)
#      and ModuleCache.noindex when it exceeds its size limit.
#   2. Worktree-local .build dirs whose worktree is idle/gone.
#   3. XcodeBuildMCP/workspaces older than --days.
#   4. git worktree prune in each app's main checkout (stale registrations only).
#   5. EXTRAS (skip with --no-extras): brew cleanup, trim old DeviceSupport
#      (keep newest 2 per platform), delete unavailable simulators.
#
# USAGE
#   tools/reclaim-disk.sh                 # aggressive daily reclaim (idle >=4d)
#   tools/reclaim-disk.sh --dry-run       # preview only
#   tools/reclaim-disk.sh --days 7        # gentler: idle >=7d
#   tools/reclaim-disk.sh --no-extras     # build caches only
#
# BUILD GUARD ENVIRONMENT
#   APPLE_BUILD_QUIET_SECONDS  Required no-build interval before apply (default 120).
#   APPLE_BUILD_MAX_WAIT_SECONDS  Maximum wait for quiet (default 900).
#   See docs/disk-reclaim.md for lock/process/open-path details.
#
set -uo pipefail

DAYS="${RECLAIM_DAYS:-4}"
ACTIVE_MIN="${ACTIVE_MIN:-15}"
DRY=0
DO_EXTRAS=1
LOG="${RECLAIM_LOG:-$HOME/Library/Logs/reclaim-disk.log}"

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DD="${DERIVED_DATA_DIR:-$HOME/Library/Developer/Xcode/DerivedData}"
MCP_WS="$HOME/Library/Developer/XcodeBuildMCP/workspaces"
MCP_WS="${MCP_WORKSPACES_DIR:-$MCP_WS}"

# Worktree roots to scan for local .build dirs (parent-of-worktrees and main checkouts).
BUILD_ROOTS=(
  "$HOME/Development/copilot-worktrees/Plozz"
  "$HOME/Development/copilot-worktrees/Mozz"
  "$HOME/Development/copilot-worktrees/Twizz"
  "$HOME/Development/Plozz"
  "$HOME/Development/Mozz"
  "$HOME/Development/Twizz"
)
# Main checkouts for `git worktree prune`.
MAIN_REPOS=(
  "$HOME/Development/Plozz"
  "$HOME/Development/Mozz"
  "$HOME/Development/Twizz"
)

if [ -n "${RECLAIM_BUILD_ROOTS:-}" ]; then
  IFS=: read -r -a BUILD_ROOTS <<< "$RECLAIM_BUILD_ROOTS"
fi
if [ -n "${RECLAIM_MAIN_REPOS:-}" ]; then
  IFS=: read -r -a MAIN_REPOS <<< "$RECLAIM_MAIN_REPOS"
fi

while [ $# -gt 0 ]; do
  case "$1" in
    --days)      DAYS="${2:?--days needs a number}"; shift ;;
    --dry-run)   DRY=1 ;;
    --no-extras) DO_EXTRAS=0 ;;
    -h|--help)   sed -n '2,45p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
  shift
done

mkdir -p "$(dirname "$LOG")"
say() { echo "$*" | tee -a "$LOG"; }
hr()  { say "------------------------------------------------------------"; }
build_guard_log() { say "$*"; }

source "$SELF_DIR/lib/apple-build-guard.sh"

avail_gb() { df -g /System/Volumes/Data 2>/dev/null | awk 'NR==2{print $4}'; }
du_gb()    { du -sk "$1" 2>/dev/null | awk '{printf "%.1f", $1/1048576}'; }

START_AVAIL="$(avail_gb)"
say ""
hr
say "reclaim-disk  $(date '+%Y-%m-%d %H:%M:%S')  days=$DAYS dry=$DRY extras=$DO_EXTRAS"
say "start: ${START_AVAIL}G free on /System/Volumes/Data"
hr

# --- shared idle-detection (mirrors prune-deriveddata.sh) ----------------------
STALE_REF="$(mktemp -t reclaimref)"
cleanup() {
  rm -f "$STALE_REF"
  release_maintenance_lock
}
trap cleanup EXIT
touch -t "$(date -v-"${DAYS}"d +%Y%m%d%H%M.%S 2>/dev/null \
        || date -d "-${DAYS} days" +%Y%m%d%H%M.%S)" "$STALE_REF"

worktree_active() {  # 0/true if any source file under $1 newer than the ref
  local wt="$1"; [ -d "$wt" ] || return 1
  local hit
  hit="$(find "$wt" -type f \
           -not -path '*/.build/*' -not -path '*/.git/*' \
           -not -path '*/DerivedData/*' -not -path '*/.swiftpm/*' \
           -newer "$STALE_REF" -print 2>/dev/null | head -n1)"
  [ -n "$hit" ]
}
recently_active() {  # 0/true if $1 modified within ACTIVE_MIN minutes
  [ -n "$(find "$1" -maxdepth 0 -mmin -"$ACTIVE_MIN" 2>/dev/null)" ]
}
rm_path() {  # $1=path $2=reason
  local p="$1" reason="$2" sz
  sz="$(du_gb "$p")"
  if recently_active "$p"; then
    say "  skip  (active <${ACTIVE_MIN}m)  ${sz}G  $p"; return
  fi
  if [ "$DRY" -ne 1 ] && ! guard_cache_path_for_delete "$p"; then
    destructive_aborted=1
    return
  fi
  if [ "$DRY" -eq 1 ]; then
    say "  would free  ${sz}G  $p   [$reason]"
  else
    if rm -rf "$p"; then
      say "  freed  ${sz}G  $p   [$reason]"
    else
      say "  failed to delete $p; stopping destructive maintenance"
      destructive_aborted=1
    fi
  fi
}

destructive_aborted=0
if [ "$DRY" -ne 1 ] && [ -d "$DD" ] && ! validate_cache_container "$DD"; then
  say "No destructive work performed."
  exit 75
fi
if [ "$DRY" -ne 1 ] && ! begin_destructive_maintenance; then
  say "No destructive work performed."
  exit 75
fi

# --- 1. DerivedData (orphans + idle) + ModuleCache -----------------------------
say "[1/5] DerivedData (orphans + idle >=${DAYS}d) + ModuleCache"
DD_ARGS=(--module-cache --stale-days "$DAYS")
[ "$DRY" -eq 1 ] && DD_ARGS+=(--dry-run)
if [ -x "$SELF_DIR/prune-deriveddata.sh" ]; then
  if [ "$DRY" -eq 1 ]; then
    ACTIVE_MIN="$ACTIVE_MIN" "$SELF_DIR/prune-deriveddata.sh" "${DD_ARGS[@]}" 2>&1 \
      | sed 's/^/  /' | tee -a "$LOG"
  elif ! guard_no_apple_build_activity "before DerivedData phase"; then
    destructive_aborted=1
  else
    ACTIVE_MIN="$ACTIVE_MIN" "$SELF_DIR/prune-deriveddata.sh" "${DD_ARGS[@]}" 2>&1 \
      | sed 's/^/  /' | tee -a "$LOG"
    [ "${PIPESTATUS[0]}" -eq 0 ] || destructive_aborted=1
  fi
else
  say "  prune-deriveddata.sh not found next to this script — skipping DerivedData"
fi

# --- 2. Worktree-local .build dirs ---------------------------------------------
say "[2/5] Worktree-local .build dirs (idle >=${DAYS}d)"
if [ "$DRY" -eq 1 ] || { [ "$destructive_aborted" -eq 0 ] && guard_no_apple_build_activity "before .build phase"; }; then
for root in "${BUILD_ROOTS[@]}"; do
  [ -d "$root" ] || continue
  if [ "$DRY" -ne 1 ] && ! validate_cache_container "$root"; then
    destructive_aborted=1
    break
  fi
  while IFS= read -r b; do
    [ "$destructive_aborted" -eq 0 ] || break
    [ -n "$b" ] || continue
    wt="$(dirname "$b")"
    if worktree_active "$wt"; then continue; fi
    rm_path "$b" "idle worktree $(basename "$wt")"
  done < <(find "$root" -maxdepth 2 -type d -name .build -prune 2>/dev/null)
done
else
  destructive_aborted=1
fi

# --- 3. XcodeBuildMCP workspaces -----------------------------------------------
say "[3/5] XcodeBuildMCP/workspaces (idle >=${DAYS}d)"
if [ "$DRY" -ne 1 ] && { [ "$destructive_aborted" -ne 0 ] || ! guard_no_apple_build_activity "before XcodeBuildMCP phase"; }; then
  destructive_aborted=1
elif [ -d "$MCP_WS" ] && [ "$DRY" -ne 1 ] && ! validate_cache_container "$MCP_WS"; then
  destructive_aborted=1
elif [ -d "$MCP_WS" ]; then
  while IFS= read -r d; do
    [ "$destructive_aborted" -eq 0 ] || break
    [ -n "$d" ] || continue
    rm_path "$d" "MCP workspace idle >=${DAYS}d"
  done < <(find "$MCP_WS" -mindepth 1 -maxdepth 1 -type d -mtime +"$DAYS" 2>/dev/null)
else
  say "  (no XcodeBuildMCP/workspaces dir)"
fi

# --- 4. git worktree prune -----------------------------------------------------
say "[4/5] git worktree prune (stale registrations)"
if [ "$DRY" -eq 1 ] || { [ "$destructive_aborted" -eq 0 ] && guard_no_apple_build_activity "before git worktree prune phase"; }; then
for repo in "${MAIN_REPOS[@]}"; do
  [ -e "$repo/.git" ] || continue
  if [ "$DRY" -eq 1 ]; then
    if ! out="$(git -C "$repo" worktree prune --dry-run -v 2>/dev/null)"; then
      say "  $(basename "$repo"): worktree prune preview failed"
      continue
    fi
  else
    if ! out="$(git -C "$repo" worktree prune -v 2>/dev/null)"; then
      say "  $(basename "$repo"): worktree prune failed; stopping destructive maintenance"
      destructive_aborted=1
      break
    fi
  fi
  say "  $(basename "$repo"): ${out:-nothing to prune}"
done
else
  destructive_aborted=1
fi

# --- 5. Extras -----------------------------------------------------------------
if [ "$DO_EXTRAS" -eq 1 ] && { [ "$DRY" -eq 1 ] || { [ "$destructive_aborted" -eq 0 ] && guard_no_apple_build_activity "before extras phase"; }; }; then
  say "[5/5] Extras: brew cleanup, DeviceSupport trim, unavailable simulators"

  if command -v brew >/dev/null 2>&1; then
    if [ "$DRY" -eq 1 ]; then
      say "  would run: brew cleanup -s ($(du_gb "$(brew --cache 2>/dev/null)")G cache)"
    else
      c="$(brew --cache 2>/dev/null)"
      if [ -n "$c" ] && guard_cache_path_for_delete "$c"; then
        if brew cleanup -s >/dev/null 2>&1; then
          say "  brew cleanup done"
        else
          say "  brew cleanup failed; stopping destructive maintenance"
          destructive_aborted=1
        fi
        if [ "$destructive_aborted" -eq 0 ] && guard_cache_path_for_delete "$c"; then
          if ! find "$c" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null; then
            say "  failed to purge Homebrew cache; stopping destructive maintenance"
            destructive_aborted=1
          fi
        elif [ "$destructive_aborted" -eq 0 ]; then
          destructive_aborted=1
        fi
      else
        destructive_aborted=1
      fi
    fi
  else
    say "  (brew not found)"
  fi

  # DeviceSupport: keep the 2 newest builds per platform (re-downloads on connect).
  for plat in "tvOS DeviceSupport" "iOS DeviceSupport" "watchOS DeviceSupport"; do
    dir="$HOME/Library/Developer/Xcode/$plat"; [ -d "$dir" ] || continue
    while IFS= read -r old; do
      [ "$destructive_aborted" -eq 0 ] || break
      [ -n "$old" ] || continue
      rm_path "${old%/}" "old $plat (keeping newest 2)"
    done < <(ls -1dt "$dir"/*/ 2>/dev/null | tail -n +3)
  done

  # Simulators whose runtime is no longer installed.
  if [ "$destructive_aborted" -eq 0 ] && command -v xcrun >/dev/null 2>&1; then
    if [ "$DRY" -eq 1 ]; then
      say "  would run: xcrun simctl delete unavailable"
    elif guard_no_apple_build_activity "before deleting unavailable simulators"; then
      if xcrun simctl delete unavailable >/dev/null 2>&1; then
        say "  deleted unavailable simulators"
      else
        say "  failed to delete unavailable simulators"
        destructive_aborted=1
      fi
    else
      destructive_aborted=1
    fi
  fi
elif [ "$DO_EXTRAS" -eq 1 ]; then
  destructive_aborted=1
  say "[5/5] Extras skipped because destructive maintenance was aborted"
else
  say "[5/5] Extras skipped (--no-extras)"
fi

# --- summary -------------------------------------------------------------------
hr
END_AVAIL="$(avail_gb)"
if [ "$DRY" -eq 1 ]; then
  say "DRY RUN — nothing deleted. Free space unchanged at ${END_AVAIL}G."
elif [ "$destructive_aborted" -ne 0 ]; then
  say "STOPPED: build/open-path safety check failed; remaining destructive work skipped."
  hr
  exit 75
else
  DELTA=$(( END_AVAIL - START_AVAIL ))
  say "done: ${START_AVAIL}G -> ${END_AVAIL}G free  (reclaimed ~${DELTA}G)"
fi
hr
