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
#   * Anything modified in the last ACTIVE_MIN (15) minutes is skipped — protects
#     in-progress builds from parallel agents. Safe to run anytime.
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
set -uo pipefail

DAYS="${RECLAIM_DAYS:-4}"
ACTIVE_MIN="${ACTIVE_MIN:-15}"
DRY=0
DO_EXTRAS=1
LOG="${RECLAIM_LOG:-$HOME/Library/Logs/reclaim-disk.log}"

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DD="${DERIVED_DATA_DIR:-$HOME/Library/Developer/Xcode/DerivedData}"
MCP_WS="$HOME/Library/Developer/XcodeBuildMCP/workspaces"

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

while [ $# -gt 0 ]; do
  case "$1" in
    --days)      DAYS="${2:?--days needs a number}"; shift ;;
    --dry-run)   DRY=1 ;;
    --no-extras) DO_EXTRAS=0 ;;
    -h|--help)   sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
  shift
done

mkdir -p "$(dirname "$LOG")"
say() { echo "$*" | tee -a "$LOG"; }
hr()  { say "------------------------------------------------------------"; }

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
trap 'rm -f "$STALE_REF"' EXIT
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
  if [ "$DRY" -eq 1 ]; then
    say "  would free  ${sz}G  $p   [$reason]"
  else
    rm -rf "$p" && say "  freed  ${sz}G  $p   [$reason]"
  fi
}

# --- 1. DerivedData (orphans + idle) + ModuleCache -----------------------------
say "[1/5] DerivedData (orphans + idle >=${DAYS}d) + ModuleCache"
DD_ARGS=(--module-cache --stale-days "$DAYS")
[ "$DRY" -eq 1 ] && DD_ARGS+=(--dry-run)
if [ -x "$SELF_DIR/prune-deriveddata.sh" ]; then
  ACTIVE_MIN="$ACTIVE_MIN" "$SELF_DIR/prune-deriveddata.sh" "${DD_ARGS[@]}" 2>&1 \
    | sed 's/^/  /' | tee -a "$LOG"
else
  say "  prune-deriveddata.sh not found next to this script — skipping DerivedData"
fi

# --- 2. Worktree-local .build dirs ---------------------------------------------
say "[2/5] Worktree-local .build dirs (idle >=${DAYS}d)"
for root in "${BUILD_ROOTS[@]}"; do
  [ -d "$root" ] || continue
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    wt="$(dirname "$b")"
    if worktree_active "$wt"; then continue; fi
    rm_path "$b" "idle worktree $(basename "$wt")"
  done < <(find "$root" -maxdepth 2 -type d -name .build -prune 2>/dev/null)
done

# --- 3. XcodeBuildMCP workspaces -----------------------------------------------
say "[3/5] XcodeBuildMCP/workspaces (idle >=${DAYS}d)"
if [ -d "$MCP_WS" ]; then
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    rm_path "$d" "MCP workspace idle >=${DAYS}d"
  done < <(find "$MCP_WS" -mindepth 1 -maxdepth 1 -type d -mtime +"$DAYS" 2>/dev/null)
else
  say "  (no XcodeBuildMCP/workspaces dir)"
fi

# --- 4. git worktree prune -----------------------------------------------------
say "[4/5] git worktree prune (stale registrations)"
for repo in "${MAIN_REPOS[@]}"; do
  [ -e "$repo/.git" ] || continue
  if [ "$DRY" -eq 1 ]; then
    out="$(git -C "$repo" worktree prune --dry-run -v 2>/dev/null)"
  else
    out="$(git -C "$repo" worktree prune -v 2>/dev/null)"
  fi
  say "  $(basename "$repo"): ${out:-nothing to prune}"
done

# --- 5. Extras -----------------------------------------------------------------
if [ "$DO_EXTRAS" -eq 1 ]; then
  say "[5/5] Extras: brew cleanup, DeviceSupport trim, unavailable simulators"

  if command -v brew >/dev/null 2>&1; then
    if [ "$DRY" -eq 1 ]; then
      say "  would run: brew cleanup -s ($(du_gb "$(brew --cache 2>/dev/null)")G cache)"
    else
      brew cleanup -s >/dev/null 2>&1 && say "  brew cleanup done"
      c="$(brew --cache 2>/dev/null)"; [ -n "$c" ] && rm -rf "${c:?}/"* 2>/dev/null
    fi
  else
    say "  (brew not found)"
  fi

  # DeviceSupport: keep the 2 newest builds per platform (re-downloads on connect).
  for plat in "tvOS DeviceSupport" "iOS DeviceSupport" "watchOS DeviceSupport"; do
    dir="$HOME/Library/Developer/Xcode/$plat"; [ -d "$dir" ] || continue
    while IFS= read -r old; do
      [ -n "$old" ] || continue
      rm_path "${old%/}" "old $plat (keeping newest 2)"
    done < <(ls -1dt "$dir"/*/ 2>/dev/null | tail -n +3)
  done

  # Simulators whose runtime is no longer installed.
  if command -v xcrun >/dev/null 2>&1; then
    if [ "$DRY" -eq 1 ]; then
      say "  would run: xcrun simctl delete unavailable"
    else
      xcrun simctl delete unavailable >/dev/null 2>&1 && say "  deleted unavailable simulators"
    fi
  fi
else
  say "[5/5] Extras skipped (--no-extras)"
fi

# --- summary -------------------------------------------------------------------
hr
END_AVAIL="$(avail_gb)"
if [ "$DRY" -eq 1 ]; then
  say "DRY RUN — nothing deleted. Free space unchanged at ${END_AVAIL}G."
else
  DELTA=$(( END_AVAIL - START_AVAIL ))
  say "done: ${START_AVAIL}G -> ${END_AVAIL}G free  (reclaimed ~${DELTA}G)"
fi
hr
